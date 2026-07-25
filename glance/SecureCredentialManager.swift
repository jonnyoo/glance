//
//  SecureCredentialManager.swift
//  glance
//
//  Two-tier password storage on top of KeychainManager:
//    1. Session key (256-bit AES) — Touch-ID-gated Keychain item. Unwrapped
//       into memory once per app launch via unlockSession(reason:).
//    2. Encrypted password blob (AES-GCM) — Keychain item, no biometric gate.
//       Meaningless without the session key, so it's safe to read at any
//       time — including from the lock screen, where a Touch ID prompt
//       can't run because there's no app UI to host it.
//
//  Touch ID authorizes the session; nothing currently authorizes each
//  individual unlock beyond that (face recognition will fill that role).
//

import Foundation
import CryptoKit
import LocalAuthentication

enum SecureCredentialError: LocalizedError {
    case emptyPassword
    case sessionLocked
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Password cannot be empty."
        case .sessionLocked:
            return "Session is locked. Authenticate with Touch ID before storing or using the password."
        case .encryptionFailed:
            return "Encryption failed."
        case .decryptionFailed:
            return "Decryption failed. The stored credential may be corrupted."
        }
    }
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"
    nonisolated private static let passwordBlobAccount = "encryptedPassword"

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    nonisolated private static func cachedKey() -> SymmetricKey? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey
    }

    nonisolated private static func setCachedKey(_ key: SymmetricKey?) {
        sessionLock.lock(); _cachedKey = key; sessionLock.unlock()
    }

    // MARK: - Generic session-key crypto (shared seam for anything encrypted
    // under the session key — passwords here, face embeddings in
    // SecureFaceStore. Requires an unlocked session; does not touch Keychain.)

    nonisolated static func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw SecureCredentialError.encryptionFailed }
            return combined
        } catch {
            throw SecureCredentialError.encryptionFailed
        }
    }

    nonisolated static func decrypt(_ ciphertext: Data) throws -> Data {
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw SecureCredentialError.decryptionFailed
        }
    }

    // MARK: - Public API

    nonisolated static func hasStoredPassword() -> Bool {
        KeychainManager.exists(account: passwordBlobAccount)
    }

    /// Prompts Touch ID / device password and unwraps the session key into
    /// memory. If no key exists yet in the Keychain (first run ever), creates
    /// one silently and stores it Touch-ID-gated for next time — there's
    /// nothing to authenticate against on the very first write, so this one
    /// bootstrap case can't itself require Touch ID. Every subsequent call
    /// (including after `lockSession()`) does require it.
    ///
    /// Must succeed before `savePassword` or `readPassword` will work.
    /// Blocking; call from a background task.
    nonisolated static func unlockSession(reason: String) throws {
        if cachedKey() != nil { return }

        if KeychainManager.exists(account: sessionKeyAccount) {
            let context = LAContext()
            context.localizedReason = reason
            let data = try KeychainManager.read(account: sessionKeyAccount, context: context)
            setCachedKey(SymmetricKey(data: data))
        } else {
            let key = SymmetricKey(size: .bits256)
            let access = try KeychainManager.makeUserPresenceAccessControl()
            try KeychainManager.save(
                account: sessionKeyAccount,
                data: key.withUnsafeBytes { Data($0) },
                accessControl: access
            )
            setCachedKey(key)
        }
    }

    /// Clears the cached session key. Next save/read requires Touch ID again.
    nonisolated static func lockSession() {
        setCachedKey(nil)
    }

    /// Encrypts and stores `passwordBytes`. Requires an unlocked session —
    /// call `unlockSession(reason:)` first. Blocking; call from a background task.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        let combined = try encrypt(passwordBytes)
        try KeychainManager.save(account: passwordBlobAccount, data: combined)
    }

    /// Decrypts and returns the stored password. Requires an unlocked
    /// session (no separate Touch ID prompt here — the blob itself isn't
    /// gated, only the session key was, at unlock time).
    ///
    /// Returns raw bytes — the caller MUST zero them via `.resetBytes(in:)`
    /// after use. Blocking; call from a background task.
    nonisolated static func readPassword() throws -> Data {
        guard cachedKey() != nil else { throw SecureCredentialError.sessionLocked }
        let ciphertext = try KeychainManager.read(account: passwordBlobAccount)
        return try decrypt(ciphertext)
    }

    /// Deletes both Keychain items and clears the cached session key.
    nonisolated static func deletePassword() throws {
        try KeychainManager.delete(account: passwordBlobAccount)
        try KeychainManager.delete(account: sessionKeyAccount)
        setCachedKey(nil)
    }
}
