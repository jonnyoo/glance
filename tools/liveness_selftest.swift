//
//  liveness_selftest.swift
//  glance (tools)
//
//  Offline, camera-free separation test for `LivenessAnalyzer`. This
//  project has no test target, so this compiles as a standalone script
//  against the real scoring files:
//
//      swiftc -O -o /tmp/liveness_selftest \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/LivenessScoring.swift \
//        glance/Liveness/LivenessAnalyzer.swift \
//        tools/liveness_selftest.swift \
//      && /tmp/liveness_selftest
//
//  Deliberately NOT `LivenessFeatures.swift` — that file's extractor takes
//  a `FaceRecognitionResult`, which drags in `FaceRecognitionPipeline`,
//  CoreML, and the ArcFace model bundle. `LivenessFrame` (the type this
//  file constructs directly) lives in LivenessScoring.swift precisely so
//  this test doesn't need any of that.
//
//  It builds two synthetic landmark-sequence generators — a PLANAR one
//  (everything a printed photo or a phone screen can physically do: rigid
//  2D rotation/scale/translation, plus a slow perspective/shear "wobble"
//  term simulating someone deliberately tilting the phone to fake
//  parallax, plus per-point detector noise) and a 3D one (a crude face
//  model — nose protruding off the eye plane, small independent non-rigid
//  motion on the flexible regions — undergoing the same small head
//  rotation) — then asserts `LivenessAnalyzer` scores the 3D sequence
//  materially higher, across a swept noise floor, not at one cherry-picked
//  level. Where separation breaks down as noise increases is printed
//  explicitly: that's the honest sensitivity limit of this approach, not
//  something to hide.
//

import Foundation

// MARK: - Face template

/// A crude but topologically faithful 2D face template — enough points per
/// region for `solveSimilarityTransform` (needs >= 2, anchor regions here
/// give 8-11) and for the flexible-region residual signals to have several
/// independent points to work with. Units are arbitrary; interocular
/// distance is ~140, in the same ballpark as a face filling a meaningful
/// fraction of a 640px-wide downscaled camera frame.
private func baseTemplate() -> [LandmarkRegion: [CGPoint]] {
    [
        .leftEye: [CGPoint(x: -80, y: -5), CGPoint(x: -75, y: 5), CGPoint(x: -65, y: 5), CGPoint(x: -60, y: -5)],
        .rightEye: [CGPoint(x: 60, y: -5), CGPoint(x: 65, y: 5), CGPoint(x: 75, y: 5), CGPoint(x: 80, y: -5)],
        .nose: [CGPoint(x: -5, y: -35), CGPoint(x: 0, y: -45), CGPoint(x: 5, y: -35)],
        .outerLips: [
            CGPoint(x: -25, y: -95), CGPoint(x: -12, y: -105), CGPoint(x: 0, y: -108),
            CGPoint(x: 12, y: -105), CGPoint(x: 25, y: -95), CGPoint(x: 0, y: -90),
        ],
        .leftEyebrow: [CGPoint(x: -85, y: 20), CGPoint(x: -72, y: 26), CGPoint(x: -58, y: 22)],
        .rightEyebrow: [CGPoint(x: 58, y: 22), CGPoint(x: 72, y: 26), CGPoint(x: 85, y: 20)],
        .faceContour: (0..<8).map { i -> CGPoint in
            let angle = Double(i) / 8 * 2 * .pi
            return CGPoint(x: 150 * cos(angle), y: -30 + 170 * sin(angle))
        },
    ]
}

/// Per-point depth (z, toward the camera is positive) for the 3D generator.
/// Only the nose protrudes — the physical fact `poseDepthConsistency`
/// exploits. Everything else sits flush on the eye plane, same as a real
/// face's eyes/brow/jaw line does relative to the nose.
private func depthTemplate() -> [LandmarkRegion: CGFloat] {
    [.leftEye: 0, .rightEye: 0, .nose: 28, .outerLips: 4, .leftEyebrow: 2, .rightEyebrow: 2, .faceContour: 0]
}

private let anchorRegions: Set<LandmarkRegion> = [.leftEye, .rightEye, .nose]
private let flexibleRegions: Set<LandmarkRegion> = [.outerLips, .innerLips, .leftEyebrow, .rightEyebrow, .faceContour, .noseCrest, .medianLine]

// MARK: - Random helpers

private func gaussian(std: CGFloat, using rng: inout SystemRandomNumberGenerator) -> CGFloat {
    guard std > 0 else { return 0 }
    // Box-Muller.
    let u1 = Double.random(in: 0.0001...0.9999, using: &rng)
    let u2 = Double.random(in: 0...1, using: &rng)
    return CGFloat(sqrt(-2 * log(u1)) * cos(2 * .pi * u2)) * std
}

// MARK: - Sequence generators

/// A flat presentation: the WHOLE template moves as one rigid-ish 2D
/// transform (small rotation, small scale drift, translation) plus a slow
/// shear/perspective "wobble" term — the adversarial case of someone
/// deliberately tilting the phone to fake parallax, which a pure
/// similarity-transform fit can't perfectly absorb either. Every point,
/// anchor or flexible, gets the same transform plus independent noise —
/// there is no such thing as an independently-moving mouth on a photo.
private func generatePlanarSequence(frameCount: Int, noiseStd: CGFloat, seed: UInt64) -> [LivenessFrame] {
    var rng = SystemRandomNumberGenerator()
    let template = baseTemplate()
    var frames: [LivenessFrame] = []

    for i in 0..<frameCount {
        let t = Double(i) / Double(max(frameCount - 1, 1))
        let rotation = CGFloat(0.05 * sin(t * 2 * .pi * 0.7))       // small rocking rotation
        let scale: CGFloat = 1 + 0.01 * CGFloat(sin(t * 2 * .pi * 0.5))
        let translation = CGPoint(x: 3 * CGFloat(sin(t * 2 * .pi * 0.3)), y: 2 * CGFloat(cos(t * 2 * .pi * 0.4)))
        // Perspective/shear wobble: grows and decays over the window,
        // shearing X proportional to Y — what a tilted phone does to a
        // flat image. Deliberately affects every region equally.
        let shear = CGFloat(0.018 * sin(t * 2 * .pi * 0.9))

        var landmarks: [LandmarkPoint] = []
        for (region, points) in template {
            for (index, base) in points.enumerated() {
                let sheared = CGPoint(x: base.x + shear * base.y, y: base.y)
                let cosT = cos(rotation), sinT = sin(rotation)
                let rotated = CGPoint(
                    x: (sheared.x * cosT - sheared.y * sinT) * scale,
                    y: (sheared.x * sinT + sheared.y * cosT) * scale
                )
                let noisy = CGPoint(
                    x: rotated.x + translation.x + gaussian(std: noiseStd, using: &rng),
                    y: rotated.y + translation.y + gaussian(std: noiseStd, using: &rng)
                )
                landmarks.append(LandmarkPoint(point: noisy, region: region, indexInRegion: index))
            }
        }

        let interocular: CGFloat = 140 * scale
        frames.append(LivenessFrame(
            timestamp: Date(timeIntervalSince1970: t),
            landmarks: landmarks,
            interocularDistance: interocular,
            yaw: Float(rotation), pitch: 0, roll: Float(rotation),
            normalizedFaceWidth: 0.3,
            leftEyeAspectRatio: 0.35, rightEyeAspectRatio: 0.35,
            noseOffsetRatio: 0,   // a plane's nose offset doesn't move with "yaw" — the whole point
            quality: 0.8, hasReliableLandmarks: true
        ))
    }
    return frames
}

/// A crude 3D face: small head rotation about the vertical axis (real
/// pose change, not a plane's fake one), applied via simple orthographic
/// projection so the protruding nose's projected X position genuinely
/// shifts with yaw — plus small independent non-rigid motion on the
/// flexible regions only (a live face's soft tissue moving on its own),
/// plus the same per-point noise the planar generator gets.
private func generateLiveSequence(frameCount: Int, noiseStd: CGFloat, seed: UInt64) -> [LivenessFrame] {
    var rng = SystemRandomNumberGenerator()
    let template = baseTemplate()
    let depths = depthTemplate()
    var frames: [LivenessFrame] = []

    for i in 0..<frameCount {
        let t = Double(i) / Double(max(frameCount - 1, 1))
        // A few degrees of passive rotation — plausible for someone just
        // sitting normally, not deliberately posing.
        let yaw = CGFloat(0.09 * sin(t * 2 * .pi * 0.6))

        var landmarks: [LandmarkPoint] = []
        for (region, points) in template {
            let z = depths[region] ?? 0
            for (index, base) in points.enumerated() {
                // Independent small non-rigid motion — only on soft tissue,
                // never on the anchor set (eyes/nose don't deform).
                var moved = base
                if flexibleRegions.contains(region) {
                    let phase = Double(index) * 1.7 + Double(region.hashValue % 10)
                    moved.x += 8.0 * CGFloat(sin(t * 2 * .pi * 1.3 + phase))
                    moved.y += 5.0 * CGFloat(cos(t * 2 * .pi * 1.1 + phase))
                }

                // Rotate about Y: x' = x cosY + z sinY (orthographic — drop
                // the resulting z). This is what makes the protruding
                // nose's projected X track yaw and everything else barely
                // move relative to it.
                let cosY = cos(yaw), sinY = sin(yaw)
                let projectedX = moved.x * cosY + z * sinY

                let noisy = CGPoint(
                    x: projectedX + gaussian(std: noiseStd, using: &rng),
                    y: moved.y + gaussian(std: noiseStd, using: &rng)
                )
                landmarks.append(LandmarkPoint(point: noisy, region: region, indexInRegion: index))
            }
        }

        let noseOffset = (28 * sin(yaw)) / 140  // matches the analyzer's own normalization
        frames.append(LivenessFrame(
            timestamp: Date(timeIntervalSince1970: t),
            landmarks: landmarks,
            interocularDistance: 140,
            yaw: Float(yaw), pitch: 0, roll: 0,
            normalizedFaceWidth: 0.3,
            leftEyeAspectRatio: 0.35, rightEyeAspectRatio: 0.35,
            noseOffsetRatio: noseOffset,
            quality: 0.9, hasReliableLandmarks: true
        ))
    }
    return frames
}

// MARK: - Sweep
//
// Wrapped in `@main` rather than left as top-level statements: `swiftc`
// only allows top-level executable code in a file literally named
// `main.swift`, and this file keeps its descriptive name instead.

@main
struct LivenessSelfTest {
    static func main() {
        let frameCount = 20 // ~1s at ~20fps, matching LivenessAnalyzer's real window
        let noiseLevels: [CGFloat] = [0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0]
        var breakingPoint: CGFloat?

        print("noise(px)  planar-score  live-score  margin")
        for noise in noiseLevels {
            let planarFrames = generatePlanarSequence(frameCount: frameCount, noiseStd: noise, seed: 1)
            let liveFrames = generateLiveSequence(frameCount: frameCount, noiseStd: noise, seed: 2)

            let planar = LivenessAnalyzer.evaluate(planarFrames, minFramesRequired: 5, threshold: 0.5)
            let live = LivenessAnalyzer.evaluate(liveFrames, minFramesRequired: 5, threshold: 0.5)
            let margin = live.overallScore - planar.overallScore

            print(String(format: "%6.1f     %9.3f     %8.3f    %+.3f", noise, planar.overallScore, live.overallScore, margin))

            if margin <= 0.05, breakingPoint == nil {
                breakingPoint = noise
            }
        }

        print("")
        if let breakingPoint {
            print("Separation breaks down at noise >= \(breakingPoint)px — the honest sensitivity limit of this synthetic model. Real Vision landmark jitter at typical webcam range should sit well under this; verify against Face Lab's live readout.")
        } else {
            print("Separation held across the entire swept noise range (0...\(noiseLevels.last!)px).")
        }

        // The load-bearing assertion: at LOW, realistic noise, live must score
        // clearly above planar. This is what would catch a regression that
        // silently broke the non-rigid-residual signal.
        let planarLowNoise = generatePlanarSequence(frameCount: frameCount, noiseStd: 1.0, seed: 1)
        let liveLowNoise = generateLiveSequence(frameCount: frameCount, noiseStd: 1.0, seed: 2)
        let planarResult = LivenessAnalyzer.evaluate(planarLowNoise, minFramesRequired: 5, threshold: 0.5)
        let liveResult = LivenessAnalyzer.evaluate(liveLowNoise, minFramesRequired: 5, threshold: 0.5)
        precondition(
            liveResult.overallScore > planarResult.overallScore + 0.15,
            "FAIL: at realistic noise (1.0px), live score (\(liveResult.overallScore)) did not clear planar score (\(planarResult.overallScore)) by a meaningful margin."
        )
        print("\nPASS: live sequence separates from planar sequence at realistic noise levels.")
    }
}
