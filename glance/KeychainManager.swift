//
//  KeychainManager.swift
//  glance
//
//  Thin, password-agnostic wrapper around Keychain Services — save/read/delete/exists by account, plus a Touch-ID access control helper.
//  Every item lives in the data protection keychain, where access is enforced by the app's provisioned keychain group. The legacy
//  file-based login keychain instead keeps a per-app ACL tied to the exact code signature, and asks for the login keychain password
//  whenever that signature changes (every rebuilt development copy, every re-signed release).
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
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

enum KeychainManager {
    /// Per build, so a differently identified development build never reads or migrates the release app's items (the legacy
    /// login keychain is shared between apps, unlike the data protection keychain's access groups).
    nonisolated static let service = Bundle.main.bundleIdentifier ?? "com.jonathan.glance"

    nonisolated private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    /// Existence check that never prompts. Without a non-interactive context, even an attributes-only query on a user-presence
    /// item shows the password/Touch ID dialog in the data protection keychain, so an existence check followed by the real read
    /// asked twice. A protected item answers `errSecInteractionNotAllowed` here instead, which still means it exists.
    nonisolated static func exists(account: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status != errSecItemNotFound
    }

    /// Pass an `LAContext` to authorize a read on an access-controlled item — the OS presents the prompt during this call.
    nonisolated static func read(account: String, context: LAContext? = nil) throws -> Data {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let context {
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
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

    /// Stores an item, updating its data in place when it already exists. Updating
    /// avoids the delete/add gap that can race with a second submit and produce
    /// `errSecDuplicateItem`. Existing access-control attributes are preserved;
    /// this method's access-control and `accessible` arguments apply when adding a new item (use `setAccessibility` to
    /// change an existing one). The default `accessible` class only allows reads while the Mac is unlocked: on Macs where
    /// locking the screen also locks the data protection keybag, such an item is unreadable on the lock screen.
    nonisolated static func save(account: String, data: Data, accessControl: SecAccessControl? = nil,
                                 accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        let itemQuery = baseQuery(account: account)

        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break // Add below.
        default:
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        if let accessControl {
            addQuery[kSecAttrAccessControl as String] = accessControl
        } else {
            addQuery[kSecAttrAccessible as String] = accessible
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecSuccess { return }
        // Another save may have added the item after our update reported
        // not-found. Complete that competing replacement with an update instead
        // of surfacing an avoidable “item already exists” error.
        if status == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                itemQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard retryStatus == errSecSuccess else { throw KeychainError.osStatus(retryStatus) }
            return
        }
        throw KeychainError.osStatus(status)
    }

    /// Moves an existing ungated item to another `accessible` class in place, keeping its data. Needs the keybag unlocked (i.e.
    /// the Mac unlocked) to re-wrap the item; on any failure the item is left exactly as it was, so callers can simply try
    /// again later. Never use this for access-controlled items.
    @discardableResult
    nonisolated static func setAccessibility(account: String, to accessible: CFString) -> Bool {
        SecItemUpdate(baseQuery(account: account) as CFDictionary,
                      [kSecAttrAccessible as String: accessible] as CFDictionary) == errSecSuccess
    }

    nonisolated static func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    /// Moves an ungated item that older builds wrote to the file-based login keychain into the data protection keychain. Does
    /// nothing if there is no old copy. Reading the old copy can show macOS's own one-time "allow access" prompt if the app's
    /// signature changed since it was written. The old copy is deleted only once the new one reads back identical (or a newer
    /// copy already exists), so a failure leaves the item where it was. Never use this for access-controlled items: those were
    /// always in the data protection keychain.
    nonisolated static func migrateLegacyItem(account: String, accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) {
        var legacyQuery = baseQuery(account: account)
        legacyQuery[kSecUseDataProtectionKeychain as String] = false
        var readQuery = legacyQuery
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(readQuery as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return }

        if !exists(account: account) {
            guard (try? save(account: account, data: data, accessible: accessible)) != nil,
                  (try? read(account: account)) == data
            else { return }
        }
        SecItemDelete(legacyQuery as CFDictionary)
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
