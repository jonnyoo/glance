//
//  FaceUnlockCoordinator.swift
//  glance
//
//  Milestone G: connects face recognition to the actual unlock path — the
//  one piece deliberately kept separate through every prior stage of this
//  project. Off by default (`isEnabled = false`); the user opts in only
//  after validating accuracy in Face Lab.
//
//  Delegates the actual keystroke injection to the existing, already-tested
//  `POCController.injectStoredPassword(requireAuthoritativeLock:)` — this
//  coordinator only decides *whether* to unlock (confident + live match),
//  never how. Mirrors POCController's own lock/wake observation pattern
//  (`withObservationTracking`, re-subscribing on every change) with its own
//  `LockMonitor` instance, since the two are deciding different things from
//  the same signal.
//
//  Drives the overlay in its "armed" mode (see NotchOverlayController): once
//  the screen locks and the feature is on, the overlay stays up for the
//  whole lock session — closed and hover-wakeable when idle, open while
//  actively scanning — until the screen unlocks or the feature is disabled.
//
//  Known limitation, surfaced in the UI, not just here: a MacBook webcam has
//  no depth sensor. `LivenessMonitor` defeats a static printed photo but not
//  a video replay — weaker than iPhone Face ID. A successful spoof here
//  types the real macOS password.
//

import Foundation
import Observation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()

    /// Off by default (until GlanceSettings has persisted otherwise).
    /// Setting this to false cancels any in-flight scan and disarms the
    /// overlay immediately. Persisted via GlanceSettings — previously this
    /// reset to `false` on every launch since nothing wrote it anywhere.
    var isEnabled: Bool {
        didSet {
            GlanceSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { disarmOverlay() }
        }
    }

    /// Raw cosine threshold — kept independent from Face Lab's own
    /// `threshold` (not read from it) so tuning the debug tool never
    /// silently changes the real unlock gate. Persisted via GlanceSettings.
    var matchThreshold: Float {
        didSet { GlanceSettings.shared.matchThreshold = matchThreshold }
    }
    private let minMargin: Float = 0.05
    /// Each scan cycle runs for this long looking for either a confident
    /// live match or a consistently-wrong face before giving up quietly.
    /// Both this and NotchOverlayController's own scanning timeout read the
    /// same setting, which is what keeps the background loop stopping in
    /// step with the UI collapsing.
    private var scanWindowDuration: TimeInterval {
        TimeInterval(GlanceSettings.shared.faceDetectionSeconds)
    }
    /// A face that scores below threshold for this many *consecutive*
    /// frames is treated as "confidently a different person" and shows the
    /// failure animation — a single bad-angle frame from the right person
    /// shouldn't trigger it, so this requires it to persist.
    private let wrongFaceStreakThreshold = 6

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    /// One-shot per lock session, like `hasArmedForCurrentLock` — an
    /// auto-retry that could itself auto-retry would loop the camera for the
    /// whole time the Mac sits locked.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`. A cycle checks this after each
    /// suspension point and bails the moment it's been superseded — see
    /// `runScanCycle(generation:)` for why cancellation alone isn't enough.
    private var scanGeneration = 0
    /// When the last scan cycle was armed, used to collapse a single wake
    /// into a single arm — see the `.wake` branch of `evaluateTrigger`.
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open emits several wake signals within a few hundred ms of
    /// each other (`LockMonitor` records `.wake` for `screensDidWake`,
    /// `didWake`, *and* `screensaver.didstop`). Anything arriving inside
    /// this window is treated as the same wake rather than a new one.
    private let rearmDebounce: Duration = .seconds(2)
    /// The pending auto-retry, held separately from `scanTask` because it's
    /// scheduled *from inside* the scan task it follows — reusing `scanTask`
    /// would have that task cancel itself before the retry ever ran.
    private var autoRetryTask: Task<Void, Never>?
    /// Gap between attempts when auto-retrying with no UI up — there's no
    /// held failure frame or collapse animation to wait out headlessly, so
    /// this just keeps the camera from restarting in a tight loop.
    private let headlessRetryDelay: Duration = .seconds(1)

    /// Whether this scan cycle should touch the notch/pill overlay at all.
    /// When "Show animation" is off, the whole point is that nothing is
    /// shown — not a silent version of the same UI, no notch/pill presence
    /// whatsoever — so every overlay call in this file is conditioned on
    /// this rather than just skipping the video.
    private var showsUI: Bool { GlanceSettings.shared.showUnlockAnimation }

    /// Reads the space key on the lock screen for the "On space" trigger.
    /// Only ever running while locked + opted in (see `updateSpaceMonitor`).
    private let spaceKeyMonitor = SpaceKeyMonitor()

    init(pocController: POCController) {
        self.pocController = pocController
        self.isEnabled = GlanceSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = GlanceSettings.shared.matchThreshold
        spaceKeyMonitor.onSpaceKeyDown = { [weak self] in self?.handleSpaceKeyPress() }
        observeLockAndWakeEvents()
    }

    /// Re-subscribes on every change, matching the pattern used by
    /// `POCController.observeLockAndWakeEvents` — `withObservationTracking`
    /// only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            // Also tracked so screensaver-stop and display-only wakes —
            // neither of which touches the three above — still wake this up.
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLockAndWakeEvents()
                // Brief settle delay: right after wake, CGSession's
                // reported state can lag the true state by a beat — same
                // reasoning as POCController's own auto-inject path.
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

        // The Mac waking up — real sleep, display sleep, or the screensaver
        // stopping, `.wake` covers all three (see `LockEventKind.wake`) — is
        // an explicit "let me back in," so clear the one-shot guard even if
        // an earlier attempt this lock session already came and went.
        //
        // `isWithinRecentArmBurst` is what keeps *one* lid-open from doing
        // that two or three times: those three signals all fire for a single
        // wake, a few hundred ms apart, and clearing the guard for each of
        // them armed and started a fresh scan cycle every time — cycles that
        // then fought each other over the one shared camera session.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Kept current on every lock/wake event, and before the
        // `hasArmedForCurrentLock` guard below so it isn't skipped once armed
        // — the space monitor's lifetime is tied to "locked + opted in," not
        // to whether an auto-scan already ran this session.
        updateSpaceMonitor()

        guard isEnabled, !hasArmedForCurrentLock else { return }
        // Which signal this is, independent of whether the user asked to
        // auto-scan on it. `.screenUnlocked`/`.willSleep`/`nil` never arm
        // anything (handled by the guards above / nil default), regardless
        // of trigger selection.
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else { return }
        // A specific display was chosen and it isn't connected right now —
        // don't run at all rather than showing up on some other screen.
        // "Main display" (nil) always resolves to something as long as any
        // screen is connected, so this only ever bails for a pinned choice.
        guard NotchGeometry.preferredScreen() != nil else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once via the Credentials tab first."
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return
        }

        // Whether *this specific signal* should also kick off a scan right
        // away, vs. just making the notch/pill available to hover. A
        // deselected trigger no longer means "do nothing" — it means "don't
        // auto-scan for this signal," so the user can still opt in by hand.
        let shouldAutoScan = GlanceSettings.shared.unlockTriggers.contains(signal)

        // Headless (no UI at all — see `showsUI`) has nothing to arm and no
        // way to hover, so "armed but not auto-scanning" isn't a state that
        // means anything there. If this signal isn't selected, there's
        // simply nothing to do — and critically, `hasArmedForCurrentLock`
        // must NOT be set, so a later signal that *is* selected can still
        // fire (setting it here would permanently lock out the rest of this
        // lock session, since nothing ever calls `arm()` to reset it).
        guard showsUI || shouldAutoScan else { return }

        hasArmedForCurrentLock = true
        lastArmedAt = .now
        Task { [weak self] in
            // Was 1s — that had no measured justification (unlike the 300ms
            // wake-settle delay above, which is backed by pmset/os_log
            // correlation) and was the dominant chunk of the wake→notch
            // delay users could feel. `arm()` only shows a small closed
            // notch silhouette, not the full scan UI, so it doesn't need
            // much of a buffer past the login window's own entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.arm(autoScan: shouldAutoScan)
        }
    }

    /// Whether the last arm was recent enough that a wake signal arriving
    /// now is almost certainly part of the same burst, not a new wake.
    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// Which user-facing trigger a given signal corresponds to, or nil for
    /// signals that shouldn't arm anything on their own. `.screenUnlocked`
    /// and `.willSleep` are handled by the guards above rather than here,
    /// and a nil `lastEvent` (nothing has happened yet this launch) must not
    /// arm — otherwise the very first observation would fire regardless of
    /// what the user selected.
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
        // Same reason `startScanCycle` bumps it: a cycle suspended at
        // `await camera.start()` will still resume after this runs, and
        // would otherwise sail past its generation check and call
        // `beginScanning()` — re-showing the scan overlay moments after it
        // was torn down. Bumping here makes any in-flight cycle inert.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        camera.stop()
        NotchOverlayController.shared.disarm()
        // Covers the paths that don't go through `evaluateTrigger`'s locked
        // branch — chiefly `isEnabled` being switched off, which calls this
        // directly. `updateSpaceMonitor` would also stop it, but stopping
        // here keeps "disarmed" and "not listening for space" in lockstep.
        spaceKeyMonitor.stop()
    }

    /// Starts or stops the lock-screen space listener to match the current
    /// state. Idempotent (both `start()`/`stop()` are), so it's safe to call
    /// on every lock/wake event. Deliberately does NOT prompt for Input
    /// Monitoring — that's the settings UI's job when the user opts in; here
    /// a missing grant just means "don't listen."
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

    /// The "On space" trigger firing: the same gate chain `evaluateTrigger`
    /// runs, then start a scan. Independent of `LockMonitor` events — a
    /// keypress isn't a lock/wake signal — so it doesn't touch
    /// `hasArmedForCurrentLock`/`requiredTrigger`.
    private func handleSpaceKeyPress() {
        guard isEnabled,
              GlanceSettings.shared.unlockTriggers.contains(.onSpace),
              LockMonitor.isScreenActuallyLocked(),
              NotchGeometry.preferredScreen() != nil,
              SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword()
        else { return }

        // Already looking — swallow auto-repeat and double-presses, and don't
        // fight an auto-scan already in flight (this is what makes "On wake"/
        // "On lock" override "On space" with no special-casing).
        guard NotchOverlayController.shared.phase != .scanning else { return }

        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // The closed pill/notch is already up (armed on the wake/lock
            // event) — expand and scan, exactly like a hover retry.
            startScanCycle()
        } else {
            Task { [weak self] in await self?.arm(autoScan: true) }
        }
    }

    /// `autoScan` is whether the signal that led here is one the user
    /// selected to scan on automatically. Either way the overlay still
    /// arms (shows the closed, hover-reactive notch/pill) — a deselected
    /// trigger only skips the *automatic* scan, so the user can always
    /// hover in to start one by hand if they decide they want to.
    private func arm(autoScan: Bool) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        guard showsUI else {
            // Headless has no overlay to arm and no way to hover, so
            // "armed but waiting to be hovered" doesn't apply — by the time
            // we get here `evaluateTrigger()` has already guaranteed
            // `autoScan` is true, so this is just "start scanning."
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

    /// Kicks off one scan cycle in the background. Called on arm, and again
    /// every time the overlay hover-activates (waking from closed, or
    /// retrying after a held failure frame).
    private func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// `generation` is what makes overlapping cycles safe. Cancelling
    /// `scanTask` is not enough on its own: `Task.cancel()` is cooperative,
    /// so a superseded cycle still resumes from whatever it was awaiting and
    /// runs to the end of this function — and every side effect down there
    /// (`camera.stop()`, `beginScanning()`, the auto-retry one-shot) is
    /// global, so it lands on the *newer* cycle instead of on itself.
    ///
    /// That was a real bug, not a theoretical one. `camera.stop()` is the
    /// worst of them: `CameraManager` owns a single shared
    /// `AVCaptureSession` with no reference counting, and both start and
    /// stop are queued onto one serial `sessionQueue`. A superseded cycle's
    /// `stop()` therefore sits in that queue *behind* the newer cycle's
    /// `startRunning()`, and `startRunning()` blocks for the camera's
    /// hardware warm-up (a couple of seconds from cold, e.g. straight out
    /// of sleep). The result: the camera visibly switches on, then dies
    /// seconds later, while the surviving cycle keeps polling a session
    /// that is no longer running and finds no frames — so the scan
    /// animation plays out its full duration and nothing ever unlocks.
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

        // A newer cycle now owns the camera and the overlay — leave both
        // alone, and leave the auto-retry one-shot unspent for it too.
        guard generation == scanGeneration else { return }

        camera.stop()

        switch outcome {
        case .matched:
            // The unlock itself already happened inside observeScanWindow
            // (injectStoredPassword) regardless of UI — this only decides
            // whether anything is shown about it.
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
        case .noResolution:
            statusMessage = "No face detected."
            if showsUI {
                // No explicit collapse call: NotchOverlayController's own
                // scanning timeout (started by beginScanning() above) fires
                // on the same mark and quietly collapses on its own.
                statusMessage = "No face detected — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        }
    }

    /// Runs one more scan cycle after a failed attempt, if the user asked
    /// for it and this lock session hasn't already used its retry.
    ///
    /// `delay` waits out whatever the overlay is still showing — the held
    /// failure frame, or the quiet collapse after a timeout — so the retry
    /// doesn't start a fresh scan underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard GlanceSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentLock else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Re-check rather than trust the delay: the user may have
            // unlocked by password, or hovered to retry manually, while this
            // was waiting. The overlay-phase check only applies when there's
            // an overlay to check — headlessly there's nothing to hover, so
            // nothing else could have already restarted the scan.
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
        case noResolution
    }

    /// Runs until either a live match unlocks (`.matched`), the same face
    /// reads as confidently-not-a-match for `wrongFaceStreakThreshold`
    /// consecutive frames (`.consistentlyWrongFace`), or `deadline` passes
    /// with neither (`.noResolution`).
    ///
    /// `requireOverlayScanning` also bails early if the overlay's own
    /// timeout already collapsed the UI, so this loop never keeps running
    /// invisibly after the notch has visually closed — but only when there
    /// *is* an overlay: headlessly, nothing ever sets `phase` to `.scanning`
    /// in the first place, so requiring it there would make this return
    /// `.noResolution` before ever looking at a frame.
    private func observeScanWindow(deadline: Date, requireOverlayScanning: Bool) async -> ScanOutcome {
        let liveness = LivenessMonitor(matchThreshold: matchThreshold)
        var consecutiveWrongFaceFrames = 0
        /// Which face (by normalized bounding box) recognition locked onto
        /// last frame — passed back in so `selectDominantFace` stays on the
        /// same person across frames instead of re-picking independently
        /// every frame. This is the fix for two-people-in-frame flip-flop:
        /// see FaceRecognitionPipeline.selectDominantFace for the full story.
        var lastFaceBoundingBox: CGRect?

        while Date() < deadline, !Task.isCancelled,
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            guard LockMonitor.isScreenActuallyLocked() else { return .noResolution }

            guard let frame = camera.currentFrame else {
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let result = try? await Task.detached(priority: .userInitiated) {
                try pipeline.recognize(in: frame, preferNear: previousBoundingBox)
            }.value

            guard let result else {
                consecutiveWrongFaceFrames = 0
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // `activeIdentities`, not `identities`: someone switched off on
            // the Your Face page stays enrolled but must not unlock the Mac.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold, minMargin: minMargin)

            if let matched {
                consecutiveWrongFaceFrames = 0
                switch liveness.observe(yaw: result.face.yaw, matchSimilarity: matched.centroidSimilarity) {
                case .live:
                    statusMessage = "Recognized — unlocking…"
                    lastOutcome = "Matched \(matched.identity.name) at \(String(format: "%.3f", matched.centroidSimilarity)), live."
                    await pocController.injectStoredPassword(requireAuthoritativeLock: true)
                    return .matched
                case .notLive(let reason):
                    lastOutcome = reason
                case .insufficientData:
                    break
                }
            } else {
                // A face WAS detected and aligned (result != nil) but didn't
                // match anyone above threshold — only escalate to "wrong
                // face" once this recurs across several consecutive frames,
                // so a single bad-angle read doesn't falsely show the
                // failure animation for the right person.
                consecutiveWrongFaceFrames += 1
                if consecutiveWrongFaceFrames >= wrongFaceStreakThreshold {
                    return .consistentlyWrongFace
                }
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return .noResolution
    }
}
