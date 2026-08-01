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
    /// Matches NotchOverlayController's own scanning timeout so the
    /// background loop stops in step with the UI collapsing.
    private let scanWindowDuration: TimeInterval = 5
    /// A face that scores below threshold for this many *consecutive*
    /// frames is treated as "confidently a different person" and shows the
    /// failure animation — a single bad-angle frame from the right person
    /// shouldn't trigger it, so this requires it to persist.
    private let wrongFaceStreakThreshold = 6

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?

    private var hasArmedForCurrentLock = false
    private var scanTask: Task<Void, Never>?

    init(pocController: POCController) {
        self.pocController = pocController
        self.isEnabled = GlanceSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = GlanceSettings.shared.matchThreshold
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
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else { return }
        guard isEnabled, !hasArmedForCurrentLock else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once via the Credentials tab first."
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return
        }

        hasArmedForCurrentLock = true
        Task { [weak self] in
            // Was 1s — that had no measured justification (unlike the 300ms
            // wake-settle delay above, which is backed by pmset/os_log
            // correlation) and was the dominant chunk of the wake→notch
            // delay users could feel. `arm()` only shows a small closed
            // notch silhouette, not the full scan UI, so it doesn't need
            // much of a buffer past the login window's own entrance.
            try? await Task.sleep(nanoseconds: 250_000_000)
            await self?.arm()
        }
    }

    private func disarmOverlay() {
        scanTask?.cancel()
        scanTask = nil
        camera.stop()
        NotchOverlayController.shared.disarm()
    }

    private func arm() async {
        guard LockMonitor.isScreenActuallyLocked() else { return }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        startScanCycle()
    }

    /// Kicks off one scan cycle in the background. Called on arm, and again
    /// every time the overlay hover-activates (waking from closed, or
    /// retrying after a held failure frame).
    private func startScanCycle() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.runScanCycle()
        }
    }

    private func runScanCycle() async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        await camera.start()
        if let error = camera.errorMessage {
            statusMessage = error
            camera.stop()
            return
        }

        NotchOverlayController.shared.beginScanning()
        statusMessage = "Looking for your face…"

        let outcome = await observeScanWindow(deadline: Date().addingTimeInterval(scanWindowDuration))
        camera.stop()

        switch outcome {
        case .matched:
            NotchOverlayController.shared.finish(success: true)
        case .consistentlyWrongFace:
            NotchOverlayController.shared.finish(success: false)
            statusMessage = "Face not recognized — hover the notch to try again."
        case .noResolution:
            // No explicit collapse call: NotchOverlayController's own
            // scanning timeout (started by beginScanning() above) fires on
            // the same ~5s mark and quietly collapses on its own.
            statusMessage = "No face detected — hover the notch to try again."
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
    /// with neither (`.noResolution`) — also bails early if the overlay's
    /// own timeout already collapsed the UI, so this loop never keeps
    /// running invisibly after the notch has visually closed.
    private func observeScanWindow(deadline: Date) async -> ScanOutcome {
        let liveness = LivenessMonitor(matchThreshold: matchThreshold)
        var consecutiveWrongFaceFrames = 0
        /// Which face (by normalized bounding box) recognition locked onto
        /// last frame — passed back in so `selectDominantFace` stays on the
        /// same person across frames instead of re-picking independently
        /// every frame. This is the fix for two-people-in-frame flip-flop:
        /// see FaceRecognitionPipeline.selectDominantFace for the full story.
        var lastFaceBoundingBox: CGRect?

        while Date() < deadline, !Task.isCancelled, NotchOverlayController.shared.phase == .scanning {
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

            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.identities)
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
