//
//  enrollment_selftest.swift
//  glance
//
//  Measures how hard guided enrollment is to finish. Compiles the shipping geometry directly — the point is to test
//  glance/Onboarding/EnrollmentPoseGeometry.swift, not a copy of it, so this cannot stay green while the app drifts:
//
//      swiftc -O tools/enrollment_selftest.swift glance/Onboarding/EnrollmentPoseGeometry.swift \
//          -o /tmp/enrollment_selftest && /tmp/enrollment_selftest
//
//  Same manual-script style as liveness_selftest.swift.
//

import Foundation

// MARK: - Mirrored from OnboardingController: the pose table and the capture-loop timings

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

let stallWidenFactor: Float = 1.25
let requiredMatchStreak = 3
let samplesPerPose = 2
let poseHoldFrames = 15        // poseHoldDuration 500ms at 30fps
let stallTimeoutFrames = 360   // stallTimeout 12s at 30fps
let framesPerSecond = 30.0

func factor(for pose: Pose, widened: Bool) -> Float {
    (widened ? stallWidenFactor : 1.0) * pose.matchLeniency
}

/// The shipping matcher.
func poseMatches(yaw: Float, pitch: Float, pose: Pose, widened: Bool) -> Bool {
    EnrollmentPoseGeometry.matches(yaw: yaw, pitch: pitch, compassAngle: pose.compassAngle,
                                   factor: factor(for: pose, widened: widened))
}

/// What the ring shows, from the same vector `headTurn` uses.
func ringProgress(yaw: Float, pitch: Float, pose: Pose) -> Double {
    let turn = EnrollmentPoseGeometry.turn(yaw: yaw, pitch: pitch)
    guard turn.isWithinRange else { return 0 }
    return min(turn.magnitude / EnrollmentPoseGeometry.requiredMagnitude(factor: factor(for: pose, widened: false)), 1)
}

/// The previous rectangular test, frozen here purely so the regression stays visible.
func legacyPoseMatches(yaw: Float, pitch: Float, pose: Pose, widened: Bool) -> Bool {
    let f = factor(for: pose, widened: widened)
    let yawInner: Float = 0.25, pitchInner: Float = 0.20
    let yawCenterTol: Float = 0.18, pitchCenterTol: Float = 0.15
    let yawOuterCap: Float = 1.2, pitchOuterCap: Float = 0.9
    let yawOK: Bool, pitchOK: Bool
    switch pose {
    case .left, .topLeft, .bottomLeft: yawOK = yaw > yawInner / f && yaw < yawOuterCap
    case .right, .topRight, .bottomRight: yawOK = yaw < -yawInner / f && yaw > -yawOuterCap
    default: yawOK = abs(yaw) < yawCenterTol * f
    }
    switch pose {
    case .top, .topLeft, .topRight: pitchOK = pitch < -pitchInner / f && pitch > -pitchOuterCap
    case .bottom, .bottomLeft, .bottomRight: pitchOK = pitch > pitchInner / f && pitch < pitchOuterCap
    default: pitchOK = abs(pitch) < pitchCenterTol * f
    }
    return yawOK && pitchOK
}

/// Turn the head `magnitude` normalized units along `compass`, and report the raw Vision angles.
func headAngles(compass: Double, magnitude: Double) -> (yaw: Float, pitch: Float) {
    let radians = compass * .pi / 180
    let x = sin(radians) * magnitude
    let y = cos(radians) * magnitude
    return (yaw: Float(-x * Double(EnrollmentPoseGeometry.yawInnerThreshold)),
            pitch: Float(-y * Double(EnrollmentPoseGeometry.pitchInnerThreshold)))
}

func headAngles(towards pose: Pose, magnitude: Double) -> (yaw: Float, pitch: Float) {
    guard let compass = pose.compassAngle else { return (0, 0) }
    return headAngles(compass: compass, magnitude: magnitude)
}

/// Seeded so a run is reproducible: a self-test reporting different numbers each time cannot be regression-checked.
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

func firstMagnitude(_ test: (Float, Float) -> Bool, towards pose: Pose) -> Double {
    var m = 0.005
    while m <= 5.0 {
        let a = headAngles(towards: pose, magnitude: m)
        if test(a.yaw, a.pitch) { return m }
        m += 0.005
    }
    return .nan
}

/// Top-level statements are only legal in a file called main.swift, and this script is compiled alongside the app's
/// own EnrollmentPoseGeometry.swift — so the runnable part lives in `main()`.
@main
enum EnrollmentSelfTest {
    static func main() {
    // MARK: - 1. The ring and the gate must agree

    print("\n1. Turn along each pose's own direction: where does the ring read 100%, where does the gate accept?\n")
    print(String(format: "   %-12@ %-10@ %-10@ %-10@ %@", "pose" as NSString, "ring 100%" as NSString,
                 "gate now" as NSString, "gate was" as NSString, "was/now" as NSString))
    for pose in Pose.allCases where pose != .center {
        let ring = firstMagnitude({ ringProgress(yaw: $0, pitch: $1, pose: pose) >= 1.0 }, towards: pose)
        let now = firstMagnitude({ poseMatches(yaw: $0, pitch: $1, pose: pose, widened: false) }, towards: pose)
        let was = firstMagnitude({ legacyPoseMatches(yaw: $0, pitch: $1, pose: pose, widened: false) }, towards: pose)
        print(String(format: "   %-12@ %-10.2f %-10.2f %-10.2f %.2fx", pose.rawValue as NSString, ring, now, was, was / now))
    }

    print("")
    for pose in Pose.allCases where pose != .center {
        var disagreed = false
        var m = 0.005
        while m <= 6.0 {
            let a = headAngles(towards: pose, magnitude: m)
            let ringReady = ringProgress(yaw: a.yaw, pitch: a.pitch, pose: pose) >= 1.0
            if ringReady != poseMatches(yaw: a.yaw, pitch: a.pitch, pose: pose, widened: false) { disagreed = true; break }
            m += 0.005
        }
        check(!disagreed, "\(pose.rawValue): ring and gate agree at every magnitude, including past the outer cap")
    }

    // MARK: - 2. Diagonals must cost no more than cardinals

    print("\n2. A diagonal should cost the same head turn as a cardinal\n")
    let cardinals: [Pose] = [.left, .top, .right, .bottom]
        let worstCardinal = cardinals
            .map { pose in firstMagnitude({ poseMatches(yaw: $0, pitch: $1, pose: pose, widened: false) }, towards: pose) }
            .max() ?? .nan
    for pose in Pose.allCases where pose.isDiagonal {
        let cost = firstMagnitude({ poseMatches(yaw: $0, pitch: $1, pose: pose, widened: false) }, towards: pose)
        check(cost <= worstCardinal + 0.01,
              String(format: "%@ costs %.2f, no worse than a cardinal's %.2f", pose.rawValue, cost, worstCardinal))
    }

    // MARK: - 3. Sectors must tile the circle exactly once, boundaries included

    print("\n3. Every direction belongs to exactly one sector\n")
    var multiClaimed: [Double] = []
    var unclaimed: [Double] = []
    var degrees = 0.0
    while degrees < 360 {
        let a = headAngles(compass: degrees, magnitude: 1.6)
        let owners = Pose.allCases.filter { poseMatches(yaw: a.yaw, pitch: a.pitch, pose: $0, widened: false) }
        if owners.count > 1 { multiClaimed.append(degrees) }
        if owners.isEmpty { unclaimed.append(degrees) }
        degrees += 0.5
    }
    check(multiClaimed.isEmpty, "no direction satisfies two poses at once (\(multiClaimed.count) would)")
    check(unclaimed.isEmpty, "no direction falls between sectors (\(unclaimed.count) would)")

    // exact sector boundaries are the case a centre-only test misses
    for pose in Pose.allCases where pose != .center {
        guard let compass = pose.compassAngle else { continue }
        for edge in [compass - 22.5, compass + 22.5] {
            let a = headAngles(compass: edge, magnitude: 1.6)
            let owners = Pose.allCases.filter { poseMatches(yaw: a.yaw, pitch: a.pitch, pose: $0, widened: false) }
            check(owners.count == 1, String(format: "boundary %.1f deg is owned by exactly one pose (%@)", edge,
                                            owners.map(\.rawValue).joined(separator: ",") as NSString))
        }
    }

    // MARK: - 4. Looking straight ahead

    print("\n4. Looking straight ahead\n")
    let straight = Pose.allCases.filter { poseMatches(yaw: 0, pitch: 0, pose: $0, widened: false) }
    check(straight == [.center], "a still head matches only centre (got \(straight.map(\.rawValue)))")

    // MARK: - 5. Full enrollment, modelling the real capture loop

    print("\n5. Simulated enrollment, modelling processMatchedEnrollFrame\n")
    print("   (per pose: 500ms continuous hold, then \(requiredMatchStreak) matching frames per sample,")
    print("    \(samplesPerPose) samples per pose; any non-matching frame restarts the hold)\n")

    func simulate(matcher: (Float, Float, Pose, Bool) -> Bool, aim: Double, noise: Double, seed: UInt64) -> Int? {
        var rng = SplitMix64(seed: seed)
        var totalFrames = 0
        for pose in Pose.allCases {
            var poseFrames = 0
            var holdFrames = 0          // poseHoldStartedAt
            var holding = false
            var streak = 0              // matchStreak
            var samples = 0             // capturedForCurrentPose
            while samples < samplesPerPose {
                poseFrames += 1
                totalFrames += 1
                if poseFrames > 900 { return nil }           // 30s on one pose: the user gave up
                let widened = poseFrames > stallTimeoutFrames
                let jitterX = Double.random(in: -noise...noise, using: &rng)
                let jitterY = Double.random(in: -noise...noise, using: &rng)
                let base = pose == .center ? (yaw: Float(0), pitch: Float(0)) : headAngles(towards: pose, magnitude: aim)
                let yaw = base.yaw + Float(jitterX * Double(EnrollmentPoseGeometry.yawInnerThreshold))
                let pitch = base.pitch + Float(jitterY * Double(EnrollmentPoseGeometry.pitchInnerThreshold))

                guard matcher(yaw, pitch, pose, widened) else {
                    streak = 0; holding = false; holdFrames = 0; continue
                }
                if !holding { holding = true; holdFrames = 0 }
                holdFrames += 1
                guard holdFrames >= poseHoldFrames else { continue }
                streak += 1
                guard streak >= requiredMatchStreak else { continue }
                streak = 0
                samples += 1
            }
        }
        return totalFrames
    }

    for (label, aim) in [("turns exactly as far as the ring asks", 1.05),
                         ("overshoots a little", 1.3),
                         ("overshoots a lot", 1.8)] {
        var nowF: [Int] = [], wasF: [Int] = []
        var nowGaveUp = 0, wasGaveUp = 0
        for seed in 0..<200 {
            if let f = simulate(matcher: poseMatches, aim: aim, noise: 0.25, seed: UInt64(seed)) { nowF.append(f) } else { nowGaveUp += 1 }
            if let f = simulate(matcher: legacyPoseMatches, aim: aim, noise: 0.25, seed: UInt64(seed)) { wasF.append(f) } else { wasGaveUp += 1 }
        }
        func secs(_ v: [Int]) -> String { v.isEmpty ? "never finished" : String(format: "%.1fs", Double(v.reduce(0, +)) / Double(v.count) / framesPerSecond) }
        print("   a user who \(label) (\(aim)x):")
        print(String(format: "     now: %@, gave up %d/200", secs(nowF) as NSString, nowGaveUp))
        print(String(format: "     was: %@, gave up %d/200", secs(wasF) as NSString, wasGaveUp))
    }

    print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) FAILED.")")
    exit(failures == 0 ? 0 : 1)

    }
}
