// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Where this install keeps its random ID. Production uses the data-protection keychain; tests inject memory.
nonisolated public protocol InstallIDStorage: Sendable {
    /// The stored ID, or nil when there is none. Throws when the store cannot be read.
    func read() throws -> String?
    func write(_ id: String) throws
}

/// The ID is a generic-password item of the app's own access group, written `ThisDeviceOnly`, never synchronizable. A restored
/// backup or a migrated Mac therefore gets a new ID. The service carries the bundle ID, so two bundle IDs never share one.
nonisolated public struct KeychainInstallIDStorage: InstallIDStorage {
    public struct Failure: Error {
        public let status: OSStatus
    }

    private let service: String

    public init(service: String = "\(Bundle.main.bundleIdentifier ?? "io.wsagency.wsurf").sync-install-id") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "install-id",
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ id: String) throws {
        let value = Data(id.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if updated == errSecSuccess {
            return
        }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        var item = query
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }
}

nonisolated public enum InstallID {
    /// The install's ID, created on first use. Nil when the store cannot be read or written (an unsigned build has no access
    /// group): sync then stays off for this run and the identity never forks. A stored value that is not a UUID is replaced.
    public static func resolve(_ storage: any InstallIDStorage) -> String? {
        do {
            if let stored = try storage.read(), UUID(uuidString: stored) != nil {
                return stored
            }
            let fresh = UUID().uuidString
            try storage.write(fresh)
            return fresh
        } catch {
            return nil
        }
    }
}
