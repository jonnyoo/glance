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
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(message)"
        }
    }
}

enum KeychainManager {
    nonisolated static let service = "com.ankush.iface"
    nonisolated static let legacyService = "com.jonathan.glance"

    /// Attributes-only existence check — never prompts, even for access-controlled items.
    nonisolated static func exists(account: String) -> Bool {
        return checkExists(service: service, account: account) ||
               checkExists(service: legacyService, account: account)
    }

    nonisolated private static func checkExists(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == -34018 {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
            return false
        }
        return status != errSecItemNotFound && status == errSecSuccess
    }

    /// Pass an `LAContext` to authorize a read on an access-controlled item — the OS presents the prompt during this call.
    nonisolated static func read(account: String, context: LAContext? = nil) throws -> Data {
        do {
            return try readFrom(service: service, account: account, context: context)
        } catch KeychainError.itemNotFound {
            // Try legacy service
            let data = try readFrom(service: legacyService, account: account, context: context)
            // Auto-migrate to current service
            try? save(account: account, data: data)
            return data
        }
    }

    nonisolated private static func readFrom(service: String, account: String, context: LAContext? = nil) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
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
        case -34018: // errSecMissingEntitlement: old or incompatible access control
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ] as CFDictionary)
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Stores an item, updating its data in place when it already exists.
    nonisolated static func save(account: String, data: Data, accessControl: SecAccessControl? = nil) throws {
        let itemQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let updateStatus = SecItemUpdate(
            itemQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        case -34018:
            _ = SecItemDelete(itemQuery as CFDictionary)
            break
        default:
            throw KeychainError.osStatus(updateStatus)
        }

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        if let accessControl {
            addQuery[kSecAttrAccessControl as String] = accessControl
            addQuery.removeValue(forKey: kSecAttrAccessible as String)
        }

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        // If saving with accessControl failed due to missing entitlement, fall back to device-unlocked
        if status == -34018 && accessControl != nil {
            addQuery.removeValue(forKey: kSecAttrAccessControl as String)
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        if status == errSecSuccess { return }
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

    nonisolated static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound || status == -34018 else {
            throw KeychainError.osStatus(status)
        }
    }

    /// `.userPresence` requires Touch ID or device password.
    nonisolated static func makeUserPresenceAccessControl() -> SecAccessControl? {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessError
        ) else {
            return nil
        }
        return access
    }
}
