//
//  FaceRecognitionPipeline.swift
//  glance
//
//  Only place that should construct a FaceEmbedder — keeps all consumers in sync.
//

import Foundation
import CoreGraphics
import Observation

nonisolated struct FaceRecognitionResult {
    let embedding: [Float]
    /// What was actually fed to the embedder, for debug UIs to inspect.
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

/// `@Observable` so the debug UI can surface which embedder is active.
@Observable
@MainActor
final class FaceRecognitionPipeline {
    nonisolated let embedder: FaceEmbedder

    /// Set when ArcFace failed to load (see tools/convert_arcface.py) and the weaker Vision feature-print embedder is in use instead.
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

    /// `nonisolated` so callers can run detect/align/embed from a background task instead of blocking the main actor.
    /// - Parameter previousBoundingBox: previous frame's selected box, if any — lets a continuous scanner keep selection "stuck" to the same person instead of re-picking every frame.
    nonisolated func recognize(in frame: CGImage, preferNear previousBoundingBox: CGRect? = nil) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame)
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame)
    }

    /// Aligns and embeds an already-chosen face; enrollment uses this to bypass the prominence filter so a too-small face reads as "move closer" rather than "nobody there".
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

    /// Camera-frame version: finds the face on the small frame (fast), then embeds and scores it from the native-resolution
    /// frame. See `recognize(_:in:includeQuality:)` for why.
    nonisolated func recognize(in frame: CameraFrame, preferNear previousBoundingBox: CGRect? = nil, includeQuality: Bool = true) throws -> FaceRecognitionResult {
        let faces = try FaceDetector.detectFaces(in: frame.image, includeQuality: false)
        guard let face = Self.selectDominantFace(in: faces, preferNear: previousBoundingBox) else {
            throw FaceRecognitionPipelineError.noFaceDetected
        }
        return try recognize(face, in: frame, includeQuality: includeQuality)
    }

    /// `face` comes from detection on `frame.image`, which CameraManager shrinks to 640px, leaving a seated user's face only
    /// ~90–130px wide. Aligning, embedding and quality-scoring from that softens every sample, so this re-finds the face in
    /// a native-resolution crop around it and uses that instead. The returned `face` is still the small-frame one, because
    /// selection continuity, liveness and glare all work in `frame.image` coordinates. Falls back to the small frame when
    /// the camera is no bigger than it or the face can't be re-found in the crop.
    nonisolated func recognize(_ face: DetectedFace, in frame: CameraFrame, includeQuality: Bool = true) throws -> FaceRecognitionResult {
        let upscale = frame.sourceSize.width / CGFloat(max(frame.image.width, 1))
        if upscale > 1.25, let detailed = try? recognizeAtNativeResolution(face, in: frame, includeQuality: includeQuality) {
            return detailed
        }
        if includeQuality, face.quality == nil,
           let scored = try? FaceDetector.detectFaces(in: frame.image, includeQuality: true),
           let match = Self.nearest(to: face.normalizedBoundingBox, in: scored) {
            let result = try recognize(match, in: frame.image)
            return FaceRecognitionResult(embedding: result.embedding, alignedImage: result.alignedImage,
                                         alignmentTier: result.alignmentTier, quality: match.quality, face: face)
        }
        return try recognize(face, in: frame.image)
    }

    /// Context around the face box for the native crop — enough for Vision to re-detect the face and for a 2-point/padded
    /// fallback alignment to have its margin.
    nonisolated private static let nativeCropPadding: CGFloat = 0.5
    /// Cap on the native crop's long edge. With the padding above, the face itself ends up ~250px — more than twice
    /// ArcFace's 112px input — while keeping the extra Vision pass cheap.
    nonisolated private static let nativeCropMaxEdge: CGFloat = 512

    nonisolated private func recognizeAtNativeResolution(_ face: DetectedFace, in frame: CameraFrame, includeQuality: Bool) throws -> FaceRecognitionResult? {
        let padX = face.boundingBox.width * Self.nativeCropPadding
        let padY = face.boundingBox.height * Self.nativeCropPadding
        let region = face.boundingBox.insetBy(dx: -padX, dy: -padY)
        guard let crop = CameraManager.renderCrop(from: frame, imageRect: region, maxEdge: Self.nativeCropMaxEdge) else { return nil }

        // The crop is centred on the face, so the detection nearest its centre is the same person.
        let cropFaces = try FaceDetector.detectFaces(in: crop, includeQuality: includeQuality)
        let centre = CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
        guard let detailed = Self.nearest(to: centre, in: cropFaces),
              detailed.normalizedBoundingBox.width >= 0.3 else { return nil }

        let result = try recognize(detailed, in: crop)
        return FaceRecognitionResult(embedding: result.embedding, alignedImage: result.alignedImage,
                                     alignmentTier: result.alignmentTier, quality: detailed.quality, face: face)
    }

    nonisolated private static func nearest(to box: CGRect, in faces: [DetectedFace]) -> DetectedFace? {
        faces.min { distance(from: $0, to: CGPoint(x: box.midX, y: box.midY)) < distance(from: $1, to: CGPoint(x: box.midX, y: box.midY)) }
    }

    /// Largest face by area with no size cutoff — unlike `selectDominantFace`, so enrollment can tell "too far" apart from "no face".
    nonisolated static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }

    /// Below this many pixels wide, a face has too little detail for a trustworthy embedding. Measured in pixels of the frame
    /// Vision actually sees — CameraManager downscales to a 640px long edge — so 64px is 10% of the frame width. A wide webcam
    /// like the BRIO puts a seated user's face at ~14% (~90px), which the old fixed 15% cutoff rejected; in testing a 104px
    /// face still matched at 0.71 against a 0.58 threshold.
    nonisolated static let minimumFacePixelWidth: CGFloat = 64

    /// A face narrower than this fraction of the largest face in the same frame is a bystander, not the person at the camera.
    /// Relative, so it adapts to however far the user sits instead of needing a distance setting.
    nonisolated static let bystanderRelativeWidth: CGFloat = 0.6

    /// Max normalized-coordinate drift between frames still counted as "the same person".
    nonisolated private static let continuityDistanceTolerance: CGFloat = 0.3

    /// Picks the person actually at the camera, not a bystander: drops faces too small to embed reliably and faces much smaller
    /// than the largest one in the frame, then prefers continuity with `previousBoundingBox` over raw largest-by-area so two
    /// similarly-sized faces can't flip-flop the selection frame to frame and starve the liveness/wrong-face streaks of agreement.
    /// Size is never a security gate — whichever face is picked must still match an enrolled identity.
    nonisolated static func selectDominantFace(in faces: [DetectedFace], preferNear previousBoundingBox: CGRect? = nil) -> DetectedFace? {
        let widest = faces.map(\.boundingBox.width).max() ?? 0
        let candidates = faces.filter {
            $0.boundingBox.width >= minimumFacePixelWidth && $0.boundingBox.width >= widest * bystanderRelativeWidth
        }
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
    /// Sorted by centroid similarity descending; includes stale identities (different embedder) since `bestMatch` is what excludes them from actually matching.
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

    /// Shared by Face Lab and FaceUnlockCoordinator so tuning stays consistent. No runner-up margin check: the same person can be enrolled multiple times under different appearances, so two of their own profiles legitimately score close together — a margin check can't tell that apart from two different people colliding.
    nonisolated func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity? {
        guard let first = scored.first, !first.identity.isStale(comparedTo: embedder) else { return nil }
        guard first.centroidSimilarity >= threshold, first.maxSampleSimilarity >= threshold else { return nil }
        return first
    }
}
