//
//  AppLockCoordinator.swift
//  glance
//
//  Runs App Lock: watches which app comes forward and, for one on the locked list, puts the curtain up over its
//  windows, looks for an enrolled face, and only then lets the app be seen. The decisions live in `AppLockEngine`; this
//  file is the part that touches the real world — workspace notifications in, curtain / camera / hide / reopen out.
//
//  Like Face Unlock itself this is a convenience, not a vault. It works by covering and hiding another app's windows,
//  so it holds only while Glance is running: anyone able to quit Glance can walk around it.
//

import AppKit
import AVFoundation
import LocalAuthentication
import OSLog
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppLockCoordinator {
    /// Everything here happens in reaction to other apps, with no UI of its own to show what it decided — this is the
    /// only trace of why a curtain went up, or didn't.
    private static let log = Logger(subsystem: "com.jonathan.glance", category: "applock")

    /// What the curtain's card is showing. Left in place while the curtain fades out, so the card doesn't blink away
    /// ahead of it, and cleared once it's down.
    private(set) var prompt: AppLockPrompt?

    private var engine = AppLockEngine()
    private let scanner: AppLockFaceScanner
    private let curtain = AppLockCurtainController()

    private var scanTask: Task<Void, Never>?
    private var idleWatchdog: Task<Void, Never>?
    private var reconcileTask: Task<Void, Never>?
    /// The system prompt currently on screen, kept so it can be dismissed if another locked app comes forward.
    private var systemPromptContext: LAContext?
    private var keyMonitor: Any?

    /// Bumped on every raise. Dropping the curtain after an `await` checks it first, so a challenge that started in
    /// the meantime keeps its cover.
    private var curtainToken = 0
    /// Whether the notch's scan animation is currently ours to resolve, and the same guard as above for collapsing it.
    private var isDrivingNotch = false
    private var notchToken = 0

    /// False while another user's session is on screen (fast user switching) — nothing here should react to this
    /// session's apps then.
    private var isSessionActive = true
    private var recentHides: [pid_t: [Date]] = [:]

    /// How long a curtain may sit waiting on the user after a scan has given up. A locked app can come forward on its
    /// own (a notification, another app opening a link in it) with nobody at the keyboard; without this it would
    /// stay in front under its cover until someone came back.
    private static let idleTimeout: Duration = .seconds(60)
    /// Launches and unhides are followed by an activation more often than not; waiting this long lets that land first,
    /// so `reconcile()` doesn't hide an app that's on its way to being challenged.
    private static let reconcileSettleDelay: Duration = .milliseconds(500)
    /// An app that reappears whenever it's hidden (some do, mid-launch or while showing an alert) would otherwise trade
    /// hides with `reconcile()` forever. Past this many in the window it's left alone until it settles.
    private static let hideBudget = (count: 6, window: TimeInterval(10))

    init(pipeline: FaceRecognitionPipeline) {
        scanner = AppLockFaceScanner(pipeline: pipeline)
        curtain.makeCard = { [unowned self] in AnyView(AppLockCardView(coordinator: self)) }
        curtain.onWindowOverview = { [unowned self] in self.windowOverviewOpened() }
        observeWorkspace()
        observeSettings()
        // Deferred: this is built while the app delegate is still being constructed, before there's anywhere to put a
        // window — and nothing needs locking in the first moment of launch.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.applySettings()
        }
    }

    // MARK: - Settings

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeSettings() {
        withObservationTracking {
            let settings = GlanceSettings.shared
            _ = settings.isAppLockEnabled
            _ = settings.lockedApps
            _ = settings.hasCompletedOnboarding
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeSettings()
                self?.applySettings()
            }
        }
    }

    private func applySettings() {
        let settings = GlanceSettings.shared
        // With nothing on the list, or nobody enrolled yet, stay out of the way entirely — first-run onboarding included.
        let isEnabled = settings.isAppLockEnabled && settings.hasCompletedOnboarding && !settings.lockedApps.isEmpty
        apply(engine.configure(isEnabled: isEnabled, lockedBundleIDs: Set(settings.lockedApps.map(\.bundleIdentifier))))
        Self.log.info("settings applied: enabled=\(isEnabled, privacy: .public), apps=\(settings.lockedApps.count, privacy: .public)")
        guard isEnabled else { return }
        curtain.prepare()
        // An app just added to the list may be sitting in plain view.
        scheduleReconcile()
    }

    // MARK: - Workspace events

    private func observeWorkspace() {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [(Notification.Name, Selector)] = [
            (NSWorkspace.didActivateApplicationNotification, #selector(applicationDidActivate(_:))),
            (NSWorkspace.didHideApplicationNotification, #selector(applicationDidHide(_:))),
            (NSWorkspace.didTerminateApplicationNotification, #selector(applicationDidTerminate(_:))),
            // Either can put a locked app's windows on screen without making it frontmost ("Show All", a background launch).
            (NSWorkspace.didLaunchApplicationNotification, #selector(worldMayHaveChanged)),
            (NSWorkspace.didUnhideApplicationNotification, #selector(worldMayHaveChanged)),
            (NSWorkspace.didWakeNotification, #selector(worldMayHaveChanged)),
            (NSWorkspace.willSleepNotification, #selector(lockEverything)),
            (NSWorkspace.screensDidSleepNotification, #selector(lockEverything)),
            (NSWorkspace.sessionDidResignActiveNotification, #selector(sessionDidResignActive)),
            (NSWorkspace.sessionDidBecomeActiveNotification, #selector(sessionDidBecomeActive)),
        ]
        for (name, selector) in workspaceEvents {
            workspace.addObserver(self, selector: selector, name: name, object: nil)
        }

        // Same notifications `LockMonitor` listens to. They're spoofable by any same-user process, which is fine in
        // this direction: the worst a forged one can do is relock.
        let distributed = DistributedNotificationCenter.default()
        let distributedEvents: [(String, Selector)] = [
            ("com.apple.screenIsLocked", #selector(lockEverything)),
            ("com.apple.screensaver.didstart", #selector(lockEverything)),
            ("com.apple.screenIsUnlocked", #selector(worldMayHaveChanged)),
        ]
        for (name, selector) in distributedEvents {
            distributed.addObserver(self, selector: selector, name: Notification.Name(name), object: nil)
        }
    }

    /// Behind the lock screen, or behind another user's session, there's no one to challenge. Whatever comes forward
    /// meanwhile is caught by the `reconcile()` that follows unlock.
    private var canChallenge: Bool {
        isSessionActive && !LockMonitor.isScreenActuallyLocked()
    }

    @objc private func applicationDidActivate(_ notification: Notification) {
        guard canChallenge, let app = Self.application(in: notification) else { return }
        apply(engine.appActivated(Self.describe(app), at: Date()))
    }

    @objc private func applicationDidHide(_ notification: Notification) {
        // Checked rather than trusted: this can be the late report of a hide the app has already come back from.
        guard let app = Self.application(in: notification), app.isHidden else { return }
        apply(engine.appHidden(pid: app.processIdentifier))
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = Self.application(in: notification) else { return }
        recentHides[app.processIdentifier] = nil
        apply(engine.appTerminated(pid: app.processIdentifier))
    }

    @objc private func worldMayHaveChanged() {
        scheduleReconcile()
    }

    @objc private func lockEverything() {
        apply(engine.lockAll())
    }

    @objc private func sessionDidResignActive() {
        isSessionActive = false
        lockEverything()
    }

    @objc private func sessionDidBecomeActive() {
        isSessionActive = true
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reconcileSettleDelay)
            guard let self, !Task.isCancelled else { return }
            self.reconcile()
        }
    }

    private func reconcile() {
        guard engine.isEnabled, canChallenge else { return }
        let workspace = NSWorkspace.shared
        let lockedBundleIDs = engine.lockedBundleIDs
        let running = workspace.runningApplications
            .filter { app in
                guard let bundleID = app.bundleIdentifier, lockedBundleIDs.contains(bundleID) else { return false }
                // `.prohibited` processes never show a window, so there's nothing of theirs to put away.
                return !app.isTerminated && app.activationPolicy != .prohibited
            }
            .map { AppLockEngine.RunningApp(app: Self.describe($0), isHidden: $0.isHidden) }
        apply(engine.reconcile(
            frontmost: workspace.frontmostApplication.map(Self.describe),
            running: running,
            at: Date()
        ))
    }

    private static func application(in notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    private static func describe(_ app: NSRunningApplication) -> AppLockEngine.App {
        AppLockEngine.App(
            pid: app.processIdentifier,
            // Without a bundle identifier it can't be on the list, but it's still an app the user switched to.
            bundleID: app.bundleIdentifier ?? "",
            isRegular: app.activationPolicy == .regular
        )
    }

    private func runningApplication(for app: AppLockEngine.App) -> NSRunningApplication? {
        NSRunningApplication(processIdentifier: app.pid)
    }

    // MARK: - Carrying out effects

    private func apply(_ effects: [AppLockEngine.Effect]) {
        for effect in effects {
            switch effect {
            case .raiseCurtain(let challenge):
                raiseCurtain(for: challenge)
            case .lowerCurtain(let app, let resolution):
                lowerCurtain(over: app, resolution)
            case .hide(let app):
                hide(app)
            case .presentSystemPrompt(let challenge):
                presentSystemPrompt(for: challenge)
            case .cancelSystemPrompt:
                systemPromptContext?.invalidate()
                systemPromptContext = nil
            case .reopen(let app):
                reopen(app)
            }
        }
    }

    private func raiseCurtain(for challenge: AppLockEngine.Challenge) {
        // Cover first, describe second: the app's windows are already on screen by the time this runs.
        curtain.raise(over: challenge.app.pid)
        curtainToken &+= 1
        installKeyMonitor()
        Self.log.info("curtain up for \(challenge.app.bundleID, privacy: .public) (challenge \(challenge.id, privacy: .public))")

        let running = runningApplication(for: challenge.app)
        let listed = GlanceSettings.shared.lockedApps.first { $0.bundleIdentifier == challenge.app.bundleID }
        prompt = AppLockPrompt(
            appName: listed?.name ?? running?.localizedName ?? "This app",
            appIcon: running?.icon ?? listed?.icon ?? NSWorkspace.shared.icon(for: .application),
            offersTouchID: SystemAuthentication.offersTouchID,
            status: .scanning
        )
        beginScan(for: challenge)
    }

    private func lowerCurtain(over app: AppLockEngine.App, _ resolution: AppLockEngine.Resolution) {
        Self.log.info("curtain down for \(app.bundleID, privacy: .public): \(String(describing: resolution), privacy: .public)")
        stopScan()
        switch resolution {
        case .unlocked:
            resolveNotch(success: true)
            // Normally a no-op: the app has been sitting visible under the curtain. If something hid it meanwhile,
            // the curtain would otherwise lift on an app with no windows.
            if let running = runningApplication(for: app), running.isHidden {
                running.unhide()
            }
            dropCurtain()
        case .abandoned:
            dismissNotch()
            dropCurtain()
        case .cancelled:
            dismissNotch()
            prompt?.status = .closing
            let token = curtainToken
            Task { [weak self] in
                await self?.putAway(app)
                guard let self, token == self.curtainToken else { return }
                self.dropCurtain()
                // An app that refused to hide is still frontmost and still locked — this puts the curtain back.
                self.scheduleReconcile()
            }
        }
    }

    /// The key monitor outlives the fade: the panel is still key while it plays, and a keystroke in that moment should
    /// be swallowed like any other rather than reach Glance's own menu. The card is cleared at the same point, so the
    /// next raise can't open on the previous app's name for a frame.
    private func dropCurtain() {
        curtain.lower(animated: true) { [weak self] in
            self?.removeKeyMonitor()
            self?.prompt = nil
        }
    }

    /// Hides `app` and waits for that to take effect, so the curtain is never lifted off windows that are still there.
    /// Gives up after a second rather than leaving the curtain up for an app that won't go.
    private func putAway(_ app: AppLockEngine.App) async {
        guard let running = runningApplication(for: app) else { return }
        running.hide()
        for _ in 0..<40 {
            if running.isHidden || running.isTerminated { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func hide(_ app: AppLockEngine.App) {
        guard let running = runningApplication(for: app), !running.isHidden else { return }
        let now = Date()
        var stamps = (recentHides[app.pid] ?? []).filter { now.timeIntervalSince($0) < Self.hideBudget.window }
        defer { recentHides[app.pid] = stamps }
        guard stamps.count < Self.hideBudget.count else {
            Self.log.error("\(app.bundleID, privacy: .public) keeps reappearing — leaving it visible for now")
            return
        }
        stamps.append(now)
        running.hide()
        Self.log.info("hid \(app.bundleID, privacy: .public)")
    }

    /// Goes through Launch Services rather than `NSRunningApplication.activate()`: it's the same request the Dock makes,
    /// so it unhides, is honoured even though Glance isn't the active app, and relaunches an app that quit meanwhile.
    private func reopen(_ app: AppLockEngine.App) {
        let workspace = NSWorkspace.shared
        guard let url = runningApplication(for: app)?.bundleURL
            ?? workspace.urlForApplication(withBundleIdentifier: app.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration)
    }

    // MARK: - Face scan

    private func isCurtainUp(for challenge: AppLockEngine.Challenge) -> Bool {
        engine.challenge?.id == challenge.id && engine.challenge?.phase == .curtain
    }

    private func beginScan(for challenge: AppLockEngine.Challenge) {
        idleWatchdog?.cancel()
        if let reason = faceUnavailableReason {
            Self.log.info("no scan for challenge \(challenge.id, privacy: .public): \(reason, privacy: .public)")
            prompt?.status = .unavailable(reason)
            startIdleWatchdog(for: challenge)
            return
        }

        prompt?.status = .scanning
        showNotchScan()
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.scanner.scan()
            guard !Task.isCancelled, self.isCurtainUp(for: challenge) else { return }
            self.finishScan(outcome, for: challenge)
        }
    }

    private func finishScan(_ outcome: AppLockFaceScanner.Outcome, for challenge: AppLockEngine.Challenge) {
        Self.log.info("scan for challenge \(challenge.id, privacy: .public): \(String(describing: outcome), privacy: .public)")
        let message: String
        switch outcome {
        case .matched:
            apply(engine.passed(challengeID: challenge.id))
            return
        case .superseded:
            return
        case .wrongFace:
            message = "Face not recognized."
        case .spoofSuspected:
            message = "Couldn't confirm a live face."
        case .noFace:
            message = "No face detected."
        case .cameraUnavailable:
            message = "The camera isn't available."
        }
        prompt?.status = .failed(message)
        resolveNotch(success: false)
        startIdleWatchdog(for: challenge)
    }

    private func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanner.cancel()
        idleWatchdog?.cancel()
        idleWatchdog = nil
    }

    /// Why a scan can't even be attempted right now, or `nil` if it can. Checked up front so the card can say so and
    /// lead with the system prompt, instead of running a camera scan that could only ever fail.
    private var faceUnavailableReason: String? {
        guard SecureCredentialManager.isSessionUnlocked else {
            return "Glance's session is locked, so it can't check your face."
        }
        guard !FaceEnrollmentStore.shared.activeIdentities.isEmpty else {
            return "No enrolled face is switched on."
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            return "Glance doesn't have camera access."
        default:
            return nil
        }
    }

    private func startIdleWatchdog(for challenge: AppLockEngine.Challenge) {
        idleWatchdog?.cancel()
        idleWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard let self, !Task.isCancelled else { return }
            self.apply(self.engine.cancel(challengeID: challenge.id))
        }
    }

    // MARK: - System prompt

    private func presentSystemPrompt(for challenge: AppLockEngine.Challenge) {
        stopScan()
        dismissNotch()
        prompt?.status = .handingOff

        let context = LAContext()
        systemPromptContext = context
        let appName = prompt?.appName ?? "this app"
        let token = curtainToken
        Task { [weak self] in
            // Out of sight first. The system prompt's window level isn't ours to rely on, so the card can't stay up
            // where it might land on top of it — and the app can't be left on show behind it either.
            await self?.putAway(challenge.app)
            guard let self else { return }
            if token == self.curtainToken {
                self.dropCurtain()
            }
            // Superseded while the app was being hidden; the engine has already moved on.
            guard self.engine.challenge?.id == challenge.id else { return }

            let success = await SystemAuthentication.authenticate(reason: "unlock \(appName)", context: context)
            if self.systemPromptContext === context {
                self.systemPromptContext = nil
            }
            Self.log.info("system prompt for challenge \(challenge.id, privacy: .public): \(success ? "passed" : "not passed", privacy: .public)")
            self.apply(self.engine.systemPromptFinished(challengeID: challenge.id, success: success, at: Date()))
        }
    }

    // MARK: - Curtain actions

    func retry() {
        guard let challenge = engine.challenge, challenge.phase == .curtain, case .failed? = prompt?.status else { return }
        beginScan(for: challenge)
    }

    func useSystemPrompt() {
        guard let challenge = engine.challenge else { return }
        apply(engine.systemPromptRequested(challengeID: challenge.id))
    }

    func cancel() {
        guard let challenge = engine.challenge else { return }
        apply(engine.cancel(challengeID: challenge.id))
    }

    /// Mission Control shows every window in miniature, the locked app's included, and the cover can't follow it
    /// there. Asking for an overview of everything else is as good as switching away, so it's handled the same: the
    /// app goes out of sight, and asks again when it's next brought forward.
    private func windowOverviewOpened() {
        Self.log.info("window overview opened under the curtain — putting the app away")
        cancel()
    }

    /// Return does whatever the card is leading with.
    private func performDefaultAction() {
        switch prompt?.status {
        case .failed: retry()
        case .unavailable: useSystemPrompt()
        case .scanning, .handingOff, .closing, nil: break
        }
    }

    // MARK: - Keyboard

    /// While the curtain is up every keystroke that reaches Glance stops here. The card being key already keeps
    /// typing out of the covered app; this is what keeps it out of Glance's own menu — ⌘Q on the card would
    /// otherwise quit Glance and take the curtain with it. An app-level monitor rather than a `keyDown` override on the
    /// panel, because the notch panel can take key too (hover-to-retry) and would bypass a per-window handler.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, !event.isARepeat {
                switch event.keyCode {
                case 53: self.cancel() // Escape
                case 36, 76: self.performDefaultAction() // Return, Enter
                default: break
                }
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        guard let keyMonitor else { return }
        NSEvent.removeMonitor(keyMonitor)
        self.keyMonitor = nil
    }

    // MARK: - Notch animation

    // The scan animation in the notch is borrowed, not owned: the lock-screen flow and onboarding use the same panel.
    // Every call below backs off if either has it, and none of the App Lock flow depends on the animation showing —
    // the curtain's card carries the same information.

    private func showNotchScan() {
        let overlay = NotchOverlayController.shared
        guard GlanceSettings.shared.showUnlockAnimation, !overlay.isArmed, overlay.phase != .onboarding,
              NotchGeometry.preferredScreen() != nil else { return }
        notchToken &+= 1
        // A hover-retry has already put the panel back into its scanning state by the time `retry()` gets here.
        if !(isDrivingNotch && overlay.phase == .scanning) {
            overlay.present(onRetry: { [weak self] in self?.retryFromNotch() })
        }
        isDrivingNotch = true
    }

    /// Hovering a held failure frame restarts the panel's own scanning state before calling back, so if there turns
    /// out to be nothing to retry it has to be put away again — one-shot mode has no timeout of its own.
    private func retryFromNotch() {
        if let challenge = engine.challenge, challenge.phase == .curtain, case .failed? = prompt?.status {
            beginScan(for: challenge)
        } else {
            isDrivingNotch = true
            dismissNotch()
        }
    }

    private func resolveNotch(success: Bool) {
        guard isDrivingNotch else { return }
        // A held failure frame is still ours: it can be hovered to retry, and has to be collapsed if the curtain goes.
        isDrivingNotch = !success
        let overlay = NotchOverlayController.shared
        guard !overlay.isArmed, overlay.phase == .scanning else { return }
        overlay.finish(success: success)
    }

    private func dismissNotch() {
        guard isDrivingNotch else { return }
        isDrivingNotch = false
        let token = notchToken
        Task { [weak self] in
            // Skipped if a new scan has presented the panel again since this was queued.
            guard let self, token == self.notchToken else { return }
            let overlay = NotchOverlayController.shared
            guard !overlay.isArmed, overlay.phase == .scanning || overlay.phase == .failure else { return }
            await overlay.collapse()
        }
    }
}
