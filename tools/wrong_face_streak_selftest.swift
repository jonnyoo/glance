//
//  wrong_face_streak_selftest.swift
//  glance (tools)
//
//  Offline, camera-free test for when FaceUnlockCoordinator gives up on a
//  scan early as "Face not recognized". This project has no test target, so
//  this compiles as a standalone script against the real files:
//
//      swiftc -O -o /tmp/wrong_face_streak_selftest \
//        glance/WrongFaceStreak.swift \
//        glance/FaceCaptureQuality.swift \
//        glance/FaceAligner.swift \
//        glance/FaceDetector.swift \
//        glance/Liveness/LandmarkGeometry.swift \
//        tools/wrong_face_streak_selftest.swift \
//      && /tmp/wrong_face_streak_selftest
//
//  (FaceAligner/FaceDetector/LandmarkGeometry only supply `AlignmentTier`;
//  nothing here touches Vision, CoreML or a camera.)
//
//  Drives `WrongFaceStreak` with synthetic frame timelines rather than a
//  camera: a 30fps run of mismatches (the old six-frame exit fired ~0.2s
//  in), a slow camera that reaches the time floor before six frames, a
//  streak broken by a match partway through, and runs where only some
//  frames are enrollment-grade enough to count, fed through the same
//  `recordMismatch(alignmentTier:quality:at:)` the coordinator calls.
//

import Foundation

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if condition {
        print("  ok    \(message)")
    } else {
        failures += 1
        print("  FAIL  \(message)")
    }
}

private let start = Date(timeIntervalSinceReferenceDate: 1_000)

/// Feeds mismatches `interval` apart, returning the 1-based frame index that gave up (nil if none within `frames`).
private func giveUpFrame(_ streak: inout WrongFaceStreak, frames: Int, interval: TimeInterval, from origin: Date = start) -> Int? {
    for index in 0..<frames {
        if streak.recordMismatch(at: origin.addingTimeInterval(Double(index) * interval)) {
            return index + 1
        }
    }
    return nil
}

@main
struct WrongFaceStreakSelfTest {
    static func main() {
        print("Time floor scales with the scan window:")
        check(WrongFaceStreak(minimumFrames: 6, scanWindow: 3).minimumDuration == 1.5, "3s window -> 1.5s floor")
        check(abs(WrongFaceStreak(minimumFrames: 6, scanWindow: 5).minimumDuration - 5.0 / 3) < 1e-9, "5s window -> a third of it")
        check(abs(WrongFaceStreak(minimumFrames: 6, scanWindow: 10).minimumDuration - 10.0 / 3) < 1e-9, "10s window -> a third of it")
        check(WrongFaceStreak(minimumFrames: 6, scanWindow: 1).minimumDuration == 1.5, "never under 1.5s")

        print("Six fast frames are no longer enough:")
        do {
            var streak = WrongFaceStreak(minimumFrames: 6, scanWindow: 5)
            check(giveUpFrame(&streak, frames: 6, interval: 1.0 / 30) == nil, "6 mismatches in 0.17s do not give up")
            check(streak.frameCount == 6, "all 6 were still counted")
        }

        print("A sustained fast streak gives up at the time floor, not before:")
        for window in [3.0, 5.0, 10.0] {
            let interval = 0.033
            var streak = WrongFaceStreak(minimumFrames: 6, scanWindow: window)
            let floor = streak.minimumDuration
            let expected = (0..<1_000).first { Double($0) * interval >= floor }.map { $0 + 1 }
            let actual = giveUpFrame(&streak, frames: 1_000, interval: interval)
            check(actual != nil && actual == expected,
                  "\(Int(window))s window: gives up on frame \(actual.map(String.init) ?? "never") (expected \(expected.map(String.init) ?? "never"), ~\(String(format: "%.2f", floor))s)")
            check(streak.recordMismatch(at: start.addingTimeInterval(Double(actual ?? 0) * interval)), "keeps saying give up once past both minimums")
        }

        print("A slow camera past the time floor still needs six frames:")
        do {
            var streak = WrongFaceStreak(minimumFrames: 6, scanWindow: 3)
            check(giveUpFrame(&streak, frames: 10, interval: 1.0) == 6, "1 frame/s: gives up on frame 6 (5s in), not frame 3 (2s in)")
        }

        print("A reset restarts both the count and the clock:")
        do {
            var streak = WrongFaceStreak(minimumFrames: 6, scanWindow: 3)
            check(giveUpFrame(&streak, frames: 40, interval: 0.033) == nil, "40 mismatches (1.3s) do not give up")
            streak.reset()
            check(streak.frameCount == 0, "count cleared")
            let resumed = start.addingTimeInterval(1.4)
            check(giveUpFrame(&streak, frames: 6, interval: 0.033, from: resumed) == nil,
                  "6 more right after the reset do not give up, though 1.6s have passed since the first mismatch")
        }

        print("Only enrollment-grade frames count as evidence of a different person:")
        check(FaceCaptureQuality.floor == 0.2, "shared floor is enrollment's 0.2")
        check(FaceCaptureQuality.isEnrollmentGrade(alignmentTier: .fivePoint, quality: nil), "5-point, no quality score -> counts")
        check(FaceCaptureQuality.isEnrollmentGrade(alignmentTier: .fivePoint, quality: 0.2), "5-point at the floor -> counts")
        check(!FaceCaptureQuality.isEnrollmentGrade(alignmentTier: .fivePoint, quality: 0.19), "5-point below the floor -> ignored")
        check(!FaceCaptureQuality.isEnrollmentGrade(alignmentTier: .twoPoint, quality: 0.9), "2-point, even high quality -> ignored")
        check(!FaceCaptureQuality.isEnrollmentGrade(alignmentTier: .paddedCrop, quality: nil), "padded crop -> ignored")

        func runScan(window: TimeInterval, frames: [(tier: AlignmentTier, quality: Float?)]) -> (gaveUpAt: Int?, counted: Int) {
            var streak = WrongFaceStreak(minimumFrames: 6, scanWindow: window)
            for (index, frame) in frames.enumerated() {
                let now = start.addingTimeInterval(Double(index) * 0.033)
                if streak.recordMismatch(alignmentTier: frame.tier, quality: frame.quality, at: now) {
                    return (index + 1, streak.frameCount)
                }
            }
            return (nil, streak.frameCount)
        }
        do {
            // A padded-crop frame is ignored outright: no give-up, and nothing counted toward the streak.
            var streak = WrongFaceStreak(minimumFrames: 6, scanWindow: 5)
            _ = streak.recordMismatch(alignmentTier: .fivePoint, quality: nil, at: start)
            check(!streak.recordMismatch(alignmentTier: .paddedCrop, quality: 0.9, at: start.addingTimeInterval(0.033)),
                  "padded crop returns false")
            check(streak.frameCount == 1, "padded crop leaves frameCount unchanged")
        }
        do {
            // A full 5s window at 30fps of glasses/off-axis frames that never align: ends at the deadline, not as a wrong face.
            let unaligned = runScan(window: 5, frames: Array(repeating: (.paddedCrop, 0.6), count: 150))
            check(unaligned.gaveUpAt == nil && unaligned.counted == 0, "150 unaligned mismatches never give up")
            let dim = runScan(window: 5, frames: Array(repeating: (.fivePoint, 0.1), count: 150))
            check(dim.gaveUpAt == nil && dim.counted == 0, "150 low-quality mismatches never give up")

            // Only every 20th frame is usable: the time floor passes long before six of them have arrived.
            let sparse = (0..<150).map { $0 % 20 == 19 ? (tier: AlignmentTier.fivePoint, quality: Float?(0.5)) : (tier: .twoPoint, quality: Float?(0.5)) }
            let sparseResult = runScan(window: 5, frames: sparse)
            check(sparseResult.gaveUpAt == 120 && sparseResult.counted == 6, "1-in-20 usable: gives up on the 6th usable frame (frame 120), not sooner")

            // Every usable frame still counts, and unusable ones between them don't reset the clock.
            let alternating = (0..<150).map { $0 % 2 == 0 ? (tier: AlignmentTier.fivePoint, quality: Float?(nil)) : (tier: .paddedCrop, quality: Float?(nil)) }
            let alternatingResult = runScan(window: 3, frames: alternating)
            check(alternatingResult.gaveUpAt == 47, "alternating usable/unusable: gives up at the 1.5s floor (frame 47)")
        }

        print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
