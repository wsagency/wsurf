// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// A merge is one ordinary commit: the survivor is replaced and the absorbed credentials leave the vault, which moves them to the
// Trash with their history. Test-only in-memory unlock keys; nothing here is evidence of Apple provider behavior.

@MainActor
struct VaultMergeTests {
    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Merge", symbol: "key", color: .blue)
            let passkeys = VaultPasskeys()
            vault = try #require(try await VaultManagerFixture.make(profile: profile, passkeys: passkeys, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        }

        @MainActor func save(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.save(accounts, in: vault)
        }

        @MainActor func accounts() async throws -> [CredentialAccount] {
            try await vault.manager.snapshot().accounts
        }

        @MainActor func revision() async throws -> UInt64 {
            try await vault.manager.snapshot().revision
        }

        @MainActor func cleanup() async {
            pasteboard.releaseGlobally()
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    private func account(
        _ username: String = "ada", _ password: String? = "pw", on origin: String = "https://example.test", id: UUID = UUID()
    ) -> CredentialAccount {
        VaultFixtures.account(id: id, username: username, password: password, origin: origin)
    }

    @Test func mergeMovesTheAbsorbedItemToTrashWithItsHistoryInOneCommit() async throws {
        try await withFixture { f in
            let keeper = account("ada", "keep")
            var absorbed = account("ada", "old")
            try await f.save([keeper, absorbed])
            absorbed.password = "new"
            try await f.save([keeper, absorbed])
            await f.model.load()
            let before = try await f.revision()

            let proposal = try await f.model.mergeProposal(ids: [keeper.id, absorbed.id])
            let receipt = try await f.model.confirmMerge(proposal)

            #expect(receipt.revision == before + 1)
            #expect(try await f.accounts().map(\.id) == [keeper.id])
            let trash = try await f.vault.manager.trashPage(after: nil).items
            #expect(trash.map(\.ownerID) == [absorbed.id])
            #expect(trash.first?.scope == .account)
            #expect(trash.first?.revisionCount == 1)
            #expect(f.model.summaries.map(\.id) == [keeper.id])
            // The survivor stands for the absorbed credential in later imports, as stored.
            #expect(try await f.accounts().first?.mergedFrom?.map(\.accountID) == [absorbed.id])
        }
    }

    @Test func theSurvivorsReplacedPasswordBecomesAMergeRevision() async throws {
        try await withFixture { f in
            let keeper = account("ada", "keep")
            var other = account("ada", "take")
            other.totp = VaultFixtures.totp()
            try await f.save([keeper, other])
            await f.model.load()

            var picks = try #require(CredentialMerge.defaultPicks(for: [keeper, other]))
            picks.survivor = keeper.id
            picks.login = other.id
            picks.code = other.id
            let proposal = try await f.model.mergeProposal(ids: [keeper.id, other.id], picks: picks)
            try await f.model.confirmMerge(proposal)

            let merged = try #require(try await f.accounts().first)
            #expect(merged.password == "take")
            #expect(merged.totp == other.totp)
            let revisions = try await f.vault.manager.revisionPage(accountID: keeper.id, after: nil).items
            #expect(revisions.map(\.subject) == [.password])
            #expect(revisions.first?.cause == "merge")
        }
    }

    @Test func restoringAnAbsorbedItemIsBlockedWhileTheSurvivorHoldsItsLogin() async throws {
        try await withFixture { f in
            let keeper = account("ada", "pw")
            let absorbed = account("ada", "pw")
            try await f.save([keeper, absorbed])
            await f.model.load()
            try await f.model.confirmMerge(try await f.model.mergeProposal(ids: [keeper.id, absorbed.id]))

            let entry = try #require(try await f.vault.manager.trashPage(after: nil).items.first)
            let preview = try await f.vault.manager.previewUndelete(entryID: entry.id)
            #expect(preview.block != nil)
        }
    }

    @Test func aStaleMergeWritesNothing() async throws {
        try await withFixture { f in
            let keeper = account("ada", "pw")
            let absorbed = account("ada", "pw")
            try await f.save([keeper, absorbed])
            await f.model.load()
            let proposal = try await f.model.mergeProposal(ids: [keeper.id, absorbed.id])

            try await f.save([keeper, absorbed, account("bob", "other")])
            let changed = try await f.revision()
            await #expect(throws: CredentialVaultError.staleRevision) { try await f.model.confirmMerge(proposal) }

            #expect(try await f.revision() == changed)
            #expect(try await f.accounts().count == 3)
            #expect(try await f.vault.manager.trashPage(after: nil).items.isEmpty)
        }
    }

    @Test func aMergeAfterALockIsRefused() async throws {
        try await withFixture { f in
            let keeper = account("ada", "pw")
            let absorbed = account("ada", "pw")
            try await f.save([keeper, absorbed])
            await f.model.load()
            let proposal = try await f.model.mergeProposal(ids: [keeper.id, absorbed.id])

            f.vault.manager.lock(reason: .manual)
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.confirmMerge(proposal) }

            try await VaultManagerFixture.unlock(f.vault)
            // The lease that came after the lock is not the one the proposal was read under.
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.confirmMerge(proposal) }
            #expect(try await f.accounts().count == 2)
        }
    }

    @Test func mergeAllIdenticalIsOneCommit() async throws {
        try await withFixture { f in
            var accounts: [CredentialAccount] = []
            for number in 0..<3 {
                accounts.append(account("user\(number)", "pw\(number)", on: "https://site\(number).example.test"))
                accounts.append(account("user\(number)", "pw\(number)", on: "https://site\(number).example.test"))
            }
            let alone = account("alone", "pw", on: "https://alone.example.test")
            accounts.append(alone)
            // The pair on site 1 differs by a second website on another site: not identical.
            accounts[3].origins.append("https://elsewhere.test")
            accounts[3].loginURLs.append(URL(string: "https://elsewhere.test/login")!)
            try await f.save(accounts)
            await f.model.load()
            let before = try await f.revision()

            let result = try await f.model.mergeAllIdentical(revision: before)

            #expect(result == CredentialMergeAllResult(merged: 2, absorbed: 2, skipped: 0))
            #expect(try await f.revision() == before + 1)
            let remaining = try await f.accounts()
            #expect(remaining.count == accounts.count - 2)
            #expect(remaining.contains { $0.id == alone.id })
            // The pair that was not identical is untouched, and no other credential gained its other-site website.
            #expect(remaining.contains { $0.id == accounts[2].id } && remaining.contains { $0.id == accounts[3].id })
            #expect(remaining.filter { $0.origins.contains("https://elsewhere.test") }.map(\.id) == [accounts[3].id])
            #expect(try await f.vault.manager.trashPage(after: nil).items.count == 2)
        }
    }

    @Test func mergeAllIdenticalNeverAddsAnotherSitesWebsite() async throws {
        try await withFixture { f in
            let first = account("ada", "pw", on: "https://example.test")
            var second = account("ada", "pw", on: "https://example.test")
            second.origins.append("https://elsewhere.test")
            try await f.save([first, second])
            await f.model.load()

            let result = try await f.model.mergeAllIdentical(revision: try await f.revision())

            #expect(result.merged == 0)
            #expect(try await f.accounts().count == 2)
        }
    }

    @Test func aGroupOverTheLimitIsSkippedAndTheRestStillMerge() async throws {
        try await withFixture { f in
            var heavy = account("ada", "pw", on: "https://site0.example.test")
            heavy.notes = (0..<CredentialAccount.noteLimit).map { CredentialNote(text: "note \($0)", field: nil) }
            var heavier = account("ada", "pw", on: "https://site0.example.test")
            heavier.notes = [CredentialNote(text: "one more", field: nil)]
            let fine = [account("bob", "pw", on: "https://site1.example.test"), account("bob", "pw", on: "https://site1.example.test")]
            try await f.save([heavy, heavier] + fine)
            await f.model.load()

            let result = try await f.model.mergeAllIdentical(revision: try await f.revision())

            #expect(result == CredentialMergeAllResult(merged: 1, absorbed: 1, skipped: 1))
            #expect(try await f.accounts().count == 3)
        }
    }

    @Test func aMergeOfDifferentPeopleIsRefusedBeforeAnythingIsRead() async throws {
        try await withFixture { f in
            let ada = account("ada")
            let bob = account("bob")
            try await f.save([ada, bob])
            await f.model.load()
            await #expect(throws: CredentialMergeError.usernamesDiffer) { try await f.model.mergeProposal(ids: [ada.id, bob.id]) }
            #expect(try await f.accounts().count == 2)
        }
    }
}
