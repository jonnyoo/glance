//
//  enrollment_selftest.swift
//  glance
//
//  Measures how hard guided enrollment is to complete, by driving the real pose-matching maths with a simulated
//  head. Same manual-script style as liveness_selftest.swift:
//
//      swiftc -O tools/enrollment_selftest.swift -o /tmp/enrollment_selftest && /tmp/enrollment_selftest
//
//  The interesting number is the gap between what the progress ring shows the user and what the gate actually
//  requires. They are computed from one shared vector now; this asserts they stay that way.
//

import Foundation

// MARK: - Constants, mirrored from OnboardingController

let yawInnerThreshold: Float = 0.25
let pitchInnerThreshold: Float = 0.20
let yawCenterTolerance: Float = 0.18
let pitchCenterTolerance: Float = 0.15
let poseSectorTolerance: Double = 22.5
let outerMagnitudeCap: Double = 4.5
let stallWidenFactor: Float = 1.25

enum Pose: String, CaseIterable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    var compassAngle: Double? {
        switch self {
        case .center: return nil
        case .left: return 270
        case .topLeft: return 315
        case .top: return 0
        case .topRight: return 45
        case .right: return 90
        case .bottomRight: return 135
        case .bottom: return 180
        case .bottomLeft: return 225
        }
    }

    var matchLeniency: Float {
        switch self {
        case .bottomLeft, .bottomRight: return 1.5
        case .bottom: return 1.2
        default: return 1
        }
    }

    var isDiagonal: Bool {
        switch self {
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        default: return false
        }
    }
}

// MARK: - The maths under test

struct TurnVector {
    let x: Double
    let y: Double
    var magnitude: Double { (x * x + y * y).squareRoot() }
    var compassAngle: Double {
        let d = atan2(x, y) * 180 / .pi
        return d < 0 ? d + 360 : d
    }
}

func normalizedTurn(yaw: Float, pitch: Float) -> TurnVector {
    TurnVector(x: Double(-yaw / yawInnerThreshold), y: Double(-pitch / pitchInnerThreshold))
}

func requiredMagnitude(for pose: Pose, widened: Bool) -> Double {
    1.0 / Double((widened ? stallWidenFactor : 1.0) * pose.matchLeniency)
}

func angularDistance(_ a: Double, _ b: Double) -> Double {
    let d = abs(a - b).truncatingRemainder(dividingBy: 360)
    return min(d, 360 - d)
}

/// Current implementation: one vector, shared with the ring.
func poseMatches(yaw: Float, pitch: Float, pose: Pose, widened: Bool) -> Bool {
    let factor = (widened ? stallWidenFactor : 1.0) * pose.matchLeniency
    guard let compass = pose.compassAngle else {
        return abs(yaw) < yawCenterTolerance * factor && abs(pitch) < pitchCenterTolerance * factor
    }
    let turn = normalizedTurn(yaw: yaw, pitch: pitch)
    guard turn.magnitude >= requiredMagnitude(for: pose, widened: widened),
          turn.magnitude <= outerMagnitudeCap else { return false }
    return angularDistance(turn.compassAngle, compass) <= poseSectorTolerance
}

/// What the ring shows the user, 0...1.
func ringProgress(yaw: Float, pitch: Float, pose: Pose) -> Double {
    let turn = normalizedTurn(yaw: yaw, pitch: pitch)
    return min(turn.magnitude / requiredMagnitude(for: pose, widened: false), 1)
}

/// The previous rectangular test, kept only so the regression stays visible.
func legacyPoseMatches(yaw: Float, pitch: Float, pose: Pose, widened: Bool) -> Bool {
    let f = (widened ? stallWidenFactor : 1.0) * pose.matchLeniency
    let yawOuterCap: Float = 1.2, pitchOuterCap: Float = 0.9
    let yawOK: Bool, pitchOK: Bool
    switch pose {
    case .left, .topLeft, .bottomLeft: yawOK = yaw > yawInnerThreshold / f && yaw < yawOuterCap
    case .right, .topRight, .bottomRight: yawOK = yaw < -yawInnerThreshold / f && yaw > -yawOuterCap
    default: yawOK = abs(yaw) < yawCenterTolerance * f
    }
    switch pose {
    case .top, .topLeft, .topRight: pitchOK = pitch < -pitchInnerThreshold / f && pitch > -pitchOuterCap
    case .bottom, .bottomLeft, .bottomRight: pitchOK = pitch > pitchInnerThreshold / f && pitch < pitchOuterCap
    default: pitchOK = abs(pitch) < pitchCenterTolerance * f
    }
    return yawOK && pitchOK
}

/// Turn the head along `pose`'s own direction by `magnitude` normalized units, and report the raw Vision angles.
func headAngles(towards pose: Pose, magnitude: Double) -> (yaw: Float, pitch: Float) {
    guard let compass = pose.compassAngle else { return (0, 0) }
    let radians = compass * .pi / 180
    let x = sin(radians) * magnitude
    let y = cos(radians) * magnitude
    return (yaw: Float(-x * Double(yawInnerThreshold)), pitch: Float(-y * Double(pitchInnerThreshold)))
}

/// Seeded so a run is reproducible: a self-test that reports different numbers each time cannot be regression-checked.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

var failures = 0
func check(_ condition: Bool, _ label: String) {
    print("  \(condition ? "PASS" : "FAIL")  \(label)")
    if !condition { failures += 1 }
}

// MARK: - 1. The ring and the gate must agree

print("\n1. Turn along each pose's own direction: where does the ring read 100%, where does the gate accept?\n")
print(String(format: "   %-12@ %-10@ %-10@ %-10@ %@", "pose" as NSString, "ring 100%" as NSString,
             "gate now" as NSString, "gate was" as NSString, "was/now" as NSString))

for pose in Pose.allCases where pose != .center {
    func firstMagnitude(_ test: (Float, Float) -> Bool) -> Double {
        var m = 0.005
        while m <= 5.0 {
            let a = headAngles(towards: pose, magnitude: m)
            if test(a.yaw, a.pitch) { return m }
            m += 0.005
        }
        return .nan
    }
    let ring = firstMagnitude { ringProgress(yaw: $0, pitch: $1, pose: pose) >= 1.0 }
    let now = firstMagnitude { poseMatches(yaw: $0, pitch: $1, pose: pose, widened: false) }
    let was = firstMagnitude { legacyPoseMatches(yaw: $0, pitch: $1, pose: pose, widened: false) }
    print(String(format: "   %-12@ %-10.2f %-10.2f %-10.2f %.2fx", pose.rawValue as NSString, ring, now, was, was / now))
}

print("")
for pose in Pose.allCases where pose != .center {
    var worst = 0.0
    var m = 0.005
    while m <= 3.0 {
        let a = headAngles(towards: pose, magnitude: m)
        let ringSaysDone = ringProgress(yaw: a.yaw, pitch: a.pitch, pose: pose) >= 1.0
        let gateAccepts = poseMatches(yaw: a.yaw, pitch: a.pitch, pose: pose, widened: false)
        if ringSaysDone != gateAccepts { worst = max(worst, m) }
        m += 0.005
    }
    check(worst == 0, "\(pose.rawValue): ring and gate agree at every turn magnitude")
}

// MARK: - 2. Diagonals must not be harder than cardinals

print("\n2. A diagonal should cost the same head turn as a cardinal\n")
let cardinalCost = ["left", "top", "right"].compactMap { name in
    Pose.allCases.first { $0.rawValue == name }
}.map { pose -> Double in
    var m = 0.005
    while m <= 5.0 {
        let a = headAngles(towards: pose, magnitude: m)
        if poseMatches(yaw: a.yaw, pitch: a.pitch, pose: pose, widened: false) { return m }
        m += 0.005
    }
    return .nan
}
let worstCardinal = cardinalCost.max() ?? .nan
for pose in Pose.allCases where pose.isDiagonal {
    var m = 0.005
    var cost = Double.nan
    while m <= 5.0 {
        let a = headAngles(towards: pose, magnitude: m)
        if poseMatches(yaw: a.yaw, pitch: a.pitch, pose: pose, widened: false) { cost = m; break }
        m += 0.005
    }
    check(cost <= worstCardinal + 0.01, String(format: "%@ costs %.2f, no worse than the %.2f a cardinal costs",
                                               pose.rawValue, cost, worstCardinal))
}

// MARK: - 3. A turn must only satisfy the sector it points at

print("\n3. A turn must satisfy only the pose it points at\n")
for pose in Pose.allCases where pose != .center {
    let a = headAngles(towards: pose, magnitude: 1.6)
    let matched = Pose.allCases.filter { poseMatches(yaw: a.yaw, pitch: a.pitch, pose: $0, widened: false) }
    check(matched == [pose], "turning toward \(pose.rawValue) matches only \(pose.rawValue) (got \(matched.map(\.rawValue)))")
}

// MARK: - 4. Looking straight ahead is still centre, and only centre

print("\n4. Looking straight ahead\n")
let straight = Pose.allCases.filter { poseMatches(yaw: 0, pitch: 0, pose: $0, widened: false) }
check(straight == [.center], "a still head matches only centre (got \(straight.map(\.rawValue)))")

// MARK: - 5. Noisy heads: can a real person finish?

print("\n5. Simulated enrollment with a noisy head estimate\n")

/// Vision's yaw/pitch on a 2D webcam jitters. Model a user who aims at the requested sector and overshoots or
/// undershoots, with per-frame noise on top, and count how many frames it takes to satisfy each pose.
func simulate(matcher: (Float, Float, Pose, Bool) -> Bool, aim: Double, noise: Double, seed: UInt64) -> Int? {
    var rng = SplitMix64(seed: seed)
    var frames = 0
    for pose in Pose.allCases {
        var streak = 0
        var poseFrames = 0
        while streak < 3 {
            poseFrames += 1
            frames += 1
            if poseFrames > 600 { return nil }          // ~20s at 30fps: the user gave up
            let widened = poseFrames > 360              // stallTimeout 12s
            let jitterX = Double.random(in: -noise...noise, using: &rng)
            let jitterY = Double.random(in: -noise...noise, using: &rng)
            let (yaw, pitch): (Float, Float)
            if pose == .center {
                yaw = Float(jitterX * Double(yawInnerThreshold))
                pitch = Float(jitterY * Double(pitchInnerThreshold))
            } else {
                let base = headAngles(towards: pose, magnitude: aim)
                yaw = base.yaw + Float(jitterX * Double(yawInnerThreshold))
                pitch = base.pitch + Float(jitterY * Double(pitchInnerThreshold))
            }
            streak = matcher(yaw, pitch, pose, widened) ? streak + 1 : 0
        }
    }
    return frames
}

for (label, aim) in [("a cautious user (turns just to the ring's 100% mark)", 1.05),
                     ("an average user (turns a bit past it)", 1.3),
                     ("a generous user (turns well past it)", 1.8)] {
    var nowFrames: [Int] = [], wasFrames: [Int] = []
    var nowGaveUp = 0, wasGaveUp = 0
    for seed in 0..<200 {
        if let f = simulate(matcher: poseMatches, aim: aim, noise: 0.25, seed: UInt64(seed)) { nowFrames.append(f) } else { nowGaveUp += 1 }
        if let f = simulate(matcher: legacyPoseMatches, aim: aim, noise: 0.25, seed: UInt64(seed)) { wasFrames.append(f) } else { wasGaveUp += 1 }
    }
    func secs(_ v: [Int]) -> String { v.isEmpty ? "never" : String(format: "%.1fs", Double(v.reduce(0,+)) / Double(v.count) / 30.0) }
    print("   \(label), aiming \(aim)x:")
    print(String(format: "     now: %@ to enrol, gave up %d/200", secs(nowFrames) as NSString, nowGaveUp))
    print(String(format: "     was: %@ to enrol, gave up %d/200", secs(wasFrames) as NSString, wasGaveUp))
}

print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")")
exit(failures == 0 ? 0 : 1)
