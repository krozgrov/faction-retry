import Cocoa
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main struct Tests {
    static var count = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fatalError("FAILED: \(label)") }
        count += 1
    }
    static func word(_ text: String, x: Double = 0.4, y: Double = 0.48) -> ReadWord { ReadWord(text: text, rect: CGRect(x: x, y: y, width: 0.15, height: 0.03)) }
    @MainActor static func fixture(_ lines: [(String, CGFloat, CGFloat)]) -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        NSColor.black.setFill(); NSRect(x: 0, y: 0, width: 1600, height: 1000).fill()
        for (line,x,y) in lines { (line as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont(name: "Georgia-Bold", size: 25) ?? NSFont.systemFont(ofSize: 25), .foregroundColor: NSColor.yellow]) }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])!
    }
    static func main() async throws {
        let finish = word("Finish", x: 0.83, y: 0.03)
        let gameWindow = VisibleWindow(id: 1, frame: CGRect(x: -2800, y: 100, width: 1200, height: 800), layer: 0, alpha: 1)
        let otherMonitor = VisibleWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), layer: 0, alpha: 1)
        let sharingBadge = VisibleWindow(id: 3, frame: CGRect(x: -2780, y: 104, width: 66, height: 20), layer: 0, alpha: 1)
        let clickPoint = CGPoint(x: -1700, y: 850)
        check(WindowHitTest.topWindow(at: clickPoint, windows: [otherMonitor, sharingBadge, gameWindow])?.id == 1, "Other displays and the sharing badge do not cover Finish")
        let blocking = VisibleWindow(id: 4, frame: CGRect(x: -1800, y: 800, width: 200, height: 100), layer: 0, alpha: 1)
        check(WindowHitTest.topWindow(at: clickPoint, windows: [blocking, gameWindow])?.id == 4, "A window actually over the button still blocks a click")
        let transparent = VisibleWindow(id: 5, frame: gameWindow.frame, layer: 0, alpha: 0)
        check(WindowHitTest.topWindow(at: clickPoint, windows: [transparent, gameWindow])?.id == 1, "Invisible windows do not cover the button")
        check(WindowHitTest.topWindow(at: CGPoint(x: 5000, y: 5000), windows: [gameWindow]) == nil, "Off-window points are never treated as the target")
        check(CaptureGeometry.crop(window: CGRect(x: -2880, y: 30, width: 1440, height: 928), display: CGRect(x: -2880, y: 0, width: 1440, height: 960)) == CGRect(x: 0, y: 30, width: 1440, height: 928), "Visible capture maps a negative-coordinate display correctly")
        check(CaptureGeometry.crop(window: CGRect(x: -20, y: 30, width: 1440, height: 800), display: CGRect(x: 0, y: 0, width: 1440, height: 960)) == nil, "A window split across displays is not miscaptured")
        let fullName = word("Full Name", y: 0.92)
        let okay = word("Okay", y: 0.43)
        let imbalance = [word("This faction is currently unavailable on this"), word("ruleset due to population imbalance.", y: 0.45), okay, finish, fullName]
        check(SceneReader.scene(imbalance) == .factionLocked, "Exact observed faction error wins over Finish behind it")
        check(SceneReader.scene([word("ruleset due to population imbalance."), finish, fullName]) == .factionLocked, "Recognized faction text prevents clicking Finish even if Okay was not read")
        var dismiss = DismissalEvidence(expected: .factionLocked)
        check(dismiss.observe(.factionLocked) == .waiting, "Sending Okay is not proof that a dialog closed")
        check(dismiss.observe(.creation) == .waiting, "One clear reading is not enough to confirm dismissal")
        check(dismiss.observe(.factionLocked) == .waiting && dismiss.observe(.creation) == .waiting, "A reappearing dialog resets dismissal confirmation")
        check(dismiss.observe(.creation) == .closed, "Two clear readings confirm the dialog is gone")
        var replacedDialog = DismissalEvidence(expected: .factionLocked)
        check(replacedDialog.observe(.otherError) == .changed, "An unrelated message is never treated as a successful dismissal")
        check(SceneReader.okay([word("Okay", y: 0.43), word("0kay", x: 0.402, y: 0.431)]) != nil, "Two OCR passes of one Okay button remain one control")
        check(SceneReader.okay([word("OIccly", y: 0.43)]) != nil, "Observed gold Okay OCR locates the modal button")
        check(SceneReader.scene([finish, fullName]) == .creation, "Prepared character editor")
        check(SceneReader.scene([word("Create Character", y: 0.05)]) == .unknown, "Create Character on a list is not a final submission")
        check(SceneReader.scene([word("Enter World", y: 0.05), word("Create Character", y: 0.05)]) == .characterList, "Existing list is recognized")
        check(SceneReader.scene([word("Creation of that type of character is currently throttled"), okay, finish]) == .throttled, "Known throttle error")
        check(SceneReader.scene([word("Too many attempts. Please try again later."), okay, finish]) == .throttled, "Too many attempts error")
        check(SceneReader.scene([word("Name is unavailable"), okay, finish]) == .otherError, "Name error pauses instead of reattempting")
        check(SceneReader.scene([word("Something unexpected happened"), okay, finish]) == .otherError, "Unknown modal blocks final submission")
        check(SceneReader.scene([word("You have too many characters on this account"), okay, finish]) == .otherError, "Character slot limits must not trigger throttle recovery")
        check(SceneReader.scene([word("Continue", y: 0.43), finish, fullName]) == .otherError, "A different modal control blocks the editor behind it")
        check(SceneReader.scene([word("You have been disconnected from the server"), okay]) == .disconnected, "Disconnected is distinct from creation failure")
        check(SceneReader.scene([word("Creating character…"), finish]) == .processing, "Pending request never sends another attempt")
        check(SceneReader.okay([okay, word("Okay", x: 0.5)]) == nil, "Ambiguous Okay fails closed")
        check(SceneReader.nameIsVisible("Thecow", words: [word("Thecow", y: 0.9)]), "Prepared name matches")
        check(!SceneReader.nameIsVisible("Thecow", words: [word("Othername", y: 0.9)]), "Different prepared name pauses")
        let play = word("Play", x: 0.55, y: 0.5)
        check(SceneReader.launchButton([play, word("WoW: Forever", x: 0.55, y: 0.6)], product: "WoW: Forever") != nil, "Verified selected launcher variant")
        check(SceneReader.launchButton([play, word("WoW: Forever", x: 0.1, y: 0.9), word("World of Warcraft", x: 0.55, y: 0.6)], product: "WoW: Forever") == nil, "Favorite or headline does not authorize the wrong version")
        let now = Date(timeIntervalSince1970: 10_000)
        var schedule = RetrySchedule()
        check(schedule.remaining(now: now, interval: 120) == 0, "First attempt is due")
        schedule.recordAttempt(at: now)
        check(schedule.remaining(now: now.addingTimeInterval(119), interval: 120) == 1, "No retry before configured duration")
        check(schedule.remaining(now: now.addingTimeInterval(120), interval: 120) == 0, "Due at configured duration")
        check(schedule.remaining(now: now.addingTimeInterval(120), interval: 300) == 180, "Custom duration applies")
        schedule.deferUntil(now.addingTimeInterval(600))
        check(schedule.remaining(now: now.addingTimeInterval(120), interval: 120) == 480, "Throttle cooldown overrides regular interval")
        schedule.deferUntil(now.addingTimeInterval(100))
        check(schedule.notBefore == now.addingTimeInterval(600), "A shorter wait never clears an existing cooldown")
        let restored = try JSONDecoder().decode(RetrySchedule.self, from: JSONEncoder().encode(schedule))
        check(restored == schedule, "Attempt time and cooldown survive a restart")
        var settings = RetrySettings()
        check(settings.cooldown(restartNumber: 1) == 600 && settings.cooldown(restartNumber: 2) == 1200 && settings.cooldown(restartNumber: 3) == 2400, "Repeated throttle recovery backs off")
        check(settings.cooldown(restartNumber: 20) == 86400, "Backoff is bounded")
        settings.intervalSeconds = 0
        check(settings.validationError != nil, "Zero-duration retry rejected")
        settings.intervalSeconds = .nan
        check(settings.validationError != nil, "Invalid duration rejected")
        let listWords = [word("Krozgrov", x: 0.70, y: 0.7), word("Thecow", x: 0.86, y: 0.7)]
        let editorNames = [ReadWord(text: "Full Name", rect: CGRect(x: 0.47, y: 0.94, width: 0.06, height: 0.02)), word("Krozgrov", x: 0.34, y: 0.90), word("Thecow", x: 0.52, y: 0.90)]
        check(SceneReader.preparedName(editorNames + editorNames) == "Krozgrov Thecow", "Duplicate OCR passes preserve both prepared name fields")
        check(SceneReader.preparedName([finish]) == nil, "Unreadable name blocks a submission")
        check(SceneReader.characterNameIsVisible("Krozgrov Thecow", words: [word("Krozgrov Thecow", y: 0.7)]), "Full name recognized as one OCR line")
        check(!SceneReader.characterNameIsVisible("Krozgrov Thecow", words: [word("Krozgrov", y: 0.7), word("Thecow", y: 0.6)]), "Different character rows cannot combine into a full name")
        check(!SceneReader.characterNameIsVisible("Krozgrov Thecow", words: [word("Krozgrov Thecowl", y: 0.7)]), "Similar name is not accepted")
        var consecutive = RunEvidence()
        consecutive.sentAttempt(name: "Krozgrov Thecow")
        check(!consecutive.observe(.characterList, words: listWords), "First matching list alone is insufficient")
        _ = consecutive.observe(.creation, words: editorNames)
        check(!consecutive.observe(.characterList, words: listWords), "Returning to the editor resets success evidence")
        _ = consecutive.observe(.characterList, words: [word("Othername", y: 0.7)])
        check(!consecutive.observe(.characterList, words: listWords) && consecutive.observe(.characterList, words: listWords), "Name mismatch resets the sequence before two matching readings")
        var evidence = RunEvidence()
        check(!evidence.observe(.characterList, words: listWords), "Preexisting list cannot mean creation succeeded")
        evidence.sentAttempt(name: "Krozgrov Thecow")
        check(!evidence.observe(.characterList, words: listWords) && evidence.observe(.characterList, words: listWords), "Success requires two stable list readings after an attempt")
        evidence.resetAfterRestart()
        check(!evidence.observe(.characterList, words: listWords), "Relaunch returning to a list is not a successful creation")
        evidence.sentAttempt(name: "Krozgrov Thecow"); evidence.sawFailure()
        check(!evidence.observe(.characterList, words: listWords), "A rejected attempt does not authorize success detection")
        var delayed = RunEvidence()
        delayed.sentAttempt(name: "Krozgrov Thecow", at: now)
        check(delayed.waitingForResponse(at: now.addingTimeInterval(3)), "The editor may remain visible while a delayed server response is pending")
        check(delayed.waitingForResponse(at: now.addingTimeInterval(29)), "A late faction error is allowed a full response window")
        check(!delayed.waitingForResponse(at: now.addingTimeInterval(30)) && delayed.submissionPending, "Expiry pauses and does not authorize a duplicate submission")
        delayed.sawFailure()
        check(!delayed.waitingForResponse(at: now.addingTimeInterval(5)) && !delayed.submissionPending, "A recognized failure clears the response wait")
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fake = root.appendingPathComponent("FakeReader")
        let helper = root.appendingPathComponent("WoWTextReader")
        let lockDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lockDirectory) }
        let lockPath = lockDirectory.appendingPathComponent("instance.lock")
        var owner: RetryOwnership? = try RetryOwnership(at: lockPath)
        let competitor = Process(); competitor.executableURL = fake; competitor.arguments = ["--ownership", lockPath.path]
        competitor.standardOutput = FileHandle.nullDevice
        try competitor.run(); competitor.waitUntilExit()
        check(competitor.terminationStatus == 73, "A second process cannot acquire the running app's lock")
        withExtendedLifetime(owner) {}
        owner = nil
        let crashedOwner = Process(); crashedOwner.executableURL = fake; crashedOwner.arguments = ["--ownership", lockPath.path, "--hold"]
        let lockReady = Pipe(); crashedOwner.standardOutput = lockReady
        try crashedOwner.run()
        check(String(data: lockReady.fileHandleForReading.availableData, encoding: .utf8) == "locked\n", "A new owner acquires the lock after a normal exit")
        Darwin.kill(crashedOwner.processIdentifier, SIGKILL); crashedOwner.waitUntilExit()
        let recoveredOwner = try RetryOwnership(at: lockPath)
        withExtendedLifetime(recoveredOwner) { check(true, "A crashed app cannot leave a stale ownership lock") }
        let unsafePath = lockDirectory.appendingPathComponent("link.lock")
        try FileManager.default.createSymbolicLink(at: unsafePath, withDestinationURL: lockPath)
        do { _ = try RetryOwnership(at: unsafePath); fatalError("Symlink accepted as a lock") }
        catch { check(true, "The ownership lock refuses a symlink") }
        let large = try await OCRProcess(executableURL: fake, timeout: 5).read(Data())
        check(large.count == 1500, "Large OCR output drains without a blocked pipe")
        do { _ = try await OCRProcess(executableURL: fake, arguments: ["--bad-json"], timeout: 5).read(Data()); fatalError("Bad JSON was accepted") }
        catch { check(true, "Bad OCR output fails safely") }
        let before = Date()
        do { _ = try await OCRProcess(executableURL: fake, arguments: ["--hang"], timeout: 0.3).read(Data()); fatalError("Hung OCR did not time out") }
        catch RetryFailure.ocrTimeout { check(Date().timeIntervalSince(before) < 3, "Hung worker is killed on deadline") }
        let job = Task { try await OCRProcess(executableURL: fake, arguments: ["--hang"], timeout: 10).read(Data(repeating: 1, count: 8_000_000)) }
        try await Task.sleep(nanoseconds: 100_000_000); job.cancel()
        do { _ = try await job.value; fatalError("Cancelled OCR completed") }
        catch is CancellationError { check(true, "Stop cancels and kills OCR promptly") }
        let png = fixture([("Full Name", 700, 930), ("Krozgrov", 550, 885), ("Thecow", 950, 885), ("This faction is currently unavailable on this", 500, 510), ("ruleset due to population imbalance.", 550, 470), ("Okay", 750, 425), ("Finish", 1390, 35)])
        let actual = try await OCRProcess(executableURL: helper, timeout: 12).read(png)
        check(SceneReader.scene(actual) == .factionLocked, "Real OCR recognizes the observed faction message and Okay")
        let ready = fixture([("Full Name", 700, 930), ("Finish", 1390, 35)])
        let recognized = try await OCRProcess(executableURL: helper, timeout: 12).read(ready)
        if SceneReader.scene(recognized) != .creation { FileHandle.standardError.write(Data("Prepared editor OCR: \(recognized)\n".utf8)) }
        check(SceneReader.scene(recognized) == .creation, "Real OCR recognizes the prepared editor")
        print("Passed \(count) checks, including real OCR, timing, recovery guards, cancellation, timeout, and large pipe output.")
    }
}
