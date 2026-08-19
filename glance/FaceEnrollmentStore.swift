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
    /// Vision's capture-quality score (0...1) for the frame this embedding
    /// came from — the same number Face Lab shows live as "Capture
    /// quality" — or nil when Vision produced none, and on samples saved
    /// before this field existed. Optional so the synthesized decoder uses
    /// `decodeIfPresent` and already-encrypted stores still load.
    let quality: Float?
}

extension FaceSample {
    /// How a stored sample's capture quality reads to the user. The bands
    /// are the ones the Your Face design calls for — red below 40%, amber
    /// through 50%, green above — and live here rather than in a view so
    /// Face Lab's debug list and the settings tick strip can't drift apart.
    enum QualityTier {
        /// No score recorded: samples captured before quality was persisted,
        /// or frames Vision declined to rate. Never counted as poor.
        case unrated
        case poor
        case fair
        case good
    }

    var qualityTier: QualityTier {
        guard let quality else { return .unrated }
        if quality < 0.4 { return .poor }
        if quality < 0.5 { return .fair }
        return .good
    }
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
    /// Whether face unlock is allowed to match against this person. Turning
    /// it off keeps the enrollment intact but takes them out of
    /// `FaceEnrollmentStore.activeIdentities`, which is what the unlock path
    /// actually scores against.
    var isEnabled: Bool

    init(
        id: UUID,
        name: String,
        samples: [FaceSample],
        modelIdentifier: String,
        embeddingDimension: Int,
        createdAt: Date,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.samples = samples
        self.modelIdentifier = modelIdentifier
        self.embeddingDimension = embeddingDimension
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }

    /// Hand-written purely so `isEnabled` can default to `true` when it's
    /// absent. A synthesized decoder throws on a missing key for a
    /// non-optional property, which would make every identity enrolled
    /// before this field existed fail to load — the whole store decodes as
    /// one array, so a single throw loses all of them. (`encode(to:)` and
    /// `CodingKeys` are still synthesized.)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        samples = try container.decode([FaceSample].self, forKey: .samples)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        embeddingDimension = try container.decode(Int.self, forKey: .embeddingDimension)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

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

    /// The identities face unlock is actually allowed to match against —
    /// everyone the user hasn't switched off on the Your Face page. Scoring
    /// against this rather than `identities` is what makes the per-identity
    /// toggle mean anything; `identities` stays the full list the settings
    /// UI renders.
    var activeIdentities: [FaceIdentity] {
        identities.filter(\.isEnabled)
    }

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
    func addSample(name: String, embedding: [Float], embedder: FaceEmbedder, pose: String? = nil, quality: Float? = nil) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let sample = FaceSample(embedding: embedding, pose: pose, capturedAt: Date(), quality: quality)

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

    /// Commits a whole guided enrollment in a single write, rather than the
    /// 18 encrypt-and-write round-trips an `addSample` loop would do.
    ///
    /// When `existingID` names a known identity, its `id` and `createdAt`
    /// are preserved and its samples are replaced *wholesale* — a recapture
    /// is a redo, not an append, and blending a person's old and new samples
    /// into one template is exactly what the old delete-then-re-add dance in
    /// `OnboardingController` existed to avoid. Because the match is by id
    /// rather than by name, a recapture can also rename the identity.
    /// Otherwise a brand-new identity is appended.
    ///
    /// Returns nil (writing nothing) for an empty name or no samples.
    @discardableResult
    func commitEnrollment(
        replacing existingID: UUID?,
        name: String,
        samples: [FaceSample],
        embedder: FaceEmbedder
    ) throws -> FaceIdentity? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !samples.isEmpty else { return nil }

        // Built against a local copy and only assigned once the encrypted
        // write actually succeeds — otherwise a locked session would leave
        // the observable array showing a save that never reached disk.
        var updated = identities
        let committed: FaceIdentity
        if let existingID, let index = updated.firstIndex(where: { $0.id == existingID }) {
            updated[index].name = trimmed
            updated[index].samples = samples
            updated[index].modelIdentifier = embedder.modelIdentifier
            updated[index].embeddingDimension = embedder.embeddingDimension
            committed = updated[index]
        } else {
            // Also the fallback when `existingID` no longer resolves — the
            // identity was deleted while the notch flow was running. Saving
            // the capture as a new identity beats discarding it.
            committed = FaceIdentity(
                id: UUID(),
                name: trimmed,
                samples: samples,
                modelIdentifier: embedder.modelIdentifier,
                embeddingDimension: embedder.embeddingDimension,
                createdAt: Date()
            )
            updated.append(committed)
        }
        try SecureFaceStore.save(updated)
        identities = updated
        return committed
    }

    /// Whether `name` already belongs to an enrolled identity. Deliberately
    /// case- and diacritic-insensitive, unlike `addSample`'s exact match:
    /// "alex", "Alex" and "Álex" would be separate identities in storage but
    /// one person to the user, so the naming step refuses the collision
    /// instead. `addSample` keeps its exact match — it's the debug-only
    /// manual path, where creating a near-duplicate is a legitimate thing to
    /// want to do.
    ///
    /// `excluding` is the identity currently being recaptured, which is of
    /// course allowed to keep its own name.
    func nameIsTaken(_ name: String, excluding id: UUID? = nil) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return identities.contains {
            $0.id != id
                && $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    /// Switches one identity in or out of face unlock without disturbing
    /// its samples, so re-enabling costs nothing. Reverts the in-memory flag
    /// if the encrypted write fails, rather than leaving the toggle showing
    /// a state that isn't on disk.
    func setEnabled(_ isEnabled: Bool, for identityID: UUID) throws {
        guard let index = identities.firstIndex(where: { $0.id == identityID }) else { return }
        let previous = identities[index].isEnabled
        guard previous != isEnabled else { return }
        identities[index].isEnabled = isEnabled
        do {
            try persist()
        } catch {
            identities[index].isEnabled = previous
            throw error
        }
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
