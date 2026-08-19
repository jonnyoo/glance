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
    case sessionKeyUnavailable

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
        case .sessionKeyUnavailable:
            return "The session key is missing, but encrypted data still exists that only it could read. Nothing has been deleted. Remove the stored password on the Password tab to clear both and start fresh."
        }
    }
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"
    nonisolated private static let passwordBlobAccount = "encryptedPassword"

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?
    /// When the session was last unlocked or actually *used* (a successful
    /// `readPassword`). `SessionAutoLocker` compares this against the user's
    /// chosen idle limit — "inactivity" means neither of those has happened
    /// recently, not merely that time has passed since unlock. Guarded by
    /// `sessionLock` alongside the key it describes, so the two can never be
    /// observed out of step with each other.
    nonisolated(unsafe) private static var _lastActivityAt: Date?

    nonisolated static var isSessionUnlocked: Bool {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey != nil
    }

    /// `nil` whenever the session is locked — there is no activity to age.
    nonisolated static var lastActivityAt: Date? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _lastActivityAt
    }

    nonisolated private static func cachedKey() -> SymmetricKey? {
        sessionLock.lock(); defer { sessionLock.unlock() }
        return _cachedKey
    }

    nonisolated private static func setCachedKey(_ key: SymmetricKey?) {
        sessionLock.lock()
        _cachedKey = key
        _lastActivityAt = key == nil ? nil : Date()
        sessionLock.unlock()
    }

    /// Resets the idle countdown. Called on each successful use of the
    /// stored password, so a session in active use never auto-locks.
    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _cachedKey != nil { _lastActivityAt = Date() }
        sessionLock.unlock()
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
    /// memory. On a genuine first run it creates the key and stores it
    /// Touch-ID-gated for next time — but does not trust that write alone to
    /// mean "unlocked," and will not create one when the key has gone
    /// missing while data encrypted under it survives (see the guard below).
    ///
    /// The old version cached the key as soon as `SecItemAdd` returned,
    /// reasoning "there's nothing to authenticate against on the very first
    /// write." That's true, but doesn't hold up in practice: confirmed via
    /// logging, `SecItemAdd` returns `errSecSuccess` — and the old code
    /// cached the key — regardless of whether the user clicked Cancel on
    /// whatever auth UI macOS happened to show around it. A first attempt at
    /// fixing this by explicitly calling `LAContext.evaluatePolicy` before
    /// the write made it worse: bridging that callback-based API to this
    /// file's synchronous style with a semaphore blocked the calling
    /// `Task.detached` thread, which starved Swift's cooperative thread pool
    /// and crashed the process outright.
    ///
    /// This is simpler and reuses a mechanism already proven to work
    /// correctly: after creating the item (silently, ungated, exactly as
    /// before), immediately read it back via the same
    /// `KeychainManager.read(account:context:)` call the existing-key branch
    /// below already uses — genuinely synchronous, no callback bridging
    /// needed, and its `kSecUseAuthenticationContext` gate is what already
    /// correctly respects Cancel for that branch. Only a successful read
    /// caches the key, so the create step being ungated is harmless: nothing
    /// sensitive exists yet at that point regardless of how it resolves.
    ///
    /// Must succeed before `savePassword` or `readPassword` will work.
    /// Blocking; call from a background task.
    nonisolated static func unlockSession(reason: String) throws {
        if cachedKey() != nil { return }

        // The existence check, not the read, is what decides whether a key
        // gets created — and that ordering is load-bearing. Cancelling the
        // prompt on a user-presence item does not report "cancelled": the
        // ACL fails to authorize and Keychain Services reports
        // `errSecItemNotFound`, indistinguishable from a key that genuinely
        // isn't there. Deciding on the read's error would therefore mint a
        // fresh key every time someone mis-tapped the prompt, and
        // `KeychainManager.save` is delete-then-add, so the only key that
        // could decrypt the stored password and every enrolled face would be
        // destroyed. An attributes-only query needs no ACL evaluation, so it
        // still answers honestly right after a cancel.
        if KeychainManager.exists(account: sessionKeyAccount) {
            let context = LAContext()
            context.localizedReason = reason
            let data = try KeychainManager.read(account: sessionKeyAccount, context: context)
            setCachedKey(SymmetricKey(data: data))
            return
        }

        // No key item at all. Creating one is still destructive if something
        // is already encrypted under a previous key — the orphaned state a
        // re-signed development build produces. Refuse rather than mint a
        // key that silently renders that data unreadable forever; the error
        // names the only real way out.
        guard !hasSessionEncryptedData else {
            throw SecureCredentialError.sessionKeyUnavailable
        }

        let key = SymmetricKey(size: .bits256)
        let access = try KeychainManager.makeUserPresenceAccessControl()
        try KeychainManager.save(
            account: sessionKeyAccount,
            data: key.withUnsafeBytes { Data($0) },
            accessControl: access
        )

        // Read back through the same gated path rather than trusting the
        // write: `SecItemAdd` returns success regardless of how any auth UI
        // macOS showed around it resolved, so only a real read proves the
        // user actually authenticated.
        let readBackContext = LAContext()
        readBackContext.localizedReason = reason
        let data = try KeychainManager.read(account: sessionKeyAccount, context: readBackContext)
        setCachedKey(SymmetricKey(data: data))
    }

    /// Whether anything on this Mac is currently encrypted under the session
    /// key. Both stores are checked without needing the key itself — a
    /// Keychain attribute query and a file-existence check — so this stays
    /// answerable precisely when the key can't be read.
    nonisolated static var hasSessionEncryptedData: Bool {
        KeychainManager.exists(account: passwordBlobAccount) || SecureFaceStore.exists
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
        let plaintext = try decrypt(ciphertext)
        // Only on success: a failed read shouldn't extend the idle window.
        recordActivity()
        return plaintext
    }

    /// Deletes both Keychain items and clears the cached session key.
    nonisolated static func deletePassword() throws {
        try KeychainManager.delete(account: passwordBlobAccount)
        try KeychainManager.delete(account: sessionKeyAccount)
        setCachedKey(nil)
    }
}
