// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Security

nonisolated enum CredentialStore {
    private static let service = "io.wsagency.wsurf"

    struct Storage: Sendable {
        var read: @Sendable (String) -> String?
        var write: @Sendable (String, String) -> OSStatus
        var delete: @Sendable (String) -> OSStatus

        static let keychain = Storage(
            read: { CredentialStore.read(account: $0) },
            write: { CredentialStore.write($0, account: $1) },
            delete: { CredentialStore.delete(account: $0) }
        )

        static func keychainStorage(service: String) -> Storage {
            Storage(
                read: { CredentialStore.read(account: $0, service: service) },
                write: { CredentialStore.write($0, account: $1, service: service) },
                delete: { CredentialStore.delete(account: $0, service: service) }
            )
        }
    }

    enum Source: Equatable, Sendable {
        case keychain
        case environment(String)
        case none
    }

    private static func account(for provider: Provider) -> String {
        "provider:\(provider.id)"
    }

    static func key(for provider: Provider) -> String? {
        guard provider.needsKey else { return nil }
        if let stored = read(account: account(for: provider)), !stored.isEmpty {
            return stored
        }
        guard let name = provider.environmentKey,
              let value = ProcessInfo.processInfo.environment[name],
              !value.isEmpty
        else { return nil }
        return value
    }

    static func isConfigured(_ provider: Provider) -> Bool {
        provider.needsKey ? key(for: provider) != nil : true
    }

    static func source(for provider: Provider) -> Source {
        guard provider.needsKey else { return .none }
        if let stored = read(account: account(for: provider)), !stored.isEmpty {
            return .keychain
        }
        if let name = provider.environmentKey,
           let value = ProcessInfo.processInfo.environment[name],
           !value.isEmpty {
            return .environment(name)
        }
        return .none
    }

    static func masked(for provider: Provider) -> String? {
        guard let key = key(for: provider), key.count >= 8 else { return nil }
        return key.prefix(3) + "…" + key.suffix(4)
    }

    @discardableResult
    static func save(_ key: String, for provider: Provider, storage: Storage = .keychain) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = account(for: provider)
        if trimmed.isEmpty {
            let status = storage.delete(account)
            guard status == errSecSuccess || status == errSecItemNotFound else { return errorMessage(status) }
            return nil
        }
        let status = storage.write(trimmed, account)
        return status == errSecSuccess ? nil : errorMessage(status)
    }

    @discardableResult
    static func delete(for provider: Provider) -> String? {
        let status = delete(account: account(for: provider))
        return status == errSecSuccess ? nil : errorMessage(status)
    }

    static func mcpAuthorization(providerID: String, serverID: UUID, storage: Storage = .keychain) -> String? {
        storage.read("openai-mcp:\(providerID):\(serverID.uuidString)")
    }

    static func saveMCPAuthorization(_ value: String, providerID: String, serverID: UUID, storage: Storage = .keychain) -> String? {
        let account = "openai-mcp:\(providerID):\(serverID.uuidString)"
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = value.isEmpty ? storage.delete(account) : storage.write(value, account)
        guard status != errSecSuccess && !(value.isEmpty && status == errSecItemNotFound) else { return nil }
        return String(localized: "The Keychain could not update the MCP authorization token.")
    }

    static func mcpOAuth(providerID: String, serverID: UUID, storage: Storage = .keychain) -> OpenAIMCPOAuthCredential? {
        guard let text = storage.read("openai-mcp-oauth:\(providerID):\(serverID.uuidString)") else { return nil }
        return try? JSONDecoder().decode(OpenAIMCPOAuthCredential.self, from: Data(text.utf8))
    }

    static func saveMCPOAuth(_ credential: OpenAIMCPOAuthCredential?, providerID: String, serverID: UUID, storage: Storage = .keychain) throws {
        let account = "openai-mcp-oauth:\(providerID):\(serverID.uuidString)"
        let status: OSStatus
        if let credential {
            let data = try JSONEncoder().encode(credential)
            status = storage.write(String(decoding: data, as: UTF8.self), account)
        } else {
            status = storage.delete(account)
        }
        guard status == errSecSuccess || (credential == nil && status == errSecItemNotFound) else { throw OpenAIMCPOAuthFailure.storage }
    }

    // MARK: - Keychain

    enum Lookup {
        case found(Data?)
        case missing
        case failure(OSStatus)
    }

    private static let legacyDataProtectionIsPermitted: Bool = {
        guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault),
              let applicationIdentifier = SecTaskCopyValueForEntitlement(
                task, "application-identifier" as CFString, nil
              ) as? String,
              let groups = SecTaskCopyValueForEntitlement(
                task, "keychain-access-groups" as CFString, nil
              ) as? [String]
        else { return false }
        return groups.contains(applicationIdentifier)
    }()

    private static func query(
        account: String,
        service: String = CredentialStore.service
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
        ]
    }

    private static func legacyQuery(
        account: String,
        service: String = CredentialStore.service
    ) -> [String: Any] {
        var query = query(account: account, service: service)
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    private static func write(
        _ value: String,
        account: String,
        service: String = CredentialStore.service
    ) -> OSStatus {
        let data = Data(value.utf8)
        let base = query(account: account, service: service)
        let update = SecItemUpdate(
            base as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard update == errSecItemNotFound else { return update }

        var insert = base
        insert[kSecValueData as String] = data
        return SecItemAdd(insert as CFDictionary, nil)
    }

    private static func insert(
        _ value: String,
        account: String,
        service: String = CredentialStore.service
    ) -> OSStatus {
        var item = query(account: account, service: service)
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil)
    }

    private static func delete(
        account: String,
        service: String = CredentialStore.service
    ) -> OSStatus {
        let status = write(String(decoding: tombstone, as: UTF8.self), account: account, service: service)
        guard status == errSecSuccess else { return status }
        if legacyDataProtectionIsPermitted {
            _ = SecItemDelete(legacyQuery(account: account, service: service) as CFDictionary)
        }
        return status
    }

    private static func read(
        account: String,
        service: String = CredentialStore.service
    ) -> String? {
        resolveRead(
            classic: lookup(query(account: account, service: service)),
            readLegacy: {
                guard legacyDataProtectionIsPermitted else { return .failure(errSecMissingEntitlement) }
                return lookup(legacyQuery(account: account, service: service))
            },
            migrate: { migrateLegacy($0, account: account, service: service) }
        )
    }

    static func resolveRead(
        classic: Lookup,
        readLegacy: () -> Lookup,
        migrate: (Data) -> String?
    ) -> String? {
        switch classic {
        case .found(let data):
            return nonemptyString(data)
        case .failure:
            return nil
        case .missing:
            guard case .found(let data?) = readLegacy() else { return nil }
            return migrate(data)
        }
    }

    private static func migrateLegacy(
        _ data: Data,
        account: String,
        service: String = CredentialStore.service
    ) -> String? {
        migrateLegacy(
            data,
            account: account,
            addCanonical: { insert($0, account: $1, service: service) },
            readCanonical: { lookup(query(account: $0, service: service)) },
            retireLegacy: { SecItemDelete(legacyQuery(account: $0, service: service) as CFDictionary) }
        )
    }

    static func migrateLegacy(
        _ data: Data,
        account: String,
        addCanonical: (String, String) -> OSStatus,
        readCanonical: (String) -> Lookup,
        retireLegacy: (String) -> OSStatus
    ) -> String? {
        guard let legacyValue = nonemptyString(data) else { return nil }
        let status = addCanonical(legacyValue, account)
        guard status == errSecDuplicateItem else {
            if status == errSecSuccess { _ = retireLegacy(account) }
            return legacyValue
        }

        guard case .found(let canonicalData?) = readCanonical(account) else { return nil }
        if canonicalData.isEmpty || canonicalData == tombstone {
            _ = retireLegacy(account)
            return nil
        }
        guard let canonicalValue = nonemptyString(canonicalData) else { return nil }
        _ = retireLegacy(account)
        return canonicalValue
    }

    private static func lookup(_ query: [String: Any]) -> Lookup {
        var copyQuery = query
        copyQuery[kSecReturnData as String] = true
        copyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(copyQuery as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .failure(status) }
        return .found(item as? Data)
    }

    // Classic Keychain reports success for empty-data updates but retains the old value.
    private static let tombstone = Data([0])

    private static func nonemptyString(_ data: Data?) -> String? {
        guard let data, data != tombstone,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private static func errorMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String?
            ?? String(localized: "The Keychain refused to store the key (error \(status)).")
    }
}
