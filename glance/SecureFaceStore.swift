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
    private static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    
    private static let primaryDirectory: URL = {
        let dir = appSupport.appendingPathComponent("iFace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    private static let legacyDirectory: URL = {
        let dir = appSupport.appendingPathComponent("glance", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var primaryFileURL: URL {
        primaryDirectory.appendingPathComponent("face-identities.enc")
    }

    private static var legacyFileURL: URL {
        legacyDirectory.appendingPathComponent("face-identities.enc")
    }

    /// True if a store exists on disk, regardless of whether the session is currently unlocked enough to read it.
    static var exists: Bool {
        FileManager.default.fileExists(atPath: primaryFileURL.path) ||
        FileManager.default.fileExists(atPath: legacyFileURL.path)
    }

    /// Throws `.sessionLocked` rather than returning an empty array, so callers can distinguish "nothing enrolled" from "enrolled, but locked".
    static func load() throws -> [FaceIdentity] {
        guard SecureCredentialManager.isSessionUnlocked else { throw SecureFaceStoreError.sessionLocked }
        
        let fileToRead: URL?
        if FileManager.default.fileExists(atPath: primaryFileURL.path) {
            fileToRead = primaryFileURL
        } else if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            fileToRead = legacyFileURL
        } else {
            fileToRead = nil
        }
        
        guard let url = fileToRead, let ciphertext = try? Data(contentsOf: url) else { return [] }
        let plaintext = try SecureCredentialManager.decrypt(ciphertext)
        let identities = try JSONDecoder().decode([FaceIdentity].self, from: plaintext)
        
        // Auto-migrate to primary location if loaded from legacy
        if url == legacyFileURL && !FileManager.default.fileExists(atPath: primaryFileURL.path) {
            try? ciphertext.write(to: primaryFileURL, options: .atomic)
        }
        
        return identities
    }

    static func save(_ identities: [FaceIdentity]) throws {
        guard SecureCredentialManager.isSessionUnlocked else { throw SecureFaceStoreError.sessionLocked }
        let plaintext = try JSONEncoder().encode(identities)
        let ciphertext = try SecureCredentialManager.encrypt(plaintext)
        try ciphertext.write(to: primaryFileURL, options: .atomic)
        try? ciphertext.write(to: legacyFileURL, options: .atomic)
    }

    static func deleteAll() {
        try? FileManager.default.removeItem(at: primaryFileURL)
        try? FileManager.default.removeItem(at: legacyFileURL)
    }
}
