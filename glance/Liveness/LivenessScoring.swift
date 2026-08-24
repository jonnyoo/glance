//
//  LivenessScoring.swift
//  glance
//
//  `LivenessFrame` — one frame's worth of liveness-relevant measurements —
//  plus the two cross-frame confirm cues that read it directly:
//  `poseDepthConsistency` and `blinkDynamics`. (The third confirm cue,
//  flat-vs-3D, lives in `GeometryLiveness.swift`; the two deny cues are
//  per-frame appearance measurements handled in `LivenessCues.swift`.)
//
//  Deliberately free of `import Vision` (and AppKit) so it compiles and
//  runs standalone, outside the app target, for
//  `tools/liveness_selftest.swift`. Everything here operates on plain
//  points and scalars, and the `LandmarkPoint`/`LandmarkRegion` types from
//  `LandmarkGeometry.swift` — those two happen to live in a
//  Vision-importing file, but are themselves just CoreGraphics data, so
//  reusing them here doesn't pull Vision in.
//
//  This file used to hold nine more scoring functions feeding a weighted
//  "overall liveness %" (non-rigid residual, residual coherence, scale
//  dynamics, temporal naturalness, mouth dynamics, a static guard, a
//  duplicate device-bezel check). Real-device testing retired all of them:
//  most were noise-limited at webcam resolution, and several scored a hand
//  holding up a phone *higher* than a live face, because smooth low-jerk
//  motion is exactly what a held phone produces. See `LivenessCues.swift`
//  for the decision model that replaced the weighted average.
//

import Foundation
import CoreGraphics

/// One frame's worth of liveness-relevant measurements. Everything here is
/// already normalized or independently meaningful — no caller needs Vision
/// to use it. Populated by `LivenessFeatureExtractor.extract(from:)`
/// (`LivenessFeatures.swift`, which does need Vision) from a real camera
/// frame, or built directly from synthetic data by
/// `tools/liveness_selftest.swift` — this struct itself has no idea which.
struct LivenessFrame {
    let timestamp: Date
    /// Every landmark point Vision found this frame, tagged by region —
    /// see `LandmarkGeometry.allPoints`.
    let landmarks: [LandmarkPoint]
    /// Distance between the two eye centers, in the same pixel space as
    /// `landmarks` — the normalization scale for every ratio below.
    let interocularDistance: CGFloat?
    let yaw: Float?
    let leftEyeAspectRatio: CGFloat?
    let rightEyeAspectRatio: CGFloat?
    /// `(noseCentroid.x - eyeMidpoint.x) / interocularDistance` — tracks
    /// `tan(yaw)` on a real 3D face (the nose sits off the eye plane) and
    /// stays constant on any flat presentation, however it's rotated. See
    /// `poseDepthConsistency` below.
    let noseOffsetRatio: CGFloat?
    /// Whether this frame's landmarks came from full 5-point detection
    /// (`AlignmentTier.fivePoint`) rather than a 2-point or padded-crop
    /// fallback. Degraded landmarks are exactly when residual noise spikes,
    /// so cues that need precision skip frames where this is false.
    let hasReliableLandmarks: Bool
    /// Fraction of this frame's face bounding box covered by a detected
    /// device-shaped rectangle — see `DeviceBezelDetector`. `nil` when
    /// detection wasn't run (or found nothing); real evidence only when
    /// non-nil and large. Read by the `deviceDetected` deny cue.
    let deviceOverlapFraction: CGFloat?
    /// Specular-highlight measurements from a native-resolution face crop —
    /// see `GlareSample`. `nil` when no crop was available (e.g. synthetic
    /// self-test data), in which case the `glossGlare` deny cue abstains
    /// rather than guessing.
    let glare: GlareSample?

    /// Explicit init (rather than the compiler-synthesized memberwise one)
    /// so `glare` can default to `nil` — a `let` property with a default
    /// value is excluded entirely from Swift's synthesized memberwise init
    /// rather than becoming an optional parameter, so without this every
    /// synthetic `LivenessFrame(...)` construction in the self-test would
    /// have to pass it explicitly.
    init(
        timestamp: Date,
        landmarks: [LandmarkPoint],
        interocularDistance: CGFloat?,
        yaw: Float?,
        leftEyeAspectRatio: CGFloat?,
        rightEyeAspectRatio: CGFloat?,
        noseOffsetRatio: CGFloat?,
        hasReliableLandmarks: Bool,
        deviceOverlapFraction: CGFloat?,
        glare: GlareSample? = nil
    ) {
        self.timestamp = timestamp
        self.landmarks = landmarks
        self.interocularDistance = interocularDistance
        self.yaw = yaw
        self.leftEyeAspectRatio = leftEyeAspectRatio
        self.rightEyeAspectRatio = rightEyeAspectRatio
        self.noseOffsetRatio = noseOffsetRatio
        self.hasReliableLandmarks = hasReliableLandmarks
        self.deviceOverlapFraction = deviceOverlapFraction
        self.glare = glare
    }
}

nonisolated enum LivenessScoring {
    // MARK: - Depth/pose consistency (confirm cue)

    /// Correlates nose-offset-from-eye-midline against tan(yaw) across the
    /// window. On a real face the nose protrudes off the eye plane, so its
    /// apparent offset tracks yaw; on any flat presentation the offset
    /// stays constant no matter how the plane is rotated. Confidence scales
    /// with the actual yaw range observed in the window — at the small
    /// rotations a passive, non-challenge scan realistically sees (a couple
    /// of degrees), the geometric displacement this predicts is well under
    /// a pixel, below Vision's landmark noise floor, so this cue
    /// deliberately abstains rather than read noise.
    static func poseDepthConsistency(_ window: [LivenessFrame]) -> CueReading {
        let pairs = window.compactMap { frame -> (CGFloat, CGFloat)? in
            guard let offset = frame.noseOffsetRatio, let yaw = frame.yaw, frame.hasReliableLandmarks else { return nil }
            return (offset, CGFloat(tan(yaw)))
        }
        guard pairs.count >= 4 else { return .none }

        let yaws = pairs.map(\.1)
        guard let minYaw = yaws.min(), let maxYaw = yaws.max() else { return .none }
        let yawRange = abs(atan(maxYaw) - atan(minYaw))
        // Below ~12 degrees of observed rotation, the predicted nose-offset
        // displacement is sub-pixel at the 640px working resolution —
        // there's nothing to measure yet. Matches `GeometryTuning
        // .minYawRangeDegrees`, which gates the flat-vs-3D cue on the same
        // underlying limit (see that property's doc comment).
        let minMeasurableRange: CGFloat = 12 * .pi / 180
        guard yawRange > minMeasurableRange else { return .none }

        guard let correlation = pearsonCorrelation(pairs.map(\.0), pairs.map(\.1)) else { return .none }
        let level = Float(clamp((correlation + 1) / 2, 0, 1))
        // Confidence ramps in over the next ~15 degrees past the minimum —
        // more rotation observed, more trustworthy the correlation is.
        let confidence = Float(clamp((yawRange - minMeasurableRange) / (15 * .pi / 180), 0, 1))
        return CueReading(level: level, confidence: confidence)
    }

    private static func pearsonCorrelation(_ xs: [CGFloat], _ ys: [CGFloat]) -> CGFloat? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        let n = CGFloat(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var covariance: CGFloat = 0, varX: CGFloat = 0, varY: CGFloat = 0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX, dy = ys[i] - meanY
            covariance += dx * dy
            varX += dx * dx
            varY += dy * dy
        }
        guard varX > 0, varY > 0 else { return nil }
        return covariance / (varX.squareRoot() * varY.squareRoot())
    }

    // MARK: - Blink dynamics (confirm cue)

    /// Looks for a dip-and-recovery in eye-aspect-ratio — a blink. Never
    /// mandatory: humans blink every 2-10 seconds — less often still while
    /// deliberately staring at a camera to unlock, a well-documented
    /// task-focus effect — so a short window frequently contains none at
    /// all, which is an abstention, not a failure. Only ever contributes
    /// *positively*: a blink is strong evidence of life, but its absence in
    /// one short window proves nothing.
    ///
    /// Thresholds loosened from the original 0.5/0.6: real-device testing
    /// found this essentially never firing even when the user deliberately
    /// blinked, which points at Vision's general-purpose landmark model not
    /// fully collapsing the eyelid contour during a real blink (it isn't a
    /// specialized blink detector) — a partial dip is apparently the
    /// realistic signal, not the deep, clean dip the original thresholds
    /// assumed. The recovery check looks within a small radius rather than
    /// requiring the immediate neighbor frame, since a ~100-150ms blink can
    /// span several frames at ~20fps and the exact minimum-EAR frame may
    /// not itself have a fully-open neighbor on both sides.
    static func blinkDynamics(_ window: [LivenessFrame]) -> CueReading {
        let ears = window.compactMap { frame -> CGFloat? in
            guard let l = frame.leftEyeAspectRatio, let r = frame.rightEyeAspectRatio else { return nil }
            return (l + r) / 2
        }
        guard ears.count >= 4 else { return .none }

        let baseline = ears.max() ?? 0
        guard baseline > 0 else { return .none }
        guard let minEAR = ears.min(), let minIndex = ears.firstIndex(of: minEAR) else { return .none }

        let dipRatio = minEAR / baseline
        let recoveryRadius = 3
        let openBefore = ears[..<minIndex].suffix(recoveryRadius).contains { $0 / baseline > 0.7 }
        let openAfter = ears[(minIndex + 1)...].prefix(recoveryRadius).contains { $0 / baseline > 0.7 }
        let hasNeighborRecovery = minIndex > 0 && minIndex < ears.count - 1 && openBefore && openAfter

        guard dipRatio < 0.65, hasNeighborRecovery else { return .none }
        return CueReading(level: 1, confidence: 1)
    }

    private static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}
