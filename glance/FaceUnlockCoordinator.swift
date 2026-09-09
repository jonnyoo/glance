//
//  FaceUnlockCoordinator.swift
//  glance
//
//  Connects face recognition to the actual unlock path. Off by default; user opts in after validating accuracy in Face Lab.
//
//  Known limitation: LivenessAnalyzer defeats a photo but not a replayed video (real non-rigid motion looks live) — a successful spoof types the real macOS password.
//

import Foundation
import CoreGraphics
import Observation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()

    /// Persisted via GlanceSettings. Setting to false cancels any in-flight scan and disarms the overlay immediately.
    var isEnabled: Bool {
        didSet {
            GlanceSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { disarmOverlay() }
        }
    }

    /// Kept independent from Face Lab's own `threshold` so tuning the debug tool never silently changes the real unlock gate.
    var matchThreshold: Float {
        didSet { GlanceSettings.shared.matchThreshold = matchThreshold }
    }
    /// Shares its setting with NotchOverlayController's scanning timeout, so the background loop stops in step with the UI collapsing.
    private var scanWindowDuration: TimeInterval {
        TimeInterval(GlanceSettings.shared.faceDetectionSeconds)
    }
    /// Requires several consecutive below-threshold frames so a single bad-angle read doesn't trigger the failure animation.
    private let wrongFaceStreakThreshold = 6

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    /// One-shot per lock session — an auto-retry that could itself auto-retry would loop the camera for the whole lock session.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle bails once superseded (see `runScanCycle(generation:)`).
    private var scanGeneration = 0
    /// When the last scan cycle was armed — collapses a single wake into a single arm (see `.wake` branch of `evaluateTrigger`).
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms of each other; anything in this window counts as the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    /// Held separately from `scanTask` since it's scheduled from inside the scan task it follows — reusing `scanTask` would self-cancel it.
    private var autoRetryTask: Task<Void, Never>?
    /// Gap between headless auto-retries, just to keep the camera from restarting in a tight loop.
    private let headlessRetryDelay: Duration = .seconds(1)

    /// When off, no notch/pill presence at all — every overlay call in this file is conditioned on this rather than just skipping the video.
    private var showsUI: Bool { GlanceSettings.shared.showUnlockAnimation }

    /// Reads the space key on the lock screen for the "On space" trigger; only runs while locked + opted in.
    private let spaceKeyMonitor = SpaceKeyMonitor()

    init(pocController: POCController) {
        self.pocController = pocController
        self.isEnabled = GlanceSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = GlanceSettings.shared.matchThreshold
        spaceKeyMonitor.onSpaceKeyDown = { [weak self] in self?.handleSpaceKeyPress() }
        observeLockAndWakeEvents()
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            // Also tracked so screensaver-stop and display-only wakes still wake this up.
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLockAndWakeEvents()
                // Brief settle delay: CGSession's reported state can lag the true state right after wake.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.evaluateTrigger()
            }
        }
    }

    private func evaluateTrigger() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else { return }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear the one-shot guard.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard isEnabled, !hasArmedForCurrentLock else { return }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else { return }
        // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Main display" (nil) always resolves.
        guard NotchGeometry.preferredScreen() != nil else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once from Password settings first."
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return
        }

        // A deselected trigger means "don't auto-scan for this signal," not "do nothing" — the user can still opt in by hand.
        let shouldAutoScan = GlanceSettings.shared.unlockTriggers.contains(signal)

        // Headless has nothing to arm/hover, so if this signal isn't selected there's nothing to do — and hasArmedForCurrentLock
        // must stay false, or a later selected signal could never fire (nothing else calls arm() to reset it).
        guard showsUI || shouldAutoScan else { return }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        Task { [weak self] in
            // arm() only shows a small closed notch silhouette, so this only needs a brief buffer past the login window's entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.arm(autoScan: shouldAutoScan)
        }
    }

    /// Whether the last arm was recent enough to be part of the same wake burst rather than a new one.
    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// nil for signals that shouldn't arm anything — including a nil `lastEvent`, or the first observation would fire regardless of user selection.
    private func requiredTrigger(for event: LockEventKind?) -> UnlockTrigger? {
        switch event {
        case .wake: return .onWake
        case .screenLocked: return .onLock
        case .screenUnlocked, .willSleep, nil: return nil
        }
    }

    private func disarmOverlay() {
        scanTask?.cancel()
        scanTask = nil
        // Bumping makes any cycle still suspended at `await camera.start()` inert, rather than resuming and re-showing the overlay.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        camera.stop()
        NotchOverlayController.shared.disarm()
        // Covers isEnabled being switched off directly, keeping "disarmed" and "not listening for space" in lockstep.
        spaceKeyMonitor.stop()
    }

    /// Idempotent and safe to call on every lock/wake event. Deliberately does not prompt for Input Monitoring — a missing grant just means "don't listen."
    private func updateSpaceMonitor() {
        let shouldListen = isEnabled
            && GlanceSettings.shared.unlockTriggers.contains(.onSpace)
            && LockMonitor.isScreenActuallyLocked()
            && SpaceKeyMonitor.hasInputMonitoringAccess()
        if shouldListen {
            spaceKeyMonitor.start()
        } else {
            spaceKeyMonitor.stop()
        }
    }

    /// Runs the same gate chain as `evaluateTrigger`, then starts a scan. Independent of `LockMonitor` events, so doesn't touch `hasArmedForCurrentLock`.
    private func handleSpaceKeyPress() {
        guard isEnabled,
              GlanceSettings.shared.unlockTriggers.contains(.onSpace),
              LockMonitor.isScreenActuallyLocked(),
              NotchGeometry.preferredScreen() != nil,
              SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword()
        else { return }

        // Already looking — swallows auto-repeat/double-presses and lets "On wake"/"On lock" override "On space" with no special-casing.
        guard NotchOverlayController.shared.phase != .scanning else { return }

        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // Closed pill/notch already up — expand and scan, like a hover retry.
            startScanCycle()
        } else {
            Task { [weak self] in await self?.arm(autoScan: true) }
        }
    }

    /// Either way the overlay still arms — a deselected trigger only skips the automatic scan, leaving hover-to-start available.
    private func arm(autoScan: Bool) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        guard showsUI else {
            // Headless: evaluateTrigger() already guaranteed autoScan is true here, so this is just "start scanning."
            startScanCycle()
            return
        }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        if autoScan {
            startScanCycle()
        }
    }

    /// Called on arm, and again whenever the overlay hover-activates.
    private func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// `generation` is what makes overlapping cycles safe: `Task.cancel()` is cooperative, so a superseded cycle still runs to the
    /// end of this function, and its global side effects (`camera.stop()` etc.) could otherwise land on the newer cycle instead
    /// of itself. This was a real bug — a superseded `camera.stop()` queued behind the newer cycle's `startRunning()` made the
    /// camera visibly switch on then die mid-warm-up, leaving the surviving cycle polling a dead session and never unlocking.
    private func runScanCycle(generation: Int) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        await camera.start()
        guard generation == scanGeneration else { return }

        if let error = camera.errorMessage {
            statusMessage = error
            camera.stop()
            return
        }

        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.beginScanning()
        }
        statusMessage = "Looking for your face…"

        let outcome = await observeScanWindow(
            deadline: Date().addingTimeInterval(scanWindowDuration),
            requireOverlayScanning: showsUI
        )

        // A newer cycle now owns the camera and overlay — leave both alone, and leave the auto-retry one-shot unspent.
        guard generation == scanGeneration else { return }

        camera.stop()

        switch outcome {
        case .matched:
            // The unlock already happened inside observeScanWindow — this only decides whether anything is shown about it.
            if showsUI {
                NotchOverlayController.shared.finish(success: true)
            }
        case .consistentlyWrongFace:
            statusMessage = "Face not recognized."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Face not recognized — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .spoofSuspected:
            statusMessage = "Couldn't confirm a live face."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Couldn't confirm a live face — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .noResolution:
            statusMessage = "No face detected."
            if showsUI {
                // No explicit collapse call: NotchOverlayController's own scanning timeout fires on the same mark and collapses itself.
                statusMessage = "No face detected — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        }
    }

    /// `delay` waits out whatever the overlay is still showing so the retry doesn't start underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard GlanceSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentLock else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Re-check rather than trust the delay: the user may have unlocked by password or retried manually while this waited.
            guard LockMonitor.isScreenActuallyLocked(), self.isEnabled else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    private enum ScanOutcome {
        case matched
        case consistentlyWrongFace
        /// A deny cue (glare, device rectangle) fired — actively rejected as a spoof regardless of match. Same failure path as `.consistentlyWrongFace`.
        case spoofSuspected
        case noResolution
    }

    /// Recognition and liveness run concurrently and each latches when it succeeds, so unlock fires the moment the second lands;
    /// liveness never fails the scan by staying undecided, it just keeps scanning until `deadline`.
    /// `requireOverlayScanning` bails early once the overlay's own timeout collapses the UI — only applied when there is an
    /// overlay, since headlessly `phase` never becomes `.scanning` at all.
    private func observeScanWindow(deadline: Date, requireOverlayScanning: Bool) async -> ScanOutcome {
        let livenessEnabled = GlanceSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { GlanceSettings.shared.livenessMode }
        var consecutiveWrongFaceFrames = 0

        /// Cleared the moment a detected face fails to match, so a latched match can't be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        /// Turning liveness off in Settings makes this half permanently ready.
        var livenessConfirmed = !livenessEnabled
        /// Last frame's selected face, passed back so `selectDominantFace` stays on the same person instead of flip-flopping.
        var lastFaceBoundingBox: CGRect?
        /// Cheap way to detect "no new camera frame yet" vs. "fresh frame" — without it a repeat frame would corrupt the liveness motion signal.
        var lastProcessedFrameID: UInt64?

        while Date() < deadline, !Task.isCancelled,
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            guard LockMonitor.isScreenActuallyLocked() else { return .noResolution }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                // 20ms keeps the liveness window's sample count high while staying close to the camera's native ~33ms cadence.
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                consecutiveWrongFaceFrames = 0
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Fed regardless of match, so liveness stays a genuinely independent gate rather than one starved by recognition confidence.
            var confirmingCue: LivenessCue?
            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    // Overrides everything, including a match and any confirmation that already happened.
                    lastOutcome = snapshot.decision.denialReason
                    return .spoofSuspected
                case .confirmed(let cue):
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            // `activeIdentities`, not `identities`: someone switched off on the Your Face page stays enrolled but must not unlock.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold)

            if let matched {
                consecutiveWrongFaceFrames = 0
                readyMatch = matched
            } else {
                readyMatch = nil
                consecutiveWrongFaceFrames += 1
                if consecutiveWrongFaceFrames >= wrongFaceStreakThreshold {
                    return .consistentlyWrongFace
                }
            }

            if let readyMatch, livenessConfirmed {
                statusMessage = "Recognized — unlocking…"
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                lastOutcome = "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.centroidSimilarity)), \(livenessNote)."
                await pocController.injectStoredPassword(requireAuthoritativeLock: true)
                return .matched
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return .noResolution
    }
}
