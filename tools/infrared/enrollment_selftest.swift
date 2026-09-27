// Compile with the real enrollment model/store and these in-memory IO doubles.
// Never accesses the user's keychain or encrypted enrollment file.
import Foundation

@MainActor enum SecureCredentialManager { static var isSessionUnlocked = true }
extension Notification.Name { static let secureCredentialSessionDidChange = Notification.Name("IRTestSession") }
@MainActor enum SecureFaceStore {
    static var records: [FaceIdentity] = []
    static var fail = false
    static func load() throws -> [FaceIdentity] { if fail { throw CocoaError(.fileReadCorruptFile) }; return records }
    static func save(_ values: [FaceIdentity]) throws { if fail { throw CocoaError(.fileWriteNoPermission) }; records = values }
    static func deleteAll() { records = [] }
}

@main struct EnrollmentSelfTest {
    @MainActor static func main() throws {
        let embedder = VisionFeaturePrintEmbedder()
        let identity = FaceIdentity(id: UUID(), name: "Test", samples: [FaceSample(embedding: [1, 0], pose: nil, capturedAt: Date(), quality: nil)],
            modelIdentifier: embedder.modelIdentifier, embeddingDimension: embedder.embeddingDimension, createdAt: Date())
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) as! [String: Any]
        old.removeValue(forKey: "infrared"); old.removeValue(forKey: "isEnabled")
        let migrated = try JSONDecoder().decode(FaceIdentity.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(migrated.infrared == nil && migrated.isEnabled && migrated.id == identity.id)
        SecureFaceStore.records = [migrated]
        let store = FaceEnrollmentStore.shared
        let ir = try InfraredEnrollment(samples: (0..<3).map { _ in
            InfraredFaceSample(captureID: UUID(), modelIdentifier: InfraredEnrollment.expectedModelIdentifier,
                embedding: [1] + [Float](repeating: 0, count: 511))
        })
        try store.setInfrared(ir, for: migrated)
        let saved = store.identities[0]
        precondition(saved.infrared == ir && SecureFaceStore.records == store.identities)
        SecureFaceStore.fail = true
        do { try store.setInfrared(nil, for: saved); fatalError("write must fail") } catch {}
        precondition(store.identities[0] == saved)
        do { try store.addSample(name: "Test", embedding: [0, 1], embedder: embedder); fatalError("write must fail") } catch {}
        precondition(store.identities[0] == saved)
        SecureFaceStore.fail = false
        _ = try store.commitEnrollment(replacing: saved.id, name: saved.name, samples: saved.samples, embedder: embedder)
        precondition(store.identities[0].infrared == nil)
        do { try store.setInfrared(ir, for: saved); fatalError("stale identity must fail") } catch {}
        SecureFaceStore.fail = true
        store.reloadIfUnlocked()
        do { _ = try store.commitEnrollment(replacing: nil, name: "Other", samples: saved.samples, embedder: embedder); fatalError("unreadable store must block") } catch {}
        SecureCredentialManager.isSessionUnlocked = false
        store.reloadIfUnlocked()
        precondition(store.isLocked && store.identities.isEmpty)
        print("Enrollment tests passed: legacy migration, IR save/rollback, RGB recapture invalidation, stale save rejection and session clearing.")
    }
}
