//
//  SecureFaceStore.swift
//  glance
//
//  Low-level encrypted persistence for enrolled face identities. Face
//  embeddings are biometric data and were previously stored as plain JSON —
//  this encrypts them with AES-GCM under the same Touch-ID-gated session key
//  already used for the stored Mac password (SecureCredentialManager.encrypt/
//  decrypt), rather than duplicating crypto or introducing a second key.
//
//  `FaceEnrollmentStore` (the public, @Observable API the rest of the app
//  uses) delegates its load/save to this file. Reading or writing requires
//  an unlocked session — there is no plaintext fallback.
//

import Foundation

enum SecureFaceStoreError: LocalizedError {
    case sessionLocked

    var errorDescription: String? {
        switch self {
        case .sessionLocked:
            return "Session is locked. Authenticate with Touch ID to access enrolled faces."
        }
    }
}

nonisolated enum SecureFaceStore {
    /// Deliberately a different filename/format than the old plain-JSON
    /// store (`face-identities.json`) rather than reusing it — the schema
    /// changed (per-sample pose tags, model identifier) and the bytes are
    /// now ciphertext, not JSON. Using a new name avoids ever attempting to
    /// decode old plaintext data as if it were ciphertext, and old
    /// enrollments are meaningless under a new embedder anyway (see
    /// `FaceIdentity.isStale(comparedTo:)`).
    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = appSupport.appendingPathComponent("glance", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("face-identities.enc")
    }()

    /// True if an encrypted store exists on disk, regardless of whether the
    /// session is currently unlocked enough to read it.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Decrypts and decodes the stored identities. Throws `.sessionLocked`
    /// if there's no cached session key yet, rather than silently returning
    /// an empty array — callers should distinguish "nothing enrolled" from
    /// "enrolled, but locked" instead of showing a misleading empty state.
    static func load() throws -> [FaceIdentity] {
        guard SecureCredentialManager.isSessionUnlocked else { throw SecureFaceStoreError.sessionLocked }
        guard let ciphertext = try? Data(contentsOf: fileURL) else { return [] }
        let plaintext = try SecureCredentialManager.decrypt(ciphertext)
        return try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
    }

    static func save(_ identities: [FaceIdentity]) throws {
        guard SecureCredentialManager.isSessionUnlocked else { throw SecureFaceStoreError.sessionLocked }
        let plaintext = try JSONEncoder().encode(identities)
        let ciphertext = try SecureCredentialManager.encrypt(plaintext)
        try ciphertext.write(to: fileURL, options: .atomic)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
