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
    /// Requires several consecutive below-threshold frames so a single bad-angle read doesn't trigger the failure animation —
    /// and, via `WrongFaceStreak`, a minimum time too, since six frames alone arrive in a fraction of a second.
    private let wrongFaceStreakThreshold = 6

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    /// One-shot per wake: cleared with `hasArmedForCurrentLock` on every new wake and on unlock, not once per lock. An auto-retry
    /// that could itself auto-retry would loop the camera for the whole lock session.
    private var hasAutoRetriedForCurrentWake = false
    /// Set once a typed password leaves the screen locked, and cleared only by a real unlock (by any means). Until then nothing
    /// types it again: resubmitting a stale password just walks loginwindow toward its failed-attempt delays.
    private var hasRejectedPassword = false
    /// Long enough for loginwindow to accept a correct password and drop the lock; a rejected one leaves it locked.
    private let unlockConfirmationTimeout: Duration = .seconds(2)
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
    /// Cap on waiting for the camera's first frame before the scan clock starts anyway — a camera that never delivers still ends.
    private let firstFrameWaitLimit: Duration = .seconds(2)

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
            hasAutoRetriedForCurrentWake = false
            // `isScreenActuallyLocked()` also returns false when the session dictionary is momentarily missing. That is
            // fail-closed for typing, but it would lift the rejected-password block without a real unlock, so only clear it on proof.
            if Self.isScreenConfirmedUnlocked() {
                hasRejectedPassword = false
            }
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else { return }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear both one-shot guards.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentWake = false
            // A retry still pending from before this wake would otherwise restart the camera under the scan this wake arms.
            autoRetryTask?.cancel()
            autoRetryTask = nil
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard isEnabled, !hasArmedForCurrentLock else { return }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else { return }
        // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Automatic" (nil) always resolves.
        guard NotchGeometry.preferredScreen() != nil else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once from Password settings first."
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return
        }
        // Without it nothing can be typed, so a match could only end in a failure — don't spend a camera cycle finding out.
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "Face unlock is on, but Accessibility isn't granted — enable glance in System Settings."
            return
        }
        guard !hasRejectedPassword else {
            statusMessage = "Face unlock is paused: your saved password wasn't accepted. Unlock by typing it, then update it in Password settings."
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
        SceneIlluminator.shared.end()
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
              SecureCredentialManager.hasStoredPassword(),
              KeystrokeInjector.isAccessibilityTrusted(),
              !hasRejectedPassword
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
        // Released here rather than on the success path alone: this function returns from many places (generation checks,
        // camera errors, the first-frame wait, the outcome switch), and the flood light is a global side effect (display
        // brightness raised, a panel over the lock screen). The generation test keeps the intended "a newer cycle owns it
        // now" hand-off — that cycle's own defer releases it.
        defer { if generation == scanGeneration { SceneIlluminator.shared.end() } }

        guard LockMonitor.isScreenActuallyLocked() else { return }

        // `stop()` clears the last frame, but a callback already in flight on the session queue publishes after the clear,
        // so a frame from the previous cycle usually survives into this one. Frame ids only grow, so any other id is new.
        let staleFrameID = camera.currentFrame?.id

        await camera.start()
        guard generation == scanGeneration else { return }

        if let error = camera.errorMessage {
            statusMessage = error
            camera.stop()
            return
        }

        // Shown before the first-frame wait, not after: at the lock screen `activate()` leaves the phase alone, so a hover
        // retry would otherwise hold the failure frame through warm-up, and the space-key and auto-retry guards (which read
        // the phase) would start further cycles on top of this one.
        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.showScanning()
        }

        // `start()` returns before the session has delivered anything, so starting the clock here spent part of a window as
        // short as 3s scanning nothing. Both the overlay timer and the deadline below start once a fresh frame exists (or
        // the wait gives up), so they still expire together, and a camera that never delivers still collapses on that timer.
        let firstFrameDeadline = ContinuousClock.now + firstFrameWaitLimit
        while camera.currentFrame == nil || camera.currentFrame?.id == staleFrameID,
              ContinuousClock.now < firstFrameDeadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard generation == scanGeneration else { return }
            guard LockMonitor.isScreenActuallyLocked() else {
                camera.stop()
                // A real unlock disarms the overlay, but a momentarily missing session dictionary reads the same here and
                // sends no event, so start the timer rather than leave `.scanning` up with nothing to end it.
                if showsUI {
                    NotchOverlayController.shared.startScanTimeout()
                }
                return
            }
        }

        if showsUI {
            NotchOverlayController.shared.startScanTimeout()
        }
        statusMessage = "Looking for your face…"

        let outcome = await observeScanWindow(
            deadline: Date().addingTimeInterval(scanWindowDuration),
            requireOverlayScanning: showsUI,
            staleFrameID: staleFrameID
        )

        // A newer cycle now owns the camera and overlay — leave both alone, and leave the auto-retry one-shot unspent.
        // The illuminator is handed over the same way, by the generation test in this function's `defer`.
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
        case .injectionFailed:
            // No auto-retry: what stopped the typing (Accessibility, a locked session) won't clear itself within the retry delay.
            statusMessage = "Recognized, but the password couldn't be typed: \(pocController.statusMessage)"
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
            }
        case .notAccepted:
            // No auto-retry either: `hasRejectedPassword` already stops any later match from typing it again.
            statusMessage = "Your saved password wasn't accepted — it may have changed. Update it in Glance's Password settings."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
            }
        }
    }

    /// `delay` waits out whatever the overlay is still showing so the retry doesn't start underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard GlanceSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentWake else { return }
        hasAutoRetriedForCurrentWake = true
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
        /// Recognized and live, but nothing was typed — shown as a failure, never as a match.
        case injectionFailed
        /// Typed, but the screen stayed locked (now or on an earlier attempt this lock), so the saved password is presumed stale.
        case notAccepted
    }

    /// Recognition and liveness run concurrently and each latches when it succeeds, so unlock fires the moment the second lands;
    /// liveness never fails the scan by staying undecided, it just keeps scanning until `deadline`.
    /// `requireOverlayScanning` bails early once the overlay's own timeout collapses the UI — only applied when there is an
    /// overlay, since headlessly `phase` never becomes `.scanning` at all.
    /// `staleFrameID` is the previous cycle's leftover frame, which is never scored even if the first-frame wait timed out.
    private func observeScanWindow(deadline: Date, requireOverlayScanning: Bool, staleFrameID: UInt64?) async -> ScanOutcome {
        let livenessEnabled = GlanceSettings.shared.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { GlanceSettings.shared.livenessMode }
        var wrongFaceStreak = WrongFaceStreak(minimumFrames: wrongFaceStreakThreshold, scanWindow: scanWindowDuration)

        /// Cleared the moment a detected face fails to match, so a latched match can't be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        /// Turning liveness off in Settings makes this half permanently ready.
        var livenessConfirmed = !livenessEnabled
        /// Last frame's selected face, passed back so `selectDominantFace` stays on the same person instead of flip-flopping.
        var lastFaceBoundingBox: CGRect?
        /// Cheap way to detect "no new camera frame yet" vs. "fresh frame" — without it a repeat frame would corrupt the liveness motion signal.
        var lastProcessedFrameID = staleFrameID
        /// One-shot per cycle: once the light is on, every later frame reads bright, so this can't be re-derived per frame.
        var hasEngagedNightBoost = false

        while Date() < deadline, !Task.isCancelled,
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            guard LockMonitor.isScreenActuallyLocked() else { return .noResolution }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                // 20ms keeps the liveness window's sample count high while staying close to the camera's native ~33ms cadence.
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            // Night boost: the first dark frame of a cycle switches the display into a flood light for the rest of it.
            // Judged on the raw luma, not the enhanced frame, and independent of animation settings — it's functional,
            // not decorative. The screen must be the one the camera faces, or the light lands behind the user. Not while
            // the saved password is marked rejected: that scan can never type, so the light would only flash the user.
            if !hasEngagedNightBoost,
               !hasRejectedPassword,
               GlanceSettings.shared.nightBoostEnabled,
               frame.meanLuminance < LowLightEnhancer.darknessThreshold,
               let screen = CameraDeviceCatalog.screenForActiveCamera() {
                hasEngagedNightBoost = true
                SceneIlluminator.shared.begin(on: screen)
                statusMessage = "Dark room — lighting up the screen…"
            }

            // Frames captured while the light ramps are bad evidence for both halves: over-exposed highlights read as
            // screen glare to the deny cue, which latches a spoof denial for the rest of the scan, and a half-lit face
            // scores below threshold, which would start the wrong-face streak (WrongFaceStreak.minimumDuration) during the
            // ramp and leave only a moment of lit frames before it gives up. Skip them outright rather than judge them.
            if SceneIlluminator.shared.isSettling {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                // Recognition gets the brightened frame; the deny cues get what the sensor actually saw, so our own
                // gain can neither manufacture nor erase the rectangle a spoofed phone bezel would show.
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.rawImage, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                wrongFaceStreak.reset()
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
                wrongFaceStreak.reset()
                readyMatch = matched
            } else {
                readyMatch = nil
                // Frames that aren't enrollment-grade are skipped inside, without extending or breaking the streak.
                if wrongFaceStreak.recordMismatch(alignmentTier: result.alignmentTier, quality: result.quality, at: Date()) {
                    return .consistentlyWrongFace
                }
            }

            if let readyMatch, livenessConfirmed {
                // Checked here, at the point of typing, as well as before arming: a hover retry starts a cycle without those gates.
                guard !hasRejectedPassword else { return .notAccepted }
                statusMessage = "Recognized — unlocking…"
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                lastOutcome = "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.centroidSimilarity)), \(livenessNote)."
                // Presumed rejected from the moment typing starts, so an overlapping cycle can't submit it again while this one waits.
                hasRejectedPassword = true
                guard await pocController.injectStoredPassword(requireAuthoritativeLock: true) else {
                    // Nothing reached loginwindow, so there's no rejection to remember.
                    hasRejectedPassword = false
                    return .injectionFailed
                }
                guard await screenUnlocksAfterInjection() else { return .notAccepted }
                hasRejectedPassword = false
                return .matched
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return .noResolution
    }

    /// loginwindow reports nothing back about a submitted password; the session actually unlocking is the only proof it was accepted.
    private func screenUnlocksAfterInjection() async -> Bool {
        let deadline = ContinuousClock.now + unlockConfirmationTimeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if Self.isScreenConfirmedUnlocked() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Self.isScreenConfirmedUnlocked()
    }

    /// `LockMonitor.isScreenActuallyLocked()` reads a missing session dictionary as unlocked, which is fail-closed for typing
    /// but fail-open here: it would clear `hasRejectedPassword` for a password loginwindow never accepted. Only a dictionary
    /// that exists, belongs to the session on the console, and doesn't say locked counts as proof. The lock flag has to stay
    /// optional: macOS 26 omits the key entirely while unlocked, so requiring it to read false would leave a rejected password
    /// blocking face unlock until the app restarts.
    private nonisolated static func isScreenConfirmedUnlocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        // Off console (fast user switching, a screen-sharing login) this session isn't the one at the lock screen, so it
        // proves nothing about loginwindow accepting the password. Present and true on a real unlock.
        guard (dict[kCGSessionOnConsoleKey] as? Bool) == true else { return false }
        guard let locked = dict["CGSSessionScreenIsLocked"] else { return true }
        return (locked as? Bool) == false
    }
}
