// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The Settings page works on one selected vault of the profile's real store: what it offers (Create, Unlock) comes from the store's
// own listing, and a v1 vault is never offered Create and never prompts for a passkey before the user agrees to migrate it.

@MainActor
struct VaultSettingsRoutingTests {
    private func withProfile(_ body: (Profile, VaultPasskeys) async throws -> Void) async throws {
        let profile = try await VaultManagerFixture.newProfile()
        do {
            try await body(profile, VaultPasskeys())
        } catch {
            await VaultManagerFixture.cleanup(profile)
            throw error
        }
        await VaultManagerFixture.cleanup(profile)
    }

    @Test func aProfileWithoutAVaultOffersCreateAndCreatingLeavesItsFirstVaultUnlocked() async throws {
        try await withProfile { profile, passkeys in
            let model = CredentialSettingsModel(profile: profile, native: passkeys.native)
            await model.load()
            #expect(model.isAvailable)
            #expect(model.vaultExists == false)
            #expect(model.error == nil)
            #expect(model.selectedVaultID == nil)

            await model.createVault(in: VaultManagerFixture.anchor())

            #expect(model.error == nil)
            let listing = try await CredentialManager.store(for: profile).listing()
            #expect(listing.count == 1)
            #expect(model.selectedVaultID == listing.first?.vaultID)
            // Created locked with one new passkey, then unlocked by asserting that same passkey.
            #expect(passkeys.registered.count == 1)
            #expect(passkeys.assertions == passkeys.registered.map(\.credentialID))
            #expect(model.vaultExists == true)
            #expect(model.isUnlocked)
            #expect(model.isLoaded)
        }
    }

    @Test func anUnreadableStoreIsReportedAndNeverOffersCreate() async throws {
        try await withProfile { profile, passkeys in
            try FileManager.default.createDirectory(at: profile.supportDirectory, withIntermediateDirectories: true)
            try Data("not a database".utf8).write(to: profile.supportDirectory.appendingPathComponent("Credentials.store"))
            guard case .failClosed = try await CredentialManager.store(for: profile).openState() else {
                Issue.record("a garbage store file must be fail-closed")
                return
            }

            let model = CredentialSettingsModel(profile: profile, native: passkeys.native)
            await model.load()

            #expect(model.vaultExists == nil)
            #expect(model.error != nil)
            #expect(model.selectedVaultID == nil)
        }
    }

    @Test func aV1VaultShowsNoCreateAndNeedsConsentBeforeAnyPasskeyPrompt() async throws {
        try await withProfile { profile, passkeys in
            let directory = profile.supportDirectory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let legacy = try LegacyV1.make(profileID: profile.id)
            try legacy.write(to: directory)
            passkeys.adopt(legacy.proof)

            let model = CredentialSettingsModel(profile: profile, native: passkeys.native)
            await model.load()
            #expect(model.vaultExists == true)
            #expect(model.selectedVaultID == legacy.vaultID)
            #expect(model.error == nil)

            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(model.needsMigrationConfirmation)
            #expect(model.error != nil)
            #expect(!model.isUnlocked)
            #expect(passkeys.assertions.isEmpty)
            #expect(try Data(contentsOf: directory.appendingPathComponent("Credentials.vault")) == legacy.bytes)

            await model.unlock(in: VaultManagerFixture.anchor(), confirmMigration: true)
            #expect(!model.needsMigrationConfirmation)
            #expect(model.error == nil)
            #expect(passkeys.assertions == [legacy.proof.credentialID])
            #expect(model.isLoaded)
            #expect(model.summaries.count == legacy.accounts.count)
        }
    }
}
