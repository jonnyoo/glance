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

/// Why overall liveness is currently forced to 100% — a blink or a
/// decent amount of mouth/lip motion, each of which a still photo cannot
/// produce. Held for `LivenessAnalyzer.liveProofHoldDuration` after the
/// event, so a single blink (or a few words) covers the rest of a short
/// unlock scan instead of falling out of the ~1s scoring window.
enum LiveProofSource: Equatable {
    case blink
    case mouth

    var title: String {
        switch self {
        case .blink: return "Blink"
        case .mouth: return "Mouth movement"
        }
    }
}

struct LivenessBreakdown {
    let overallScore: Float
    let signalScores: [LivenessSignal: LivenessSignalScore]
    let verdict: LivenessVerdict
    let frameCount: Int
    /// Remaining time on the blink/mouth live-proof hold. `nil` when the
    /// overall score is coming from the weighted signals as usual.
    let liveProofRemaining: TimeInterval?
    let liveProofSource: LiveProofSource?

    init(
        overallScore: Float,
        signalScores: [LivenessSignal: LivenessSignalScore],
        verdict: LivenessVerdict,
        frameCount: Int,
        liveProofRemaining: TimeInterval? = nil,
        liveProofSource: LiveProofSource? = nil
    ) {
        self.overallScore = overallScore
        self.signalScores = signalScores
        self.verdict = verdict
        self.frameCount = frameCount
        self.liveProofRemaining = liveProofRemaining
        self.liveProofSource = liveProofSource
    }

    static let empty = LivenessBreakdown(overallScore: 0, signalScores: [:], verdict: .insufficientData, frameCount: 0)

    func holdingLive(for remaining: TimeInterval, source: LiveProofSource) -> LivenessBreakdown {
        LivenessBreakdown(
            overallScore: 1,
            signalScores: signalScores,
            verdict: .live,
            frameCount: frameCount,
            liveProofRemaining: remaining,
            liveProofSource: source
        )
    }
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
    /// Set when a blink or mouth-motion event fires; overall stays at 100%
    /// until this instant regardless of the other signals (and of the hard
    /// vetoes — a photo cannot blink or independently move its lips).
    private var provenLiveUntil: Date?
    private var proofSource: LiveProofSource?

    /// How long a blink or mouth-motion event keeps overall liveness at
    /// 100%. Long enough to cover a typical unlock scan after a single
    /// blink; short enough that Face Lab returns to the live weighted
    /// score instead of looking stuck.
    static let liveProofHoldDuration: TimeInterval = 10

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
        provenLiveUntil = nil
        proofSource = nil
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

        // Proof is checked on the rolling window itself, even before
        // `evaluate` has enough frames for a weighted verdict — a blink
        // in the first few frames should still immediately pass.
        if let source = Self.detectedLiveProof(in: frames) {
            provenLiveUntil = Date().addingTimeInterval(Self.liveProofHoldDuration)
            proofSource = source
        }

        var breakdown = Self.evaluate(frames, minFramesRequired: minFramesRequired, threshold: thresholdProvider())
        if let until = provenLiveUntil, let source = proofSource, until > Date() {
            breakdown = breakdown.holdingLive(for: until.timeIntervalSinceNow, source: source)
        } else {
            provenLiveUntil = nil
            proofSource = nil
        }
        lastBreakdown = breakdown
        return breakdown
    }

    /// A blink or a decent amount of mouth motion in this window — either
    /// is treated as decisive proof of a live face. Independent of
    /// `evaluate`'s min-frame gate so the hold can start immediately.
    nonisolated static func detectedLiveProof(in window: [LivenessFrame]) -> LiveProofSource? {
        let blink = LivenessScoring.blinkDynamics(window)
        if blink.confidence > 0, blink.score >= 1 { return .blink }
        let mouth = LivenessScoring.mouthDynamics(window)
        if mouth.confidence > 0, mouth.score >= 1 { return .mouth }
        return nil
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

        // Every signal is always computed, even once a veto fires below —
        // so the debug UI can show the full breakdown regardless of which
        // path decided the verdict, rather than a partial one.
        var scores: [LivenessSignal: LivenessSignalScore] = [:]
        for signal in LivenessSignal.allCases {
            scores[signal] = score(for: signal, window: window)
        }

        // Hard vetoes, checked before any weighted combination: no vote
        // tally should be able to outvote direct evidence like "this never
        // moved at all" or "there's a phone-shaped rectangle right where
        // the face is."
        for (signal, reason) in [
            (LivenessSignal.staticGuard, "No natural motion detected — possible static photo."),
            (LivenessSignal.deviceBezel, "A device-shaped rectangle was detected around the face — this looks like a photo or screen."),
        ] {
            let result = scores[signal] ?? .noEvidence
            if result.confidence > 0, result.score < 0.5 {
                return LivenessBreakdown(overallScore: 0, signalScores: scores, verdict: .notLive(reason: reason), frameCount: window.count)
            }
        }

        var weightedSum: Float = 0
        var weightTotal: Float = 0
        for signal in LivenessSignal.allCases where signal != .staticGuard && signal != .deviceBezel {
            let result = scores[signal] ?? .noEvidence
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
        case .mouthDynamics: return LivenessScoring.mouthDynamics(window)
        case .scaleDynamics: return LivenessScoring.scaleDynamics(window)
        case .temporalNaturalness: return LivenessScoring.temporalNaturalness(window)
        case .staticGuard: return LivenessScoring.staticGuard(window)
        case .deviceBezel: return LivenessScoring.deviceBezel(window)
        }
    }
}
