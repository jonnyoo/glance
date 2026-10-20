//
//  LivenessAnalyzer.swift
//  glance
//
//  Rolling-window driver for the liveness cues. Takes `LivenessFrame`, not
//  `FaceRecognitionResult`, keeping this file's dependency graph shallow enough
//  to compile standalone in `tools/liveness_selftest.swift`.
//

import Foundation

@MainActor
final class LivenessAnalyzer {
    private let windowDuration: TimeInterval

    /// Read fresh on every `observe()`, not captured at init, so a mid-scan Settings change takes effect immediately.
    var modeProvider: () -> LivenessMode = { .light }
    var tuningProvider: () -> LivenessTuning = { .default }
    /// Face Lab can switch individual cues off to isolate one; the unlock
    /// path leaves this at "all enabled."
    var enabledCuesProvider: () -> Set<LivenessCue> = { Set(LivenessCue.allCases) }
    /// Face Lab wants the geometry diagnostics to keep updating after Heavy mode confirms; the unlock path
    /// doesn't, because confirmation is latched and only deny cues can still change the decision.
    var keepsComputingConfirmCuesAfterConfirmation = false

    private var frames: [LivenessFrame] = []
    private var evaluator = LivenessEvaluator()
    private(set) var lastSnapshot = LivenessSnapshot.empty
    /// Kept for Face Lab's diagnostics panel (excess ratio, coherence, pair
    /// counts, yaw range) — the numbers behind the flat-vs-3D cue's level.
    private(set) var lastGeometry = GeometryLivenessResult.empty

    init(windowDuration: TimeInterval = 2.0) {
        self.windowDuration = windowDuration
    }

    func reset() {
        frames.removeAll()
        evaluator.reset()
        lastSnapshot = .empty
        lastGeometry = .empty
    }

    /// Call once per frame with a detected face, regardless of whether it matched an identity,
    /// so liveness stays an independent gate. The window is time-pruned (~2s) but the evaluator's
    /// fire counts are not — they accumulate across the whole scan, so a spoof tell can't be waited out.
    @discardableResult
    func observe(_ frame: LivenessFrame) -> LivenessSnapshot {
        frames.append(frame)
        frames.removeAll { frame.timestamp.timeIntervalSince($0.timestamp) > windowDuration }

        let mode = modeProvider()
        evaluator.mode = mode
        evaluator.tuning = tuningProvider()
        evaluator.enabledCues = enabledCuesProvider()

        // Light mode confirms by frame count and never reads confirm cues. Heavy mode needs them only until
        // it has confirmed; the evaluator latches that, so afterwards only a deny cue can change the outcome.
        // Face Lab opts back in so its geometry diagnostics keep updating.
        let alreadyConfirmedInHeavy = lastSnapshot.mode == .heavy && lastSnapshot.decision.isConfirmed
        let needsConfirmCues = mode == .heavy && (keepsComputingConfirmCuesAfterConfirmation || !alreadyConfirmedInHeavy)

        let geometry: GeometryLivenessResult
        let readings: [LivenessCue: CueReading]
        if needsConfirmCues {
            geometry = GeometryLiveness.evaluate(frames)
            readings = LivenessCues.readings(window: frames, geometry: geometry)
        } else {
            geometry = .empty
            readings = LivenessCues.denyReadings(window: frames)
        }

        lastGeometry = geometry
        let snapshot = evaluator.observe(readings)
        lastSnapshot = snapshot
        return snapshot
    }
}
