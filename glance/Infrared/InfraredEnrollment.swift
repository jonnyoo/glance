import Foundation

/// Stored only inside the existing encrypted FaceIdentity record. RGB samples
/// remain separate; a recapture of RGB invalidates this second enrollment.
nonisolated struct InfraredEnrollment: Codable, Equatable, Sendable {
    static let expectedModelIdentifier = "brio-046d-085e-l8ir-five-point-v1/arcface-w600k_mbf-v1"
    let revision: UUID
    let modelIdentifier: String
    let embeddings: [[Float]]
    let createdAt: Date

    init(samples: [InfraredFaceSample]) throws {
        guard samples.count == InfraredReference.requiredSamples,
              Set(samples.map(\.captureID)).count == samples.count,
              samples.allSatisfy({ $0.modelIdentifier == Self.expectedModelIdentifier }) else {
            throw InfraredReferenceError.invalidEmbedding
        }
        var reference = InfraredReference()
        for sample in samples { try reference.add(sample) }
        revision = UUID()
        modelIdentifier = Self.expectedModelIdentifier
        embeddings = samples.map(\.embedding)
        createdAt = Date()
    }

    var isUsable: Bool { (try? reference()) != nil }

    func compare(_ sample: InfraredFaceSample) throws -> InfraredSimilarity {
        try reference().compare(sample)
    }

    private func reference() throws -> InfraredReference {
        guard modelIdentifier == Self.expectedModelIdentifier,
              embeddings.count == InfraredReference.requiredSamples else {
            throw InfraredReferenceError.differentModel
        }
        var result = InfraredReference()
        for vector in embeddings {
            try result.add(InfraredFaceSample(captureID: UUID(), modelIdentifier: modelIdentifier, embedding: vector))
        }
        return result
    }
}

/// Pure final gate, shared by the real unlock path and deterministic tests.
/// Durations use a monotonic clock; this evidence never survives a scan/session.
nonisolated enum InfraredUnlockPolicy {
    static let defaultThreshold = 0.70
    static let maximumEvidenceAge: TimeInterval = 15
    static func permits(score: InfraredSimilarity, threshold: Double, elapsed: TimeInterval,
                        sameIdentityAndEnrollment: Bool, sameScan: Bool,
                        sessionUnlocked: Bool, screenLocked: Bool, sleeping: Bool,
                        livenessConfirmed: Bool, helperEnabled: Bool) -> Bool {
        guard threshold.isFinite, (0.60...1).contains(threshold),
              elapsed.isFinite, (0...maximumEvidenceAge).contains(elapsed),
              score.centroid.isFinite, score.minimumReference.isFinite, score.maximumReference.isFinite,
              (-1...1).contains(score.centroid), (-1...1).contains(score.minimumReference),
              (-1...1).contains(score.maximumReference),
              score.minimumReference <= score.maximumReference,
              sameIdentityAndEnrollment, sameScan, sessionUnlocked, screenLocked,
              !sleeping, livenessConfirmed, helperEnabled else { return false }
        return score.centroid >= threshold && score.minimumReference >= threshold
    }
}
