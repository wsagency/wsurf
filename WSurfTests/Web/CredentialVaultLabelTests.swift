// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// One vault is called the same thing on every surface, and what a lock or an unlock of any vault of the profile changes is seen
// without the user doing anything: the name is sealed while the vault is locked and must not outlive the lock in memory.

@MainActor
struct CredentialVaultLabelTests {
    private func listing(_ ordinal: Int, name: String?, isUnlocked: Bool) -> VaultListing {
        VaultListing(vaultID: UUID(), ordinal: ordinal, name: name, isUnlocked: isUnlocked, isVerified: false)
    }

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

    /// A model over a profile whose one vault, named "Personal", exists and is locked.
    private func lockedModel(_ profile: Profile, _ passkeys: VaultPasskeys) async -> CredentialSettingsModel {
        let model = CredentialSettingsModel(profile: profile, native: passkeys.native)
        await model.load()
        await model.createVault(name: "Personal", choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())
        return model
    }

    // MARK: Label

    @Test func aLockedVaultIsLabelledByItsNumberAndAnUnlockedOneByItsNameAndNumber() {
        #expect(listing(1, name: nil, isUnlocked: false).label == "Vault 1 (locked)")
        #expect(listing(1, name: "Personal", isUnlocked: true).label == "Personal · Vault 1")
        #expect(listing(12, name: "Household", isUnlocked: true).label == "Household · Vault 12")
        // A name an older listing still holds is never shown for a locked vault.
        #expect(listing(2, name: "Personal", isUnlocked: false).label == "Vault 2 (locked)")
    }

    @Test func aVaultWithoutADistinctNameIsLabelledByItsNumberAlone() {
        #expect(listing(1, name: nil, isUnlocked: true).label == "Vault 1")
        #expect(listing(1, name: "", isUnlocked: true).label == "Vault 1")
        #expect(listing(3, name: "Vault 3", isUnlocked: true).label == "Vault 3")
        #expect(listing(1, name: "Personal", isUnlocked: true).displayName == "Personal", "the name to edit stays the plain name")
    }

    // MARK: A lock drops the name

    @Test func aLockDropsTheDecryptedNameFromMemoryAtOnce() async throws {
        try await withProfile { profile, passkeys in
            let model = await lockedModel(profile, passkeys)
            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(model.vaults.map(\.label) == ["Personal · Vault 1"])
            #expect(model.vaultName == "Personal")

            model.lock()

            // No suspension since the lock: nothing has read the list again.
            #expect(model.vaults.map(\.name) == [nil])
            #expect(model.vaults.map(\.label) == ["Vault 1 (locked)"])
            #expect(model.vaultName == nil)
        }
    }

    @Test func thePasskeyChoiceNamesTheVaultByItsRealNameAfterUnlockingAndByNumberAfterALock() async throws {
        try await withProfile { profile, passkeys in
            let model = await lockedModel(profile, passkeys)
            #expect(model.existingPasskeys.map { $0.vault.label } == ["Vault 1 (locked)"])

            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(model.existingPasskeys.map { $0.vault.label } == ["Personal · Vault 1"])

            model.lock()
            #expect(model.existingPasskeys.map { $0.vault.label } == ["Vault 1 (locked)"])
        }
    }

    // MARK: A change in another vault

    @Test func anUnlockOrLockOfAnotherVaultUpdatesTheListingWithoutAnyActionOnThePage() async throws {
        let made = try await VaultManagerFixture.make(vaults: [.locked, .locked])
        do {
            let model = CredentialSettingsModel(profile: made.profile)
            await model.load()
            let other = made.vaults[1]
            #expect(model.selectedVaultID == made.vaults[0].vaultID)
            #expect(model.vaults.map(\.label) == ["Vault 1 (locked)", "Vault 2 (locked)"])

            // The other vault unlocks somewhere else (autofill, another window); this page has the first one selected.
            try await VaultManagerFixture.unlock(other)
            #expect(await waitUntil { model.vaults.map(\.label) == ["Vault 1 (locked)", "Vault 2"] })

            let epoch = try #require(other.manager.authorizationEpoch)
            _ = try await other.manager.renameVault("Household", authorizedEpoch: epoch)
            await model.refreshListing()
            #expect(model.vaults.map(\.label) == ["Vault 1 (locked)", "Household · Vault 2"])

            // Selecting an unlocked vault reads its listing too: the page shows what it has just opened.
            await model.select(vaultID: other.vaultID)
            #expect(model.isUnlocked && model.selectedVaultID == other.vaultID)
            #expect(model.vaults.map(\.label) == ["Vault 1 (locked)", "Household · Vault 2"])

            // The lock drops the name at once, and the read that follows agrees.
            other.manager.lock(reason: .manual)
            #expect(model.vaults.map(\.name) == [nil, nil])
            #expect(await waitUntil { model.vaults.map(\.label) == ["Vault 1 (locked)", "Vault 2 (locked)"] })
        } catch {
            await VaultManagerFixture.cleanup(made.profile)
            throw error
        }
        await VaultManagerFixture.cleanup(made.profile)
    }
}
