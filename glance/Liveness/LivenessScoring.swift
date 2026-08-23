//
//  LivenessScoring.swift
//  glance
//
//  The pure scoring core — deliberately free of `import Vision` (and
//  AppKit) so it compiles and runs standalone, outside the app target, for
//  `tools/liveness_selftest.swift`'s synthetic separation test. Everything
//  here operates on `LivenessFrame` (plain points and scalars) and the
//  `LandmarkPoint`/`LandmarkRegion` types from `LandmarkGeometry.swift` —
//  those two types happen to live in a Vision-importing file, but are
//  themselves just CoreGraphics data, so reusing them here doesn't pull
//  Vision in.
//
//  Core thesis: a flat presentation (printed photo or a photo/video on a
//  phone screen) can only ever move as one rigid 2D transform — rotation,
//  uniform scale, translation. A real face's soft-tissue regions (mouth,
//  eyebrows, jaw) deform *independently* of that rigid motion. Every
//  landmark point on a photo is fully explained by fitting a similarity
//  transform to a handful of "anchor" points (eyes, nose bridge — the most
//  rigid part of a real face too); every landmark point on a live face is
//  NOT, because the flexible regions genuinely move on their own.
//
//  So rather than testing "did yaw change" (the old, broken test — a
//  rotating plane changes yaw too), every signal below is built around
//  comparing the RESIDUAL after removing rigid motion, not the raw motion
//  itself.
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
    let pitch: Float?
    let roll: Float?
    /// Normalized (0...1) face width — the same value
    /// `FaceRecognitionPipeline.minimumProminentFaceWidth` filters on.
    let normalizedFaceWidth: CGFloat
    let leftEyeAspectRatio: CGFloat?
    let rightEyeAspectRatio: CGFloat?
    /// Vertical inner-lip extent in a face-aligned frame, in units of
    /// interocular distance. Grows when the mouth opens, shrinks when it
    /// closes — independent of the head translating or rolling. See
    /// `LandmarkGeometry.mouthExpressionMetrics`.
    let mouthOpeningRatio: CGFloat?
    /// Horizontal outer-lip extent in the same face-aligned frame. Grows
    /// when the mouth widens (a smile), shrinks when it relaxes.
    let mouthWidthRatio: CGFloat?
    /// `(noseCentroid.x - eyeMidpoint.x) / interocularDistance` — tracks
    /// `tan(yaw)` on a real 3D face (the nose sits off the eye plane) and
    /// stays constant on any flat presentation, however it's rotated. See
    /// `poseDepthConsistency` below.
    let noseOffsetRatio: CGFloat?
    let quality: Float?
    /// Whether this frame's landmarks came from full 5-point detection
    /// (`AlignmentTier.fivePoint`) rather than a 2-point or padded-crop
    /// fallback. Degraded landmarks are exactly when residual noise spikes,
    /// so signals confidence-weight down on frames where this is false.
    let hasReliableLandmarks: Bool
    /// Fraction of this frame's face bounding box covered by a detected
    /// device-shaped rectangle — see `DeviceBezelDetector`. `nil` when
    /// detection wasn't run (or found nothing); real evidence only when
    /// non-nil and large.
    let deviceOverlapFraction: CGFloat?
}

struct LivenessSignalScore {
    /// 0...1, higher = more consistent with a live face.
    let score: Float
    /// 0...1, how much this particular signal actually had to go on this
    /// window. A signal with confidence 0 contributes nothing to the
    /// combined score in either direction — see `LivenessAnalyzer.combine`.
    let confidence: Float

    nonisolated static let noEvidence = LivenessSignalScore(score: 0.5, confidence: 0)
}

enum LivenessSignal: String, CaseIterable {
    case nonRigidResidual
    case residualCoherence
    case poseDepthConsistency
    case blinkDynamics
    case mouthDynamics
    case scaleDynamics
    case temporalNaturalness
    case staticGuard
    case deviceBezel

    var title: String {
        switch self {
        case .nonRigidResidual: return "Non-rigid motion"
        case .residualCoherence: return "Motion structure"
        case .poseDepthConsistency: return "Depth/pose"
        case .blinkDynamics: return "Blink"
        case .mouthDynamics: return "Mouth"
        case .scaleDynamics: return "Scale change"
        case .temporalNaturalness: return "Motion smoothness"
        case .staticGuard: return "Static guard"
        case .deviceBezel: return "Device detected"
        }
    }

    /// Relative vote weight in the combined score. `staticGuard` and
    /// `deviceBezel` aren't weighted in with the others at all — both are
    /// hard vetoes, checked first in `LivenessAnalyzer.evaluate()` — their
    /// weight here is purely for the debug UI's bar chart.
    ///
    /// `nonRigidResidual`/`residualCoherence` were originally weighted
    /// much higher (3.0/1.5, `nonRigidResidual` alone worth more than
    /// everything else combined) on the theory that residual-after-
    /// rigid-fit was the strongest available signal. Real-device testing
    /// showed otherwise: both saturated near 100% for *every* real photo
    /// tested (on a stand, hand-held, tilted) at scores statistically
    /// indistinguishable from a live face — real Vision landmark noise is
    /// spatially correlated and the anchor-only fit has genuine
    /// extrapolation error against the farther-away flexible regions,
    /// neither of which the synthetic self-test's independent-per-point
    /// Gaussian noise model captured. Demoted here until they can be
    /// recalibrated against real residual numbers (Face Lab now exposes
    /// these live) rather than synthetic ones.
    nonisolated var weight: Float {
        switch self {
        case .nonRigidResidual: return 1.0
        case .residualCoherence: return 0.5
        case .poseDepthConsistency: return 1.0
        case .blinkDynamics: return 1.0
        case .mouthDynamics: return 1.0
        case .scaleDynamics: return 0.5
        case .temporalNaturalness: return 1.0
        case .staticGuard: return 0
        case .deviceBezel: return 0
        }
    }
}

/// Regions whose points anchor the rigid-motion fit — the parts of a real
/// face that move essentially rigidly with head pose (eyes barely deform;
/// the nose bridge doesn't at all). Deliberately excludes the jaw/contour,
/// which visibly moves when the mouth opens.
nonisolated private let anchorRegions: Set<LandmarkRegion> = [.leftEye, .rightEye, .nose]

/// Everything else — soft tissue capable of moving independently of head
/// pose: talking, smiling, raising an eyebrow. This is where non-rigid
/// motion shows up on a live face and can *never* show up on a flat
/// presentation, because a print or screen has no independently-movable
/// parts at all.
nonisolated private let flexibleRegions: Set<LandmarkRegion> = [.outerLips, .innerLips, .leftEyebrow, .rightEyebrow, .faceContour, .noseCrest, .medianLine]

nonisolated enum LivenessScoring {
    // MARK: - Cross-frame point correspondence

    /// Points present, with matching per-region counts, in both frames —
    /// the guard the "correspondence gotcha" requires: a region can be
    /// entirely absent on either frame, and comparing mismatched arrays
    /// would silently pair up unrelated points. Returns matched arrays
    /// grouped by region, in stable per-region order.
    static func correspondingPoints(
        _ a: [LandmarkPoint], _ b: [LandmarkPoint]
    ) -> [LandmarkRegion: (source: [CGPoint], destination: [CGPoint])] {
        let aByRegion = Dictionary(grouping: a, by: \.region)
        let bByRegion = Dictionary(grouping: b, by: \.region)
        var result: [LandmarkRegion: (source: [CGPoint], destination: [CGPoint])] = [:]
        for region in LandmarkRegion.allCases {
            guard let aPoints = aByRegion[region], let bPoints = bByRegion[region],
                  aPoints.count == bPoints.count, !aPoints.isEmpty else { continue }
            let aSorted = aPoints.sorted { $0.indexInRegion < $1.indexInRegion }
            let bSorted = bPoints.sorted { $0.indexInRegion < $1.indexInRegion }
            result[region] = (aSorted.map(\.point), bSorted.map(\.point))
        }
        return result
    }

    private static func flatten(_ byRegion: [LandmarkRegion: (source: [CGPoint], destination: [CGPoint])], in regions: Set<LandmarkRegion>) -> (source: [CGPoint], destination: [CGPoint]) {
        var source: [CGPoint] = []
        var destination: [CGPoint] = []
        for (region, points) in byRegion where regions.contains(region) {
            source += points.source
            destination += points.destination
        }
        return (source, destination)
    }

    private static func rms(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sumSquares = values.reduce(CGFloat(0)) { $0 + $1 * $1 }
        return (sumSquares / CGFloat(values.count)).squareRoot()
    }

    private static func residualMagnitudes(actual: [CGPoint], predicted: [CGPoint]) -> [CGFloat] {
        zip(actual, predicted).map { hypot($0.x - $1.x, $0.y - $1.y) }
    }

    // MARK: - S7: static guard (hard veto)

    /// Immediate fail if landmarks are *pixel-identical* (or near enough)
    /// across the whole window — a photo on a stand, or a paused video
    /// frame. Deliberately the crudest possible test and checked before
    /// anything else: no amount of clever scoring elsewhere should be able
    /// to outvote "this literally never moved at all."
    static func staticGuard(_ window: [LivenessFrame]) -> LivenessSignalScore {
        var maxDisplacement: CGFloat = 0
        var sawAnyPair = false
        for i in 1..<max(window.count, 1) where i < window.count {
            let matched = correspondingPoints(window[i - 1].landmarks, window[i].landmarks)
            let (source, destination) = flatten(matched, in: Set(LandmarkRegion.allCases))
            guard !source.isEmpty, let interocular = window[i].interocularDistance, interocular > 0 else { continue }
            sawAnyPair = true
            let displacement = zip(source, destination).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0
            maxDisplacement = max(maxDisplacement, displacement / interocular)
        }
        guard sawAnyPair else { return .noEvidence }
        // A continuous ramp, not a hard 0/1 cutoff — real-device testing
        // showed a rigidly-mounted phone still clears a naive tiny floor
        // (0.0015, tuned against clean synthetic noise) outright, because
        // real Vision landmark jitter — sensor noise, auto-exposure
        // micro-adjustment, detector quantization — sits well above that
        // even for a genuinely motionless object. `floor`/`ceiling` are
        // first-pass, real-camera-informed estimates, not final: watch
        // this score directly in Face Lab against a phone actually held on
        // a stand and adjust both to match what's really observed.
        let floor: CGFloat = 0.006
        let ceiling: CGFloat = 0.016
        let score = Float(clamp((maxDisplacement - floor) / (ceiling - floor), 0, 1))
        return LivenessSignalScore(score: score, confidence: 1)
    }

    // MARK: - Device bezel (hard veto)

    /// Persistent evidence, across the window, that the face is displayed
    /// on a rectangular device rather than being a real head — see
    /// `DeviceBezelDetector`. Requiring persistence (not just one frame)
    /// guards against a one-off false positive from an unrelated
    /// background rectangle; only ever returns confident evidence *against*
    /// liveness, never for it — see the type's own doc comment.
    static func deviceBezel(_ window: [LivenessFrame]) -> LivenessSignalScore {
        guard !window.isEmpty else { return .noEvidence }
        let detectedCount = window.filter { ($0.deviceOverlapFraction ?? 0) > 0.55 }.count
        let detectionFraction = Float(detectedCount) / Float(window.count)
        guard detectionFraction > 0.35 else { return .noEvidence }
        return LivenessSignalScore(score: 0, confidence: 1)
    }

    // MARK: - S1: non-rigid residual (primary)

    /// For each consecutive frame pair: fit a rigid transform on the anchor
    /// points only, then measure how well that SAME transform predicts the
    /// flexible-region points. The anchor-only residual is the noise floor
    /// (detector jitter, alignment error) for that pair; the flexible
    /// residual is that same noise floor PLUS whatever real non-rigid
    /// motion happened. The ratio between them is what a flat presentation
    /// cannot fake — a print or screen has no flexible points that move
    /// independently of the rigid whole, so its ratio sits at ~1.
    static func nonRigidResidual(_ window: [LivenessFrame]) -> LivenessSignalScore {
        var ratios: [CGFloat] = []
        for i in 1..<max(window.count, 1) where i < window.count {
            guard let ratio = residualRatio(from: window[i - 1], to: window[i]) else { continue }
            ratios.append(ratio)
        }
        guard !ratios.isEmpty else { return .noEvidence }

        let meanRatio = ratios.reduce(0, +) / CGFloat(ratios.count)
        // Ratio ~1 = purely rigid (a plane). ~1.8+ = flexible regions moved
        // clearly beyond the anchor noise floor — comfortably into "real
        // face" territory. Calibrate against Face Lab's liveness scatter
        // rather than treating these as fixed truths.
        let score = Float(clamp((meanRatio - 1.0) / (1.8 - 1.0), 0, 1))
        // Confidence scales with how many pairs actually had usable
        // flexible-region correspondence — a face turned enough to lose
        // eyebrow/contour landmarks shouldn't let a lucky single pair
        // decide the whole window.
        let confidence = Float(clamp(Double(ratios.count) / Double(max(window.count - 1, 1)), 0, 1))
        return LivenessSignalScore(score: score, confidence: confidence)
    }

    /// Returns flexible-residual / anchor-residual for one consecutive
    /// pair, or nil if there wasn't enough correspondence to compute it.
    private static func residualRatio(from a: LivenessFrame, to b: LivenessFrame) -> CGFloat? {
        guard let interocular = b.interocularDistance, interocular > 0 else { return nil }
        let matched = correspondingPoints(a.landmarks, b.landmarks)
        let (anchorSrc, anchorDst) = flatten(matched, in: anchorRegions)
        let (flexSrc, flexDst) = flatten(matched, in: flexibleRegions)
        guard anchorSrc.count >= 4, !flexSrc.isEmpty,
              let transform = LandmarkGeometry.solveSimilarityTransform(from: anchorSrc, to: anchorDst)
        else { return nil }

        let anchorPredicted = anchorSrc.map { $0.applying(transform) }
        let anchorResidual = rms(residualMagnitudes(actual: anchorDst, predicted: anchorPredicted)) / interocular

        let flexPredicted = flexSrc.map { $0.applying(transform) }
        let flexResidual = rms(residualMagnitudes(actual: flexDst, predicted: flexPredicted)) / interocular

        // Anchor residual is the noise floor; never let it collapse to
        // (near) zero and blow the ratio up on a lucky quiet frame — real
        // detector jitter never truly hits zero either, so a floor this
        // small is itself unrealistic to divide by.
        let noiseFloor: CGFloat = 0.003
        return flexResidual / max(anchorResidual, noiseFloor)
    }

    // MARK: - S2: residual spatial coherence

    /// Whether the flexible-region residual is *differentiated* across
    /// regions (mouth moved, eyebrows didn't — or vice versa) rather than
    /// uniform. Structured, region-differentiated motion is what a real,
    /// localized facial movement looks like; undifferentiated residual
    /// spread evenly across every region looks like plain noise, which is
    /// exactly what a hand-tremored photo produces too. Secondary and
    /// lower-weighted (see `LivenessSignal.weight`) — this is the least
    /// battle-tested signal here.
    static func residualCoherence(_ window: [LivenessFrame]) -> LivenessSignalScore {
        var perRegionMeans: [LandmarkRegion: [CGFloat]] = [:]
        for i in 1..<max(window.count, 1) where i < window.count {
            guard let interocular = window[i].interocularDistance, interocular > 0 else { continue }
            let matched = correspondingPoints(window[i - 1].landmarks, window[i].landmarks)
            let (anchorSrc, anchorDst) = flatten(matched, in: anchorRegions)
            guard anchorSrc.count >= 4,
                  let transform = LandmarkGeometry.solveSimilarityTransform(from: anchorSrc, to: anchorDst)
            else { continue }

            for region in flexibleRegions {
                guard let points = matched[region] else { continue }
                let predicted = points.source.map { $0.applying(transform) }
                let residual = rms(residualMagnitudes(actual: points.destination, predicted: predicted)) / interocular
                perRegionMeans[region, default: []].append(residual)
            }
        }

        let regionAverages = perRegionMeans.compactMapValues { values -> CGFloat? in
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / CGFloat(values.count)
        }
        guard regionAverages.count >= 2 else { return .noEvidence }

        let values = Array(regionAverages.values)
        let mean = values.reduce(0, +) / CGFloat(values.count)
        guard mean > 0 else { return .noEvidence }
        let variance = values.reduce(CGFloat(0)) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(values.count)
        let coefficientOfVariation = variance.squareRoot() / mean

        // A CV near 0 means every region moved by about the same amount —
        // undifferentiated, noise-like. Real localized motion (talking
        // moves the mouth far more than the eyebrows) pushes this up.
        let score = Float(clamp(coefficientOfVariation / 0.8, 0, 1))
        let confidence = Float(clamp(Double(regionAverages.count) / Double(flexibleRegions.count), 0, 1)) * 0.7
        return LivenessSignalScore(score: score, confidence: confidence)
    }

    // MARK: - S3: depth/pose consistency

    /// Correlates nose-offset-from-eye-midline against tan(yaw) across the
    /// window. On a real face the nose protrudes off the eye plane, so its
    /// apparent offset tracks yaw; on any flat presentation the offset
    /// stays constant no matter how the plane is rotated. Confidence scales
    /// with the actual yaw range observed in the window — at the small
    /// rotations a passive, non-challenge scan realistically sees (a couple
    /// of degrees), the geometric displacement this predicts is well under
    /// a pixel, below Vision's landmark noise floor, so this signal
    /// deliberately abstains rather than vote on noise.
    static func poseDepthConsistency(_ window: [LivenessFrame]) -> LivenessSignalScore {
        let pairs = window.compactMap { frame -> (CGFloat, CGFloat)? in
            guard let offset = frame.noseOffsetRatio, let yaw = frame.yaw, frame.hasReliableLandmarks else { return nil }
            return (offset, CGFloat(tan(yaw)))
        }
        guard pairs.count >= 4 else { return .noEvidence }

        let yaws = pairs.map(\.1)
        guard let minYaw = yaws.min(), let maxYaw = yaws.max() else { return .noEvidence }
        let yawRange = abs(atan(maxYaw) - atan(minYaw))
        // Below ~5 degrees of observed rotation, the predicted nose-offset
        // displacement is sub-pixel — there's nothing to measure yet.
        let minMeasurableRange: CGFloat = 5 * .pi / 180
        guard yawRange > minMeasurableRange else { return .noEvidence }

        guard let correlation = pearsonCorrelation(pairs.map(\.0), pairs.map(\.1)) else { return .noEvidence }
        let score = Float(clamp((correlation + 1) / 2, 0, 1))
        // Confidence ramps in over the next ~15 degrees past the minimum —
        // more rotation observed, more trustworthy the correlation is.
        let confidence = Float(clamp((yawRange - minMeasurableRange) / (15 * .pi / 180), 0, 1))
        return LivenessSignalScore(score: score, confidence: confidence)
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

    // MARK: - S4: blink dynamics (supporting evidence only)

    /// Looks for a dip-and-recovery in eye-aspect-ratio — a blink. Never
    /// mandatory: humans blink every 2-10 seconds — less often still while
    /// deliberately staring at a camera to unlock, a well-documented
    /// task-focus effect — so a ~1s window frequently contains none at
    /// all, which is `.noEvidence`, not a penalty. Only ever contributes
    /// *positively* — a blink is strong evidence of life, but its absence
    /// in one short window proves nothing.
    ///
    /// Thresholds loosened from the original 0.5/0.6: real-device testing
    /// found this essentially never firing even when the user
    /// deliberately blinked, which points at Vision's general-purpose
    /// landmark model not fully collapsing the eyelid contour during a
    /// real blink (it isn't a specialized blink detector) — a partial dip
    /// is apparently the realistic signal, not the deep, clean dip the
    /// original thresholds assumed. The recovery check now looks within a
    /// small radius rather than requiring the immediate neighbor frame,
    /// since a ~100-150ms blink can span several frames at ~20fps and the
    /// exact minimum-EAR frame may not itself have a fully-open neighbor
    /// on both sides.
    static func blinkDynamics(_ window: [LivenessFrame]) -> LivenessSignalScore {
        let ears = window.compactMap { frame -> CGFloat? in
            guard let l = frame.leftEyeAspectRatio, let r = frame.rightEyeAspectRatio else { return nil }
            return (l + r) / 2
        }
        guard ears.count >= 4 else { return .noEvidence }

        let baseline = ears.max() ?? 0
        guard baseline > 0 else { return .noEvidence }
        guard let minEAR = ears.min(), let minIndex = ears.firstIndex(of: minEAR) else { return .noEvidence }

        let dipRatio = minEAR / baseline
        let recoveryRadius = 3
        let openBefore = ears[..<minIndex].suffix(recoveryRadius).contains { $0 / baseline > 0.7 }
        let openAfter = ears[(minIndex + 1)...].prefix(recoveryRadius).contains { $0 / baseline > 0.7 }
        let hasNeighborRecovery = minIndex > 0 && minIndex < ears.count - 1 && openBefore && openAfter

        guard dipRatio < 0.65, hasNeighborRecovery else { return .noEvidence }
        return LivenessSignalScore(score: 1.0, confidence: 1.0)
    }

    // MARK: - Mouth dynamics (supporting evidence only)

    /// Looks for a *decent expression change*: the mouth opening or
    /// closing, or the lips widening/narrowing as in a smile. Same role
    /// as `blinkDynamics` — never mandatory, only ever positive, and a
    /// firing event latches overall liveness at 100% (see
    /// `LivenessAnalyzer`'s live-proof hold).
    ///
    /// Deliberately NOT "did the mouth region move." Whole-head motion
    /// and Vision jitter move those points constantly; the previous MAR
    /// range check treated that as a smile and pegged this signal at
    /// 100%. Opening and width are measured in a face-aligned frame
    /// (eye-line x-axis, units of interocular distance), so translating,
    /// rolling, or leaning in does not count. A real "ah" or smile
    /// changes these by a tenth of IOD or more; a still face turning
    /// slightly does not.
    static func mouthDynamics(_ window: [LivenessFrame]) -> LivenessSignalScore {
        let openings = window.compactMap { frame -> CGFloat? in
            guard frame.hasReliableLandmarks else { return nil }
            return frame.mouthOpeningRatio
        }
        let widths = window.compactMap { frame -> CGFloat? in
            guard frame.hasReliableLandmarks else { return nil }
            return frame.mouthWidthRatio
        }
        guard openings.count >= 4, widths.count >= 4 else { return .noEvidence }

        // Absolute IOD units, not a % of the current value — a closed
        // mouth's opening is a small number, so a relative threshold
        // fires on jitter alone. Tune against Face Lab's Opening/Width
        // readout: they should sit still while you only move your head,
        // and jump when you open or smile.
        let openingRange = robustRange(openings)
        let widthRange = robustRange(widths)
        let openingChanged = openingRange >= 0.08 && hasSustainedShift(openings)
        let widthChanged = widthRange >= 0.1 && hasSustainedShift(widths)
        guard openingChanged || widthChanged else { return .noEvidence }

        return LivenessSignalScore(score: 1.0, confidence: 1.0)
    }

    /// 15th–85th percentile span, so one noisy frame can't look like an
    /// expression. On a short window this is close to min–max.
    private static func robustRange(_ values: [CGFloat]) -> CGFloat {
        guard values.count >= 2 else { return 0 }
        let sorted = values.sorted()
        let low = sorted[(sorted.count - 1) / 6]
        let high = sorted[(sorted.count * 5) / 6]
        return high - low
    }

    /// Both a low and a high cluster exist — rejects a single spike
    /// sitting far from an otherwise flat series.
    private static func hasSustainedShift(_ values: [CGFloat]) -> Bool {
        guard let minValue = values.min(), let maxValue = values.max(), maxValue > minValue else { return false }
        let midpoint = (minValue + maxValue) / 2
        return values.filter { $0 < midpoint }.count >= 2 && values.filter { $0 > midpoint }.count >= 2
    }

    // MARK: - S5: scale/depth dynamics (weak, supporting)

    /// Total variation in the anchor transform's scale factor across the
    /// window. Weak on its own — a rigidly-held photo at fixed distance and
    /// a person sitting very still look similar here — so this is
    /// low-weighted and exists mainly to catch a photo held at a
    /// perfectly constant distance, reinforcing (not replacing) the static
    /// guard.
    static func scaleDynamics(_ window: [LivenessFrame]) -> LivenessSignalScore {
        var scales: [CGFloat] = []
        for i in 1..<max(window.count, 1) where i < window.count {
            let matched = correspondingPoints(window[i - 1].landmarks, window[i].landmarks)
            let (anchorSrc, anchorDst) = flatten(matched, in: anchorRegions)
            guard anchorSrc.count >= 4,
                  let transform = LandmarkGeometry.solveSimilarityTransform(from: anchorSrc, to: anchorDst)
            else { continue }
            scales.append(sqrt(transform.a * transform.a + transform.b * transform.b))
        }
        guard scales.count >= 3 else { return .noEvidence }

        let mean = scales.reduce(0, +) / CGFloat(scales.count)
        guard mean > 0 else { return .noEvidence }
        let variance = scales.reduce(CGFloat(0)) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(scales.count)
        let coefficientOfVariation = variance.squareRoot() / mean

        let score = Float(clamp(coefficientOfVariation / 0.01, 0, 1))
        return LivenessSignalScore(score: score, confidence: 0.5)
    }

    // MARK: - S6: temporal naturalness

    /// Rejects implausibly jagged frame-to-frame motion — the generalized
    /// replacement for the old `maxYawVariation` upper bound. Computed as
    /// the "jerk" (second difference) of per-pair anchor displacement: a
    /// live face's motion is smooth from one ~50ms frame to the next; a
    /// hand physically shaking a photo, or detector instability, produces
    /// sharp, high-frequency direction reversals.
    static func temporalNaturalness(_ window: [LivenessFrame]) -> LivenessSignalScore {
        var displacements: [CGFloat] = []
        for i in 1..<max(window.count, 1) where i < window.count {
            guard let interocular = window[i].interocularDistance, interocular > 0 else { continue }
            let matched = correspondingPoints(window[i - 1].landmarks, window[i].landmarks)
            let (anchorSrc, anchorDst) = flatten(matched, in: anchorRegions)
            guard !anchorSrc.isEmpty else { continue }
            let mean = rms(residualMagnitudes(actual: anchorDst, predicted: anchorSrc)) / interocular
            displacements.append(mean)
        }
        guard displacements.count >= 3 else { return .noEvidence }

        var jerks: [CGFloat] = []
        for i in 1..<(displacements.count - 1) {
            jerks.append(abs(displacements[i + 1] - 2 * displacements[i] + displacements[i - 1]))
        }
        guard !jerks.isEmpty else { return .noEvidence }
        let meanJerk = jerks.reduce(0, +) / CGFloat(jerks.count)

        // Below this, motion reads as smooth; above, as erratic/unnatural.
        let jerkCeiling: CGFloat = 0.03
        let score = Float(clamp(1 - meanJerk / jerkCeiling, 0, 1))
        return LivenessSignalScore(score: score, confidence: 0.6)
    }

    private static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(max(value, lower), upper)
    }
}
