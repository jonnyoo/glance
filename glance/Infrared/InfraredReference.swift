import Foundation

/// Session-only measurements. This type is deliberately not Codable and has no
/// connection to enrollment storage, liveness decisions or password injection.
nonisolated struct InfraredFaceSample: Sendable {
    let captureID: UUID
    let modelIdentifier: String
    let embedding: [Float]
}

nonisolated struct InfraredSimilarity: Sendable {
    let centroid: Double
    let minimumReference: Double
    let maximumReference: Double
}

nonisolated enum InfraredReferenceError: LocalizedError {
    case invalidEmbedding
    case differentModel
    case repeatedCapture
    case referenceFull
    case referenceIncomplete

    var errorDescription: String? {
        switch self {
        case .invalidEmbedding: return "The face model returned an invalid infrared sample. Try another scan."
        case .differentModel: return "The face model changed. Clear the reference and capture it again."
        case .repeatedCapture: return "This image is already in the reference. Capture a new infrared scan."
        case .referenceFull: return "The three reference scans are complete. Compare a new scan or clear the reference."
        case .referenceIncomplete: return "Capture three reference scans before comparing."
        }
    }
}

nonisolated struct InfraredReference: Sendable {
    static let requiredSamples = 3
    static let embeddingDimension = 512
    private var samples: [InfraredFaceSample] = []
    var count: Int { samples.count }
    var isComplete: Bool { count == Self.requiredSamples }

    mutating func add(_ sample: InfraredFaceSample) throws {
        guard !isComplete else { throw InfraredReferenceError.referenceFull }
        let normalized = try validate(sample)
        samples.append(InfraredFaceSample(captureID: sample.captureID,
            modelIdentifier: sample.modelIdentifier, embedding: normalized.map(Float.init)))
    }

    func compare(_ sample: InfraredFaceSample) throws -> InfraredSimilarity {
        guard isComplete else { throw InfraredReferenceError.referenceIncomplete }
        let query = try validate(sample)
        let references = try samples.map { try Self.normalize($0.embedding) }
        var sum = [Double](repeating: 0, count: Self.embeddingDimension)
        for reference in references {
            for index in sum.indices { sum[index] += reference[index] }
        }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-12 else { throw InfraredReferenceError.invalidEmbedding }
        let centroid = sum.map { $0 / norm }
        let individual = references.map { Self.cosine(query, $0) }
        return InfraredSimilarity(centroid: Self.cosine(query, centroid),
            minimumReference: individual.min()!, maximumReference: individual.max()!)
    }

    mutating func clear() { samples.removeAll(keepingCapacity: false) }

    private func validate(_ sample: InfraredFaceSample) throws -> [Double] {
        guard !sample.modelIdentifier.isEmpty else { throw InfraredReferenceError.invalidEmbedding }
        if let first = samples.first, first.modelIdentifier != sample.modelIdentifier {
            throw InfraredReferenceError.differentModel
        }
        guard !samples.contains(where: { $0.captureID == sample.captureID }) else {
            throw InfraredReferenceError.repeatedCapture
        }
        return try Self.normalize(sample.embedding)
    }

    private static func normalize(_ vector: [Float]) throws -> [Double] {
        guard vector.count == embeddingDimension, vector.allSatisfy(\.isFinite) else {
            throw InfraredReferenceError.invalidEmbedding
        }
        let values = vector.map(Double.init)
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-12 else { throw InfraredReferenceError.invalidEmbedding }
        return values.map { $0 / norm }
    }

    private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        // Both vectors are normalized. Clamp only floating-point roundoff.
        min(1, max(-1, zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }))
    }
}
