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
    /// single largest face in `frame`. Detection, alignment, and embedding
    /// are all synchronous/CPU-bound; this method is `nonisolated` so
    /// callers can run it from a background task (`Task.detached`) rather
    /// than blocking the main actor.
    nonisolated func recognize(in frame: CGImage) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame)
        guard let face = Self.largestFace(in: faces) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }

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

    nonisolated private static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
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
    /// `bestMatch(in:threshold:minMargin:)` below excludes them from
    /// actually matching.
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
    /// result: not stale, both centroid and max-sample similarity clear
    /// `threshold`, and — once more than one identity is enrolled — a
    /// `minMargin` lead over the runner-up. Both the Face Lab debug UI and
    /// `FaceUnlockCoordinator` call this same function rather than each
    /// having their own copy of the logic — tuning one without the other
    /// would be a real risk for a security-sensitive comparison.
    nonisolated func bestMatch(in scored: [ScoredIdentity], threshold: Float, minMargin: Float = 0.05) -> ScoredIdentity? {
        guard let first = scored.first, !first.identity.isStale(comparedTo: embedder) else { return nil }
        guard first.centroidSimilarity >= threshold, first.maxSampleSimilarity >= threshold else { return nil }
        if scored.count > 1 {
            guard first.centroidSimilarity - scored[1].centroidSimilarity >= minMargin else { return nil }
        }
        return first
    }
}
