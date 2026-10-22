// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The Statistics section's two vault-wide counts, against a real fixture vault: the Trash entries and the earlier versions the vault
// keeps. The other rows come from the summaries (`CredentialListFilterTests`). Synthetic data only.

@MainActor
struct CredentialSettingsStatisticsTests {
    @Test func statisticsMatchTheVaultAndItsTrash() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let vault = try #require(vaults.first)
            let kept = VaultFixtures.account(username: "user1@example.test", password: "pw-one", origin: "https://one.example.test")
            let removed = VaultFixtures.account(username: "user2@example.test", password: "pw-two", origin: "https://two.example.test")
            try await VaultManagerFixture.save([kept, removed], in: vault)
            let model = CredentialSettingsModel(profile: profile, manager: vault.manager)
            await model.load()

            // Nothing is claimed before the counts are read.
            #expect(model.trashTotal == nil && model.earlierVersionCount == nil)
            try await model.loadStatistics()
            #expect(model.trashTotal == 0 && model.earlierVersionCount == 0)
            #expect(CredentialStatistics(model.summaries).credentials == 2)

            // A new password keeps the old one as an earlier version; a credential that is gone is in Trash.
            var changed = kept
            changed.password = "pw-one-changed"
            try await VaultManagerFixture.save([changed], in: vault)
            await model.load()
            try await model.loadStatistics()
            #expect(model.trashTotal == 1)
            #expect(model.earlierVersionCount == 1)
            #expect(CredentialStatistics(model.summaries).credentials == 1)
        }
    }

    @Test func lockingDropsTheCountsAndTheyCannotBeReadLocked() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let vault = try #require(vaults.first)
            try await VaultManagerFixture.save([VaultFixtures.account()], in: vault)
            let model = CredentialSettingsModel(profile: profile, manager: vault.manager)
            await model.load()
            try await model.loadStatistics()
            #expect(model.trashTotal == 0)

            vault.manager.lock(reason: .manual)
            #expect(model.trashTotal == nil && model.earlierVersionCount == nil)
            await #expect(throws: CredentialVaultError.self) { try await model.loadStatistics() }
        }
    }
}
