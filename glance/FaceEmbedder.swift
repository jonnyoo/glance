//
//  FaceEmbedder.swift
//  glance
//
//  Milestone D: turn a cropped face image into a fixed-length list of
//  numbers (an "embedding"). Two embeddings of the same person's face end up
//  close together; different people end up far apart — recognition is just
//  measuring that distance.
//
//  Two implementations exist side by side:
//  - `VisionFeaturePrintEmbedder`: Apple's built-in, on-device, general-
//    purpose image descriptor. No downloaded model, works instantly, but
//    (measured live) gives only a ~5-7% similarity gap between the owner
//    and a different person — too thin to gate an unlock on.
//  - `ArcFaceEmbedder` (ArcFaceEmbedder.swift): a real face-discriminative
//    model, converted from InsightFace's `w600k_mbf` weights. Requires a
//    canonically-aligned 112x112 input (see `FaceAligner`).
//
//  Swapping which one is active is a one-line change wherever `FaceEmbedder`
//  is constructed — nothing else in the pipeline needs to change.
//

import Vision
import CoreGraphics

/// Pure, synchronous, CPU-bound work — `nonisolated` so implementations can
/// run on a background task despite the project's default main-actor
/// isolation.
protocol FaceEmbedder: Sendable {
    /// Name shown in the debug UI so it's obvious which embedder produced a
    /// given saved sample.
    nonisolated var name: String { get }
    /// Stable identifier persisted alongside every saved sample.
    /// `SecureFaceStore` uses this to detect samples that came from a
    /// different embedder and refuse to compare across them — comparing an
    /// old Vision-feature-print vector against an ArcFace one wouldn't
    /// error, it would just produce confident nonsense.
    nonisolated var modelIdentifier: String { get }
    /// Declared output length, used for cross-model mismatch detection
    /// without needing to run an embedding first.
    nonisolated var embeddingDimension: Int { get }
    /// Whether this embedder expects a canonically-aligned input (ArcFace)
    /// as opposed to tolerating a loose bounding-box crop (Vision
    /// feature-print).
    nonisolated var requiresAlignment: Bool { get }
    nonisolated func embedding(for face: CGImage) throws -> [Float]
}

enum FaceEmbedderError: LocalizedError {
    case noObservation
    case unsupportedElementType

    var errorDescription: String? {
        switch self {
        case .noObservation:
            return "Vision did not produce a feature print for this image."
        case .unsupportedElementType:
            return "Feature print used an unexpected element type."
        }
    }
}

struct VisionFeaturePrintEmbedder: FaceEmbedder {
    nonisolated let name = "Vision Feature Print"
    nonisolated let modelIdentifier = "vision-feature-print-v1"
    // Apple's documented default output size for the current
    // VNGenerateImageFeaturePrintRequest revision. Only used as a nominal
    // hint for mismatch detection — `modelIdentifier` is the real
    // discriminator `SecureFaceStore` relies on, so an off-by-a-bit value
    // here isn't safety-critical.
    nonisolated let embeddingDimension = 2048
    nonisolated let requiresAlignment = false

    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: face, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FaceEmbedderError.noObservation
        }
        return try Self.floatVector(from: observation)
    }

    /// Vision only exposes the feature print as raw bytes + an element type;
    /// this decodes it into `[Float]` so we can persist it as plain JSON and
    /// average multiple samples together when enrolling.
    nonisolated private static func floatVector(from observation: VNFeaturePrintObservation) throws -> [Float] {
        let count = observation.elementCount
        switch observation.elementType {
        case .float:
            var result = [Float](repeating: 0, count: count)
            observation.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let buffer = raw.bindMemory(to: Float.self)
                for i in 0..<count { result[i] = buffer[i] }
            }
            return result
        case .double:
            var result = [Float](repeating: 0, count: count)
            observation.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let buffer = raw.bindMemory(to: Double.self)
                for i in 0..<count { result[i] = Float(buffer[i]) }
            }
            return result
        default:
            throw FaceEmbedderError.unsupportedElementType
        }
    }
}

nonisolated enum FaceEmbedding {
    /// Scales `vector` to unit length. ArcFace-style embeddings are meant to
    /// be compared as unit vectors — cosine similarity is scale-invariant
    /// for a single comparison, but normalization matters as soon as
    /// vectors are combined (see `average` below).
    static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity, range -1...1 (1 = identical direction). This is
    /// what "how close are these two number-lists" actually means in
    /// practice — it ignores overall magnitude and just compares shape.
    /// This is the raw value ArcFace thresholds are conventionally quoted
    /// in (typical verification cutoffs sit around 0.28-0.40).
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Maps cosine similarity (-1...1) into a 0...100% for the legacy
    /// Vision-feature-print UI. Do not use this to tune ArcFace thresholds —
    /// it obscures the raw cosine value that published thresholds are
    /// quoted in; use `cosineSimilarity` directly instead.
    static func similarityPercent(_ a: [Float], _ b: [Float]) -> Double {
        let similarity = cosineSimilarity(a, b)
        return Double((similarity + 1) / 2) * 100
    }

    /// Fuses several samples of one identity into a single template vector:
    /// normalize each sample, average, then renormalize. A plain
    /// element-wise mean (the previous implementation) is wrong once
    /// embeddings are meant to be unit vectors — it doesn't preserve unit
    /// length, and any sample with larger raw magnitude would silently
    /// dominate the average.
    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let count = Float(vectors.count)
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            let normalized = l2Normalized(vector)
            for i in 0..<normalized.count { sum[i] += normalized[i] }
        }
        let mean = sum.map { $0 / count }
        return l2Normalized(mean)
    }
}
