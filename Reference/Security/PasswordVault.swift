//
//  PasswordVault.swift
//  FaceUnlock
//
//  Two-tier password storage:
//    1. Session key (256-bit AES) — Keychain-stored, gated by Touch ID (.userPresence).
//       Held in memory as a `SymmetricKey` after one successful unwrap per app launch.
//    2. Encrypted password blob (AES-GCM) — Keychain-stored, no biometric gate.
//       Meaningless without the session key.
//
//  The plaintext password is never persisted anywhere unencrypted. In memory it's
//  handled as `Data`, callers zero it via `.resetBytes(in:)` after use.
//

import Foundation
import Security
import LocalAuthentication
import CryptoKit

enum PasswordVaultError: LocalizedError {
    case emptyPassword
    case dataEncodingFailed
    case accessControlFailed(String)
    case keychainError(OSStatus)
    case userCancelled
    case sessionLocked
    case encryptionFailed
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return "Password cannot be empty."
        case .dataEncodingFailed:
            return "Couldn't encode the password as UTF-8 data."
        case .accessControlFailed(let msg):
            return "Couldn't create Keychain access control: \(msg)"
        case .keychainError(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        case .userCancelled:
            return "Authentication was cancelled."
        case .sessionLocked:
            return "Session is locked. Touch ID is required to unlock the session before encrypted data can be accessed."
        case .encryptionFailed:
            return "Encryption failed."
        case .decryptionFailed:
            return "Decryption failed. The stored password may be corrupted."
        }
    }
}

enum PasswordVault {
    nonisolated static let service = "com.hasbrain.FaceUnlock"
    nonisolated static let sessionKeyAccount = "sessionKey"
    nonisolated static let encryptedBlobAccount = "encryptedPasswordBlob"

    // Legacy accounts wiped on delete (from previous app versions).
    nonisolated private static let legacyAccounts = ["macUserPassword", "embedding.json"]

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey? = nil

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    nonisolated private static func loadCachedKey() -> SymmetricKey? {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return _cachedKey
    }

    nonisolated private static func storeCachedKey(_ key: SymmetricKey?) {
        sessionLock.lock()
        _cachedKey = key
        sessionLock.unlock()
    }

    // MARK: - Public API

    /// Does an encrypted blob exist? (Existence check — no auth required.)
    nonisolated static func hasStoredPassword() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: encryptedBlobAccount,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecItemNotFound
    }

    /// Does a session key exist in the Keychain? (Existence check via
    /// attributes-only query — does not prompt for Touch ID.)
    ///
    /// If this returns true but `isSessionUnlocked` is false, the caller must
    /// call `unlockSession(reason:)` before any save/encrypt/decrypt call.
    nonisolated static func hasSessionKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionKeyAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecItemNotFound
    }

    /// Save (or replace) the password. Uses the existing session key if one is
    /// available (cached or freshly-generated); if the Keychain already has a key
    /// but the session is locked, throws `.sessionLocked` — caller must unlock first.
    ///
    /// Blocking; call from a background actor.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw PasswordVaultError.emptyPassword }

        let key = try ensureSessionKey()

        // Encrypt with AES-GCM
        let combined: Data
        do {
            let sealed = try AES.GCM.seal(passwordBytes, using: key)
            guard let c = sealed.combined else { throw PasswordVaultError.encryptionFailed }
            combined = c
        } catch {
            throw PasswordVaultError.encryptionFailed
        }

        // Persist encrypted blob (no biometric gate — meaningless without the key)
        try saveEncryptedBlob(combined)
    }

    /// Encrypt arbitrary data with the current session key. Used by
    /// `FaceEnrollmentService` to encrypt the enrolled face embeddings at rest.
    ///
    /// Requires either a cached session key OR no session key at all (first use
    /// creates one). Fails if a key exists in Keychain but the session is locked —
    /// caller must call `unlockSession(reason:)` first.
    nonisolated static func encryptWithSessionKey(_ plaintext: Data) throws -> Data {
        let key = try ensureSessionKey()
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw PasswordVaultError.encryptionFailed }
            return combined
        } catch {
            throw PasswordVaultError.encryptionFailed
        }
    }

    /// Decrypt data that was encrypted with `encryptWithSessionKey`. Requires the
    /// session to be unlocked (or first-use with no key yet, which would then fail
    /// to decrypt anyway — legitimate use always follows an encrypted-write).
    nonisolated static func decryptWithSessionKey(_ ciphertext: Data) throws -> Data {
        guard let key = loadCachedKey() else {
            throw PasswordVaultError.sessionLocked
        }
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw PasswordVaultError.decryptionFailed
        }
    }

    /// Returns the session key: cached in memory if available, freshly created
    /// (and persisted to Keychain) if none exists yet, or throws `.sessionLocked`
    /// if a key is present but not yet unwrapped this session.
    nonisolated private static func ensureSessionKey() throws -> SymmetricKey {
        if let cached = loadCachedKey() { return cached }

        // Attributes-only query — doesn't need auth, just checks presence.
        let existsQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionKeyAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(existsQuery as CFDictionary, &item)
        if status != errSecItemNotFound {
            // Key already exists in Keychain but we don't have it in memory.
            // Caller must call unlockSession(reason:) to unwrap it via Touch ID.
            throw PasswordVaultError.sessionLocked
        }

        // No key anywhere — create one now, silently (Touch ID is enforced on future READS).
        let key = SymmetricKey(size: .bits256)
        try saveSessionKey(key)
        storeCachedKey(key)
        return key
    }

    /// Prompts Touch ID / device password and unwraps the session key into memory.
    /// Call once per app launch (typically at startup) before any reads.
    ///
    /// Blocking; call from a background actor.
    nonisolated static func unlockSession(reason: String) throws {
        let context = LAContext()
        context.localizedReason = reason

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw PasswordVaultError.dataEncodingFailed
            }
            let key = SymmetricKey(data: data)
            storeCachedKey(key)
        case errSecUserCanceled, errSecAuthFailed:
            throw PasswordVaultError.userCancelled
        default:
            throw PasswordVaultError.keychainError(status)
        }
    }

    /// Explicitly clear the cached session key. Next read will require Touch ID again.
    nonisolated static func lockSession() {
        storeCachedKey(nil)
    }

    /// Read + decrypt the password. Requires the session to be unlocked
    /// (call `unlockSession(reason:)` first if not).
    ///
    /// Returns raw bytes — the caller MUST zero them via `.resetBytes(in:)` after use.
    /// Blocking; call from a background actor.
    nonisolated static func readPassword() throws -> Data {
        guard let key = loadCachedKey() else {
            throw PasswordVaultError.sessionLocked
        }

        // Fetch encrypted blob (no Touch ID prompt — just accessible when unlocked)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: encryptedBlobAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let ciphertext = item as? Data else {
            throw PasswordVaultError.keychainError(status)
        }

        // Decrypt
        do {
            let sealed = try AES.GCM.SealedBox(combined: ciphertext)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw PasswordVaultError.decryptionFailed
        }
    }

    /// Delete both the session key and encrypted blob (plus legacy items).
    /// Clears the cached session state.
    nonisolated static func deletePassword() throws {
        let accountsToDelete = [encryptedBlobAccount, sessionKeyAccount] + legacyAccounts
        for account in accountsToDelete {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw PasswordVaultError.keychainError(status)
            }
        }
        storeCachedKey(nil)
    }

    // MARK: - Internal Keychain helpers

    nonisolated private static func saveSessionKey(_ key: SymmetricKey) throws {
        // Wipe any prior key first (may itself be Touch-ID-gated; delete allowed regardless).
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionKeyAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Touch ID / device password gate on read.
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            let msg = (accessError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw PasswordVaultError.accessControlFailed(msg)
        }

        let keyData = key.withUnsafeBytes { Data($0) }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: sessionKeyAccount,
            kSecValueData as String: keyData,
            kSecAttrAccessControl as String: access
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PasswordVaultError.keychainError(status)
        }
    }

    nonisolated private static func saveEncryptedBlob(_ data: Data) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: encryptedBlobAccount
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: encryptedBlobAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PasswordVaultError.keychainError(status)
        }
    }
}
