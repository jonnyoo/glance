//
//  SecureCredentialManager.swift
//  glance
//
//  Two-tier storage on KeychainManager: a Touch-ID-gated session key (unwrapped once per launch) wraps an ungated encrypted
//  password blob, safe to read anytime — including the lock screen, where no app UI exists to host a Touch ID prompt.
//  Touch ID authorizes the session; nothing yet authorizes each individual unlock beyond that (face recognition will).
//  Optionally (off by default), an ungated copy of the session key lets a launch unlock the session with no prompt, so a Mac
//  without Touch ID doesn't have to type its password into Glance after every login. See `setUnlockAtLogin`.
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

extension Notification.Name {
    /// Fires whenever the cached session key changes, so anything encrypted under it (e.g. `FaceEnrollmentStore`) can reload
    /// itself instead of relying on each call site to remember to — a past bug had the sidebar's unlock forget this, leaving
    /// face unlock silently running on stale pre-unlock data.
    static let secureCredentialSessionDidChange = Notification.Name("SecureCredentialManager.sessionDidChange")
}

enum SecureCredentialManager {
    nonisolated private static let sessionKeyAccount = "sessionKey"
    nonisolated private static let passwordBlobAccount = "encryptedPassword"
    nonisolated private static let loginKeyAccount = "sessionKeyAtLogin"

    /// Runs `KeychainManager.migrateLegacyItem` once per process, before anything reads or writes the password blob. Older
    /// builds put the blob (never the gated session key) in the file-based login keychain. A static `let` is initialised exactly
    /// once and thread-safely, so concurrent callers can't race the move.
    nonisolated private static let legacyMigration: Void = {
        KeychainManager.migrateLegacyItem(account: passwordBlobAccount)
    }()

    nonisolated private static func migrateLegacyStorageIfNeeded() {
        _ = legacyMigration
    }

    // MARK: - Session state (thread-safe via NSLock)

    nonisolated private static let sessionLock = NSLock()
    nonisolated(unsafe) private static var _cachedKey: SymmetricKey?
    /// Last unlock or successful `readPassword` — what `SessionAutoLocker` compares against the idle limit. Guarded by
    /// `sessionLock` alongside the key so the two can never be observed out of step.
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
        let changed = (key != nil) != (_cachedKey != nil)
        _cachedKey = key
        _lastActivityAt = key == nil ? nil : Date()
        sessionLock.unlock()
        // Posted after releasing the lock — observers may call back into `isSessionUnlocked` (re-acquiring it) from a
        // background thread, so posting while still locked risks a real self-deadlock, not a theoretical one.
        guard changed else { return }
        NotificationCenter.default.post(name: .secureCredentialSessionDidChange, object: nil)
    }

    /// Resets the idle countdown on each successful use, so an actively-used session never auto-locks.
    nonisolated private static func recordActivity() {
        sessionLock.lock()
        if _cachedKey != nil { _lastActivityAt = Date() }
        sessionLock.unlock()
    }

    // MARK: - Generic session-key crypto (shared by passwords here and face embeddings in SecureFaceStore; requires an unlocked session)

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
        migrateLegacyStorageIfNeeded()
        return KeychainManager.exists(account: passwordBlobAccount)
    }

    /// Prompts Touch ID and unwraps the session key, creating it Touch-ID-gated on first run. Caches only after a real gated
    /// read-back succeeds — `SecItemAdd` alone returns success even if the user hit Cancel on the auth UI, and bridging
    /// `LAContext.evaluatePolicy` synchronously via a semaphore deadlocks the thread pool and crashes the process.
    /// Must succeed before `savePassword`/`readPassword`. Blocking; call from a background task.
    nonisolated static func unlockSession(reason: String) throws {
        if cachedKey() != nil { return }

        // The existence check, not the read, decides whether a key gets created (load-bearing): a cancelled Touch ID prompt on
        // a user-presence item reports `errSecItemNotFound`, indistinguishable from no key — deciding on the read's error would
        // mint a fresh key (destroying the one that decrypts existing data) on every mis-tap.
        if KeychainManager.exists(account: sessionKeyAccount) {
            let context = LAContext()
            context.localizedReason = reason
            let data = try KeychainManager.read(account: sessionKeyAccount, context: context)
            setCachedKey(SymmetricKey(data: data))
            return
        }

        // No key at all, but minting one is still destructive if data is already encrypted under a previous key (e.g. a
        // re-signed dev build) — refuse rather than silently render it unreadable forever.
        guard !hasSessionEncryptedData else {
            throw SecureCredentialError.sessionKeyUnavailable
        }

        // An ungated copy left over from a previous key would never decrypt anything encrypted under the new one.
        try? KeychainManager.delete(account: loginKeyAccount)

        let key = SymmetricKey(size: .bits256)
        let access = try KeychainManager.makeUserPresenceAccessControl()
        try KeychainManager.save(
            account: sessionKeyAccount,
            data: key.withUnsafeBytes { Data($0) },
            accessControl: access
        )

        // Read back through the gated path rather than trusting the write — only a real read proves authentication happened.
        let readBackContext = LAContext()
        readBackContext.localizedReason = reason
        let data = try KeychainManager.read(account: sessionKeyAccount, context: readBackContext)
        setCachedKey(SymmetricKey(data: data))
    }

    /// Checked without needing the key itself, so this stays answerable precisely when the key can't be read.
    nonisolated static var hasSessionEncryptedData: Bool {
        migrateLegacyStorageIfNeeded()
        return KeychainManager.exists(account: passwordBlobAccount) || SecureFaceStore.exists
    }

    // MARK: - Unlock at login (opt-in)

    /// Whether launching Glance unlocks the session without a prompt. The keychain item is the only record of the choice, so
    /// it can never disagree with what launch will actually do.
    nonisolated static var unlocksAtLogin: Bool {
        KeychainManager.exists(account: loginKeyAccount)
    }

    /// Enabling stores an ungated copy of the current session key, so the next launch (in practice, the next macOS login) can
    /// unlock without Touch ID or the account password. The copy stays on this Mac, can only be read while the Mac is unlocked,
    /// and only by apps signed into Glance's keychain group. What it gives up is the per-launch confirmation: the macOS login
    /// itself becomes the only authentication. Enabling requires an unlocked session; disabling deletes the copy.
    nonisolated static func setUnlockAtLogin(_ enabled: Bool) throws {
        guard enabled else {
            try KeychainManager.delete(account: loginKeyAccount)
            return
        }
        guard let key = cachedKey() else { throw SecureCredentialError.sessionLocked }
        try KeychainManager.save(account: loginKeyAccount, data: key.withUnsafeBytes { Data($0) })
    }

    /// Never prompts. Returns `false` and leaves the session locked when the user hasn't opted in, or the copy can't be read
    /// (e.g. the keychain is still locked). A copy that fails to decrypt the stored password is deleted rather than trusted.
    /// Blocking; call from a background task.
    nonisolated static func unlockSessionFromLoginKey() -> Bool {
        if cachedKey() != nil { return true }
        migrateLegacyStorageIfNeeded()
        guard KeychainManager.exists(account: sessionKeyAccount),
              let data = try? KeychainManager.read(account: loginKeyAccount),
              data.count == SymmetricKeySize.bits256.bitCount / 8
        else { return false }

        let key = SymmetricKey(data: data)
        if let ciphertext = try? KeychainManager.read(account: passwordBlobAccount) {
            guard let sealed = try? AES.GCM.SealedBox(combined: ciphertext),
                  var plaintext = try? AES.GCM.open(sealed, using: key)
            else {
                try? KeychainManager.delete(account: loginKeyAccount)
                return false
            }
            plaintext.resetBytes(in: 0..<plaintext.count)
        }
        setCachedKey(key)
        return true
    }

    /// Clears the cached session key. Next save/read requires Touch ID again.
    nonisolated static func lockSession() {
        setCachedKey(nil)
    }

    /// Encrypts and stores `passwordBytes`. Requires an unlocked session —
    /// call `unlockSession(reason:)` first. Blocking; call from a background task.
    nonisolated static func savePassword(_ passwordBytes: Data) throws {
        guard !passwordBytes.isEmpty else { throw SecureCredentialError.emptyPassword }
        migrateLegacyStorageIfNeeded()
        let combined = try encrypt(passwordBytes)
        try KeychainManager.save(account: passwordBlobAccount, data: combined)
    }

    /// No separate Touch ID prompt — only the session key was gated, at unlock time. Caller MUST zero the returned bytes via
    /// `.resetBytes(in:)` after use. Blocking; call from a background task.
    nonisolated static func readPassword() throws -> Data {
        guard cachedKey() != nil else { throw SecureCredentialError.sessionLocked }
        migrateLegacyStorageIfNeeded()
        let ciphertext = try KeychainManager.read(account: passwordBlobAccount)
        let plaintext = try decrypt(ciphertext)
        // Only on success: a failed read shouldn't extend the idle window.
        recordActivity()
        return plaintext
    }

    /// Deletes every Keychain item (including the unlock-at-login copy) and clears the cached session key.
    nonisolated static func deletePassword() throws {
        migrateLegacyStorageIfNeeded()
        try KeychainManager.delete(account: loginKeyAccount)
        try KeychainManager.delete(account: passwordBlobAccount)
        try KeychainManager.delete(account: sessionKeyAccount)
        setCachedKey(nil)
    }
}
