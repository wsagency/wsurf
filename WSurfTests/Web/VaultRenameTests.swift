// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// A vault's name is one sealed field of its head (spec §4.1). Renaming rewrites that head and nothing else, needs the unlocked vault,
// and a locked vault is listed by its number again afterwards.

@MainActor
struct VaultRenameTests {
    private func withUnlockedVault(
        _ body: (_ profile: Profile, _ vault: FixtureVault, _ store: ProfileVaultStore) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            try await body(profile, vaults[0], try CredentialManager.store(for: profile))
        }
    }

    private func headKey(_ vault: FixtureVault, revision: UInt64) -> String {
        "head/\(vault.vaultID.lowerText)/\(revision)"
    }

    @Test func renameRewritesTheSealedNameAndTheListingShowsIt() async throws {
        try await withUnlockedVault { profile, vault, store in
            let before = try VaultManagerFixture.rows(of: vault.vaultID, in: profile)
            let epoch = try #require(vault.manager.authorizationEpoch)
            let revision = try await vault.manager.snapshot().revision

            let receipt = try await vault.manager.renameVault("Household", authorizedEpoch: epoch)

            #expect(receipt.revision == revision + 1)
            #expect(try await store.listing().map(\.displayName) == ["Household"])
            let after = try VaultManagerFixture.rows(of: vault.vaultID, in: profile)
            // Only the vault's head is new; every record and journal row, and the Trash head, is byte for byte what it was.
            #expect(Set(after.keys).subtracting(before.keys) == [headKey(vault, revision: receipt.revision)])
            #expect(after.filter { !$0.key.hasPrefix("head/") } == before.filter { !$0.key.hasPrefix("head/") })
            // Neither name is readable in any stored byte.
            for name in ["Household", "Vault 1"] {
                #expect(!after.values.contains { $0.range(of: Data(name.utf8)) != nil }, "\(name)")
            }

            // The new name is what the next unlock reads back from the head.
            vault.manager.lock(reason: .manual)
            #expect(try await store.listing().map(\.name) == [nil])
            try await VaultManagerFixture.unlock(vault)
            #expect(try await store.listing().map(\.displayName) == ["Household"])
        }
    }

    @Test func renameTrimsTheNameAndAcceptsTheLongestOne() async throws {
        try await withUnlockedVault { _, vault, store in
            let epoch = try #require(vault.manager.authorizationEpoch)
            _ = try await vault.manager.renameVault("  Household \n", authorizedEpoch: epoch)
            #expect(try await store.listing().map(\.displayName) == ["Household"])

            let longest = String(repeating: "n", count: StoreFormat.nameLimit)
            _ = try await vault.manager.renameVault(longest, authorizedEpoch: epoch)
            #expect(try await store.listing().map(\.displayName) == [longest])
        }
    }

    @Test func renameRefusesAnEmptyOrTooLongName() async throws {
        try await withUnlockedVault { profile, vault, store in
            let before = try VaultManagerFixture.rows(of: vault.vaultID, in: profile)
            let epoch = try #require(vault.manager.authorizationEpoch)

            for name in ["", "   \n", String(repeating: "n", count: StoreFormat.nameLimit + 1)] {
                await #expect(throws: CredentialStoreError.invalidVaultName, "\(name.count) characters") {
                    try await vault.manager.renameVault(name, authorizedEpoch: epoch)
                }
            }

            #expect(try VaultManagerFixture.rows(of: vault.vaultID, in: profile) == before)
            #expect(try await store.listing().map(\.displayName) == ["Vault 1"])
        }
    }

    @Test func renamingToTheSameNameWritesNothing() async throws {
        try await withUnlockedVault { profile, vault, _ in
            let before = try VaultManagerFixture.rows(of: vault.vaultID, in: profile)
            let epoch = try #require(vault.manager.authorizationEpoch)
            let revision = try await vault.manager.snapshot().revision

            for name in ["Vault 1", "  Vault 1  "] {
                let receipt = try await vault.manager.renameVault(name, authorizedEpoch: epoch)
                #expect(receipt.revision == revision)
            }

            #expect(try VaultManagerFixture.rows(of: vault.vaultID, in: profile) == before)
        }
    }

    @Test func renameNeedsTheVaultUnlocked() async throws {
        try await withUnlockedVault { profile, vault, store in
            let before = try VaultManagerFixture.rows(of: vault.vaultID, in: profile)
            let epoch = try #require(vault.manager.authorizationEpoch)
            vault.manager.lock(reason: .manual)

            await #expect(throws: CredentialVaultError.unauthorized) {
                try await vault.manager.renameVault("Household", authorizedEpoch: epoch)
            }
            // A newer unlock does not carry a rename decided under the earlier one.
            try await VaultManagerFixture.unlock(vault)
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await vault.manager.renameVault("Household", authorizedEpoch: epoch)
            }

            #expect(try VaultManagerFixture.rows(of: vault.vaultID, in: profile) == before)
            #expect(try await store.listing().map(\.displayName) == ["Vault 1"])
        }
    }

    @Test func aRenamedLockedVaultIsStillListedByItsNumber() async throws {
        try await withUnlockedVault { _, vault, store in
            let epoch = try #require(vault.manager.authorizationEpoch)
            _ = try await vault.manager.renameVault("Household", authorizedEpoch: epoch)

            vault.manager.lock(reason: .manual)

            let listing = try await store.listing()
            #expect(listing.map(\.name) == [nil])
            #expect(listing.map(\.displayName) == ["Vault 1"])
        }
    }

    @Test func theTransferHeaderUsesTheNewName() async throws {
        try await withUnlockedVault { profile, vault, _ in
            let epoch = try #require(vault.manager.authorizationEpoch)
            #expect(try await vault.manager.displayNames().vault == "Vault 1")

            _ = try await vault.manager.renameVault("Household", authorizedEpoch: epoch)

            let names = try await vault.manager.displayNames()
            #expect(names.vault == "Household")
            #expect(names.profile == profile.name)
        }
    }

    @Test func aRenameLeavesTheCredentialsWritable() async throws {
        try await withUnlockedVault { _, vault, _ in
            try await VaultManagerFixture.save([VaultFixtures.account()], in: vault)
            let epoch = try #require(vault.manager.authorizationEpoch)

            _ = try await vault.manager.renameVault("Household", authorizedEpoch: epoch)

            // The head's revision moved with the rename; a write that reads it afresh still commits and the account is intact.
            try await VaultManagerFixture.save([VaultFixtures.account(username: "grace")], in: vault)
            #expect(try await vault.manager.snapshot().accounts.map(\.username) == ["grace"])
        }
    }
}
