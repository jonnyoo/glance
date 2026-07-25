//
//  FaceEnrollmentStore.swift
//  glance
//
//  Milestone E: save a person's face as a named "identity" made of one or
//  more sample embeddings, averaged into a single template vector.
//  Persisted encrypted (see SecureFaceStore) under the same Touch-ID-gated
//  session key as the stored Mac password — on-device only, nothing leaves
//  the Mac.
//
//  Because storage is now encrypted under the session key, reading/writing
//  requires an unlocked session (the same Touch ID gate the Credentials tab
//  already uses). `isLocked` and `reloadIfUnlocked()` let the UI handle that
//  rather than silently showing "no identities" when the real state is
//  "locked."
//

import Foundation
import Observation

struct FaceSample: Codable, Equatable {
    let embedding: [Float]
    /// Which guided-enrollment pose this came from ("center", "left",
    /// "right"), or nil for untagged captures (e.g. Face Lab's manual
    /// "Capture Sample" button).
    let pose: String?
    let capturedAt: Date
}

struct FaceIdentity: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var samples: [FaceSample]
    /// Which `FaceEmbedder.modelIdentifier` produced these samples.
    /// Embeddings from different models live in unrelated vector spaces —
    /// comparing across them wouldn't error, it would just produce
    /// confident nonsense. See `isStale(comparedTo:)`.
    var modelIdentifier: String
    var embeddingDimension: Int
    var createdAt: Date

    /// The single vector actually compared against at recognition time.
    nonisolated var template: [Float]? {
        FaceEmbedding.average(samples.map(\.embedding))
    }

    /// True if this identity's samples came from a different embedder than
    /// the one currently active — recognition should refuse to match
    /// against a stale identity and prompt re-enrollment instead.
    nonisolated func isStale(comparedTo embedder: FaceEmbedder) -> Bool {
        modelIdentifier != embedder.modelIdentifier
    }
}

@Observable
@MainActor
final class FaceEnrollmentStore {
    /// Shared instance so the Face Lab tab and the onboarding window (each
    /// with their own controller) observe and persist the same identities
    /// instead of two independently-loaded, silently-diverging copies.
    static let shared = FaceEnrollmentStore()

    private(set) var identities: [FaceIdentity] = []
    /// True until a successful load — distinguishes "nothing enrolled yet"
    /// from "enrolled, but the session needs Touch ID before we can read
    /// it." Starts true; callers should call `reloadIfUnlocked()` once the
    /// session is expected to be unlocked (e.g. view `.onAppear`, or right
    /// after `SecureCredentialManager.unlockSession` succeeds).
    private(set) var isLocked = true

    private init() {
        reloadIfUnlocked()
    }

    /// Re-attempts loading from encrypted storage. A no-op (leaves
    /// `isLocked = true`) if the session isn't unlocked yet.
    func reloadIfUnlocked() {
        guard SecureCredentialManager.isSessionUnlocked else {
            isLocked = true
            return
        }
        identities = (try? SecureFaceStore.load()) ?? []
        isLocked = false
    }

    /// Adds one captured sample to `name`'s identity (creating it if new).
    /// If the identity's existing samples came from a different embedder,
    /// they're discarded first — old and new samples aren't comparable, so
    /// silently mixing them would corrupt the template. Requires an
    /// unlocked session; throws `SecureFaceStoreError.sessionLocked`
    /// otherwise rather than silently dropping the sample.
    @discardableResult
    func addSample(name: String, embedding: [Float], embedder: FaceEmbedder, pose: String? = nil) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let sample = FaceSample(embedding: embedding, pose: pose, capturedAt: Date())

        if let index = identities.firstIndex(where: { $0.name == trimmed }) {
            if identities[index].modelIdentifier != embedder.modelIdentifier {
                identities[index].samples = [sample]
            } else {
                identities[index].samples.append(sample)
            }
            identities[index].modelIdentifier = embedder.modelIdentifier
            identities[index].embeddingDimension = embedder.embeddingDimension
        } else {
            identities.append(FaceIdentity(
                id: UUID(),
                name: trimmed,
                samples: [sample],
                modelIdentifier: embedder.modelIdentifier,
                embeddingDimension: embedder.embeddingDimension,
                createdAt: Date()
            ))
        }
        try persist()
        return true
    }

    func delete(_ identity: FaceIdentity) throws {
        identities.removeAll { $0.id == identity.id }
        try persist()
    }

    func deleteAll() throws {
        identities.removeAll()
        try persist()
    }

    private func persist() throws {
        try SecureFaceStore.save(identities)
    }
}
