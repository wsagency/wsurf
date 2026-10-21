// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// A merge keeps every value. The primary's name, login, code and notes win; every other password and verification code, with
// each earlier version of it, is copied into the merged credential's History in the merge's one commit; passkeys (with their
// credential IDs), notes, items and websites are united. Synthetic data and test-only in-memory unlock keys.
@MainActor
struct VaultMergeHistoryTests {
    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Merge History", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, passkeys: VaultPasskeys(), vaults: [.unlocked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        }

        @MainActor func save(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.save(accounts, in: vault)
        }

        @MainActor func accounts() async throws -> [CredentialAccount] {
            try await vault.manager.snapshot().accounts
        }

        @MainActor func history(of id: UUID) async throws -> [RevisionValue] {
            try await vault.manager.revisionValuePage(accountID: id, after: nil).items
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

    private func account(_ password: String?, on origin: String = "https://example.test", username: String = "ada") -> CredentialAccount {
        VaultFixtures.account(username: username, password: password, origin: origin)
    }

    private func code(_ byte: UInt8, issuer: String = "Example") -> TOTPGenerator {
        TOTPGenerator(secret: Data(repeating: byte, count: 10), algorithm: .sha1, period: 30, digits: 6, issuer: issuer, userName: nil)
    }

    private func passwords(_ values: [RevisionValue]) throws -> [String] {
        try values.filter { $0.item.subject == .password }.compactMap { try JSONDecoder().decode(PasswordValue.self, from: $0.value).password }
    }

    private func codes(_ values: [RevisionValue]) throws -> [TOTPGenerator] {
        try values.filter { $0.item.subject == .totp }.map { try JSONDecoder().decode(TOTPGenerator.self, from: $0.value) }
    }

    @Test func thePrimaryWinsAndEveryOtherValueSurvives() async throws {
        try await withFixture { f in
            var primary = account("primary-pw")
            primary.displayName = "Primary"
            primary.totp = code(1)
            primary.notes = [CredentialNote(text: "primary note", field: nil)]
            var second = account("second-old", on: "https://login.example.test")
            second.displayName = "Second"
            second.totp = code(2)
            second.passkeys = [try VaultFixtures.passkey(credentialID: Data(repeating: 7, count: 32))]
            second.secureItems = [SecureItemFixtures.card()]
            var third = account("third-pw", on: "https://elsewhere.test")
            // The primary's code under another label: the same numbers, so it is not kept twice.
            third.totp = code(1, issuer: "Relabelled")
            third.notes = [CredentialNote(text: "third note", field: nil)]
            third.secureItems = [SecureItemFixtures.address()]
            third.passkeys = [try VaultFixtures.passkey(rpID: "elsewhere.test", credentialID: Data(repeating: 8, count: 32))]
            try await f.save([primary, second, third])
            second.password = "second-new"
            try await f.save([primary, second, third])
            await f.model.load()

            let proposal = try await f.model.mergeProposal(ids: [second.id, primary.id, third.id], survivor: primary.id)
            #expect(proposal.preview.passwordsInHistory == 2)
            #expect(proposal.preview.codesInHistory == 1)
            #expect(proposal.picks.extraWebsites == ["https://elsewhere.test"], "a website on another site starts ticked")
            try await f.model.confirmMerge(proposal)

            let remaining = try await f.accounts()
            let merged = try #require(remaining.first)
            #expect(remaining.count == 1)
            #expect(merged.id == primary.id)
            #expect(merged.displayName == "Primary")
            #expect(merged.username == "ada")
            #expect(merged.password == "primary-pw")
            #expect(merged.totp == primary.totp)
            #expect(merged.notes?.map(\.text) == ["primary note", "third note"])
            #expect(merged.passkeys.map(\.id) == second.passkeys.map(\.id) + third.passkeys.map(\.id))
            #expect(merged.passkeys.map(\.credentialID) == second.passkeys.map(\.credentialID) + third.passkeys.map(\.credentialID))
            #expect(merged.secureItems == [SecureItemFixtures.card(), SecureItemFixtures.address()])
            #expect(Set(merged.origins) == ["https://example.test", "https://login.example.test", "https://elsewhere.test"])

            let history = try await f.history(of: primary.id)
            #expect(Set(try passwords(history)) == ["second-old", "second-new", "third-pw"])
            #expect(try codes(history) == [code(2)])
            let kept = history.filter { $0.item.cause == CredentialChangeCause.mergedFrom }
            #expect(Set(try passwords(kept)) == ["second-new", "third-pw"], "the merged-away credentials' current passwords")
            // The earlier version is a copy with its own date and cause (the fixture saved it without one).
            let earlier = try #require(history.first { (try? JSONDecoder().decode(PasswordValue.self, from: $0.value).password) == "second-old" })
            #expect(earlier.item.cause == nil)
            #expect(earlier.item.recordedAt <= (kept.first?.item.recordedAt ?? .distantFuture))
            // The merged-away credentials keep their own history in the Trash, so the copies lose nothing there either.
            let trash = try await f.vault.manager.trashPage(after: nil).items
            #expect(Set(trash.map(\.ownerID)) == [second.id, third.id])
            #expect(trash.first { $0.ownerID == second.id }?.revisionCount == 1)
        }
    }

    @Test func aPasswordOrCodeTheMergedCredentialHoldsIsNotCopiedAgain() async throws {
        try await withFixture { f in
            var primary = account("same")
            primary.totp = code(3)
            var twin = account("same")
            twin.totp = code(3, issuer: "Other label")
            var usernameOnly = account(nil)
            usernameOnly.totp = code(3)
            try await f.save([primary, twin, usernameOnly])
            await f.model.load()

            let proposal = try await f.model.mergeProposal(ids: [primary.id, twin.id, usernameOnly.id], survivor: primary.id)
            #expect(proposal.preview.passwordsInHistory == 0)
            #expect(proposal.preview.codesInHistory == 0)
            try await f.model.confirmMerge(proposal)

            #expect(try await f.history(of: primary.id).isEmpty)
        }
    }

    @Test func thePrimarysOwnReplacedLoginIsNotCopiedTwice() async throws {
        try await withFixture { f in
            // The primary has no password, so the merged login comes from the other credential and the primary's username-only
            // login is superseded by the commit itself: one password row in History, never a second copy of the other's password.
            let primary = account(nil)
            let other = account("taken")
            try await f.save([primary, other])
            await f.model.load()

            try await f.model.confirmMerge(try await f.model.mergeProposal(ids: [primary.id, other.id], survivor: primary.id))

            let merged = try #require(try await f.accounts().first)
            #expect(merged.password == "taken")
            #expect(try passwords(try await f.history(of: primary.id)).isEmpty)
        }
    }

    @Test func undoingAThreeWayMergeReturnsEveryCredentialAsItWas() async throws {
        try await withFixture { f in
            var primary = account("one")
            primary.totp = code(4)
            var second = account("two", on: "https://www.example.test")
            second.passkeys = [try VaultFixtures.passkey(credentialID: Data(repeating: 5, count: 32))]
            var third = account("three", on: "https://login.example.test")
            third.totp = code(6)
            third.secureItems = [SecureItemFixtures.card()]
            try await f.save([primary, second, third])
            await f.model.load()
            let before = try await f.accounts()

            try await f.model.confirmMerge(try await f.model.mergeProposal(ids: [primary.id, second.id, third.id], survivor: primary.id))
            #expect(try await f.accounts().count == 1)
            #expect(f.model.canUndo)

            await f.model.undo()

            let after = try await f.accounts()
            #expect(Set(after.map(\.id)) == Set(before.map(\.id)))
            for original in before {
                let back = try #require(after.first { $0.id == original.id })
                #expect(back.password == original.password)
                #expect(back.totp == original.totp)
                #expect(back.passkeys.map(\.credentialID) == original.passkeys.map(\.credentialID))
                #expect(back.secureItems == original.secureItems)
                #expect(back.origins == original.origins)
                #expect(back.mergedFrom == nil)
            }
            #expect(try await f.vault.manager.trashPage(after: nil).items.isEmpty, "no passkey, code or item is left behind in the Trash")

            // Merging again copies nothing a second time: the History already holds those values.
            let held = try await f.history(of: primary.id).filter { $0.item.subject == .password || $0.item.subject == .totp }.count
            try await f.model.confirmMerge(try await f.model.mergeProposal(ids: [primary.id, second.id, third.id], survivor: primary.id))
            let again = try await f.history(of: primary.id).filter { $0.item.subject == .password || $0.item.subject == .totp }.count
            #expect(again == held)
        }
    }

    @Test func twoMergedAwayCredentialsNeverShowAsOneVersion() async throws {
        try await withFixture { f in
            let primary = account("primary-pw")
            // Ids that sort A before B, the order in which A's code would otherwise sit right after B's password in History.
            var withCode = account("a-pw")
            withCode.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
            withCode.totp = code(9)
            var passwordOnly = account("b-pw")
            passwordOnly.id = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000B"))
            try await f.save([primary, withCode, passwordOnly])
            await f.model.load()

            try await f.model.confirmMerge(
                try await f.model.mergeProposal(ids: [primary.id, withCode.id, passwordOnly.id], survivor: primary.id)
            )

            let current = try #require(try await f.accounts().first)
            let versions = try CredentialHistory.versions(current: current, revisions: try await f.history(of: primary.id))
            let kept = versions.filter { $0.cause == CredentialChangeCause.mergedFrom }
            #expect(kept.count == 2, "one version per merged-away credential")
            let both = try #require(kept.first { $0.changed == [.password, .totp] })
            #expect(both.account.password == "a-pw" && both.account.totp == code(9))
            let alone = try #require(kept.first { $0.changed == [.password] })
            #expect(alone.account.password == "b-pw")
        }
    }

    @Test func mergeAllIdenticalTurnsNumberedCopiesIntoOneLogin() async throws {
        try await withFixture { f in
            let copies = [account("pw", username: "ada@example.test")] + (1...3).map { account("pw", username: "ada@example.test (\($0))") }
            let other = account("pw", on: "https://unrelated.test", username: "ada@example.test (4)")
            try await f.save(copies + [other])
            await f.model.load()

            let result = try await f.model.mergeAllIdentical(revision: try await f.vault.manager.snapshot().revision)

            #expect(result == CredentialMergeAllResult(merged: 1, absorbed: 3, skipped: 0))
            let remaining = try await f.accounts()
            #expect(remaining.count == 2, "the copy on another site is not merged")
            let merged = try #require(remaining.first { $0.id != other.id })
            #expect(merged.username == "ada@example.test")
            #expect(merged.password == "pw")
        }
    }

    @Test func aMergeMapThatNamesALiveAccountWritesNothing() async throws {
        try await withFixture { f in
            let primary = account("one")
            let other = account("two")
            try await f.save([primary, other])
            let epoch = try #require(f.vault.manager.authorizationEpoch)
            let revision = try await f.vault.manager.snapshot().revision

            // `other` stays live, so it was not merged away: the store refuses the map rather than copying its values.
            var changed = primary
            changed.password = "changed"
            await #expect(throws: CredentialVaultError.invalidData) {
                try await f.vault.manager.commit(
                    [changed, other], expectedRevision: revision, authorizedEpoch: epoch, cause: "merge", merging: [other.id: primary.id]
                )
            }
            #expect(try await f.vault.manager.snapshot().revision == revision)
        }
    }
}
