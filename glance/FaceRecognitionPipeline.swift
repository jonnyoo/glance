//
//  FaceRecognitionPipeline.swift
//  glance
//
//  Single composition point for detect -> align -> embed. Swapping which
//  embedder is active (Vision feature-print vs ArcFace) is a one-line change
//  here — nothing else in the app should construct a FaceEmbedder directly,
//  so every consumer (Face Lab, onboarding, eventually unlock) stays in sync.
//

import Foundation
import CoreGraphics
import Observation

nonisolated struct FaceRecognitionResult {
    let embedding: [Float]
    /// Exactly what was fed to the embedder — useful for debug UIs to show
    /// what alignment actually produced, not just the raw detection crop.
    let alignedImage: CGImage
    let alignmentTier: AlignmentTier
    let quality: Float?
    let face: DetectedFace
}

nonisolated enum FaceRecognitionPipelineError: LocalizedError {
    case noFaceDetected
    case alignmentFailed

    var errorDescription: String? {
        switch self {
        case .noFaceDetected: return "No face detected in frame."
        case .alignmentFailed: return "Could not align the detected face."
        }
    }
}

/// `@Observable` so the debug UI can surface which embedder is active and
/// whether ArcFace loaded successfully, without a separate notification path.
@Observable
@MainActor
final class FaceRecognitionPipeline {
    nonisolated let embedder: FaceEmbedder

    /// Set when ArcFace failed to load (most commonly: the model hasn't
    /// been converted yet — see tools/convert_arcface.py) and the pipeline
    /// fell back to the much weaker Vision feature-print embedder. Surfaced
    /// in the UI rather than failing silently, since recognition quality
    /// degrades substantially in this fallback mode.
    private(set) var usingFallbackEmbedder: Bool
    private(set) var fallbackReason: String?

    init() {
        do {
            embedder = try ArcFaceEmbedder()
            usingFallbackEmbedder = false
            fallbackReason = nil
        } catch {
            embedder = VisionFeaturePrintEmbedder()
            usingFallbackEmbedder = true
            fallbackReason = error.localizedDescription
        }
    }

    /// Runs the full frame -> detect -> align -> embed sequence for the
    /// single dominant face in `frame` (see `selectDominantFace`).
    /// Detection, alignment, and embedding are all synchronous/CPU-bound;
    /// this method is `nonisolated` so callers can run it from a background
    /// task (`Task.detached`) rather than blocking the main actor.
    ///
    /// - Parameter previousBoundingBox: the normalized bounding box selected
    ///   on the previous frame of the same scan, if any — passing this lets
    ///   a caller scanning continuously (FaceUnlockCoordinator) keep
    ///   selection "stuck" to the same person across frames instead of
    ///   re-picking independently every frame. Callers that only ever
    ///   recognize a single isolated frame (Face Lab, onboarding) can omit
    ///   it entirely.
    nonisolated func recognize(in frame: CGImage, preferNear previousBoundingBox: CGRect? = nil) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame)
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame)
    }

    /// Aligns and embeds an already-chosen face. Enrollment uses this after
    /// picking the largest face *without* the prominence filter, so a
    /// too-small face can be flagged as "move closer" instead of looking
    /// like nobody is there.
    nonisolated func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult {
        let inputImage: CGImage
        let tier: AlignmentTier
        if embedder.requiresAlignment {
            guard let aligned = FaceAligner.align(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = aligned.image
            tier = aligned.tier
        } else {
            guard let cropped = FaceDetector.crop(face, from: frame) else {
                throw FaceRecognitionPipelineError.alignmentFailed
            }
            inputImage = cropped
            tier = .paddedCrop
        }

        let embedding = try embedder.embedding(for: inputImage)
        return FaceRecognitionResult(embedding: embedding, alignedImage: inputImage, alignmentTier: tier, quality: face.quality, face: face)
    }

    /// Largest face by area, with no prominence cutoff. Enrollment needs
    /// this to tell "too far" apart from "no face" — `selectDominantFace`
    /// drops small faces entirely, which is correct for unlock but would
    /// make the closer-up prompt unreachable.
    nonisolated static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// Below this fraction of frame width, a detected face is treated as a
    /// bystander or background person rather than a candidate to recognize
    /// — shared with the "move closer" prompt onboarding shows during
    /// enrollment (`OnboardingController.isTooFar`), so both agree on what
    /// counts as close enough to matter.
    ///
    /// User-tunable from the Recognition settings page (`GlanceSettings
    /// .minimumFaceWidth`), which writes through to this on every change and
    /// seeds it from the persisted value at launch. `nonisolated(unsafe) var`
    /// rather than routing through GlanceSettings directly, because this is
    /// read from `selectDominantFace` — a `nonisolated static func` called
    /// from a background `Task.detached` — which can't synchronously touch
    /// GlanceSettings' MainActor-isolated storage. Acceptable here since it's
    /// a UI-tunable heuristic float, not security-sensitive state.
    nonisolated(unsafe) static var minimumProminentFaceWidth: Float = 0.18

    /// How far (in normalized 0...1 frame coordinates) a face's center may
    /// drift from the previously-selected face and still count as "the same
    /// person" between consecutive scan frames.
    nonisolated private static let continuityDistanceTolerance: CGFloat = 0.3

    /// Picks the single "dominant" face to recognize from `faces` — the
    /// person actually in front of the camera trying to unlock, not a
    /// bystander or someone in the background. Two things keep this stable
    /// when more than one face is in frame:
    ///
    ///   1. A minimum-prominence filter excludes faces smaller than
    ///      `minimumProminentFaceWidth` outright — someone standing well
    ///      behind the primary user is never even a candidate, regardless
    ///      of what else is happening in the frame.
    ///   2. Among the remaining candidates, if `previousBoundingBox` is
    ///      given (the box selected on the previous frame), the closest
    ///      match to it wins over the raw largest-by-area. Without this,
    ///      two similarly-sized faces can flip which one reads as "largest"
    ///      from frame to frame — which starves both the liveness streak
    ///      and the wrong-face streak of consecutive agreement, since each
    ///      requires several frames in a row to agree on the same person.
    ///      With two people in frame, selection could flip-flop between
    ///      them fast enough that neither streak ever completed, so a scan
    ///      would run out its timeout with no match *and* no confident
    ///      rejection — it just silently gave up.
    ///
    /// Falls back to largest-by-area when there's no previous face to
    /// anchor to (first frame of a scan) or nothing left is close enough to
    /// it anymore (that face left the frame).
    nonisolated static func selectDominantFace(in faces: [DetectedFace], preferNear previousBoundingBox: CGRect? = nil) -> DetectedFace? {
        let candidates = faces.filter { $0.normalizedBoundingBox.width >= CGFloat(minimumProminentFaceWidth) }
        guard !candidates.isEmpty else { return nil }

        if let previous = previousBoundingBox {
            let previousCenter = CGPoint(x: previous.midX, y: previous.midY)
            if let nearest = candidates.min(by: { distance(from: $0, to: previousCenter) < distance(from: $1, to: previousCenter) }),
               distance(from: nearest, to: previousCenter) < continuityDistanceTolerance {
                return nearest
            }
        }

        return candidates.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    nonisolated private static func distance(from face: DetectedFace, to point: CGPoint) -> CGFloat {
        let center = CGPoint(x: face.normalizedBoundingBox.midX, y: face.normalizedBoundingBox.midY)
        return hypot(center.x - point.x, center.y - point.y)
    }
}

nonisolated struct ScoredIdentity {
    let identity: FaceIdentity
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest individual sample — catches
    /// cases where averaging blurred together poses that shouldn't be
    /// blended.
    let maxSampleSimilarity: Float
}

extension FaceRecognitionPipeline {
    /// Compares `embedding` against every enrolled identity, sorted by
    /// centroid similarity descending. Includes stale identities (samples
    /// from a different embedder) — callers decide how to surface that;
    /// `bestMatch(in:threshold:)` below excludes them from actually
    /// matching.
    nonisolated func score(_ embedding: [Float], against identities: [FaceIdentity]) -> [ScoredIdentity] {
        identities.compactMap { identity in
            guard let template = identity.template, !identity.samples.isEmpty else { return nil }
            let centroidSim = FaceEmbedding.cosineSimilarity(embedding, template)
            let maxSim = identity.samples
                .map { FaceEmbedding.cosineSimilarity(embedding, $0.embedding) }
                .max() ?? centroidSim
            return ScoredIdentity(identity: identity, centroidSimilarity: centroidSim, maxSampleSimilarity: maxSim)
        }.sorted { $0.centroidSimilarity > $1.centroidSimilarity }
    }

    /// The shared match decision, applied to an already-sorted `score(...)`
    /// result: not stale, and both centroid and max-sample similarity clear
    /// `threshold`. Both the Face Lab debug UI and `FaceUnlockCoordinator`
    /// call this same function rather than each having their own copy of
    /// the logic — tuning one without the other would be a real risk for a
    /// security-sensitive comparison.
    ///
    /// Deliberately no runner-up margin check: an earlier version required
    /// the top score to beat the second-closest identity by 0.05, to guard
    /// against two different enrolled people scoring close enough that
    /// picking the higher one was a coin flip. Dropped because "identity"
    /// here isn't necessarily "one distinct person" — the same person is
    /// meant to be enrollable multiple times under different appearances
    /// (glasses, lighting, hairstyle), and two such profiles legitimately
    /// score close to each other on every future capture of that same
    /// face. A margin built to catch ambiguity between different people
    /// can't tell that apart from "these two profiles agree," and rejected
    /// the second case unconditionally, forever — not a tunable threshold
    /// problem. If cross-person ambiguity ever needs catching again, it
    /// has to be identity-aware (e.g. only compare across different
    /// `FaceIdentity.id`s that aren't themselves same-person aliases), not
    /// a flat score gap.
    nonisolated func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity? {
        guard let first = scored.first, !first.identity.isStale(comparedTo: embedder) else { return nil }
        guard first.centroidSimilarity >= threshold, first.maxSampleSimilarity >= threshold else { return nil }
        return first
    }
}
