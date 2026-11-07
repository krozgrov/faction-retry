import Cocoa
import SwiftUI
import Combine
import IOKit.pwr_mgt

enum RunPhase: String {
    case idle = "Ready", reading = "Reading WoW", running = "Retrying", waiting = "Waiting", cooling = "Cooling down", restarting = "Restarting WoW", paused = "Paused", needsAccess = "Access needed", complete = "Finished"
    var busy: Bool { [.reading, .running, .waiting, .cooling, .restarting].contains(self) }
}
struct Activity: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
}

@MainActor final class RetryModel: ObservableObject {
    @Published var settings: RetrySettings { didSet { persistSettings() } }
    @Published var phase: RunPhase = .idle
    @Published var message = "Leave your prepared character in WoW. Start will use its current options and name."
    @Published var screen = "Not read yet"
    @Published var countdown = "—"
    @Published var attempts = 0
    @Published var restarts = 0
    @Published var clickAccess = false
    @Published var screenAccess = false
    @Published var activities: [Activity] = []
    @Published var lastReadText = ""
    @Published var lastReadImage: Data?
    private let reader = WindowReader()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var targetWindow: CGWindowID?
    private var schedule: RetrySchedule
    private var evidence = RunEvidence()
    private var powerAssertion: IOPMAssertionID = 0
    private var hasPowerAssertion = false
    private let defaults: UserDefaults
    private let logURL: URL
    private var targetFrame: CGRect?
    private var inputMonitors: [Any] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, logDirectory: URL? = nil, observeUserActivity: Bool = true) {
        self.defaults = defaults
        settings = defaults.data(forKey: "v2.settings").flatMap { try? JSONDecoder().decode(RetrySettings.self, from: $0) } ?? RetrySettings()
        schedule = defaults.data(forKey: "v2.schedule").flatMap { try? JSONDecoder().decode(RetrySchedule.self, from: $0) } ?? RetrySchedule()
        restarts = defaults.integer(forKey: "v2.restarts")
        let directory = logDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WoWRetry")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logURL = directory.appendingPathComponent("activity.log")
        clickAccess = CGPreflightPostEventAccess()
        screenAccess = CGPreflightScreenCaptureAccess()
        record("App opened. No game actions have been sent.")
        if observeUserActivity { installActivityObservers() }
    }
    private func installActivityObservers() {
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged], handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleGlobalInput(event) }
        }) { inputMonitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 47 && event.modifierFlags.intersection([.command, .shift]) == [.command, .shift] { self?.stop("Stopped with Shift–Command–period."); return nil }
            return event
        }) { inputMonitors.append(monitor) }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interrupt("The Mac slept or the session became inactive. Press Start to resume.") }
            })
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt("The Mac was locked. Unlock it, then press Start to resume.") }
        }
    }
    deinit {
        inputMonitors.forEach(NSEvent.removeMonitor)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        if let lockObserver { DistributedNotificationCenter.default().removeObserver(lockObserver) }
    }
    private func handleGlobalInput(_ event: NSEvent) {
        if event.type == .keyDown && event.keyCode == 47 && event.modifierFlags.intersection([.command, .shift]) == [.command, .shift] {
            interrupt("Stopped with Shift–Command–period."); return
        }
        guard phase.busy else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL.resolvingSymlinksInPath()
        let gameURL = URL(fileURLWithPath: settings.wowPath).standardizedFileURL.resolvingSymlinksInPath()
        let launcherURL = URL(fileURLWithPath: settings.launcherPath).standardizedFileURL.resolvingSymlinksInPath()
        let targetIsFrontmost = frontmost == gameURL || (phase == .restarting && frontmost == launcherURL)
        let inside = event.cgEvent.map { targetFrame?.contains($0.location) == true } ?? false
        if InputInterruption.shouldPause(marker: event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0, targetIsFrontmost: targetIsFrontmost, pointerInsideTarget: inside, keyboard: event.type == .keyDown) {
            interrupt("You interacted with the game. Retrying is paused; press Start when you are ready.")
        }
    }
    func interrupt(_ reason: String) {
        guard phase.busy else { return }
        stop(reason)
    }
    func persistSettings() { if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: "v2.settings") } }
    private func persistSchedule() { if let data = try? JSONEncoder().encode(schedule) { defaults.set(data, forKey: "v2.schedule") } }
    func record(_ value: String) {
        activities.insert(Activity(text: value), at: 0)
        if activities.count > 200 { activities.removeLast() }
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(value)\n"
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: logURL) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close() }
    }
    private func set(_ next: RunPhase, _ value: String, log: Bool = true) {
        phase = next; message = value
        if log { record(value) }
    }
    func stop(_ reason: String = "Stopped. Your next-attempt time is retained.") {
        generation += 1; task?.cancel(); task = nil; countdown = "—"
        releaseAwake()
        set(.paused, reason)
    }
    private func finished(_ phase: RunPhase, _ text: String) {
        task = nil; countdown = "—"; releaseAwake(); set(phase, text)
        if phase == .complete { NSSound.beep() }
    }
    private func preventIdleSleep() {
        if !hasPowerAssertion {
            hasPowerAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "WoW character retry in progress" as CFString, &powerAssertion) == kIOReturnSuccess
        }
    }
    private func releaseAwake() { if hasPowerAssertion { IOPMAssertionRelease(powerAssertion); hasPowerAssertion = false } }
    private func game() throws -> NSRunningApplication {
        let wanted = URL(fileURLWithPath: settings.wowPath).standardizedFileURL.resolvingSymlinksInPath()
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == wanted }) else {
            throw RetryFailure.message("Open the selected WoW client in windowed mode and prepare your character first.")
        }
        return app
    }
    private func readGame(activate: Bool) async throws -> WindowReading {
        try SessionSafety.requireActive()
        let app = try game()
        if activate {
            if settings.bringForward || targetWindow == nil { try await WindowInput.activate(app) }
            else if NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier { throw RetryFailure.message("WoW is not active. Select its window, then Start to resume.") }
        }
        let result = try await reader.read(pid: app.processIdentifier, windowID: targetWindow)
        try Task.checkCancellation()
        targetWindow = result.id
        targetFrame = result.frame
        screenAccess = true; screen = result.scene.rawValue
        lastReadText = result.words.map(\.text).joined(separator: "\n")
        lastReadImage = result.imageData
        return result
    }
    func enableAccess() {
        guard !phase.busy else { return }
        // Permissions are requested only through this explicit setup action.
        clickAccess = CGPreflightPostEventAccess() || CGRequestPostEventAccess()
        let capture = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        screenAccess = capture
        if !clickAccess {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else if !capture {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        set(.needsAccess, "Approve WoW Character Retry from Applications in macOS. Then use Read screen to verify access. Start does not open permission settings.")
    }
    func inspect() {
        guard !phase.busy else { return }
        generation += 1; let run = generation; targetWindow = nil
        set(.reading, "Reading your current WoW screen. This test sends no clicks.")
        task = Task {
            do {
                let result = try await readGame(activate: true)
                guard generation == run else { return }
                clickAccess = CGPreflightPostEventAccess()
                finished(.idle, "Detected: \(result.scene.rawValue). Screen reading works. Start verifies whether each click takes effect. No click was sent by this test.")
            } catch is CancellationError { return }
            catch {
                guard generation == run else { return }
                if case RetryFailure.captureDenied = error { screenAccess = false; finished(.needsAccess, error.localizedDescription) }
                else { finished(.paused, error.localizedDescription) }
            }
        }
    }
    func start() {
        guard !phase.busy else { return }
        guard SessionSafety.isActive else { set(.paused, "Unlock your Mac and return to this user session before starting."); return }
        guard AXIsProcessTrusted() else { set(.needsAccess, "Enable Device Control/Accessibility so manual game input can pause retries safely."); return }
        if let invalid = settings.validationError { set(.paused, invalid); return }
        clickAccess = CGPreflightPostEventAccess()
        guard FileManager.default.isExecutableFile(atPath: settings.wowPath + "/Contents/MacOS/World of Warcraft") else { set(.paused, "Choose a valid WoW application in Settings."); return }
        generation += 1; let run = generation; targetWindow = nil; evidence = RunEvidence(); attempts = 0
        preventIdleSleep()
        set(.running, "Reading your prepared character before the first attempt.")
        task = Task { await retryLoop(run: run) }
    }
    private func sleep(_ seconds: Double) async throws { try await Task.sleep(nanoseconds: UInt64(max(0, seconds)*1_000_000_000)); try Task.checkCancellation() }
    private func waitUntilDue(cooling: Bool = false) async throws {
        var remaining = schedule.remaining(now: Date(), interval: settings.intervalSeconds)
        if remaining <= 0 { countdown = "—"; return }
        set(cooling ? .cooling : .waiting, cooling ? "WoW reported too many attempts. Waiting before recovery." : "Faction is still restricted. Waiting for the next attempt.")
        while remaining > 0 {
            countdown = Self.duration(remaining)
            try await sleep(min(1, remaining))
            remaining = schedule.remaining(now: Date(), interval: settings.intervalSeconds)
        }
        countdown = "—"
    }
    static func duration(_ seconds: Double) -> String {
        let value = max(0, Int(ceil(seconds)))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value/3600, (value/60)%60, value%60) }
        return String(format: "%02d:%02d", value/60, value%60)
    }
    private func retryLoop(run: Int) async {
        var unknownSince: Date?
        var firstRead = true
        do {
            while generation == run {
                try Task.checkCancellation()
                let result = try await readGame(activate: true)
                guard generation == run else { return }
                let state = result.scene
                let successConfirmed = evidence.observe(state, words: result.words)
                switch state {
                case .factionLocked:
                    unknownSince = nil
                    evidence.sawFailure()
                    if firstRead && schedule.remaining(now: Date(), interval: settings.intervalSeconds) <= 0 { schedule.deferUntil(Date().addingTimeInterval(settings.intervalSeconds)); persistSchedule() }
                    try await dismissFailure(result, expected: .factionLocked, run: run)
                    firstRead = false
                    try await waitUntilDue()
                case .creation:
                    firstRead = false; unknownSince = nil
                    if evidence.submissionPending {
                        if evidence.waitingForResponse(at: Date()) {
                            phase = .running; message = "Finish was pressed. Waiting for WoW’s response; no additional click will be sent."
                            try await sleep(1)
                            continue
                        }
                        throw RetryFailure.message("WoW has not shown a recognized result within 30 seconds. Paused without pressing Finish again.")
                    }
                    guard SceneReader.nameIsVisible(settings.expectedName, words: result.words) else { throw RetryFailure.message("The optional character-name check does not match the editor. Your options were left untouched.") }
                    if schedule.remaining(now: Date(), interval: settings.intervalSeconds) > 0 { try await waitUntilDue(); continue }
                    guard let button = SceneReader.creationButton(result.words) else { throw RetryFailure.message("The final creation button could not be located.") }
                    guard let fullName = SceneReader.preparedName(result.words) else { throw RetryFailure.message("The character's full name could not be read. Move the pointer away from the name fields and try again.") }
                    // Save a conservative next-attempt time before sending input,
                    // including if Stop or a crash occurs between down and up.
                    schedule.recordAttempt(at: Date().addingTimeInterval(1)); persistSchedule()
                    try await WindowInput.click(button, reading: result)
                    evidence.sentAttempt(name: fullName); attempts = evidence.attempts
                    set(.running, "Attempt \(attempts) sent. Reading WoW’s response…")
                    try await sleep(2)
                case .throttled:
                    firstRead = false; unknownSince = nil
                    evidence.sawFailure()
                    record("Recognized a character-creation throttle message.")
                    schedule.deferUntil(Date().addingTimeInterval(settings.cooldown(restartNumber: restarts+1))); persistSchedule()
                    if settings.restartOnThrottle {
                        guard restarts < settings.maximumRestarts else { throw RetryFailure.message("Reached the automatic restart limit. The cooldown remains in place; check WoW before continuing.") }
                        restarts += 1; defaults.set(restarts, forKey: "v2.restarts")
                        try await recoverThroughLauncher(run: run)
                        return
                    } else {
                        try await dismissFailure(result, expected: .throttled, run: run)
                        try await waitUntilDue(cooling: true)
                    }
                case .characterList:
                    unknownSince = nil
                    if successConfirmed {
                        finished(.complete, "Your character's full name was confirmed on two consecutive character-list readings. Retrying has stopped.")
                        return
                    }
                    if !evidence.submissionPending { finished(.paused, "WoW is at the character list. Prepare your character with its chosen options, then Start. Nothing was created by this run."); return }
                    guard let name = evidence.submittedName, SceneReader.characterNameIsVisible(name, words: result.words) else { throw RetryFailure.message("The character list appeared, but the submitted full name could not be confirmed. Retrying is paused; check your character in WoW.") }
                    try await sleep(1)
                case .otherError:
                    throw RetryFailure.message("WoW displayed a different message. Paused with the dialog intact so you can inspect it.")
                case .disconnected:
                    throw RetryFailure.message("WoW disconnected. Paused; sign back in and prepare the character before resuming.")
                case .processing, .unknown:
                    evidence.listReadings = 0
                    if unknownSince == nil { unknownSince = Date() }
                    if Date().timeIntervalSince(unknownSince!) > 30 { throw RetryFailure.message("WoW has not shown a recognizable result for 30 seconds. Paused without further input.") }
                    phase = .running; message = "Waiting for WoW’s response…"
                    try await sleep(1)
                }
                firstRead = false
            }
        } catch is CancellationError { return }
        catch {
            guard generation == run else { return }
            if case RetryFailure.captureDenied = error { screenAccess = false; finished(.needsAccess, error.localizedDescription) }
            else { finished(.paused, error.localizedDescription) }
        }
    }
    private func dismissFailure(_ initial: WindowReading, expected: GameScene, run: Int) async throws {
        var reading = initial
        for attempt in 1...3 {
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            guard reading.scene == expected, let okay = SceneReader.okay(reading.words) else {
                throw RetryFailure.message("The message is visible, but its Okay button could not be confirmed. Paused with the dialog intact.")
            }
            try await WindowInput.click(okay, reading: reading)
            record("Okay sent (\(attempt)/3). Confirming that the dialog closes…")
            var confirmation = DismissalEvidence(expected: expected)
            let deadline = Date().addingTimeInterval(8)
            repeat {
                try await sleep(0.4)
                reading = try await readGame(activate: true)
                guard generation == run else { throw CancellationError() }
                switch confirmation.observe(reading.scene) {
                case .closed:
                    record("\(expected.rawValue) dialog closed — verified on two readings.")
                    return
                case .changed:
                    throw RetryFailure.message("A different message appeared while closing the dialog. Paused for you to inspect it.")
                case .waiting: break
                }
            } while Date() < deadline
        }
        throw RetryFailure.message("Okay did not close the dialog after three confirmed clicks. Paused without another Finish attempt.")
    }
    private func recoverThroughLauncher(run: Int) async throws {
        let wow = try game()
        set(.restarting, "Throttle detected. Closing the selected WoW client before its cooldown.")
        try Task.checkCancellation()
        guard wow.terminate() else { throw RetryFailure.message("WoW did not accept a normal quit request. Close it manually; no force-quit was attempted.") }
        for _ in 0..<30 {
            if wow.isTerminated { break }
            try await sleep(1)
        }
        guard wow.isTerminated else { throw RetryFailure.message("WoW is still running after 30 seconds. Check for a quit dialog, then resume manually.") }
        targetWindow = nil; evidence.resetAfterRestart()
        record("WoW closed normally. Your retry time remains saved.")
        try await waitUntilDue(cooling: true)
        try Task.checkCancellation()
        guard generation == run else { return }
        set(.restarting, "Opening Battle.net. Checking the selected game version before Play.")
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        let launcher = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: settings.launcherPath), configuration: config)
        try Task.checkCancellation()
        try await WindowInput.activate(launcher)
        var clickedPlay = false
        var lastError: Error?
        for _ in 0..<15 {
            try Task.checkCancellation()
            do {
                let result = try await reader.read(pid: launcher.processIdentifier)
                guard let play = SceneReader.launchButton(result.words, product: settings.productLabel) else {
                    lastError = RetryFailure.message("Battle.net must show \(settings.productLabel) directly above Play. Select the correct version, then resume.")
                    try await sleep(2); continue
                }
                try await WindowInput.activate(launcher)
                // Re-read after activation, so coordinates and the selected product
                // are verified immediately before sending the Play click.
                let fresh = try await reader.read(pid: launcher.processIdentifier, windowID: result.id)
                guard let confirmed = SceneReader.launchButton(fresh.words, product: settings.productLabel), confirmed.key == play.key else { throw RetryFailure.message("Battle.net changed before Play. Paused for you to check it.") }
                try await WindowInput.click(confirmed, reading: fresh)
                clickedPlay = true; record("Clicked Play in Battle.net for the verified game version."); break
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error; try await sleep(2) }
        }
        guard clickedPlay else { throw lastError ?? RetryFailure.message("Battle.net’s Play control was not available.") }
        set(.restarting, "Battle.net launched WoW. Waiting for the selected client…")
        for second in 0..<180 {
            try Task.checkCancellation()
            if (try? game()) != nil {
                record("The selected WoW client is running again.")
                finished(.paused, "WoW relaunched through Battle.net. Restore your current character options and name if needed, then Start. No character choices were guessed or changed.")
                return
            }
            countdown = Self.duration(Double(180-second)); try await sleep(1)
        }
        throw RetryFailure.message("WoW did not appear within three minutes after Play. Check Battle.net for a login, update, or error.")
    }
    func chooseWoW() {
        let panel = NSOpenPanel(); panel.title = "Choose the WoW client to retry"; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url { settings.wowPath = url.path }
    }
    func showLog() { NSWorkspace.shared.activateFileViewerSelecting([logURL]) }
    func resetRecoveryCounter() {
        guard !phase.busy else { return }
        restarts = 0; defaults.set(0, forKey: "v2.restarts")
        record("Recovery counter reset manually. Existing attempt and cooldown timers were retained.")
    }
}

struct RetryView: View {
    @ObservedObject var model: RetryModel
    @State private var showAdvanced = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WORLD OF WARCRAFT").font(.system(size: 11, weight: .bold)).tracking(2).foregroundStyle(.secondary)
                        Text("Character Retry").font(.system(size: 31, weight: .semibold))
                        Text("Keep your character. Wait for an opening.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 35, weight: .light)).foregroundStyle(.blue).padding(.top, 10)
                }
                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Circle().fill(model.phase == .complete ? Color.green : model.phase.busy ? Color.blue : Color.orange).frame(width: 8, height: 8)
                        Text(model.phase.rawValue.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.4)
                        Spacer()
                        Text(model.countdown).font(.system(size: 25, weight: .medium, design: .monospaced))
                    }
                    Text(model.message).font(.system(size: 15)).fixedSize(horizontal: false, vertical: true).frame(minHeight: 40, alignment: .topLeading)
                    Divider()
                    HStack(spacing: 30) {
                        metric("ATTEMPTS", "\(model.attempts)")
                        metric("RESTARTS", "\(model.restarts)")
                        metric("SCREEN", model.screen)
                        Spacer()
                    }
                }.padding(18).background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
                HStack(spacing: 12) {
                    Button(model.phase.busy ? "Stop" : "Start") { if model.phase.busy { model.stop() } else { model.start() } }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.return, modifiers: [])
                    Button("Read screen") { model.inspect() }.disabled(model.phase.busy).controlSize(.large)
                    if model.phase == .needsAccess || !model.screenAccess {
                        Button("Enable access") { model.enableAccess() }.disabled(model.phase.busy).controlSize(.large)
                    }
                    Spacer()
                    Text("Shift–⌘–. to stop").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 15) {
                    Text("RETRY SETTINGS").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                    HStack {
                        Text("Time between attempts")
                        Spacer()
                        TextField("120", value: $model.settings.intervalSeconds, format: .number).frame(width: 80).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        Text("seconds").foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
                    }
                    Toggle("Relaunch WoW through Battle.net after a throttle error", isOn: $model.settings.restartOnThrottle)
                    if model.settings.restartOnThrottle {
                        HStack {
                            Text("Wait before relaunching")
                            Spacer()
                            TextField("10", value: $model.settings.cooldownMinutes, format: .number).frame(width: 80).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                            Text("minutes").foregroundStyle(.secondary).frame(width: 65, alignment: .leading)
                        }
                        Text("Repeated throttle errors get a longer cooldown. A restart can clear unfinished customization; the app pauses for you to restore it before resuming.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    DisclosureGroup("More settings", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 13) {
                            Toggle("Bring WoW forward when an attempt is due", isOn: $model.settings.bringForward)
                            HStack { Text("Maximum automatic restarts before reset"); Spacer(); Stepper("\(model.settings.maximumRestarts)", value: $model.settings.maximumRestarts, in: 1...10).frame(width: 100) }
                            if model.restarts > 0 { Button("Reset recovery counter (keep cooldown)") { model.resetRecoveryCounter() } }
                            HStack { Text("Optional name check"); TextField("Leave blank to use the prepared character", text: $model.settings.expectedName).textFieldStyle(.roundedBorder) }
                            HStack { Text("Battle.net game version"); TextField("WoW: Forever", text: $model.settings.productLabel).textFieldStyle(.roundedBorder) }
                            HStack { VStack(alignment: .leading) { Text("Selected WoW client"); Text(model.settings.wowPath).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled) }; Spacer(); Button("Choose…") { model.chooseWoW() } }
                        }.padding(.top, 12)
                    }
                }.disabled(model.phase.busy)
                Divider()
                HStack { Text("ACTIVITY").font(.system(size: 11, weight: .bold)).tracking(1.2).foregroundStyle(.secondary); Spacer(); Button("Show log") { model.showLog() }.buttonStyle(.link) }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.activities.prefix(8)) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Text(item.time, style: .time).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                            Text(item.text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                DisclosureGroup("What the app sees (no clicks)") {
                    VStack(alignment: .leading, spacing: 10) {
                        if let data = model.lastReadImage, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 320).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Text(model.lastReadText.isEmpty ? "Use Read screen to inspect WoW without pressing buttons." : model.lastReadText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 8)
                }
                Text("Reads the visible game or Battle.net window area. Screens stay in memory and are never uploaded. Unknown errors pause the run. Your chosen character options are never edited.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(28)
        }.frame(minWidth: 680, minHeight: 690)
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).tracking(1); Text(value).font(.system(size: 13, weight: .medium)) }
    }
}

@MainActor final class RetryDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var model: RetryModel!
    private var ownership: RetryOwnership?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WoWRetry")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            ownership = try RetryOwnership(at: directory.appendingPathComponent("instance.lock"))
        } catch OwnershipFailure.alreadyRunning {
            NSWorkspace.shared.runningApplications.first(where: {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.bundleIdentifier == Bundle.main.bundleIdentifier
            })?.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not reserve the retry app"
            alert.informativeText = "The app cannot safely start without its single-instance lock. Check access to its Application Support folder."
            alert.runModal(); NSApp.terminate(nil)
            return
        }
        model = RetryModel()
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root); let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit WoW Character Retry", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); root.submenu = submenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "WoW Character Retry"; window.minSize = NSSize(width: 700, height: 600)
        window.contentView = NSHostingView(rootView: RetryView(model: model))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.stop("App closed. No further game input will be sent.") }
}

#if !RETRY_TESTS
@main struct RetryApplication {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared; let delegate = RetryDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        }
    }
}
#endif
