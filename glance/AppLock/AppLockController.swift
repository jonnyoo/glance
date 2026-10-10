//
//  AppLockController.swift
//  glance
//
//  Orchestrates face verification for locked apps.
//

import AppKit
import Foundation
import Combine
import AVFoundation

@Observable @MainActor
final class AppLockController {

    private let watcher = AppLockWatcher()
    private let sessionBook = AppLockSessionBook()
    private var shieldController: AppLockShieldController { AppLockShieldController.shared }

    private(set) var activeApp: NSRunningApplication?
    private var queue: [NSRunningApplication] = []
    var isVerifying: Bool = false

    private var cancellables = Set<AnyCancellable>()
    private var verificationTask: Task<Void, Never>?
    private var hasStarted = false

    init() {
        // Deliberately lightweight — heavy setup deferred to start().
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        setupWatcher()
        setupSystemEventHandling()
        watcher.start()
    }

    func stop() {
        watcher.stop()
        shieldController.dismiss()
        sessionBook.revokeAll()
        activeApp?.hide()
        hasStarted = false
    }

    private var suppressingFocusLossForBundleID: String?

    // MARK: - Watcher Callbacks

    private func setupWatcher() {
        watcher.onLockedAppDetected = { [weak self] app in
            self?.handleLockedAppDetected(app)
        }

        watcher.onBackgroundLocked = { [weak self] app in
            guard let bundleId = app.bundleIdentifier else { return }
            if !(self?.sessionBook.isUnlocked(bundleId) ?? false) {
                app.hide()
            }
        }

        watcher.onAppActivated = { [weak self] bundleId in
            self?.sessionBook.appActivated(bundleId)
        }

        watcher.onFocusLost = { [weak self] bundleId in
            guard let self else { return }
            if self.suppressingFocusLossForBundleID == bundleId {
                return
            }
            self.sessionBook.focusLost(bundleId)
        }

        watcher.onAppTerminated = { [weak self] bundleId in
            self?.sessionBook.revoke(bundleId)
        }
    }

    // MARK: - Verification Flow

    private func handleLockedAppDetected(_ app: NSRunningApplication) {
        guard let bundleId = app.bundleIdentifier else { return }

        if sessionBook.isUnlocked(bundleId) {
            return
        }

        if isVerifying {
            if activeApp != app && !queue.contains(app) {
                queue.append(app)
            }
            return
        }

        startVerification(for: app)
    }

    private func startVerification(for app: NSRunningApplication) {
        isVerifying = true
        activeApp = app
        if let bundleId = app.bundleIdentifier {
            suppressingFocusLossForBundleID = bundleId
        }

        // Steal focus immediately and hide the locked app
        NSApp.activate(ignoringOtherApps: true)
        app.hide()

        // Show the shield with correct API
        let appName = app.localizedName ?? "App"
        let icon = app.icon
        let pid = app.processIdentifier
        shieldController.present(appName: appName, icon: icon, pid: pid)
        shieldController.model.state = .verifying
        shieldController.model.onTryAgain = { [weak self] in self?.retryVerification() }
        shieldController.model.onQuitApp = { [weak self] in self?.quitActiveApp() }

        runFaceVerification()
    }

    private func runFaceVerification() {
        verificationTask?.cancel()

        verificationTask = Task { [weak self] in
            guard let self else { return }

            let status = AVCaptureDevice.authorizationStatus(for: .video)
            if status == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }

            var identities = FaceEnrollmentStore.shared.activeIdentities
            if identities.isEmpty {
                FaceEnrollmentStore.shared.reloadIfUnlocked()
                identities = FaceEnrollmentStore.shared.activeIdentities
            }

            let pipeline = FaceRecognitionPipeline()
            let camera = CameraManager()

            await camera.start()
            let start = Date()
            var success = false

            while Date().timeIntervalSince(start) < 5.0 {
                if Task.isCancelled { break }

                // Wait for a frame
                guard let frame = camera.currentFrame else {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    continue
                }

                // Run recognition on a detached task
                let cgImage = frame.image
                let currentIdentities = identities
                let threshold = GlanceSettings.shared.matchThreshold
                let matched = await Task.detached(priority: .userInitiated) {
                    guard let result = try? await pipeline.recognize(in: cgImage) else { return false }
                    let scored = pipeline.score(result.embedding, against: currentIdentities)
                    return pipeline.bestMatch(in: scored, threshold: threshold) != nil
                }.value

                if matched {
                    success = true
                    break
                }

                try? await Task.sleep(nanoseconds: 120_000_000)
            }

            camera.stop()

            if Task.isCancelled { return }
            success ? handleVerificationSuccess() : handleVerificationFailure()
        }
    }

    private func handleVerificationSuccess() {
        guard let app = activeApp, let bundleId = app.bundleIdentifier else { return }

        let store = LockedAppStore.shared
        let policy = store.apps.first(where: { $0.bundleID == bundleId })?.policy ?? .everyTime
        sessionBook.grant(bundleId, policy: policy)

        shieldController.model.state = .success
        shieldController.dismiss()

        app.unhide()
        app.activate(options: .activateIgnoringOtherApps)

        // Clear focus suppression after a brief debounce to allow unhide/activation events to settle
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.suppressingFocusLossForBundleID = nil
        }

        finishCurrentVerification()
    }

    private func handleVerificationFailure() {
        shieldController.model.state = .failed
    }

    private func retryVerification() {
        shieldController.model.state = .verifying
        runFaceVerification()
    }

    private func quitActiveApp() {
        verificationTask?.cancel()
        activeApp?.hide()
        activeApp?.terminate()
        shieldController.dismiss()
        finishCurrentVerification()
    }

    private func finishCurrentVerification() {
        activeApp = nil
        isVerifying = false

        if let nextApp = queue.first {
            queue.removeFirst()
            startVerification(for: nextApp)
        }
    }

    // MARK: - System Events

    private func setupSystemEventHandling() {
        let center = NSWorkspace.shared.notificationCenter
        let distCenter = DistributedNotificationCenter.default()

        center.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.revokeAllSessions() }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.revokeAllSessions() }
            .store(in: &cancellables)

        center.publisher(for: NSWorkspace.sessionDidResignActiveNotification)
            .sink { [weak self] _ in self?.revokeAllSessions() }
            .store(in: &cancellables)

        distCenter.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .sink { [weak self] _ in self?.revokeAllSessions() }
            .store(in: &cancellables)
    }

    private func revokeAllSessions() {
        sessionBook.revokeAll()
        activeApp?.hide()
        queue.forEach { $0.hide() }
    }
}
