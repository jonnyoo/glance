//
//  LivenessCues.swift
//  glance
//
//  The liveness decision model. Replaces the previous two-checker design
//  (a weighted-mean "overall %" over ~11 motion signals, plus a separate
//  noisy-OR spoof score over 7 appearance cues) with five cues and no
//  score to threshold at all.
//
//  That redesign came out of real-device testing: most of the old signals
//  were noise-limited at webcam resolution, several actively rewarded the
//  smooth motion of a hand holding up a phone, and averaging them produced
//  a number that wandered 30-80% on a live face while a phone photo scored
//  about the same. Only five cues actually separated a real face from a
//  phone in practice, and each of them is *individually* decisive when it
//  fires — which makes averaging exactly the wrong combination rule. So
//  there is deliberately no overall percentage here: each cue simply has to
//  show up over a few frames to count, and what it means when it does
//  depends only on which side it's evidence for.
//
//  Two roles, asymmetric on purpose:
//
//    * DENY cues (gloss/glare, device detected) are evidence of a spoof.
//      Either one firing fails the scan outright, independently of
//      everything else, and overrides any confirmation that already
//      happened. A spoof tell doesn't get outvoted.
//
//    * CONFIRM cues (flat-vs-3D, depth/pose, blink) are evidence of a real
//      face. Any one firing is enough. Critically, their *absence* is not a
//      failure — a live person can sit still and not blink for a whole
//      scan. Nothing confirming just leaves the decision `.pending`, and
//      the scan keeps looking until the user's own face-detection duration
//      runs out.
//
//  No Vision/CoreImage import — same discipline as `LivenessScoring.swift`
//  — so this compiles into `tools/liveness_selftest.swift` standalone.
//

import CoreGraphics

/// One cue's latest reading. `confidence` 0 means "this cue had nothing to
/// go on this frame" (no native-resolution crop, not enough head rotation,
/// too few frames) and is always treated as an abstention, never as a
/// reading of zero — a cue that can't see anything must not be able to
/// convict *or* acquit.
struct CueReading: Equatable {
    /// 0...1 strength of this cue's own evidence, in the direction that
    /// cue argues for (spoof-ness for deny cues, liveness for confirm cues).
    let level: Float
    let confidence: Float

    nonisolated static let none = CueReading(level: 0, confidence: 0)
}

enum LivenessCueRole: Equatable {
    /// Evidence of a spoof. Firing fails the scan and overrides confirmation.
    case deny
    /// Evidence of a real face. Firing passes the liveness half of the scan.
    case confirm
}

enum LivenessCue: String, CaseIterable, Hashable, Identifiable {
    case glossGlare
    case deviceDetected
    case flatVs3D
    case depthPose
    case blink

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .glossGlare: return "Gloss/glare"
        case .deviceDetected: return "Device detected"
        case .flatVs3D: return "Flat vs 3D"
        case .depthPose: return "Depth/pose"
        case .blink: return "Blink"
        }
    }

    nonisolated var role: LivenessCueRole {
        switch self {
        case .glossGlare, .deviceDetected: return .deny
        case .flatVs3D, .depthPose, .blink: return .confirm
        }
    }

    /// One-line explanation of what firing actually means, for Face Lab.
    nonisolated var explanation: String {
        switch self {
        case .glossGlare: return "Large flat specular highlight — glass/screen glare rather than skin's small scattered shine."
        case .deviceDetected: return "A device-shaped rectangle overlaps the face — a phone or tablet held up."
        case .flatVs3D: return "Held-out nose points miss the plane fit — the face has real depth."
        case .depthPose: return "Nose offset tracks head yaw — the nose sits off the eye plane, so this isn't flat."
        case .blink: return "Eye aspect ratio dipped and recovered — a photo cannot blink."
        }
    }
}

/// How much liveness checking runs. Both modes always run the deny cues —
/// the difference is only whether a *positive* proof of life is also
/// required before unlocking.
enum LivenessMode: String, CaseIterable, Identifiable, Sendable {
    /// Deny-only: "confirmed unless proven wrong." Nothing has to prove the
    /// face is real; a spoof tell still fails the scan. Never blocks a
    /// legitimate user who happens to sit still, which is why it's the
    /// default.
    case light
    /// Deny cues, plus at least one confirm cue must fire before unlock. A
    /// real presentation-attack gate — but it can leave a genuinely live
    /// user unable to unlock if they hold perfectly still and don't blink
    /// for the whole scan, since none of the confirm cues would ever fire.
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .heavy: return "Heavy"
        }
    }

    var summary: String {
        switch self {
        case .light: return "Only rejects obvious spoofs."
        case .heavy: return "Also requires proof of a real face."
        }
    }
}

/// Fire thresholds per cue: a cue counts a frame when its reading is
/// confident and at/above `level`, and fires once it has counted
/// `frames` of them within the scan.
///
/// These are seeded from real-device observation, not synthetic data:
/// gloss/glare sat at 0 on a live face and 30-40% against a phone screen,
/// and the device rectangle detector was reliable enough that even slight
/// persistent overlap is worth acting on. Retune from Face Lab, where every
/// cue's live reading and frame count are shown directly.
struct LivenessTuning: Equatable {
    var glossLevel: Float = 0.15
    var glossFrames: Int = 3

    var deviceLevel: Float = 0.3
    var deviceFrames: Int = 5

    /// 0.25, not the 0.5 you might expect from "spikes up". The synthetic
    /// self-test measures a clean 3D face at only ~0.21 once ~1px of
    /// landmark noise is present (0.99 at zero noise, 0.46 at 0.5px) —
    /// real-world Vision jitter is in that range, so a 0.5 gate would mean
    /// this cue essentially never fires and Heavy mode would rest entirely
    /// on blink. A tilted photo measures ~0.02 and a still plane 0.00 in
    /// the same test, so 0.25 still leaves an order of magnitude of margin
    /// over the thing this cue exists to reject.
    var flatVs3DLevel: Float = 0.25
    var flatVs3DFrames: Int = 2

    /// 0.8, deliberately high, because this cue's level is a remapped
    /// correlation: `(r + 1) / 2`. That puts *zero* correlation — pure
    /// noise, no relationship between nose offset and yaw at all — at
    /// exactly 0.5. Anything at or near 0.5 is therefore evidence of
    /// nothing, and a 0.5 gate would let a noisy flat presentation confirm
    /// itself as live. 0.8 corresponds to r >= 0.6: a genuinely positive
    /// relationship of the kind only a nose sitting off the eye plane
    /// produces.
    var depthPoseLevel: Float = 0.4
    var depthPoseFrames: Int = 2

    /// A blink is already a discrete dip-and-recover event detected across
    /// the window (see `LivenessScoring.blinkDynamics`), not a level that
    /// ramps — so one firing frame is the event itself, not a coincidence.
    var blinkFrames: Int = 1

    /// Frames Light mode waits before auto-confirming, so the deny cues get
    /// a fair chance to fire first. At ~20fps this is well under a tenth of
    /// a second — imperceptible, and recognition itself takes longer — but
    /// without it a first-frame match could unlock before the glare/device
    /// check had ever run, which would make Light mode's "unless proven
    /// wrong" promise hollow.
    var lightModeMinimumFrames: Int = 3

    nonisolated static let `default` = LivenessTuning()

    nonisolated func level(for cue: LivenessCue) -> Float {
        switch cue {
        case .glossGlare: return glossLevel
        case .deviceDetected: return deviceLevel
        case .flatVs3D: return flatVs3DLevel
        case .depthPose: return depthPoseLevel
        // Any confident blink reading is the event; see `blinkFrames`.
        case .blink: return 0.5
        }
    }

    nonisolated func frames(for cue: LivenessCue) -> Int {
        switch cue {
        case .glossGlare: return glossFrames
        case .deviceDetected: return deviceFrames
        case .flatVs3D: return flatVs3DFrames
        case .depthPose: return depthPoseFrames
        case .blink: return blinkFrames
        }
    }
}

enum LivenessDecision: Equatable {
    /// Nothing decided yet. Not a failure — the scan should keep going.
    case pending
    /// Cue is `nil` when Light mode auto-confirmed rather than any cue firing.
    case confirmed(by: LivenessCue?)
    case denied(by: LivenessCue)

    var isConfirmed: Bool { if case .confirmed = self { return true }; return false }
    var isDenied: Bool { if case .denied = self { return true }; return false }

    /// User-facing explanation for a denial, matching the tone of the
    /// coordinator's other outcome strings.
    var denialReason: String? {
        guard case .denied(let cue) = self else { return nil }
        switch cue {
        case .glossGlare: return "Screen glare detected — this looks like a photo on a display."
        case .deviceDetected: return "A device-shaped rectangle was detected around the face — this looks like a photo or screen."
        default: return "Liveness check failed."
        }
    }
}

/// Running state for one cue across a scan.
struct LivenessCueState: Equatable {
    var reading: CueReading = .none
    /// How many frames this cue has counted so far this scan. Cumulative,
    /// not consecutive — matching the rule these cues are specified by
    /// ("has to appear a few times"), and more forgiving of the one-frame
    /// dropouts Vision routinely produces mid-scan.
    var framesCounted: Int = 0
    var hasFired: Bool = false

    /// 0...1 progress toward firing, for Face Lab's progress bars.
    func progress(threshold: Int) -> Float {
        guard threshold > 0 else { return hasFired ? 1 : 0 }
        return min(1, Float(framesCounted) / Float(threshold))
    }
}

struct LivenessSnapshot: Equatable {
    let decision: LivenessDecision
    let mode: LivenessMode
    let cueStates: [LivenessCue: LivenessCueState]
    let frameCount: Int

    nonisolated static let empty = LivenessSnapshot(
        decision: .pending, mode: .light, cueStates: [:], frameCount: 0
    )

    func state(for cue: LivenessCue) -> LivenessCueState {
        cueStates[cue] ?? LivenessCueState()
    }
}

/// The stateful decision core, kept as a plain `struct` rather than folded
/// into `LivenessAnalyzer` so `tools/liveness_selftest.swift` can drive the
/// real firing/latching logic frame by frame with no actor or camera.
struct LivenessEvaluator {
    var mode: LivenessMode
    var tuning: LivenessTuning
    /// Face Lab can switch individual cues off to isolate one; the unlock
    /// path leaves this at "all enabled."
    var enabledCues: Set<LivenessCue>

    private(set) var states: [LivenessCue: LivenessCueState] = [:]
    private(set) var framesObserved: Int = 0

    init(
        mode: LivenessMode = .light,
        tuning: LivenessTuning = .default,
        enabledCues: Set<LivenessCue> = Set(LivenessCue.allCases)
    ) {
        self.mode = mode
        self.tuning = tuning
        self.enabledCues = enabledCues
    }

    mutating func reset() {
        states = [:]
        framesObserved = 0
    }

    /// Folds one frame's readings in and returns the decision as it now
    /// stands. Firing is latched: a cue that has fired stays fired for the
    /// rest of the scan, so a spoof tell that appears briefly can't be
    /// waited out, and a blink early in the scan still counts later.
    mutating func observe(_ readings: [LivenessCue: CueReading]) -> LivenessSnapshot {
        framesObserved += 1

        for cue in LivenessCue.allCases {
            var state = states[cue] ?? LivenessCueState()
            let reading = readings[cue] ?? .none
            state.reading = reading
            if reading.confidence > 0, reading.level >= tuning.level(for: cue) {
                state.framesCounted += 1
                if state.framesCounted >= tuning.frames(for: cue) {
                    state.hasFired = true
                }
            }
            states[cue] = state
        }

        return LivenessSnapshot(
            decision: currentDecision(), mode: mode, cueStates: states, frameCount: framesObserved
        )
    }

    /// Deny is evaluated first and is unconditional — it overrides a
    /// confirmation that already happened, which is the whole point of
    /// splitting the cues by role rather than scoring them together.
    private func currentDecision() -> LivenessDecision {
        for cue in LivenessCue.allCases
        where cue.role == .deny && enabledCues.contains(cue) && (states[cue]?.hasFired ?? false) {
            return .denied(by: cue)
        }

        if mode == .light {
            return framesObserved >= tuning.lightModeMinimumFrames ? .confirmed(by: nil) : .pending
        }

        for cue in LivenessCue.allCases
        where cue.role == .confirm && enabledCues.contains(cue) && (states[cue]?.hasFired ?? false) {
            return .confirmed(by: cue)
        }

        return .pending
    }
}

/// Turns a rolling window (plus the geometry result computed from it) into
/// this frame's reading for every cue.
///
/// Deny cues read the *latest frame only* — they're per-frame appearance
/// measurements, and `LivenessEvaluator`'s frame counting is what supplies
/// the "sustained over several frames" requirement. Confirm cues are
/// inherently cross-frame (parallax, yaw correlation, a blink's
/// dip-and-recover) so they read the whole window.
nonisolated enum LivenessCues {
    nonisolated static func readings(
        window: [LivenessFrame], geometry: GeometryLivenessResult
    ) -> [LivenessCue: CueReading] {
        [
            .glossGlare: glossGlare(window.last),
            .deviceDetected: deviceDetected(window.last),
            .flatVs3D: geometry.planarReading,
            .depthPose: LivenessScoring.poseDepthConsistency(window),
            .blink: LivenessScoring.blinkDynamics(window),
        ]
    }

    /// Skin gives many small scattered specular points; glass gives one big
    /// flat blob. `specularFraction` alone would fire on a bright forehead,
    /// so it's gated by how concentrated that glare is.
    nonisolated static func glossGlare(_ frame: LivenessFrame?) -> CueReading {
        guard let glare = frame?.glare else { return .none }
        let fractionScore = ramp(glare.specularFraction, floor: 0.01, ceiling: 0.08)
        let clusterFactor = ramp(glare.specularClusterRatio, floor: 0.3, ceiling: 1.0)
        let level = fractionScore * (0.3 + 0.7 * clusterFactor)
        // Below ~50 native px of face there isn't enough detail to tell a
        // glare blob from a bright patch; ramps to full trust by ~130px.
        let confidence = ramp(Float(glare.cropPixelWidth), floor: 50, ceiling: 130)
        return CueReading(level: level, confidence: confidence)
    }

    /// Raw overlap fraction from `DeviceBezelDetector`, used directly rather
    /// than re-scaled: the fire threshold is expressed in the same units
    /// (a fraction of the face box covered by a device-shaped rectangle),
    /// so what Face Lab shows is exactly what the threshold compares.
    nonisolated static func deviceDetected(_ frame: LivenessFrame?) -> CueReading {
        guard let overlap = frame?.deviceOverlapFraction else { return .none }
        return CueReading(level: Float(min(max(overlap, 0), 1)), confidence: 1)
    }

    nonisolated static func ramp(_ value: Float, floor: Float, ceiling: Float) -> Float {
        min(max((value - floor) / max(ceiling - floor, 0.0001), 0), 1)
    }
}
