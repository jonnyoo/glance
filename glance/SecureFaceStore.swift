//
//  SecureFaceStore.swift
//  glance
//
//  Low-level encrypted persistence for enrolled face identities — AES-GCM under the same session key SecureCredentialManager
//  uses for the Mac password, rather than a second key. `FaceEnrollmentStore` delegates its load/save here; no plaintext fallback.
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
    /// Distinct filename/extension so plaintext can never be mistaken for ciphertext.
    private static let fileURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let subdirectory = Bundle.main.bundleIdentifier ?? "com.salimmous.glance"
        let directory = appSupport.appendingPathComponent(subdirectory, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appendingPathComponent("face-identities.enc")
    }()

    /// True if a store exists on disk, regardless of whether the session is currently unlocked enough to read it.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    /// Throws `.sessionLocked` rather than returning an empty array, so callers can distinguish "nothing enrolled" from "enrolled, but locked".
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
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
