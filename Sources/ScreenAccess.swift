import Cocoa
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

enum SessionSafety {
    static var isActive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true &&
            session[kCGSessionLoginDoneKey as String] as? Bool == true &&
            session["CGSSessionScreenIsLocked"] as? Bool != true
    }
    static func requireActive() throws {
        guard isActive else { throw RetryFailure.message("The Mac session is locked or inactive. Unlock it, then press Start to resume.") }
    }
}

struct WindowReading {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let capturedAt: Date
    let words: [ReadWord]
    let imageData: Data
    var scene: GameScene { SceneReader.scene(words) }
}

final class OCRProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var completion: ((Result<[ReadWord], Error>) -> Void)?
    private var finished = false
    private var cancelled = false
    private let executableURL: URL
    private let arguments: [String]
    private let timeout: Double
    init(executableURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/WoWTextReader"), arguments: [String] = [], timeout: Double = 12) {
        self.executableURL = executableURL; self.arguments = arguments; self.timeout = timeout
    }
    private func finish(_ result: Result<[ReadWord], Error>, killWorker: Bool = false) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let handler = completion; completion = nil
        let running = process; lock.unlock()
        if killWorker, let running, running.isRunning { Darwin.kill(running.processIdentifier, SIGKILL) }
        handler?(result)
    }
    func cancel() {
        lock.lock(); cancelled = true; let hasCompletion = completion != nil; lock.unlock()
        if hasCompletion { finish(.failure(CancellationError()), killWorker: true) }
    }
    func read(_ data: Data) async throws -> [ReadWord] {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                completion = { continuation.resume(with: $0) }; lock.unlock()
                let worker = Process()
                worker.executableURL = executableURL; worker.arguments = arguments
                let input = Pipe(); let output = Pipe()
                // A cancelled or timed-out reader can exit during a write. Turn
                // SIGPIPE into a normal write error on this descriptor only.
                guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                    finish(.failure(RetryFailure.message("Could not prepare a cancellable text reader."))); return
                }
                worker.standardInput = input; worker.standardOutput = output; worker.standardError = FileHandle.nullDevice
                lock.lock(); process = worker
                if cancelled { lock.unlock(); finish(.failure(CancellationError())); return }
                do { try worker.run(); lock.unlock() }
                catch { lock.unlock(); finish(.failure(error)); return }
                // Drain output while the worker is running, so a large OCR result
                // cannot fill a pipe and deadlock its termination handler.
                DispatchQueue.global(qos: .userInitiated).async {
                    do { try input.fileHandleForWriting.write(contentsOf: data); try input.fileHandleForWriting.close() }
                    catch { self.finish(.failure(error), killWorker: true) }
                }
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    let result = output.fileHandleForReading.readDataToEndOfFile()
                    worker.waitUntilExit()
                    if worker.terminationStatus == 0 {
                        do { finish(.success(try JSONDecoder().decode([ReadWord].self, from: result))) }
                        catch { finish(.failure(RetryFailure.message("The text reader returned an invalid result."))) }
                    } else { finish(.failure(RetryFailure.message("The text reader stopped unexpectedly. Try Read screen again."))) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    finish(.failure(RetryFailure.ocrTimeout), killWorker: true)
                }
            }
        }, onCancel: { self.cancel() })
    }
}

actor WindowReader {
    func read(pid: pid_t, windowID: CGWindowID? = nil) async throws -> WindowReading {
        try Task.checkCancellation()
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch {
            if (error as NSError).code == -3801 { throw RetryFailure.captureDenied }
            throw RetryFailure.message("Window capture failed: \(error.localizedDescription)")
        }
        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 500 && $0.frame.height > 250 && (windowID == nil || $0.windowID == windowID)
        }) else { throw RetryFailure.message("The selected app has no visible window. Restore it from the Dock, then try again.") }
        guard let display = content.displays.first(where: { CaptureGeometry.crop(window: window.frame, display: $0.frame) != nil }) else {
            throw RetryFailure.message("Keep the game window fully on one display so its visible area can be read accurately.")
        }
        let configuration = SCStreamConfiguration()
        let scale = min(2, 2400 / window.frame.width)
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.sourceRect = CaptureGeometry.crop(window: window.frame, display: display.frame)!
        let capturedAt = Date()
        let image: CGImage
        // Read the composited, visible window area. A desktop-independent
        // capture can omit surfaces/overlays in hardware-rendered games.
        do { image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration) }
        catch {
            if (error as NSError).code == -3801 { throw RetryFailure.captureDenied }
            throw RetryFailure.message("Window capture failed: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw RetryFailure.message("Could not prepare the WoW window for reading.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RetryFailure.message("Could not read the WoW window image.") }
        let words = try await OCRProcess().read(bytes as Data)
        try Task.checkCancellation()
        return WindowReading(id: window.windowID, pid: pid, frame: window.frame, capturedAt: capturedAt, words: words, imageData: bytes as Data)
    }
}

@MainActor enum WindowInput {
    static func activate(_ app: NSRunningApplication) async throws {
        try SessionSafety.requireActive()
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
        if let url = app.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        for _ in 0..<20 {
            try Task.checkCancellation()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RetryFailure.message("WoW could not be brought forward. Select its window and resume.")
    }
    static func click(_ word: ReadWord, reading: WindowReading) async throws {
        try Task.checkCancellation()
        try SessionSafety.requireActive()
        guard Date().timeIntervalSince(reading.capturedAt) < 8 else { throw RetryFailure.message("The screen reading was too old to click reliably. Try Read screen again.") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == reading.pid else { throw RetryFailure.message("Another app took focus. No click was sent.") }
        let point = CGPoint(x: reading.frame.minX + reading.frame.width * word.rect.midX, y: reading.frame.minY + reading.frame.height * (1-word.rect.midY))
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = raw.compactMap { value -> VisibleWindow? in
            guard let id = value[kCGWindowNumber as String] as? UInt32,
                  let bounds = value[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return VisibleWindow(id: id, frame: frame, layer: value[kCGWindowLayer as String] as? Int ?? -1, alpha: value[kCGWindowAlpha as String] as? Double ?? 1)
        }
        guard let top = WindowHitTest.topWindow(at: point, windows: windows), top.id == reading.id else {
            throw RetryFailure.message("Another window covers the button in WoW. No click was sent.")
        }
        let currentFrame = top.frame
        guard abs(currentFrame.minX-reading.frame.minX) < 1, abs(currentFrame.minY-reading.frame.minY) < 1,
              abs(currentFrame.width-reading.frame.width) < 1, abs(currentFrame.height-reading.frame.height) < 1 else {
            throw RetryFailure.message("The WoW window moved after it was read. No click was sent.")
        }
        // Games may cache the pointer position independently of mouse-down.
        let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        move?.setIntegerValueField(.eventSourceUserData, value: InputInterruption.automationMarker)
        move?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 120_000_000)
        try Task.checkCancellation()
        try SessionSafety.requireActive()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == reading.pid else { throw RetryFailure.message("Another app took focus. No click was sent.") }
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left), let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw RetryFailure.message("Could not prepare the click.") }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.setIntegerValueField(.eventSourceUserData, value: InputInterruption.automationMarker)
        up.setIntegerValueField(.eventSourceUserData, value: InputInterruption.automationMarker)
        down.post(tap: .cghidEventTap)
        // A posted mouse-down is always paired with mouse-up, even after Stop.
        try? await Task.sleep(nanoseconds: 60_000_000)
        up.post(tap: .cghidEventTap)
        try Task.checkCancellation()
    }
}
