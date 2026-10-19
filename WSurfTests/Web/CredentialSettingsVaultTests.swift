// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// A vault's name is sealed in its head, so the page lists a locked vault by its number and an unlocked one by its name. The listing is
// read again whenever that changes, never only when a vault is created.

@MainActor
struct CredentialSettingsVaultTests {
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

    @Test func theUnlockedVaultIsListedByItsNameRightAfterUnlocking() async throws {
        try await withProfile { profile, passkeys in
            let model = await lockedModel(profile, passkeys)
            #expect(model.vaults.map(\.displayName) == ["Vault 1"])

            await model.unlock(in: VaultManagerFixture.anchor())

            #expect(model.isUnlocked)
            #expect(model.vaults.map(\.displayName) == ["Personal"])
        }
    }

    @Test func aLockedVaultIsListedByItsNumberAgain() async throws {
        try await withProfile { profile, passkeys in
            let model = await lockedModel(profile, passkeys)
            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(model.vaults.map(\.displayName) == ["Personal"])

            model.lock()

            #expect(await waitUntil { model.vaults.map(\.displayName) == ["Vault 1"] })
        }
    }

    // MARK: Renaming from the page

    @Test func renamingFromThePageShowsTheNewNameAndLeavesTheSessionWritable() async throws {
        try await withProfile { profile, passkeys in
            let model = await lockedModel(profile, passkeys)
            await model.unlock(in: VaultManagerFixture.anchor())
            let revision = model.revision

            await model.renameVault("  Household ")

            #expect(model.error == nil)
            #expect(model.vaults.map(\.displayName) == ["Household"])
            #expect(try await model.manager?.displayNames().vault == "Household")
            // The rename is a new revision; the open session reads it, so the next write is not stale.
            #expect(model.revision == revision + 1)
            _ = try await model.save(VaultFixtures.account(), expectedRevision: model.revision)
            #expect(model.error == nil)
        }
    }

    @Test func aNameThePageRefusesChangesNothing() async throws {
        try await withProfile { profile, passkeys in
            let model = await lockedModel(profile, passkeys)
            await model.unlock(in: VaultManagerFixture.anchor())
            let revision = model.revision

            for name in ["", "   ", String(repeating: "n", count: StoreFormat.nameLimit + 1)] {
                await model.renameVault(name)
                #expect(model.error == String(localized: "Use a name of 1 to \(StoreFormat.nameLimit) characters."))
            }

            #expect(model.vaults.map(\.displayName) == ["Personal"])
            #expect(model.revision == revision)
        }
    }

    @Test func aLockedPageCannotRenameTheVault() async throws {
        try await withProfile { profile, passkeys in
            let model = await lockedModel(profile, passkeys)

            await model.renameVault("Household")

            #expect(model.error == String(localized: "Credentials are locked."))
            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(model.vaults.map(\.displayName) == ["Personal"])
        }
    }

    @Test func aNewVaultIsSuggestedTheNumberTheStoreGivesIt() async throws {
        try await withProfile { profile, passkeys in
            let model = CredentialSettingsModel(profile: profile, native: passkeys.native)
            await model.load()
            #expect(model.suggestedVaultName == "Vault 1")
            await model.createVault(name: model.suggestedVaultName, choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())
            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(model.suggestedVaultName == "Vault 2")

            await model.createVault(name: model.suggestedVaultName, choice: .newPasskey(authorizedBy: nil), in: VaultManagerFixture.anchor())
            let locked = model.vaults.map(\.displayName)
            await model.unlock(in: VaultManagerFixture.anchor())

            // A vault left with its suggested name reads the same locked and unlocked.
            #expect(locked == ["Vault 1", "Vault 2"])
            #expect(model.vaults.map(\.displayName) == locked)
            #expect(model.vaults.map(\.name) == ["Vault 1", "Vault 2"])
        }
    }
}
