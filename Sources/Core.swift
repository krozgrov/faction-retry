import Foundation
import CoreGraphics
import Darwin

enum OwnershipFailure: Error { case alreadyRunning, unavailable }

enum InputInterruption {
    static let automationMarker: Int64 = 0x4652545259
    static func shouldPause(marker: Int64, targetIsFrontmost: Bool, pointerInsideTarget: Bool, keyboard: Bool) -> Bool {
        marker != automationMarker && (targetIsFrontmost || (!keyboard && pointerInsideTarget))
    }
}

final class RetryOwnership {
    private let descriptor: Int32
    init(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw OwnershipFailure.unavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            close(descriptor); throw OwnershipFailure.unavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            throw busy ? OwnershipFailure.alreadyRunning : OwnershipFailure.unavailable
        }
        self.descriptor = descriptor
    }
    // Keep the file: unlinking it would allow another process to lock a new
    // inode while this process still owns the old one. Exit releases the lock.
    deinit { close(descriptor) }
}

struct ReadWord: Codable, Equatable {
    var text: String
    var rect: CGRect
    var key: String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
}

enum GameScene: String, Codable {
    case creation = "Character ready"
    case factionLocked = "Faction imbalance"
    case throttled = "Too many attempts"
    case characterList = "Character list"
    case disconnected = "Disconnected"
    case processing = "Waiting for WoW"
    case otherError = "Unrecognized message"
    case unknown = "Screen not recognized"
}

struct VisibleWindow {
    let id: UInt32
    let frame: CGRect
    let layer: Int
    let alpha: Double
}
enum WindowHitTest {
    static func topWindow(at point: CGPoint, windows: [VisibleWindow]) -> VisibleWindow? {
        windows.first { $0.layer >= 0 && $0.alpha > 0.01 && $0.frame.width > 1 && $0.frame.height > 1 && $0.frame.contains(point) }
    }
}
enum CaptureGeometry {
    static func crop(window: CGRect, display: CGRect) -> CGRect? {
        guard display.insetBy(dx: -1, dy: -1).contains(window) else { return nil }
        return window.offsetBy(dx: -display.minX, dy: -display.minY)
    }
}

enum CaptureVisibility {
    static func isClear(id: UInt32, frame: CGRect, windows: [VisibleWindow]) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == id }), frame.width > 0, frame.height > 28 else { return false }
        let current = windows[index].frame
        guard abs(current.minX-frame.minX) < 1, abs(current.minY-frame.minY) < 1,
              abs(current.width-frame.width) < 1, abs(current.height-frame.height) < 1 else { return false }
        // macOS can put its sharing badge over the title bar. It is excluded
        // from the capture filter; any overlap with game content still blocks.
        let content = CGRect(x: frame.minX, y: frame.minY+28, width: frame.width, height: frame.height-28)
        return !windows[..<index].contains {
            $0.layer >= 0 && $0.alpha > 0.01 && $0.frame.width > 1 && $0.frame.height > 1 && content.intersects($0.frame)
        }
    }
}

struct SceneReader {
    static func button(_ keys: [String], in words: [ReadWord], region: CGRect? = nil) -> ReadWord? {
        let matches = words.filter { keys.contains($0.key) && (region == nil || region!.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY))) }
        guard let first = matches.first else { return nil }
        // The full-window and enhanced-dialog passes can see the same control.
        // Distinct controls remain ambiguous and are never selected arbitrarily.
        return matches.dropFirst().allSatisfy { abs($0.rect.midX-first.rect.midX) < 0.03 && abs($0.rect.midY-first.rect.midY) < 0.03 } ? first : nil
    }
    static let bottom = CGRect(x: 0.1, y: 0, width: 0.9, height: 0.23)
    static let middle = CGRect(x: 0.23, y: 0.25, width: 0.54, height: 0.45)
    static func creationButton(_ words: [ReadWord]) -> ReadWord? { button(["finish", "createcharacter"], in: words, region: bottom) }
    static func okay(_ words: [ReadWord]) -> ReadWord? { button(["okay", "ok", "0kay", "oiccly"], in: words, region: middle) }
    static func scene(_ words: [ReadWord]) -> GameScene {
        let central = words.filter { middle.intersects($0.rect) }.map(\.text).joined(separator: " ").lowercased()
        let all = words.map(\.text).joined(separator: " ").lowercased()
        let hasDialog = okay(words) != nil || button(["cancel", "accept", "continue", "reconnect", "retry"], in: words, region: middle) != nil
        if central.contains("population imbalance") || (central.contains("faction") && central.contains("imbalance")) { return .factionLocked }
        let throttle = ["currently throttled", "too many attempts", "too many requests", "too quickly", "rate limit"]
        if hasDialog && throttle.contains(where: central.contains) { return .throttled }
        if central.contains("disconnected") || (central.contains("connection") && central.contains("lost")) { return .disconnected }
        if hasDialog { return .otherError }
        if button(["enterworld"], in: words, region: bottom) != nil { return .characterList }
        if central.contains("creating character") || central.contains("retrieving character") || central.contains("logging in") || central.contains("connecting") { return .processing }
        // On a character list, Create Character opens an editor; it is not a final
        // submission button. Require editor-specific name/customization text.
        let hasEditor = all.contains("full name") || all.contains("customization") || words.contains { $0.key == "fullname" || ($0.key == "name" && $0.rect.midY < 0.35) }
        if creationButton(words) != nil && hasEditor { return .creation }
        return .unknown
    }
    static func nameIsVisible(_ name: String, words: [ReadWord]) -> Bool {
        let expected = name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if expected.isEmpty { return true }
        let visible = words.filter { $0.rect.midY > 0.75 || ($0.rect.midY < 0.3 && $0.key != "createcharacter") }.map(\.key)
        return expected.allSatisfy { visible.contains($0) }
    }
    static func preparedName(_ words: [ReadWord]) -> String? {
        guard let label = words.first(where: { $0.key == "fullname" && $0.rect.midY > 0.8 }) else { return nil }
        let candidates = words.filter {
            (0.3...0.7).contains($0.rect.midX) && $0.rect.midY < label.rect.minY &&
            $0.rect.midY > label.rect.minY - 0.06 && !$0.key.isEmpty
        }.sorted { $0.rect.minX < $1.rect.minX }
        var unique: [ReadWord] = []
        for word in candidates {
            if !unique.contains(where: { $0.key == word.key && abs($0.rect.midX-word.rect.midX) < 0.03 && abs($0.rect.midY-word.rect.midY) < 0.015 }) { unique.append(word) }
        }
        guard let first = unique.first, unique.allSatisfy({ abs($0.rect.midY-first.rect.midY) < 0.015 }) else { return nil }
        return unique.map(\.text).joined(separator: " ")
    }
    static func characterNameIsVisible(_ name: String, words: [ReadWord]) -> Bool {
        let expected = name.split(whereSeparator: \.isWhitespace).map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty }
        guard !expected.isEmpty else { return false }
        // Match the complete name within one OCR line; separate characters on
        // different rows must never combine into a matching full name.
        for anchor in words {
            let row = words.filter { abs($0.rect.midY-anchor.rect.midY) < min($0.rect.height, anchor.rect.height) * 0.5 }.sorted { $0.rect.minX < $1.rect.minX }
            var unique: [ReadWord] = []
            for word in row {
                if !unique.contains(where: { $0.key == word.key && abs($0.rect.midX-word.rect.midX) < 0.03 }) { unique.append(word) }
            }
            let tokens = unique.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map { String($0).lowercased().filter { $0.isLetter || $0.isNumber } } }
            if tokens.count >= expected.count {
                for index in 0...(tokens.count-expected.count) {
                    if Array(tokens[index..<(index+expected.count)]) == expected { return true }
                }
            }
        }
        return false
    }
    static func launchButton(_ words: [ReadWord], product: String) -> ReadWord? {
        guard let play = button(["play"], in: words) else { return nil }
        let required = product.lowercased().filter { $0.isLetter || $0.isNumber }
        // The selected version must be immediately above the Play control.
        // A game name elsewhere in the launcher is insufficient evidence.
        let choices = words.filter { $0.rect.midY > play.rect.midY && $0.rect.midY < play.rect.midY + 0.18 && abs($0.rect.midX-play.rect.midX) < 0.18 }
        guard choices.contains(where: { $0.key == required }) else { return nil }
        return play
    }
}

struct RetrySettings: Codable, Equatable {
    var intervalSeconds: Double = 120
    var cooldownMinutes: Double = 10
    var restartOnThrottle = true
    var maximumRestarts = 3
    var bringForward = true
    var expectedName = ""
    var wowPath = "/Applications/World of Warcraft/_forever_/World of Warcraft.app"
    var launcherPath = "/Applications/Battle.net.app"
    var productLabel = "WoW: Forever"
    var validationError: String? {
        if !intervalSeconds.isFinite || !(5...86400).contains(intervalSeconds) { return "Retry interval must be between 5 seconds and 24 hours." }
        if !cooldownMinutes.isFinite || !(1...1440).contains(cooldownMinutes) { return "Cooldown must be between 1 minute and 24 hours." }
        if !(1...10).contains(maximumRestarts) { return "Maximum restarts must be between 1 and 10." }
        if productLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter the Battle.net game version shown above Play." }
        return nil
    }
    func cooldown(restartNumber: Int) -> TimeInterval {
        min(86400, cooldownMinutes * 60 * pow(2, Double(max(0, restartNumber-1))))
    }
}

struct RetrySchedule: Codable, Equatable {
    var lastAttempt: Date?
    var notBefore: Date?
    func remaining(now: Date, interval: TimeInterval) -> TimeInterval {
        max(0, max(lastAttempt?.addingTimeInterval(interval).timeIntervalSince(now) ?? 0, notBefore?.timeIntervalSince(now) ?? 0))
    }
    mutating func recordAttempt(at date: Date) { lastAttempt = date }
    mutating func deferUntil(_ date: Date) { notBefore = max(notBefore ?? .distantPast, date) }
}

struct RunEvidence {
    var attempts = 0
    var submissionPending = false
    var submittedAt: Date?
    var listReadings = 0
    private(set) var submittedName: String?
    mutating func sentAttempt(name: String, at date: Date = Date()) { attempts += 1; submissionPending = true; submittedAt = date; submittedName = name; listReadings = 0 }
    func waitingForResponse(at now: Date, timeout: TimeInterval = 30) -> Bool {
        submissionPending && submittedAt.map { now.timeIntervalSince($0) < timeout } == true
    }
    mutating func sawFailure() { submissionPending = false; submittedAt = nil; submittedName = nil; listReadings = 0 }
    mutating func observe(_ scene: GameScene, words: [ReadWord]) -> Bool {
        guard submissionPending, scene == .characterList, let name = submittedName,
              SceneReader.characterNameIsVisible(name, words: words) else { listReadings = 0; return false }
        listReadings += 1
        return listReadings >= 2
    }
    mutating func resetAfterRestart() { sawFailure() }
}

enum DismissalResult { case waiting, closed, changed }
struct DismissalEvidence {
    let expected: GameScene
    private var clearReadings = 0
    init(expected: GameScene) { self.expected = expected }
    mutating func observe(_ scene: GameScene) -> DismissalResult {
        if scene == .creation || scene == .characterList {
            clearReadings += 1
            return clearReadings >= 2 ? .closed : .waiting
        }
        clearReadings = 0
        if scene == expected || scene == .processing || scene == .unknown { return .waiting }
        return .changed
    }
}

enum RetryFailure: LocalizedError {
    case message(String)
    case captureDenied
    case ocrTimeout
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .captureDenied: return "Screen access is missing. Use Enable access, then approve this app in macOS."
        case .ocrTimeout: return "Text recognition exceeded 12 seconds. The reader was stopped; no new click was sent."
        }
    }
}
