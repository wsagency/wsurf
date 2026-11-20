// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import CryptoKit
import Foundation
import Security

nonisolated enum CredentialStore {
    /// The installed app's Keychain service.
    static let productionService = "io.wsagency.wsurf"

    /// The service of a process. A test host gets its own in every build configuration, so a test can never read or write
    /// the installed app's items, even when it is hosted by a Release build.
    static func serviceName(isRunningTests: Bool, processID: Int32) -> String {
        isRunningTests ? "\(productionService).tests.\(processID)" : productionService
    }

    /// This process's service. Stage runs exist only in Debug builds and keep their own, as in the autofill vaults.
    static let service: String = {
        #if DEBUG
        if StageMode.isActive, let home = StageMode.home {
            return StageMode.defaultsSuiteName(for: home)
        }
        #endif
        return serviceName(isRunningTests: AppDatabase.isRunningTests, processID: ProcessInfo.processInfo.processIdentifier)
    }()

    struct Storage: Sendable {
        var read: @Sendable (String) -> String?
        var write: @Sendable (String, String) -> OSStatus
        var delete: @Sendable (String) -> OSStatus
        var readForTransfer: (@Sendable (String) throws -> String?)?

        func transferValue(at name: String) throws -> String? {
            guard let readForTransfer else { return read(name) }
            return try readForTransfer(name)
        }

        static let keychain = keychainStorage(service: CredentialStore.service)

        static func keychainStorage(service: String) -> Storage {
            Storage(
                read: { CredentialStore.read(account: $0, service: service) },
                write: {
                    guard $0 != CredentialStore.tombstoneString else { return errSecParam }
                    return CredentialStore.write(Data($0.utf8), account: $1, service: service)
                },
                delete: { CredentialStore.delete(account: $0, service: service) },
                readForTransfer: { account in
                    let classic = CredentialStore.lookup(CredentialStore.query(account: account, service: service))
                    if case .missing = classic {
                        return try CredentialStore.lookup(CredentialStore.legacyQuery(account: account, service: service)).valueIfReadable
                    }
                    return try classic.valueIfReadable
                }
            )
        }
    }

    /// Exact, synchronizable Data Protection items in a namespace separate from all existing local credentials.
    static var synchronizableProviderKeys: Storage {
        @Sendable func query(_ name: String) -> [String: Any] {
            [
                kSecClass as String: kSecClassGenericPassword,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: true,
                kSecAttrService as String: service + ".shared-provider-key.v1",
                kSecAttrAccount as String: name,
            ]
        }
        return Storage(
            read: { name in
                guard case .found(let data) = lookup(query(name)) else { return nil }
                return nonemptyString(data)
            },
            write: { value, name in
                let match = query(name), data = Data(value.utf8)
                let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                guard status == errSecItemNotFound else { return status }
                var item = match
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                item[kSecValueData as String] = data
                return SecItemAdd(item as CFDictionary, nil)
            },
            delete: { SecItemDelete(query($0) as CFDictionary) }
        )
    }

    enum Source: Equatable, Sendable {
        case keychain
        case environment(String)
        case none
    }

    static func key(for provider: Provider) -> String? {
        guard provider.needsKey else { return nil }
        if let saved = ProviderKeySharing.shared.savedKey(for: provider) {
            return saved
        }
        return environmentValue(for: provider)
    }

    private static func environmentValue(for provider: Provider) -> String? {
        guard let name = provider.environmentKey, ProviderKeySharing.shared.allowsEnvironment(for: provider),
              let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return nil }
        return value
    }

    static func isConfigured(_ provider: Provider) -> Bool {
        provider.needsKey ? key(for: provider) != nil : true
    }

    static func source(for provider: Provider) -> Source {
        guard provider.needsKey else { return .none }
        if ProviderKeySharing.shared.savedKey(for: provider) != nil {
            return .keychain
        }
        if let name = provider.environmentKey, environmentValue(for: provider) != nil {
            return .environment(name)
        }
        return .none
    }

    static func masked(for provider: Provider) -> String? {
        guard let key = key(for: provider), key.count >= 8 else { return nil }
        return key.prefix(3) + "…" + key.suffix(4)
    }

    @discardableResult
    static func save(_ key: String, for provider: Provider) -> String? {
        ProviderKeySharing.shared.saveLocal(key, for: provider)
    }

    static func save(_ key: String, for provider: Provider, storage: Storage) -> String? {
        store(key, at: ProviderKeySharing.localAddress(provider), in: storage)
    }

    fileprivate static func store(_ key: String, at account: String, in storage: Storage) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
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
        ProviderKeySharing.shared.saveLocal("", for: provider)
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

        var valueIfReadable: String? {
            get throws {
                switch self {
                case .found(let data?):
                    return CredentialStore.nonemptyString(data)
                case .missing:
                    return nil
                case .found(nil):
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecDecode))
                case .failure(let status):
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
            }
        }
    }

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
        _ data: Data,
        account: String,
        service: String = CredentialStore.service
    ) -> OSStatus {
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
        _ data: Data,
        account: String,
        service: String = CredentialStore.service
    ) -> OSStatus {
        var item = query(account: account, service: service)
        item[kSecValueData as String] = data
        return SecItemAdd(item as CFDictionary, nil)
    }

    private static func delete(
        account: String,
        service: String = CredentialStore.service
    ) -> OSStatus {
        let status = write(tombstone, account: account, service: service)
        guard status == errSecSuccess else { return status }
        _ = SecItemDelete(legacyQuery(account: account, service: service) as CFDictionary)
        return status
    }

    private static func read(
        account: String,
        service: String = CredentialStore.service
    ) -> String? {
        resolveRead(
            classic: lookup(query(account: account, service: service)),
            readLegacy: { lookup(legacyQuery(account: account, service: service)) },
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
        addCanonical: (Data, String) -> OSStatus,
        readCanonical: (String) -> Lookup,
        retireLegacy: (String) -> OSStatus
    ) -> String? {
        guard let legacyValue = nonemptyString(data) else { return nil }
        let status = addCanonical(data, account)
        guard status == errSecDuplicateItem else {
            if status == errSecSuccess {
                _ = retireLegacy(account)
            }
            return legacyValue
        }

        guard case .found(let canonicalData?) = readCanonical(account) else { return nil }
        return nonemptyString(canonicalData)
    }

    private static func lookup(_ query: [String: Any]) -> Lookup {
        var copyQuery = query
        copyQuery[kSecReturnData as String] = true
        copyQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(copyQuery as CFDictionary, &item)
        if status == errSecItemNotFound {
            return .missing
        }
        guard status == errSecSuccess else { return .failure(status) }
        return .found(item as? Data)
    }

    // Classic Keychain reports success for empty-data updates but retains the old value.
    private static let tombstoneString = "\u{0}"
    private static let tombstone = Data(tombstoneString.utf8)

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

/// The transport supplies a verified account identity. Neither local browsing nor a settings snapshot opens the shared Keychain.
nonisolated final class ProviderKeySharing: @unchecked Sendable {
    static let shared: ProviderKeySharing = {
        #if DEBUG
        let defaults = StageMode.defaults
        let available = !StageMode.isActive && !AppDatabase.isRunningTests
        #else
        let defaults = UserDefaults.standard
        let available = !AppDatabase.isRunningTests
        #endif
        return ProviderKeySharing(defaults: defaults, local: .keychain, cloud: CredentialStore.synchronizableProviderKeys, available: available)
    }()

    enum Failure: LocalizedError {
        case unavailable, noLocalKey, noSharedKey, refused
        var errorDescription: String? {
            switch self {
            case .unavailable:
                String(localized: "Enable key sharing for this Apple Account first.")
            case .noLocalKey:
                String(localized: "There is no saved key for this endpoint on this Mac.")
            case .noSharedKey:
                String(localized: "A shared key for this endpoint is unavailable.")
            case .refused:
                String(localized: "The Keychain could not update the saved key.")
            }
        }
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let local: CredentialStore.Storage
    private let cloud: CredentialStore.Storage
    private var verifiedAccount: String?
    private let available: Bool

    private enum Pref {
        static let account = "sync.providerKeys.lastAccount"
        static let epoch = "sync.providerKeys.consentID"
        static let enabled = "sync.providerKeys.enabled"
        static let approved = "sync.providerKeys.approved."
        static let trusted = "sync.providerKeys.localEndpoint."
        static let blocked = "sync.providerKeys.unapproved."
        static let legacy = "sync.providerKeys.legacy."
        static let canonical = "sync.providerKeys.savedAtEndpoint."
    }

    init(defaults: UserDefaults, local: CredentialStore.Storage, cloud: CredentialStore.Storage, available: Bool = true) {
        self.available = available
        self.defaults = defaults
        self.local = local
        self.cloud = cloud
    }

    static func validEndpoint(_ url: URL?) -> URL? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              scheme == "https" || (scheme == "http" && IntelligenceViewModel.isLoopback(url)),
              url.absoluteString.utf8.count <= 4096 else { return nil }
        return url
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func localAddress(_ provider: Provider) -> String {
        if provider.isCustom || provider.id.hasPrefix("custom.") {
            return "provider-endpoint:" + fingerprint(provider)
        }
        return "provider:" + provider.id
    }

    static func fingerprint(_ provider: Provider) -> String {
        digest(provider.id + "\u{0}" + (provider.baseURL?.absoluteString ?? ""))
    }

    /// A remote catalog addition cannot claim an old ID-only password left by a previous installation of that provider.
    func catalogChanged(from old: Provider?, to new: Provider?, received: Bool) {
        guard let id = old?.id ?? new?.id, old?.baseURL != new?.baseURL else { return }
        lock.withLock {
            if defaults.string(forKey: Pref.legacy + id) == nil {
                if let old {
                    defaults.set(Self.fingerprint(old), forKey: Pref.legacy + id)
                } else if received {
                    defaults.set("", forKey: Pref.legacy + id)
                }
            }
            let previous = old.map(Self.fingerprint)
            let blocked = defaults.string(forKey: Pref.blocked + id)
            let trusted = defaults.string(forKey: Pref.trusted + id) ?? (previous == blocked ? nil : previous)
            if let trusted {
                defaults.set(trusted, forKey: Pref.trusted + id)
            }
            if let new {
                let endpoint = Self.fingerprint(new)
                if (received || trusted != nil) && trusted != endpoint {
                    defaults.set(endpoint, forKey: Pref.blocked + id)
                    defaults.removeObject(forKey: Pref.approved + endpoint)
                } else {
                    defaults.set(endpoint, forKey: Pref.trusted + id)
                    defaults.removeObject(forKey: Pref.blocked + id)
                }
            }
        }
    }

    /// Also scopes outstanding website approvals. Re-entering the same account after sign-out gets a fresh consent ID.
    var accountContext: String? {
        lock.withLock { verifiedAccount == nil ? nil : defaults.string(forKey: Pref.epoch) }
    }

    @MainActor func setAccountIdentifier(_ id: String?) {
        let changed = lock.withLock {
            let next = available ? id.flatMap { $0.isEmpty ? nil : Self.digest($0) } : nil
            let previous = defaults.string(forKey: Pref.account)
            let changed = verifiedAccount != next || previous != next
            if previous != next || next == nil {
                defaults.removeObject(forKey: Pref.enabled)
                defaults.set(next, forKey: Pref.account)
                defaults.set(next.map { _ in UUID().uuidString }, forKey: Pref.epoch)
            }
            verifiedAccount = next
            return changed
        }
        if changed {
            announceConsentChange()
        }
    }

    /// A temporary verification failure blocks shared reads and writes while preserving consent for the same account.
    @MainActor func suspendAccountVerification() {
        let changed = lock.withLock {
            let wasVerified = verifiedAccount != nil
            verifiedAccount = nil
            return wasVerified
        }
        if changed {
            announceConsentChange()
        }
    }

    @MainActor private func announceConsentChange() {
        NotificationCenter.default.post(name: .wsurfProviderKeyConsentDidChange, object: self)
    }

    var wantsSharing: Bool {
        lock.withLock { defaults.bool(forKey: Pref.enabled) }
    }

    var isEnabled: Bool {
        lock.withLock { enabled }
    }

    private var enabled: Bool {
        verifiedAccount != nil && defaults.bool(forKey: Pref.enabled)
    }

    func setEnabled(_ enabled: Bool) throws {
        try lock.withLock {
            guard !enabled || verifiedAccount != nil else { throw Failure.unavailable }
            defaults.set(enabled, forKey: Pref.enabled)
        }
    }

    private func cloudAddress(_ provider: Provider) -> String? {
        guard enabled, let verifiedAccount, provider.needsKey, Self.validEndpoint(provider.baseURL) != nil else { return nil }
        return verifiedAccount + "." + Self.fingerprint(provider)
    }

    private func approved(_ provider: Provider) -> Bool {
        guard let epoch = defaults.string(forKey: Pref.epoch) else { return false }
        return defaults.string(forKey: Pref.approved + Self.fingerprint(provider)) == epoch
    }

    func participates(_ provider: Provider) -> Bool {
        lock.withLock { cloudAddress(provider) != nil && approved(provider) }
    }

    private func legacyAllowed(_ provider: Provider) -> Bool {
        guard let bound = defaults.string(forKey: Pref.legacy + provider.id) else { return true }
        return bound == Self.fingerprint(provider)
    }

    func needsEndpointApproval(_ provider: Provider) -> Bool {
        lock.withLock { endpointBlocked(provider) }
    }

    private func endpointBlocked(_ provider: Provider) -> Bool {
        defaults.string(forKey: Pref.blocked + provider.id) == Self.fingerprint(provider)
    }

    func approveLocalEndpoint(_ provider: Provider) throws {
        try lock.withLock {
            guard endpointBlocked(provider), validLocalTarget(provider) else { throw Failure.unavailable }
            if let previous = defaults.string(forKey: Pref.trusted + provider.id),
               try local.transferValue(at: Self.localAddress(provider)) == nil {
                // A locked item is different from a missing item. Keep the confirmation available until the copy succeeds.
                let old = try local.transferValue(at: "provider-endpoint:" + previous)
                    ?? (mayReadLegacy(id: provider.id, endpoint: previous) ? local.transferValue(at: "provider:" + provider.id) : nil)
                if let old, writeLocal(old, for: provider) != errSecSuccess {
                    throw Failure.refused
                }
            }
            defaults.set(Self.fingerprint(provider), forKey: Pref.trusted + provider.id)
            defaults.removeObject(forKey: Pref.blocked + provider.id)
        }
    }

    func allowsEnvironment(for provider: Provider) -> Bool {
        lock.withLock { validLocalTarget(provider) && !endpointBlocked(provider) && legacyAllowed(provider) }
    }

    private func validLocalTarget(_ provider: Provider) -> Bool {
        guard provider.needsKey else { return false }
        if let builtin = ProviderCatalog.builtIn.first(where: { $0.id == provider.id }) {
            return provider.baseURL == builtin.baseURL
        }
        return true
    }

    private func localValue(_ provider: Provider) -> String? {
        guard validLocalTarget(provider) else { return nil }
        if let value = local.read(Self.localAddress(provider)) {
            return value
        }
        guard provider.isCustom, mayReadLegacy(id: provider.id, endpoint: Self.fingerprint(provider)) else { return nil }
        return local.read("provider:" + provider.id)
    }

    private func mayReadLegacy(id: String, endpoint: String) -> Bool {
        let bound = defaults.string(forKey: Pref.legacy + id)
        return !defaults.bool(forKey: Pref.canonical + endpoint) && (bound == nil || bound == endpoint)
    }

    private func writeLocal(_ value: String, for provider: Provider) -> OSStatus {
        let status = local.write(value, Self.localAddress(provider))
        if status == errSecSuccess, provider.isCustom {
            defaults.set(true, forKey: Pref.canonical + Self.fingerprint(provider))
        }
        return status
    }

    func savedKey(for provider: Provider) -> String? {
        lock.withLock {
            guard validLocalTarget(provider), !endpointBlocked(provider) else { return nil }
            if let name = cloudAddress(provider), approved(provider), let value = cloud.read(name) {
                if local.read(Self.localAddress(provider)) != value {
                    _ = writeLocal(value, for: provider)
                }
                return value
            }
            return localValue(provider)
        }
    }

    func saveLocal(_ key: String, for provider: Provider) -> String? {
        lock.withLock {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard validLocalTarget(provider) || (provider.isCustom && value.isEmpty) else { return Failure.refused.localizedDescription }
            let address = Self.localAddress(provider)
            if let error = CredentialStore.store(value, at: address, in: local) {
                return error
            }
            if provider.isCustom {
                defaults.set(true, forKey: Pref.canonical + Self.fingerprint(provider))
            }
            if !value.isEmpty {
                let target = Self.fingerprint(provider)
                let blocked = defaults.string(forKey: Pref.blocked + provider.id)
                if blocked == target || (blocked == nil && defaults.string(forKey: Pref.trusted + provider.id) == nil) {
                    defaults.set(target, forKey: Pref.trusted + provider.id)
                    defaults.removeObject(forKey: Pref.blocked + provider.id)
                }
            }
            if value.isEmpty {
                if provider.isCustom, legacyAllowed(provider) {
                    if let error = CredentialStore.store("", at: "provider:" + provider.id, in: local) {
                        return error
                    }
                }
                clearApproval(for: provider)
            } else if approved(provider) {
                // A local edit made while paused or unverified must survive the next shared read.
                guard let name = cloudAddress(provider) else {
                    defaults.removeObject(forKey: Pref.approved + Self.fingerprint(provider))
                    return nil
                }
                if cloud.write(value, name) != errSecSuccess {
                    defaults.removeObject(forKey: Pref.approved + Self.fingerprint(provider))
                    return Failure.refused.localizedDescription
                }
            }
            return nil
        }
    }

    func shareLocal(_ provider: Provider) throws {
        try lock.withLock {
            guard let name = cloudAddress(provider), validLocalTarget(provider), !endpointBlocked(provider) else { throw Failure.unavailable }
            guard let value = localValue(provider) else { throw Failure.noLocalKey }
            guard cloud.write(value, name) == errSecSuccess else { throw Failure.refused }
            defaults.set(defaults.string(forKey: Pref.epoch), forKey: Pref.approved + Self.fingerprint(provider))
        }
    }

    func useCloud(_ provider: Provider) throws {
        try lock.withLock {
            guard let name = cloudAddress(provider), validLocalTarget(provider), !endpointBlocked(provider) else { throw Failure.unavailable }
            guard let value = cloud.read(name) else { throw Failure.noSharedKey }
            guard writeLocal(value, for: provider) == errSecSuccess else { throw Failure.refused }
            defaults.set(defaults.string(forKey: Pref.epoch), forKey: Pref.approved + Self.fingerprint(provider))
        }
    }

    private func clearApproval(for provider: Provider) {
        if approved(provider) {
            defaults.removeObject(forKey: Pref.approved + Self.fingerprint(provider))
        }
    }

    func pause(_ provider: Provider) {
        lock.withLock { clearApproval(for: provider) }
    }

    func removeCloudCopy(_ provider: Provider) throws {
        try lock.withLock {
            guard let name = cloudAddress(provider) else { throw Failure.unavailable }
            let status = cloud.delete(name)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.refused }
            clearApproval(for: provider)
        }
    }
}
