// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// The dropdown's "Unlock Credentials…" row: offered only while every vault of the profile is locked, it unlocks through the
/// ordinary unlock (the real manager, store and route; only the passkey prompt is the fixture's stub), and then the lookup reads the
/// vault. A lock or an ended request while the vault choice is open unlocks nothing.
@MainActor
struct AutofillUnlockRowTests {
    private static let origin = "https://login.example.test"

    private func account(_ username: String) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: nil, origins: [Self.origin], loginURLs: [], password: "pw", passkeys: [],
            totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    @Test func onlyAProfileWhoseVaultsAreAllLockedIsOfferedTheUnlockRow() async throws {
        try await VaultManagerFixture.with(vaults: [.locked, .locked]) { profile, _, _ in
            let locked = await AutofillSuggestions.allVaultsLocked(of: profile)
            #expect(locked)
        }
        try await VaultManagerFixture.with(vaults: [.unlocked, .locked]) { profile, _, _ in
            let locked = await AutofillSuggestions.allVaultsLocked(of: profile)
            #expect(!locked, "an unlocked vault answers with its own accounts")
        }
        try await VaultManagerFixture.with(vaults: []) { profile, _, _ in
            let locked = await AutofillSuggestions.allVaultsLocked(of: profile)
            #expect(!locked, "a profile without a vault has nothing to unlock")
        }
        let privateLocked = await AutofillSuggestions.allVaultsLocked(of: .privateBrowsing())
        #expect(!privateLocked)
    }

    @Test func theOnlyVaultIsUnlockedWithoutAChoiceAndTheLookupThenReadsIt() async throws {
        let passkeys = VaultPasskeys()
        try await VaultManagerFixture.with(passkeys: passkeys, vaults: [.unlocked]) { profile, _, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            vaults[0].manager.lock(reason: .manual)
            let before = passkeys.assertions.count

            let unlocked = await AutofillSuggestions.shared.unlockVault(of: profile, in: VaultManagerFixture.anchor()) { true }

            #expect(unlocked && vaults[0].manager.isUnlocked)
            #expect(passkeys.assertions.count == before + 1, "one native unlock, and no vault choice")
            let locked = await AutofillSuggestions.allVaultsLocked(of: profile)
            #expect(!locked)
            let accounts = try await vaults[0].manager.snapshot().accounts
            let rows = CredentialAccountSelection.suggestions(accounts, origin: Self.origin, pageURL: nil, entered: nil, field: .password)
            #expect(rows.map(\.id) == [ada.id], "the lookup that runs again offers the page's account")
        }
    }

    @Test func withSeveralVaultsTheChosenOneIsUnlocked() async throws {
        try await VaultManagerFixture.with(vaults: [.locked, .locked]) { profile, _, vaults in
            let chosen = vaults[1].vaultID
            var offered: [UUID] = []
            VaultChoicePrompt.answersForTesting[profile.id] = { listings in
                offered = listings.map(\.vaultID)
                return chosen
            }
            defer { VaultChoicePrompt.answersForTesting[profile.id] = nil }

            let unlocked = await AutofillSuggestions.shared.unlockVault(of: profile, in: VaultManagerFixture.anchor()) { true }

            #expect(unlocked)
            #expect(offered == [vaults[0].vaultID, vaults[1].vaultID], "every vault is a choice, in order")
            #expect(vaults[1].manager.isUnlocked && !vaults[0].manager.isUnlocked)
        }
    }

    @Test func aLockWhileTheChoiceIsOpenUnlocksNothing() async throws {
        let passkeys = VaultPasskeys()
        try await VaultManagerFixture.with(passkeys: passkeys, vaults: [.locked, .locked]) { profile, _, vaults in
            let before = passkeys.assertions.count
            let chosen = vaults[0].vaultID
            VaultChoicePrompt.answersForTesting[profile.id] = { _ in
                CredentialManager.lock(profileID: profile.id, reason: .profileSwitch)
                return chosen
            }
            defer { VaultChoicePrompt.answersForTesting[profile.id] = nil }

            let unlocked = await AutofillSuggestions.shared.unlockVault(of: profile, in: VaultManagerFixture.anchor()) { true }

            #expect(!unlocked)
            #expect(passkeys.assertions.count == before, "no native unlock follows the lock")
            #expect(!vaults[0].manager.isUnlocked && !vaults[1].manager.isUnlocked)
        }
    }

    @Test func aRequestThatEndedWhileTheChoiceWasOpenUnlocksNothing() async throws {
        let passkeys = VaultPasskeys()
        try await VaultManagerFixture.with(passkeys: passkeys, vaults: [.locked, .locked]) { profile, _, vaults in
            let before = passkeys.assertions.count
            var current = true
            let chosen = vaults[0].vaultID
            VaultChoicePrompt.answersForTesting[profile.id] = { _ in
                current = false
                return chosen
            }
            defer { VaultChoicePrompt.answersForTesting[profile.id] = nil }

            let unlocked = await AutofillSuggestions.shared.unlockVault(of: profile, in: VaultManagerFixture.anchor()) { current }

            #expect(!unlocked)
            #expect(passkeys.assertions.count == before)
            #expect(!vaults[0].manager.isUnlocked)
        }
    }

    @Test func aCanceledChoiceUnlocksNothing() async throws {
        try await VaultManagerFixture.with(vaults: [.locked, .locked]) { profile, _, vaults in
            VaultChoicePrompt.answersForTesting[profile.id] = { _ in nil }
            defer { VaultChoicePrompt.answersForTesting[profile.id] = nil }

            let unlocked = await AutofillSuggestions.shared.unlockVault(of: profile, in: VaultManagerFixture.anchor()) { true }

            #expect(!unlocked && !vaults[0].manager.isUnlocked && !vaults[1].manager.isUnlocked)
        }
    }
}
