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

    @Test func aFirstRunOffersCreateAndCreatingLeavesItsFirstVaultLockedUntilTheUserUnlocksIt() async throws {
        try await withProfile { profile, passkeys in
            let model = CredentialSettingsModel(profile: profile, native: passkeys.native)
            await model.load()
            #expect(model.isAvailable)
            #expect(model.vaultExists == false)
            #expect(model.canCreateVault && model.canCreateWithNewPasskey)
            #expect(model.error == nil)
            #expect(model.selectedVaultID == nil)

            await model.createVault(name: "Personal", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())

            #expect(model.error == nil)
            let listing = try await CredentialManager.store(for: profile).listing()
            #expect(listing.count == 1)
            #expect(model.selectedVaultID == listing.first?.vaultID)
            // Created with one new passkey and nothing else: no assertion, no unlock, no loaded credentials.
            #expect(passkeys.registered.count == 1)
            #expect(passkeys.assertions.isEmpty)
            #expect(model.vaultExists == true)
            #expect(!model.isUnlocked && !model.isLoaded)
            // A second vault needs an open one to approve a new passkey, or an enrolled passkey to approve with.
            #expect(!model.canCreateWithNewPasskey)
            #expect(model.canCreateVault && model.existingPasskeys.count == 1)

            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(passkeys.assertions == passkeys.registered.map(\.credentialID))
            #expect(model.isUnlocked && model.isLoaded)
            #expect(model.canCreateWithNewPasskey)
        }
    }

    @Test func aFurtherVaultNeedsAnApprovingPasskeyAndIsRefusedWithoutOneWritingNothing() async throws {
        try await withProfile { profile, passkeys in
            let model = CredentialSettingsModel(profile: profile, native: passkeys.native)
            await model.load()
            await model.createVault(name: "First", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())
            let store = try CredentialManager.store(for: profile)
            let first = try #require(try await store.listing().first)

            // Locked: a new passkey has nothing to be authorized by; an unrelated passkey is not enrolled in any vault.
            await model.createVault(name: "Second", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())
            #expect(model.error != nil)
            let stranger = VaultFixtures.proof(9)
            await model.createVault(
                name: "Third", choice: .existing(sourceVaultID: first.vaultID, credentialID: stranger.credentialID, prfInput: stranger.prfInput),
                in: VaultManagerFixture.anchor()
            )
            #expect(model.error != nil)
            #expect(try await store.listing().count == 1)
            #expect(passkeys.registered.count == 1)

            // Unlocked: the selected vault approves a new passkey, and the new vault stays locked and selected.
            await model.unlock(in: VaultManagerFixture.anchor())
            await model.createVault(name: "Second", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())
            #expect(model.error == nil)
            let listing = try await store.listing()
            #expect(listing.count == 2 && passkeys.registered.count == 2)
            let second = try #require(listing.first { $0.vaultID != first.vaultID })
            #expect(model.selectedVaultID == second.vaultID && !model.isUnlocked)

            // An enrolled passkey of an existing vault authorizes a third, even with the selected vault locked.
            let enrolled = try #require(passkeys.registered.first)
            await model.createVault(
                name: "Third", choice: .existing(sourceVaultID: first.vaultID, credentialID: enrolled.credentialID, prfInput: enrolled.prfInput),
                in: VaultManagerFixture.anchor()
            )
            #expect(model.error == nil)
            #expect(try await store.listing().count == 3)
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
            #expect(model.failClosed != nil)
            #expect(!model.canCreateVault)
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
            #expect(model.needsMigrationConfirmation)
            #expect(!model.canCreateVault)

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

    @Test func aTransferEndingBelongsToTheVaultItHappenedInAndNeverReadsAsAnotherVaultsTransfer() async throws {
        try await withProfile { profile, passkeys in
            let model = CredentialSettingsModel(profile: profile, native: passkeys.native)
            await model.load()
            await model.createVault(name: "First", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())
            let first = try #require(model.selectedVaultID)
            await model.unlock(in: VaultManagerFixture.anchor())
            let epoch = try #require(model.authorizationEpoch)
            let unknown = CredentialExportSelection(accountID: UUID(), password: true, passkeyIDs: [], totp: false)
            #expect(await model.exportCredentials(selection: [unknown], epoch: epoch, in: VaultManagerFixture.anchor()) == nil)
            let ending = try #require(model.transferMessage)

            await model.createVault(name: "Second", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())
            #expect(model.selectedVaultID != first)
            #expect(model.transferMessage == nil)

            await model.select(vaultID: first)
            #expect(model.transferMessage == ending)
        }
    }
}
