// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
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
        #expect(CredentialStore.save("   \n\t", for: provider, storage: storage) == nil)
        #expect(values.withLock { $0.isEmpty })
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
        #expect(!legacyPresent)
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
        #expect(!legacyPresent)
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
        var wroteCanonical = false
        var retiredBeforeWrite = false
        let migrated = CredentialStore.migrateLegacy(
            Data("legacy-fixture".utf8),
            account: "provider:test-\(UUID().uuidString)",
            addCanonical: { _, _ in wroteCanonical = true; return errSecSuccess },
            readCanonical: { _ in .missing },
            retireLegacy: { _ in
                if !wroteCanonical { retiredBeforeWrite = true }
                return errSecSuccess
            }
        )
        #expect(migrated == "legacy-fixture")
        #expect(wroteCanonical)
        #expect(!retiredBeforeWrite)
    }

    @Test func nativeClassicKeychainCRUDUsesAnOwnedService() {
        let provider = Self.provider(auth: .bearer)
        let account = "provider:\(provider.id)"
        let storage = CredentialStore.Storage.keychainStorage(
            service: "io.wsagency.wsurf.tests.\(UUID().uuidString)"
        )
        defer { _ = storage.delete(account) }

        #expect(CredentialStore.save("fixture-key-one", for: provider, storage: storage) == nil)
        #expect(storage.read(account) == "fixture-key-one")
        #expect(CredentialStore.save("fixture-key-two", for: provider, storage: storage) == nil)
        #expect(storage.read(account) == "fixture-key-two")
        #expect(storage.delete(account) == errSecSuccess)
        #expect(storage.read(account) == nil)
        #expect(CredentialStore.save("fixture-key-three", for: provider, storage: storage) == nil)
        #expect(storage.read(account) == "fixture-key-three")
    }
}
