//
//  FaceEmbedder.swift
//  glance
//
//  Two implementations: `VisionFeaturePrintEmbedder` (Apple's built-in, but only ~5-7% similarity gap between people —
//  too thin to gate unlock on) and `ArcFaceEmbedder` (real face-discriminative model).
//

import Vision
import CoreGraphics

/// `nonisolated` so implementations can run on a background task despite the project's default main-actor isolation.
protocol FaceEmbedder: Sendable {
    /// Name shown in the debug UI so it's obvious which embedder produced a given saved sample.
    nonisolated var name: String { get }
    /// Persisted alongside every sample; `SecureFaceStore` uses it to refuse comparing across different embedders
    /// (which wouldn't error, just produce confident nonsense).
    nonisolated var modelIdentifier: String { get }
    /// Declared output length, for cross-model mismatch detection without running an embedding first.
    nonisolated var embeddingDimension: Int { get }
    /// Whether this embedder needs a canonically-aligned input (ArcFace) vs. tolerating a loose crop (Vision feature-print).
    nonisolated var requiresAlignment: Bool { get }
    /// Whether this embedder has sufficient inter-person separation to authorize Mac unlock (true for ArcFace, false for Vision feature-print).
    nonisolated var isUnlockCapable: Bool { get }
    nonisolated func embedding(for face: CGImage) throws -> [Float]
}

enum FaceEmbedderError: LocalizedError {
    case noObservation
    case unsupportedElementType
    case corruptedObservationData

    var errorDescription: String? {
        switch self {
        case .noObservation:
            return "Vision did not produce a feature print for this image."
        case .unsupportedElementType:
            return "Feature print used an unexpected element type."
        case .corruptedObservationData:
            return "Feature print data buffer had an unexpected byte length."
        }
    }
}

struct VisionFeaturePrintEmbedder: FaceEmbedder {
    nonisolated let name = "Vision Feature Print"
    nonisolated let modelIdentifier = "vision-feature-print-v1"
    // Nominal hint only — `modelIdentifier` is the real discriminator `SecureFaceStore` relies on.
    nonisolated let embeddingDimension = 2048
    nonisolated let requiresAlignment = false
    nonisolated let isUnlockCapable = false

    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: face, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNFeaturePrintObservation else {
            throw FaceEmbedderError.noObservation
        }
        return try Self.floatVector(
            from: observation.data,
            elementCount: observation.elementCount,
            elementType: observation.elementType
        )
    }

    /// Decodes Vision's raw bytes + element type into `[Float]` via bounds-checked, alignment-safe byte copies.
    nonisolated static func floatVector(
        from data: Data,
        elementCount count: Int,
        elementType: VNElementType
    ) throws -> [Float] {
        guard count >= 0 else { throw FaceEmbedderError.corruptedObservationData }
        switch elementType {
        case .float:
            let byteCount = count * MemoryLayout<Float>.stride
            guard data.count >= byteCount else { throw FaceEmbedderError.corruptedObservationData }
            var result = [Float](repeating: 0, count: count)
            result.withUnsafeMutableBytes { dst in
                if byteCount > 0 {
                    _ = data.copyBytes(to: dst, count: byteCount)
                }
            }
            return result
        case .double:
            let byteCount = count * MemoryLayout<Double>.stride
            guard data.count >= byteCount else { throw FaceEmbedderError.corruptedObservationData }
            var doubles = [Double](repeating: 0, count: count)
            doubles.withUnsafeMutableBytes { dst in
                if byteCount > 0 {
                    _ = data.copyBytes(to: dst, count: byteCount)
                }
            }
            return doubles.map(Float.init)
        default:
            throw FaceEmbedderError.unsupportedElementType
        }
    }
}

nonisolated enum FaceEmbedding {
    /// Scales `vector` to unit length; matters once vectors are combined (see `average` below).
    static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity, range -1...1. The raw value ArcFace thresholds are quoted in (typical cutoffs ~0.28-0.40).
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

    /// For the legacy Vision-feature-print UI only. Don't use to tune ArcFace thresholds — use `cosineSimilarity` directly.
    static func similarityPercent(_ a: [Float], _ b: [Float]) -> Double {
        let similarity = cosineSimilarity(a, b)
        return Double((similarity + 1) / 2) * 100
    }

    /// Normalize each sample, average, then renormalize — a plain element-wise mean would let a larger-magnitude
    /// sample silently dominate.
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
