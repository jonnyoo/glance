//
//  LivenessAnalyzer.swift
//  glance
//
//  Rolling-window driver for the liveness cues: holds the last ~2s of
//  `LivenessFrame`s, computes every cue's reading from them each frame, and
//  feeds those into a `LivenessEvaluator` that accumulates fire counts and
//  produces a decision.
//
//  Deliberately takes `LivenessFrame` values, not `FaceRecognitionResult` —
//  callers extract via `LivenessFeatureExtractor.extract(from:)` first.
//  That keeps this file's dependency graph shallow (no
//  FaceRecognitionPipeline, no CoreML, no FaceEnrollmentStore), which is
//  what makes `tools/liveness_selftest.swift` able to compile and exercise
//  the real decision logic against synthetic data, offline, with no camera.
//
//  There is no score and no threshold here any more. The previous version
//  combined ~11 signals into a weighted mean and compared it against a
//  user-facing "liveness strictness" slider; that number wandered 30-80% on
//  a live face and sat in the same range for a photo on a phone. See
//  `LivenessCues.swift` for the five-cue, fire-and-latch model that
//  replaced it.
//

import Foundation

@MainActor
final class LivenessAnalyzer {
    private let windowDuration: TimeInterval

    /// Read fresh on every `observe()` rather than captured at init, so a
    /// mid-scan change in Settings (or a Face Lab toggle) takes effect on
    /// the next frame instead of needing a new scan cycle.
    var modeProvider: () -> LivenessMode = { .light }
    var tuningProvider: () -> LivenessTuning = { .default }
    /// Face Lab can switch individual cues off to isolate one; the unlock
    /// path leaves this at "all enabled."
    var enabledCuesProvider: () -> Set<LivenessCue> = { Set(LivenessCue.allCases) }

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

    /// Feeds one frame into the rolling window and returns the decision as
    /// it now stands. Call once per frame that had a face detected —
    /// liveness is fed regardless of whether that frame also matched an
    /// identity, so the window stays dense and liveness stays a genuinely
    /// independent gate rather than one starved by recognition's own
    /// confidence.
    ///
    /// Note the asymmetry between the two pieces of state: the *window* is
    /// time-pruned (a cue reading only ever reflects the last ~2s), but the
    /// evaluator's fire counts are **not** — they accumulate across the
    /// whole scan. That's deliberate. A blink 4 seconds into a scan should
    /// still count at second 6, and a spoof tell that flashes briefly
    /// shouldn't be waitable-out by holding still until it ages out.
    @discardableResult
    func observe(_ frame: LivenessFrame) -> LivenessSnapshot {
        frames.append(frame)
        frames.removeAll { frame.timestamp.timeIntervalSince($0.timestamp) > windowDuration }

        evaluator.mode = modeProvider()
        evaluator.tuning = tuningProvider()
        evaluator.enabledCues = enabledCuesProvider()

        let geometry = GeometryLiveness.evaluate(frames)
        lastGeometry = geometry

        let readings = LivenessCues.readings(window: frames, geometry: geometry)
        let snapshot = evaluator.observe(readings)
        lastSnapshot = snapshot
        return snapshot
    }
}
