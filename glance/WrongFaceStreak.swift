//
//  WrongFaceStreak.swift
//  glance
//
//  Decides when a run of non-matching frames is enough to end a scan as "Face not recognized" before its window runs out.
//  Kept free of camera and pipeline state (it only takes a frame's alignment tier and quality score, via FaceAligner's
//  `AlignmentTier`), so tools/wrong_face_streak_selftest.swift can drive it with synthetic timelines.
//

import Foundation

nonisolated struct WrongFaceStreak {
    /// Several frames, so a single bad-angle read doesn't trigger the failure animation.
    let minimumFrames: Int
    /// Frames alone pile up in ~0.2s at camera cadence — less time than turning toward the screen or the webcam settling its
    /// exposure after `start()`. A third of the scan window, never under 1.5s, keeps "Face detection time" meaning something.
    let minimumDuration: TimeInterval

    private(set) var frameCount = 0
    private var startedAt: Date?

    init(minimumFrames: Int, scanWindow: TimeInterval) {
        self.minimumFrames = minimumFrames
        minimumDuration = max(1.5, scanWindow / 3)
    }

    /// A match, or a frame with no face at all, ends the streak.
    mutating func reset() {
        frameCount = 0
        startedAt = nil
    }

    /// True once the streak has lasted long enough, in both frames and time, to give up on the scan.
    mutating func recordMismatch(at now: Date) -> Bool {
        if startedAt == nil { startedAt = now }
        frameCount += 1
        guard let startedAt, frameCount >= minimumFrames else { return false }
        return now.timeIntervalSince(startedAt) >= minimumDuration
    }

    /// Only a frame enrollment would accept counts as evidence of someone else. An unaligned or low-quality frame neither
    /// extends nor breaks the streak (it records nothing and returns false), so the scan just waits for the next frame or
    /// its deadline. The coordinator calls this, so the self-test exercises the same gating rather than a copy of it.
    mutating func recordMismatch(alignmentTier: AlignmentTier, quality: Float?, at now: Date) -> Bool {
        guard FaceCaptureQuality.isEnrollmentGrade(alignmentTier: alignmentTier, quality: quality) else { return false }
        return recordMismatch(at: now)
    }
}
