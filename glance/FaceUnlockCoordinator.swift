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

    /// Off by default. Setting this to false mid-attempt cancels it
    /// immediately rather than letting an in-flight recognition attempt
    /// finish.
    var isEnabled: Bool = false {
        didSet {
            if !isEnabled { cancelActiveAttempt() }
        }
    }

    /// Raw cosine threshold — kept independent from Face Lab's own
    /// `threshold` (not read from it) so tuning the debug tool never
    /// silently changes the real unlock gate. Update this once you've
    /// calibrated a value you trust.
    var matchThreshold: Float = 0.36
    private let minMargin: Float = 0.05
    /// Safety gate: at most this many independent observation windows per
    /// lock cycle, each separated by a backoff pause — not a single long
    /// retry loop. Keeps a failed cycle bounded (a few times ~4s apart)
    /// rather than hammering the camera/CPU for the whole timeout.
    private let maxAttemptsPerCycle = 3
    private let attemptTimeout: TimeInterval = 4
    private let backoffBetweenAttempts: TimeInterval = 1

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?

    private var hasAttemptedForCurrentLock = false
    private var attemptTask: Task<Void, Never>?

    init(pocController: POCController) {
        self.pocController = pocController
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
            hasAttemptedForCurrentLock = false
            cancelActiveAttempt()
            return
        }
        guard !lockMonitor.isSleeping else { return }
        guard isEnabled, !hasAttemptedForCurrentLock else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once via the Credentials tab first."
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return
        }

        hasAttemptedForCurrentLock = true
        attemptTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000) // let the lock screen settle
            await self?.runAttempt()
        }
    }

    private func cancelActiveAttempt() {
        attemptTask?.cancel()
        attemptTask = nil
        camera.stop()
    }

    private func runAttempt() async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        await camera.start()
        defer { camera.stop() }

        if let error = camera.errorMessage {
            statusMessage = error
            return
        }

        for attemptIndex in 1...maxAttemptsPerCycle {
            guard LockMonitor.isScreenActuallyLocked(), !Task.isCancelled else { return }
            statusMessage = "Looking for your face… (attempt \(attemptIndex)/\(maxAttemptsPerCycle))"

            let unlocked = await observeOnce(deadline: Date().addingTimeInterval(attemptTimeout))
            if unlocked { return }

            if attemptIndex < maxAttemptsPerCycle {
                try? await Task.sleep(nanoseconds: UInt64(backoffBetweenAttempts * 1_000_000_000))
            }
        }

        statusMessage = "No confident, live match after \(maxAttemptsPerCycle) attempts — will try again next lock."
    }

    /// One bounded observation window: feeds frames into a fresh
    /// `LivenessMonitor` (each attempt starts clean — carrying stale
    /// samples across a backoff gap wouldn't reflect continuous motion)
    /// until either a live match triggers unlock (returns true) or
    /// `deadline` passes (false).
    private func observeOnce(deadline: Date) async -> Bool {
        let liveness = LivenessMonitor(matchThreshold: matchThreshold)

        while Date() < deadline, !Task.isCancelled {
            // Re-checked every iteration, not just at entry — bail
            // immediately if the user unlocks manually mid-attempt.
            guard LockMonitor.isScreenActuallyLocked() else { return false }

            guard let frame = camera.currentFrame else {
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }

            let pipeline = self.pipeline
            let result = try? await Task.detached(priority: .userInitiated) {
                try pipeline.recognize(in: frame)
            }.value

            guard let result else {
                try? await Task.sleep(nanoseconds: 150_000_000)
                continue
            }

            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.identities)
            let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold, minMargin: minMargin)
            let similarity = matched?.centroidSimilarity ?? -1

            switch liveness.observe(yaw: result.face.yaw, matchSimilarity: similarity) {
            case .live:
                statusMessage = "Recognized — unlocking…"
                lastOutcome = "Matched \(matched?.identity.name ?? "?") at \(String(format: "%.3f", similarity)), live."
                await pocController.injectStoredPassword(requireAuthoritativeLock: true)
                return true
            case .notLive(let reason):
                lastOutcome = reason
            case .insufficientData:
                break
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return false
    }
}
