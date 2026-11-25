//
//  AppLockMonitor.swift
//  glance
//
//  Watches which app comes to the front and covers locked ones until the user's face, Touch ID or password opens them.
//

import AppKit
import LocalAuthentication

@MainActor
final class AppLockMonitor: NSObject {
    private var state = AppLockState()
    private let verifier: FaceVerifier
    private let overlay = AppLockOverlayController()
    /// The locked app currently behind the overlay, if any.
    private var pendingApp: NSRunningApplication?
    private var checkTask: Task<Void, Never>?

    init(pipeline: FaceRecognitionPipeline) {
        // Its own camera, not the lock screen's: a late `stop()` on a shared camera can kill a lock-screen scan mid-warm-up.
        verifier = FaceVerifier(camera: CameraManager(), pipeline: pipeline)
        super.init()

        overlay.model.onTouchID = { [weak self] in self?.authenticateWithDeviceOwner() }
        overlay.model.onRetry = { [weak self] in self?.startFaceCheck() }
        overlay.model.onCancel = { [weak self] in self?.cancel(hidingApp: true) }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appDidActivate(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appDidDeactivate(_:)), name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(appDidTerminate(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(lockEverything(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(lockEverything(_:)),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil
        )

        // An app that is already in front when Glance launches never posts an activation.
        DispatchQueue.main.async { [weak self] in
            self?.handleActivation(of: NSWorkspace.shared.frontmostApplication)
        }
    }

    private static func app(from notification: Notification) -> NSRunningApplication? {
        notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    }

    @objc private func appDidActivate(_ notification: Notification) {
        handleActivation(of: Self.app(from: notification))
    }

    @objc private func appDidDeactivate(_ notification: Notification) {
        guard let app = Self.app(from: notification), let bundleID = app.bundleIdentifier else { return }
        state.markDeactivated(bundleID: bundleID, pid: app.processIdentifier, at: Date())
    }

    @objc private func appDidTerminate(_ notification: Notification) {
        guard let app = Self.app(from: notification), let bundleID = app.bundleIdentifier else { return }
        state.markTerminated(bundleID: bundleID)
        if pendingApp?.processIdentifier == app.processIdentifier {
            cancel(hidingApp: false)
        }
    }

    @objc private func lockEverything(_ notification: Notification) {
        state.lockAll()
        if pendingApp != nil {
            cancel(hidingApp: true)
        }
    }

    private func handleActivation(of app: NSRunningApplication?) {
        guard let app, let bundleID = app.bundleIdentifier, bundleID != Bundle.main.bundleIdentifier else { return }
        if let pendingApp {
            guard pendingApp.processIdentifier != app.processIdentifier else { return }
            // The user moved on mid-check: keep the locked app out of sight.
            cancel(hidingApp: true)
        }
        let settings = GlanceSettings.shared
        guard settings.lockedAppBundleIDs.contains(bundleID) else { return }
        if state.needsVerification(bundleID: bundleID, pid: app.processIdentifier, policy: settings.appLockRelockPolicy, now: Date()) {
            begin(app)
        } else {
            state.markActivated(bundleID: bundleID, pid: app.processIdentifier)
        }
    }

    private func begin(_ app: NSRunningApplication) {
        pendingApp = app
        overlay.present(appName: app.localizedName ?? app.bundleIdentifier ?? "", appIcon: app.icon)
        startFaceCheck()
    }

    private func startFaceCheck() {
        checkTask?.cancel()
        overlay.model.phase = .scanning
        checkTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.verifier.verify()
            guard !Task.isCancelled, self.pendingApp != nil else { return }
            switch outcome {
            case .matched:
                self.unlockPendingApp()
            case .notRecognized:
                self.overlay.model.phase = .notRecognized
            case .unavailable:
                self.authenticateWithDeviceOwner()
            }
        }
    }

    private func authenticateWithDeviceOwner() {
        guard let app = pendingApp else { return }
        checkTask?.cancel()
        overlay.model.phase = .authenticating
        let name = app.localizedName ?? ""
        checkTask = Task { [weak self] in
            let context = LAContext()
            let approved = (try? await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Authenticate to open \(name)")
            )) ?? false
            guard let self, !Task.isCancelled, self.pendingApp?.processIdentifier == app.processIdentifier else { return }
            if approved {
                self.unlockPendingApp()
            } else {
                self.overlay.model.phase = .notRecognized
            }
        }
    }

    private func unlockPendingApp() {
        guard let app = pendingApp, let bundleID = app.bundleIdentifier else { return }
        checkTask?.cancel()
        checkTask = nil
        state.markUnlocked(bundleID: bundleID, pid: app.processIdentifier, at: Date())
        pendingApp = nil
        overlay.dismiss()
        _ = app.activate()
    }

    private func cancel(hidingApp: Bool) {
        checkTask?.cancel()
        checkTask = nil
        let app = pendingApp
        pendingApp = nil
        overlay.dismiss()
        if hidingApp {
            _ = app?.hide()
        }
    }
}
