// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Security
import Synchronization
import Testing

@testable import WSurf

/// Credential tests use fresh provider IDs and clean up only those exact
/// synthetic Keychain records.
struct CredentialStoreTests {
    private let store: any ProviderCredentialStore = KeychainProviderCredentialStore()

    private static func provider(
        auth: Provider.Auth,
        environmentKey: String? = nil
    ) -> Provider {
        Provider(
            id: "test-\(UUID().uuidString)",
            name: "Test Provider",
            blurb: "",
            symbol: "questionmark",
            baseURL: URL(string: "https://example.invalid/v1"),
            wire: .chatCompletions,
            auth: auth,
            environmentKey: environmentKey
        )
    }

    /// `PATH` is non-secret and long enough for the mask assertions.
    private static func liveEnvironmentEntry() throws -> (key: String, value: String) {
        ("PATH", try #require(ProcessInfo.processInfo.environment["PATH"]))
    }

    @Test func aProviderWithoutAuthNeedsNoKey() {
        let provider = Self.provider(auth: .none, environmentKey: "PATH")
        #expect(store.key(for: provider) == nil)
        #expect(store.isConfigured(provider))
        #expect(store.source(for: provider) == CredentialStore.Source.none)
        #expect(store.masked(for: provider) == nil)
    }

    @Test func aBearerProviderWithNothingAnywhereIsUnconfigured() {
        let provider = Self.provider(auth: .bearer)
        #expect(store.key(for: provider) == nil)
        #expect(!store.isConfigured(provider))
        #expect(store.source(for: provider) == CredentialStore.Source.none)
        #expect(store.masked(for: provider) == nil)
    }

    @Test func anUnsetEnvironmentVariableCountsAsNoKey() {
        let provider = Self.provider(
            auth: .bearer,
            environmentKey: "WSURF_TEST_NEVER_SET_\(UUID().uuidString.prefix(8))"
        )
        #expect(store.key(for: provider) == nil)
        #expect(!store.isConfigured(provider))
        #expect(store.source(for: provider) == CredentialStore.Source.none)
    }

    @Test func theEnvironmentSuppliesTheKeyWhenTheKeychainHasNone() throws {
        let entry = try Self.liveEnvironmentEntry()
        let provider = Self.provider(auth: .bearer, environmentKey: entry.key)
        #expect(store.key(for: provider) == entry.value)
        #expect(store.isConfigured(provider))
        #expect(store.source(for: provider) == .environment(entry.key))
    }

    /// Three characters in, four out: enough to tell two keys apart, never
    /// enough to use one.
    @Test func masksTheActiveKeyToAFingerprint() throws {
        let entry = try Self.liveEnvironmentEntry()
        let provider = Self.provider(auth: .bearer, environmentKey: entry.key)
        let masked = try #require(store.masked(for: provider))
        #expect(masked == "\(entry.value.prefix(3))…\(entry.value.suffix(4))")
        #expect(masked.count == 8)
    }

    @Test func savingABlankKeyUsesStorageDeletion() {
        let values = Mutex<[String: String]>([:])
        let storage = CredentialStore.Storage(
            read: { account in values.withLock { $0[account] } },
            write: { value, account in
                values.withLock { $0[account] = value }
                return errSecSuccess
            },
            delete: { account in
                values.withLock { $0.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess }
            }
        )
        let provider = Self.provider(auth: .bearer)
        let account = "provider:\(provider.id)"
        values.withLock { $0[account] = "fixture-key" }
        #expect(CredentialStore.save("   \n\t", for: provider, storage: storage) == nil)
        #expect(storage.read(account) == nil)
    }

    @Test func keychainReadErrorsNeverFallBackToLegacyData() {
        var didReadLegacy = false
        let denied = CredentialStore.resolveRead(
            classic: .failure(errSecInteractionNotAllowed),
            readLegacy: {
                didReadLegacy = true
                return .found(Data("stale-fixture".utf8))
            },
            migrate: { _ in "stale-fixture" }
        )
        #expect(denied == nil)
        #expect(!didReadLegacy)

        var didMigrate = false
        let legacyFailure = CredentialStore.resolveRead(
            classic: .missing,
            readLegacy: { .failure(errSecUserCanceled) },
            migrate: { _ in didMigrate = true; return "stale-fixture" }
        )
        #expect(legacyFailure == nil)
        #expect(!didMigrate)
    }

    @Test func failedLegacyCopyRemainsReadableAndIsNotRetired() {
        var legacyPresent = true
        let migrated = CredentialStore.migrateLegacy(
            Data("legacy-fixture".utf8),
            account: "provider:test-\(UUID().uuidString)",
            addCanonical: { _, _ in errSecNotAvailable },
            readCanonical: { _ in .missing },
            retireLegacy: { _ in legacyPresent = false; return errSecSuccess }
        )
        #expect(migrated == "legacy-fixture")
        #expect(legacyPresent)
    }

    @Test func invalidLegacyValuesAreNeverMigrated() {
        for data in [Data(), Data([0]), Data([0xff])] {
            var didAdd = false
            var didRetire = false
            let migrated = CredentialStore.migrateLegacy(
                data,
                account: "provider:test-\(UUID().uuidString)",
                addCanonical: { _, _ in didAdd = true; return errSecSuccess },
                readCanonical: { _ in .missing },
                retireLegacy: { _ in didRetire = true; return errSecSuccess }
            )
            #expect(migrated == nil)
            #expect(!didAdd)
            #expect(!didRetire)
        }
    }

    @Test func migrationPreservesAConcurrentCanonicalSave() {
        var canonical: Data?
        var legacyPresent = true
        let migrated = CredentialStore.migrateLegacy(
            Data("legacy-fixture".utf8),
            account: "provider:test-\(UUID().uuidString)",
            addCanonical: { _, _ in
                canonical = Data("new-fixture".utf8)
                return errSecDuplicateItem
            },
            readCanonical: { _ in canonical.map(CredentialStore.Lookup.found) ?? .missing },
            retireLegacy: { _ in legacyPresent = false; return errSecSuccess }
        )
        #expect(migrated == "new-fixture")
        #expect(canonical == Data("new-fixture".utf8))
        #expect(legacyPresent)
    }

    @Test func migrationDoesNotResurrectAConcurrentTombstone() {
        var canonical: Data?
        var legacyPresent = true
        let migrated = CredentialStore.migrateLegacy(
            Data("legacy-fixture".utf8),
            account: "provider:test-\(UUID().uuidString)",
            addCanonical: { _, _ in
                canonical = Data([0])
                return errSecDuplicateItem
            },
            readCanonical: { _ in canonical.map(CredentialStore.Lookup.found) ?? .missing },
            retireLegacy: { _ in legacyPresent = false; return errSecSuccess }
        )
        #expect(migrated == nil)
        #expect(canonical == Data([0]))
        #expect(legacyPresent)
    }

    @Test func classicKeychainValueWinsOverLegacyAndTombstoneStopsFallback() {
        var didReadLegacy = false
        let canonical = CredentialStore.resolveRead(
            classic: .found(Data("canonical-fixture".utf8)),
            readLegacy: { didReadLegacy = true; return .found(Data("legacy-fixture".utf8)) },
            migrate: { _ in "legacy-fixture" }
        )
        #expect(canonical == "canonical-fixture")
        #expect(!didReadLegacy)

        let tombstone = CredentialStore.resolveRead(
            classic: .found(Data([0])),
            readLegacy: { didReadLegacy = true; return .found(Data("legacy-fixture".utf8)) },
            migrate: { _ in "legacy-fixture" }
        )
        #expect(tombstone == nil)
        #expect(!didReadLegacy)
    }

    @Test func successfulMigrationWritesBeforeRetiringLegacy() {
        let legacyData = Data([0x65, 0xcc, 0x81])
        var insertedData: Data?
        var wroteCanonical = false
        var retiredBeforeWrite = false
        let migrated = CredentialStore.migrateLegacy(
            legacyData,
            account: "provider:test-\(UUID().uuidString)",
            addCanonical: { data, _ in
                insertedData = data
                wroteCanonical = true
                return errSecSuccess
            },
            readCanonical: { _ in .missing },
            retireLegacy: { _ in
                if !wroteCanonical {
                    retiredBeforeWrite = true
                }
                return errSecSuccess
            }
        )
        #expect(migrated == "e\u{301}")
        #expect(insertedData == legacyData)
        #expect(wroteCanonical)
        #expect(!retiredBeforeWrite)
    }

    @Test func nativeClassicKeychainCRUDRejectsTombstoneInputsOnOwnedService() {
        let provider = Self.provider(auth: .bearer)
        let account = "provider:\(provider.id)"
        let mcpProviderID = "fixture"
        let mcpServerID = UUID()
        let mcpAccount = "openai-mcp:\(mcpProviderID):\(mcpServerID.uuidString)"
        let service = "io.wsagency.wsurf.tests.\(UUID().uuidString)"
        let storage = CredentialStore.Storage.keychainStorage(service: service)
        defer {
            for recordAccount in [account, mcpAccount] {
                SecItemDelete([
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: recordAccount,
                    kSecUseDataProtectionKeychain as String: false,
                ] as CFDictionary)
            }
        }

        #expect(CredentialStore.save("fixture-key-one", for: provider, storage: storage) == nil)
        #expect(storage.read(account) == "fixture-key-one")
        #expect(CredentialStore.save("fixture-key-two", for: provider, storage: storage) == nil)
        #expect(storage.read(account) == "fixture-key-two")
        #expect(storage.delete(account) == errSecSuccess)
        #expect(storage.read(account) == nil)
        #expect(CredentialStore.save("fixture-key-three", for: provider, storage: storage) == nil)
        #expect(storage.read(account) == "fixture-key-three")
        #expect(CredentialStore.save("\u{0}", for: provider, storage: storage) != nil)
        #expect(storage.read(account) == "fixture-key-three")
        #expect(
            CredentialStore.saveMCPAuthorization(
                "manual-token", providerID: mcpProviderID, serverID: mcpServerID, storage: storage
            ) == nil
        )
        #expect(
            CredentialStore.saveMCPAuthorization(
                "\u{0}", providerID: mcpProviderID, serverID: mcpServerID, storage: storage
            ) != nil
        )
        #expect(
            CredentialStore.mcpAuthorization(
                providerID: mcpProviderID, serverID: mcpServerID, storage: storage
            ) == "manual-token"
        )
    }

    /// The service is chosen by `serviceName`, which has no `#if DEBUG`: a test host hosted by a Release build gets its own
    /// service too, and never the installed app's.
    @Test func aTestHostNeverUsesTheInstalledAppsKeychainService() {
        #expect(CredentialStore.serviceName(isRunningTests: false, processID: 41) == "io.wsagency.wsurf")
        #expect(CredentialStore.serviceName(isRunningTests: true, processID: 41) == "io.wsagency.wsurf.tests.41")
        #expect(CredentialStore.productionService == "io.wsagency.wsurf")
        #expect(AppDatabase.isRunningTests)
        #expect(CredentialStore.service != CredentialStore.productionService)
        #expect(CredentialStore.service.hasPrefix(CredentialStore.productionService + "."))
    }
}

extension CredentialStore.Storage {
    nonisolated static func fixture() -> Self {
        let items = Mutex([String: String]())
        return Self(
            read: { name in items.withLock { $0[name] } },
            write: { value, name in items.withLock { $0[name] = value }; return errSecSuccess },
            delete: { name in items.withLock { $0[name] = nil }; return errSecSuccess }
        )
    }
}

extension CredentialStoreTests {
    @Test func savedKeysRequireAccountAndEndpointConsentOnBothPopulatedMacs() throws {
        let cloud = CredentialStore.Storage.fixture()
        let localA = CredentialStore.Storage.fixture(), localB = CredentialStore.Storage.fixture()
        let suiteA = AppDatabase.defaultsSuite("KeySync.\(UUID())"), suiteB = AppDatabase.defaultsSuite("KeySync.\(UUID())")
        let defaultsA = try #require(UserDefaults(suiteName: suiteA)), defaultsB = try #require(UserDefaults(suiteName: suiteB))
        defer { defaultsA.removePersistentDomain(forName: suiteA); defaultsB.removePersistentDomain(forName: suiteB) }
        let a = ProviderKeySharing(defaults: defaultsA, local: localA, cloud: cloud)
        let b = ProviderKeySharing(defaults: defaultsB, local: localB, cloud: cloud)
        let provider = ProviderCatalog.openAI
        #expect(a.saveLocal("studio-fixture", for: provider) == nil)
        #expect(b.saveLocal("air-fixture", for: provider) == nil)
        #expect(throws: (any Error).self) { try a.shareLocal(provider) }
        a.setAccountIdentifier("first")
        b.setAccountIdentifier("first")
        try a.setEnabled(true)
        try b.setEnabled(true)
        var environmentOnly = ProviderCatalog.openAI
        environmentOnly.environmentKey = "PATH"
        let empty = ProviderKeySharing(defaults: defaultsA, local: .fixture(), cloud: cloud)
        empty.setAccountIdentifier("first")
        #expect(throws: ProviderKeySharing.Failure.noLocalKey) { try empty.shareLocal(environmentOnly) }
        try a.shareLocal(provider)
        #expect(b.savedKey(for: provider) == "air-fixture")
        try b.useCloud(provider)
        #expect(b.savedKey(for: provider) == "studio-fixture")
        #expect(a.saveLocal("rotated-fixture", for: provider) == nil)
        #expect(b.savedKey(for: provider) == "rotated-fixture")
        var changed = provider
        changed.baseURL = URL(string: "https://unapproved.test/v1")
        #expect(b.savedKey(for: changed) == nil)
        #expect(b.saveLocal("wrong-endpoint-fixture", for: changed) != nil)
        #expect(b.savedKey(for: provider) == "rotated-fixture")
        #expect(throws: (any Error).self) { try b.useCloud(changed) }
        let originalContext = b.accountContext
        b.suspendAccountVerification()
        #expect(b.accountContext == nil)
        #expect(!b.isEnabled)
        #expect(b.wantsSharing)
        #expect(throws: (any Error).self) { try b.useCloud(provider) }
        b.setAccountIdentifier("first")
        #expect(b.accountContext == originalContext)
        #expect(b.participates(provider))
        b.suspendAccountVerification()
        try b.setEnabled(false)
        b.setAccountIdentifier("first")
        #expect(!b.wantsSharing && !b.isEnabled)
        #expect(b.savedKey(for: provider) == "rotated-fixture")
        b.setAccountIdentifier("second")
        #expect(!b.isEnabled)
        #expect(throws: (any Error).self) { try b.shareLocal(provider) }
        try b.setEnabled(true)
        #expect(throws: (any Error).self) { try b.useCloud(provider) }
        let secondContext = b.accountContext
        b.suspendAccountVerification()
        b.setAccountIdentifier(nil)
        b.setAccountIdentifier("second")
        #expect(b.accountContext != secondContext)
        #expect(!b.isEnabled)
        try b.setEnabled(true)
        #expect(!b.participates(provider))
        #expect(b.savedKey(for: provider) == "rotated-fixture")
    }

    @Test func localEditsDuringSuspensionSurviveReverification() throws {
        let suite = AppDatabase.defaultsSuite("PausedKey.\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sharing = ProviderKeySharing(defaults: defaults, local: .fixture(), cloud: .fixture())
        let provider = ProviderCatalog.openAI
        sharing.setAccountIdentifier("fixture")
        try sharing.setEnabled(true)
        #expect(sharing.saveLocal("original-fixture", for: provider) == nil)
        try sharing.shareLocal(provider)
        sharing.suspendAccountVerification()
        #expect(sharing.saveLocal("offline-fixture", for: provider) == nil)
        sharing.setAccountIdentifier("fixture")
        #expect(sharing.savedKey(for: provider) == "offline-fixture")
        #expect(!sharing.participates(provider))
        try sharing.useCloud(provider)
        #expect(sharing.savedKey(for: provider) == "original-fixture")
    }

    @Test func legacyKeyNeedsApprovalAfterRemoteRemovalAndEndpointChange() throws {
        let suite = AppDatabase.defaultsSuite("LegacyKey.\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = CredentialStore.Storage.fixture()
        let sharing = ProviderKeySharing(defaults: defaults, local: local, cloud: .fixture())
        let catalog = ProviderCatalog(defaults: defaults, keySharing: sharing)
        var original = ProviderCatalog.newCustom()
        original.baseURL = URL(string: "https://first.test/v1")
        catalog.save(original)
        #expect(local.write("legacy-fixture", "provider:" + original.id) == errSecSuccess)
        #expect(sharing.savedKey(for: original) == "legacy-fixture")
        sharing.setAccountIdentifier("fixture")
        try sharing.setEnabled(true)
        try sharing.shareLocal(original)
        catalog.remove(original, received: true)
        var replacement = original
        replacement.baseURL = URL(string: "https://second.test/v1")
        catalog.save(replacement, received: true)
        #expect(sharing.needsEndpointApproval(replacement))
        #expect(sharing.savedKey(for: replacement) == nil)
        #expect(throws: (any Error).self) { try sharing.shareLocal(replacement) }
        #expect(throws: (any Error).self) { try sharing.useCloud(replacement) }
        #expect(throws: (any Error).self) { try sharing.approveLocalEndpoint(original) }
        try sharing.setEnabled(false)
        try sharing.approveLocalEndpoint(replacement)
        #expect(sharing.savedKey(for: replacement) == "legacy-fixture")
        #expect(sharing.savedKey(for: original) == "legacy-fixture")
        #expect(!sharing.participates(replacement))
        try sharing.setEnabled(true)
        #expect(throws: (any Error).self) { try sharing.useCloud(replacement) }
        try sharing.shareLocal(replacement)
        #expect(sharing.participates(replacement))
    }

    @Test func savingAKeyForAnOlderEndpointKeepsCurrentApprovalPending() throws {
        let suite = AppDatabase.defaultsSuite("ChangedEndpoint.\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sharing = ProviderKeySharing(defaults: defaults, local: .fixture(), cloud: .fixture())
        let catalog = ProviderCatalog(defaults: defaults, keySharing: sharing)
        var first = ProviderCatalog.newCustom()
        first.baseURL = URL(string: "https://first.test/v1")
        var second = first
        second.baseURL = URL(string: "https://second.test/v1")
        catalog.save(second)
        #expect(sharing.saveLocal("previous-second", for: second) == nil)
        catalog.save(first)
        #expect(sharing.saveLocal("first-fixture", for: first) == nil)
        catalog.save(second, received: true)
        #expect(sharing.needsEndpointApproval(second))
        #expect(sharing.saveLocal("revised-first", for: first) == nil)
        #expect(sharing.needsEndpointApproval(second))
        #expect(sharing.savedKey(for: second) == nil)
        try sharing.approveLocalEndpoint(second)
        #expect(sharing.savedKey(for: second) == "previous-second")
    }

    @Test func removedProviderEndpointStillHasIndependentKeyControlsAfterRestart() throws {
        let suite = AppDatabase.defaultsSuite("RetiredKey.\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sharing = ProviderKeySharing(defaults: defaults, local: .fixture(), cloud: .fixture())
        sharing.setAccountIdentifier("fixture")
        try sharing.setEnabled(true)
        let catalog = ProviderCatalog(defaults: defaults, keySharing: sharing)
        var first = ProviderCatalog.newCustom()
        first.name = "Fixture"
        first.baseURL = URL(string: "https://first.test/v1")
        catalog.save(first)
        #expect(sharing.saveLocal("first-fixture", for: first) == nil)
        try sharing.shareLocal(first)
        var next = first
        next.baseURL = URL(string: "https://next.test/v1")
        catalog.save(next, received: true)
        #expect(sharing.saveLocal("next-fixture", for: next) == nil)
        try sharing.shareLocal(next)
        catalog.remove(next, received: true)
        let reopened = ProviderCatalog(defaults: defaults, keySharing: sharing)
        #expect(reopened.provider(id: first.id) == nil)
        let choices = reopened.keyEndpoints.filter { $0.provider.id == first.id }
        #expect(Set(choices.compactMap { $0.provider.baseURL }) == Set([first.baseURL, next.baseURL].compactMap { $0 }))
        #expect(choices.allSatisfy { $0.isRetired })
        try sharing.useCloud(first)
        #expect(sharing.participates(next))
        try sharing.removeCloudCopy(first)
        #expect(sharing.participates(next))
        #expect(throws: ProviderKeySharing.Failure.noSharedKey) { try sharing.useCloud(first) }
        #expect(sharing.savedKey(for: first) == "first-fixture")
        #expect(sharing.savedKey(for: next) == "next-fixture")
    }

    @Test func unreadableRotatedKeyNeverFallsBackToEarlierIDOnlyKey() throws {
        let suite = AppDatabase.defaultsSuite("RotatedKey.\(UUID())")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = CredentialStore.Storage.fixture(), readable = Mutex(true)
        var provider = ProviderCatalog.newCustom()
        provider.baseURL = URL(string: "https://old.test/v1")
        let address = ProviderKeySharing.localAddress(provider)
        let local = CredentialStore.Storage(read: { name in
            if name == address && !readable.withLock({ $0 }) {
                return nil
            }
            return storage.read(name)
        }, write: storage.write, delete: storage.delete)
        let sharing = ProviderKeySharing(defaults: defaults, local: local, cloud: .fixture())
        #expect(storage.write("superseded", "provider:" + provider.id) == errSecSuccess)
        #expect(sharing.savedKey(for: provider) == "superseded")
        #expect(sharing.saveLocal("rotated", for: provider) == nil)
        readable.withLock { $0 = false }
        #expect(sharing.savedKey(for: provider) == nil)
        sharing.setAccountIdentifier("fixture")
        try sharing.setEnabled(true)
        #expect(throws: ProviderKeySharing.Failure.noLocalKey) { try sharing.shareLocal(provider) }
    }

    @Test func providerMetadataKeepsSelectionsAndEndpointBoundLocalKeys() throws {
        let profile = Profile.original(), folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try MacSettingsFixture(profile: profile, folder: folder.appending(path: "studio"))
        let b = try MacSettingsFixture(profile: profile, folder: folder.appending(path: "air"))
        defer { a.cleanup(); b.cleanup() }
        var one = ProviderCatalog.newCustom()
        one.baseURL = URL(string: "https://first.test/v1")
        one.name = "Fixture"
        a.catalog.save(one)
        b.catalog.save(one)
        #expect(b.catalog.keySharing.saveLocal("only-on-air", for: one) == nil)
        a.stores.models.providerID = one.id
        a.stores.models.setModel("fixture-model", for: one)
        a.stores.models.setReasoningEffort(.high, for: one)
        a.stores.models.reasoningEffort = .medium
        let selections = try a.adapter.values(for: .providers, profileID: profile.id)
        for (key, value) in selections {
            try b.adapter.apply(value, key: key, for: .providers, profileID: profile.id)
        }
        let extra = Profile(id: UUID(), name: "Later", symbol: "person", color: .gray)
        let later = try MacSettingsFixture(profile: extra, folder: folder.appending(path: "later-profile"))
        defer { later.cleanup() }
        // Pre-sync versions wrote this preference without an index. This profile opens after the definition was removed.
        later.stores.models.defaults.set("legacy-model", forKey: "llm.model." + one.id)
        var two = one
        two.baseURL = URL(string: "https://second.test/v1")
        a.catalog.save(two)
        let record = try #require(a.adapter.values(for: .providers, profileID: nil).first)
        try b.adapter.apply(record.value, key: record.key, for: .providers, profileID: nil)
        #expect(try JSONSerialization.jsonObject(with: record.value) as? [String: String] == [
            "name": "Fixture", "endpoint": "https://second.test/v1",
        ])
        #expect(throws: (any Error).self) { try b.adapter.apply(record.value, key: record.key, for: .providers, profileID: profile.id) }
        #expect(throws: (any Error).self) { try b.adapter.apply(nil, key: "model|openai", for: .providers, profileID: nil) }
        #expect(b.catalog.provider(id: one.id)?.baseURL == two.baseURL)
        #expect(b.catalog.keySharing.savedKey(for: two) == nil)
        try b.adapter.apply(nil, key: record.key, for: .providers, profileID: nil)
        #expect(b.catalog.provider(id: one.id) == nil)
        #expect(b.stores.models.providerID == one.id)
        let unavailable = b.catalog.selection(for: b.stores.models)
        #expect(unavailable.id == one.id)
        #expect(unavailable.baseURL == nil)
        #expect(b.stores.models.model(for: one) == "fixture-model")
        #expect(b.stores.models.reasoningEffort(for: one) == .high)
        #expect(b.stores.models.reasoningEffort == .medium)
        #expect(b.catalog.keySharing.savedKey(for: one) == "only-on-air")
        #expect(try b.adapter.values(for: .providers, profileID: profile.id) == selections)
        let reopened = MacSettingsSyncAdapter(profiles: [], catalog: b.catalog, stores: { _ in later.stores }, refreshWindows: { _, _, _ in })
        reopened.register(extra)
        #expect(try reopened.values(for: .providers, profileID: extra.id)["model|" + one.id] == JSONEncoder().encode("legacy-model"))
        let unsupported = Data(#"{"name":"Fixture","endpoint":"https://extra.test/v1","environmentKey":"FIXTURE_ONLY"}"#.utf8)
        #expect(throws: (any Error).self) { try b.adapter.apply(unsupported, key: record.key, for: .providers, profileID: nil) }
        #expect(b.catalog.provider(id: one.id) == nil)
        a.catalog.remove(two)
        let locallyRemoved = MacSettingsSyncAdapter(profiles: [extra], catalog: a.catalog, stores: { _ in later.stores }, refreshWindows: { _, _, _ in })
        #expect(try locallyRemoved.values(for: .providers, profileID: extra.id)["model|" + one.id] == JSONEncoder().encode("legacy-model"))
    }
}
