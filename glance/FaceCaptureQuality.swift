//
//  FaceCaptureQuality.swift
//  glance
//
//  What makes a camera frame trustworthy evidence about whose face is in it. Shared so enrollment (which only keeps such
//  frames as samples) and unlock (which only counts such frames against a match) can't drift apart.
//

import Foundation

nonisolated enum FaceCaptureQuality {
    /// Permissive floor for Vision's capture-quality score (no fixed universal cutoff) —
    /// better to accept a mediocre sample than stall the whole flow.
    static let floor: Float = 0.2

    /// Only a 5-point alignment is reliably canonical; a 2-point or padded-crop fallback, or a low-quality capture, scores low
    /// against ArcFace because the measurement is bad, not because the face is someone else's.
    static func isEnrollmentGrade(alignmentTier: AlignmentTier, quality: Float?) -> Bool {
        alignmentTier == .fivePoint && (quality.map { $0 >= floor } ?? true)
    }
}
