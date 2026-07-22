//
//  FaceEmbedder.swift
//  glance
//
//  Milestone D: turn a cropped face image into a fixed-length list of
//  numbers (an "embedding"). Two embeddings of the same person's face end up
//  close together; different people end up far apart — recognition (F) is
//  just measuring that distance.
//
//  `VisionFeaturePrintEmbedder` uses Apple's built-in, on-device Vision
//  feature-print — it needs no downloaded model, so the whole A-F pipeline
//  can be exercised today. It's a *general-purpose* image descriptor, not a
//  face-specialized one, so match thresholds are empirical (tune via the
//  Face Lab slider) rather than a fixed, well-known cutoff.
//
//  To upgrade accuracy later: implement `FaceEmbedder` with a dedicated
//  Core ML face model (e.g. MobileFaceNet, 112x112 or 224x224 in, 512-float
//  out) and swap it in wherever `FaceEmbedder` is constructed — nothing else
//  in the pipeline needs to change.
//
//  TODO: MobileFaceNetEmbedder — struct MobileFaceNetEmbedder: FaceEmbedder,
//  backed by a bundled .mlpackage, once a licensed/converted model is sourced.
//

import Vision
import CoreGraphics

/// Pure, synchronous, CPU-bound work — `nonisolated` so implementations can
/// run on a background task despite the project's default main-actor
/// isolation.
protocol FaceEmbedder: Sendable {
    /// Name shown in the debug UI so it's obvious which embedder produced a
    /// given saved sample (matters once a second embedder exists).
    nonisolated var name: String { get }
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

enum FaceEmbedding {
    /// Cosine similarity, range -1...1 (1 = identical direction). This is
    /// what "how close are these two number-lists" actually means in
    /// practice — it ignores overall magnitude and just compares shape.
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

    /// Maps cosine similarity (-1...1) into a 0...100% shown in the UI.
    static func similarityPercent(_ a: [Float], _ b: [Float]) -> Double {
        let similarity = cosineSimilarity(a, b)
        return Double((similarity + 1) / 2) * 100
    }

    /// Element-wise mean of several samples of the same identity, producing
    /// one stable "template" embedding instead of comparing against every
    /// captured sample individually.
    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let count = Float(vectors.count)
        var sum = [Float](repeating: 0, count: first.count)
        for vector in vectors where vector.count == first.count {
            for i in 0..<vector.count { sum[i] += vector[i] }
        }
        return sum.map { $0 / count }
    }
}
