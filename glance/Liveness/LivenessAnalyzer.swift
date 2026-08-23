//
//  LivenessAnalyzer.swift
//  glance
//
//  Replaces `LivenessMonitor`. Where that only tested "did yaw wobble more
//  than 0.003 radians" — trivially cleared by hand tremor on a photo, since
//  a rotating plane changes apparent yaw too — this holds a rolling window
//  of `LivenessFrame`s and combines several independent signals (see
//  `LivenessScoring`) into one score, gated separately from face-match
//  confidence so the two stay independently tunable:
//
//      similarity >= matchThreshold  AND  livenessScore >= livenessThreshold
//
//  Deliberately takes `LivenessFrame` values, not `FaceRecognitionResult` —
//  callers extract via `LivenessFeatureExtractor.extract(from:)` first.
//  That keeps this file's dependency graph shallow (no FaceRecognitionPipeline,
//  no CoreML, no FaceEnrollmentStore), which is what makes
//  `tools/liveness_selftest.swift` able to compile and exercise the real
//  scoring logic against synthetic data, offline, with no camera.
//

import Foundation

enum LivenessVerdict: Equatable {
    case insufficientData
    case notLive(reason: String)
    case live
}

struct LivenessBreakdown {
    let overallScore: Float
    let signalScores: [LivenessSignal: LivenessSignalScore]
    let verdict: LivenessVerdict
    let frameCount: Int

    static let empty = LivenessBreakdown(overallScore: 0, signalScores: [:], verdict: .insufficientData, frameCount: 0)
}

@MainActor
final class LivenessAnalyzer {
    private let windowDuration: TimeInterval
    private let minFramesRequired: Int
    /// Read fresh on every `observe()` rather than captured at init, so a
    /// mid-scan change to the Recognition page's strictness slider (or a
    /// Face Lab calibration run) takes effect on the next frame instead of
    /// needing a new scan cycle.
    private let thresholdProvider: () -> Float

    private var frames: [LivenessFrame] = []
    private(set) var lastBreakdown = LivenessBreakdown.empty

    init(
        windowDuration: TimeInterval = 1.0,
        minFramesRequired: Int = 5,
        threshold: @escaping @autoclosure () -> Float
    ) {
        self.windowDuration = windowDuration
        self.minFramesRequired = minFramesRequired
        self.thresholdProvider = threshold
    }

    func reset() {
        frames.removeAll()
        lastBreakdown = .empty
    }

    /// Feeds one frame into the rolling window and returns the current
    /// verdict. Call once per frame that had a face detected — unlike the
    /// old `LivenessMonitor`, this is fed regardless of whether that frame
    /// also matched an identity, so the window stays dense and liveness
    /// stays a genuinely independent gate rather than one starved by
    /// recognition's own confidence.
    @discardableResult
    func observe(_ frame: LivenessFrame) -> LivenessBreakdown {
        frames.append(frame)
        frames.removeAll { frame.timestamp.timeIntervalSince($0.timestamp) > windowDuration }
        let breakdown = Self.evaluate(frames, minFramesRequired: minFramesRequired, threshold: thresholdProvider())
        lastBreakdown = breakdown
        return breakdown
    }

    /// The pure evaluation step — a `static` function taking the window
    /// explicitly (rather than reading `self.frames`) so it's exactly what
    /// `tools/liveness_selftest.swift` calls against synthetic windows.
    /// `nonisolated` deliberately: this touches no actor-isolated state
    /// (only the `window` array passed in, and `LivenessScoring`'s own pure
    /// statics), so the self-test can call it from a plain synchronous
    /// `main.swift` with no `@MainActor`/async ceremony.
    nonisolated static func evaluate(_ window: [LivenessFrame], minFramesRequired: Int, threshold: Float) -> LivenessBreakdown {
        guard window.count >= minFramesRequired else {
            return LivenessBreakdown(overallScore: 0, signalScores: [:], verdict: .insufficientData, frameCount: window.count)
        }

        // Hard veto, checked first: no weighted combination of the other
        // signals should be able to outvote "this never moved at all."
        let staticGuard = LivenessScoring.staticGuard(window)
        if staticGuard.confidence > 0, staticGuard.score < 0.5 {
            var scores: [LivenessSignal: LivenessSignalScore] = [.staticGuard: staticGuard]
            for signal in LivenessSignal.allCases where signal != .staticGuard {
                scores[signal] = score(for: signal, window: window)
            }
            return LivenessBreakdown(
                overallScore: 0,
                signalScores: scores,
                verdict: .notLive(reason: "No natural motion detected — possible static photo."),
                frameCount: window.count
            )
        }

        var scores: [LivenessSignal: LivenessSignalScore] = [.staticGuard: staticGuard]
        var weightedSum: Float = 0
        var weightTotal: Float = 0
        for signal in LivenessSignal.allCases where signal != .staticGuard {
            let result = score(for: signal, window: window)
            scores[signal] = result
            let effectiveWeight = signal.weight * result.confidence
            weightedSum += effectiveWeight * result.score
            weightTotal += effectiveWeight
        }

        guard weightTotal > 0 else {
            return LivenessBreakdown(overallScore: 0, signalScores: scores, verdict: .insufficientData, frameCount: window.count)
        }

        let overall = weightedSum / weightTotal
        let verdict: LivenessVerdict = overall >= threshold
            ? .live
            : .notLive(reason: "Motion doesn't look like a live face (\(Int(overall * 100))%, need \(Int(threshold * 100))%).")
        return LivenessBreakdown(overallScore: overall, signalScores: scores, verdict: verdict, frameCount: window.count)
    }

    private nonisolated static func score(for signal: LivenessSignal, window: [LivenessFrame]) -> LivenessSignalScore {
        switch signal {
        case .nonRigidResidual: return LivenessScoring.nonRigidResidual(window)
        case .residualCoherence: return LivenessScoring.residualCoherence(window)
        case .poseDepthConsistency: return LivenessScoring.poseDepthConsistency(window)
        case .blinkDynamics: return LivenessScoring.blinkDynamics(window)
        case .scaleDynamics: return LivenessScoring.scaleDynamics(window)
        case .temporalNaturalness: return LivenessScoring.temporalNaturalness(window)
        case .staticGuard: return LivenessScoring.staticGuard(window)
        }
    }
}
