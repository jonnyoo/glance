//
//  KeychainManager.swift
//  glance
//
//  Thin, password-agnostic wrapper around Keychain Services — save/read/delete/exists by account, plus a Touch-ID access control helper.
//

import Foundation
import Security
import LocalAuthentication

enum KeychainError: LocalizedError {
    case itemNotFound
    case unexpectedData
    case accessControlFailed(String)
    case authenticationFailed
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Keychain item not found."
        case .unexpectedData:
            return "Keychain item had an unexpected format."
        case .accessControlFailed(let msg):
            return "Couldn't create Keychain access control: \(msg)"
        case .authenticationFailed:
            return "Authentication was cancelled or failed."
        case .osStatus(let status):
            if status == errSecMissingEntitlement {
                return "Keychain error: Missing code-signing entitlement (-34018). Select a Development Team in Xcode → Signing & Capabilities."
            }
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

enum KeychainManager {
    nonisolated static let service = Bundle.main.bundleIdentifier ?? "com.salimmous.glance"

    /// Attributes-only existence check — skips auth UI (`kSecUseAuthenticationUISkip`) so it never prompts
    /// even for `.userPresence` items, and treats only `errSecSuccess` / `errSecInteractionNotAllowed` as existing.
    /// Checks Data Protection Keychain first, then falls back to legacy Keychain for pre-migration items.
    nonisolated static func exists(account: String) -> Bool {
        if exists(account: account, dataProtection: true) {
            return true
        }
        return exists(account: account, dataProtection: false)
    }

    nonisolated private static func exists(account: String, dataProtection: Bool) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// Pass an `LAContext` to authorize a read on an access-controlled item — the OS presents the prompt during this call.
    /// Reads from the Data Protection Keychain first, with a transparent legacy-Keychain fallback for ungated items saved
    /// by older builds before both items were unified on the Data Protection Keychain.
    nonisolated static func read(account: String, context: LAContext? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound, context == nil {
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var legacyItem: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
            if legacyStatus == errSecSuccess {
                guard let data = legacyItem as? Data else { throw KeychainError.unexpectedData }
                return data
            }
        }
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.authenticationFailed
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Stores an item in the Data Protection Keychain, updating its data in place when it already exists.
    /// Updating avoids the delete/add gap that can race with a second submit and produce
    /// `errSecDuplicateItem`. Any pre-migration copy in the legacy file-based Keychain is cleaned up on write.
    nonisolated static func save(account: String, data: Data, accessControl: SecAccessControl? = nil) throws {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]

        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            if accessControl == nil { deleteLegacyCopyIfPresent(account: account) }
            return
        case errSecItemNotFound:
            break // Add below.
        default:
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let accessControl {
            addQuery[kSecAttrAccessControl as String] = accessControl
        } else {
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess {
            if accessControl == nil { deleteLegacyCopyIfPresent(account: account) }
            return
        }
        // Another save may have added the item after our update reported
        // not-found. Complete that competing replacement with an update instead
        // of surfacing an avoidable “item already exists” error.
        if status == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                itemQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else { throw KeychainError.osStatus(retryStatus) }
            if accessControl == nil { deleteLegacyCopyIfPresent(account: account) }
            return
        }
        throw KeychainError.osStatus(status)
    }

    nonisolated static func delete(account: String) throws {
        let dpQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
        let dpStatus = SecItemDelete(dpQuery as CFDictionary)
        deleteLegacyCopyIfPresent(account: account)
        guard dpStatus == errSecSuccess || dpStatus == errSecItemNotFound else {
            throw KeychainError.osStatus(dpStatus)
        }
    }

    nonisolated private static func deleteLegacyCopyIfPresent(account: String) {
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        _ = SecItemDelete(legacyQuery as CFDictionary)
    }

    /// `.userPresence` requires Touch ID or device password, with no separate no-hardware handling needed.
    nonisolated static func makeUserPresenceAccessControl() throws -> SecAccessControl {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            let msg = (accessError?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown"
            throw KeychainError.accessControlFailed(msg)
        }
        return access
    }
}
