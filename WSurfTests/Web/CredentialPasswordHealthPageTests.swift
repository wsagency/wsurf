// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// Password health on the Credentials page (S4b): the flags the vault's report puts on the list's summaries, the Weak and Reused
// chips, the editor's note, and when the page asks for a report. Test-only in-memory unlock keys and synthetic passwords; nothing here
// touches a real vault, the Keychain or a native ceremony, and no check prints a password.

@MainActor
struct CredentialPasswordHealthPageTests {
    private static let shared = "Kx9!vQ2#mW7p"

    private func login(_ password: String?, at origin: String) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: "ada", displayName: nil, origins: [origin], loginURLs: [URL(string: "\(origin)/login")!],
            password: password, passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    /// A weak password, one password saved for two websites, and a strong one.
    private func accounts() -> [CredentialAccount] {
        [
            login("123456Xy", at: "https://example.net"), login(Self.shared, at: "https://example.com"),
            login(Self.shared, at: "https://example.org"), login("Zt4$pL8@nR2w", at: "https://example.edu"),
        ]
    }

    private func snapshot(_ accounts: [CredentialAccount], revision: UInt64) -> StoreSnapshot {
        StoreSnapshot(vaultID: UUID(), revision: revision, accounts: accounts, blockedPasswordOrigins: [], stamps: [:])
    }

    private func report(_ accounts: [CredentialAccount], revision: UInt64) -> PasswordHealthReport {
        PasswordHealth.report(vaultID: UUID(), revision: revision, accounts: accounts)
    }

    private func flagged(_ summaries: [CredentialSummary]) -> [UUID] {
        summaries.filter { $0.health != nil }.map(\.id)
    }

    // MARK: - Summaries, the session and the chips

    @Test func aSummaryWithHealthFlagsDiffersFromOneWithout() {
        let summary = CredentialSummary(login("123456Xy", at: "https://example.net"))
        var marked = summary
        marked.health = PasswordHealthFinding(reuse: nil, weaknesses: [.pattern])
        #expect(summary != marked)
        #expect(marked == marked)
    }

    /// A report lands only on the revision it describes, stays while that revision is read again, and goes with the next one.
    @Test func aReportFlagsOnlyTheRevisionItDescribes() {
        let all = accounts()
        let expected = [all[0].id, all[1].id, all[2].id]
        var session = CredentialVaultSession(epoch: 1, snapshot: snapshot(all, revision: 4))
        session.applyHealth(report(all, revision: 3))
        #expect(session.healthRevision == nil && flagged(session.summaries).isEmpty)

        session.applyHealth(report(all, revision: 4))
        #expect(session.healthRevision == 4 && flagged(session.summaries) == expected)

        session.refresh(snapshot(all, revision: 4))
        #expect(flagged(session.summaries) == expected, "read again at the same revision, the flags stay")
        session.committed(all, revision: 5)
        #expect(session.healthRevision == nil && flagged(session.summaries).isEmpty, "a write drops them")
        session.applyHealth(report(all, revision: 5))
        session.refresh(snapshot(all, revision: 6))
        #expect(session.healthRevision == nil && flagged(session.summaries).isEmpty, "so does a newer read")
    }

    @Test func theWeakAndReusedChipsShowOnlyWhileACredentialIsFlagged() {
        let all = accounts()
        var session = CredentialVaultSession(epoch: 1, snapshot: snapshot(all, revision: 1))
        let unflagged = CredentialListFilter.chips(counts: CredentialListFilter.counts(session.summaries), selected: .all)
        #expect(!unflagged.contains(.weak) && !unflagged.contains(.reused))
        #expect(CredentialListFilter.chips(counts: nil, selected: .weak).contains(.weak), "the filter in use keeps its chip")

        session.applyHealth(report(all, revision: 1))
        let summaries = session.summaries
        let counts = CredentialListFilter.counts(summaries)
        #expect(counts[.weak] == 1 && counts[.reused] == 2)
        #expect(CredentialListFilter.chips(counts: counts, selected: .all).suffix(2) == [.weak, .reused])
        #expect(CredentialListFilter.visible(summaries, query: "", filter: .weak).map(\.id) == [all[0].id])
        #expect(CredentialListFilter.visible(summaries, query: "", filter: .reused).map(\.id) == [all[1].id, all[2].id])
    }

    // MARK: - The editor's note

    @Test func theNoteNamesEachRuleAndTheOtherCredentials() {
        let weak = CredentialHealthNote.weakness([.pattern, .short])
        #expect(weak.contains(String(localized: "it is shorter than 8 characters")))
        #expect(weak.contains(String(localized: "most of it is a pattern, such as 123456 or qwerty")))
        #expect(!weak.contains(String(localized: "it is only digits, or letters of one case")))

        let group = UUID()
        #expect(CredentialHealthNote.reuse(PasswordReuse(group: group, otherSites: 1), sharedWith: [])
            == String(localized: "The same password is saved for one other website."))
        let two = CredentialHealthNote.reuse(PasswordReuse(group: group, otherSites: 2), sharedWith: ["Alpha", "Bravo"])
        #expect(two.hasPrefix(String(localized: "The same password is saved for \(2) other websites.")))
        #expect(two.contains("Alpha") && two.contains("Bravo"))

        let five = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
        let named = CredentialHealthNote.reuse(PasswordReuse(group: group, otherSites: 5), sharedWith: five)
        #expect(named.contains("Charlie") && !named.contains("Delta") && !named.contains("Echo"), "three by name")
        #expect(named.contains(String(localized: "\(2) more")))
    }

    // MARK: - Through the page

    /// Stands in for Touch ID: records each reason, refuses while `refuses` is set, and runs `whileAsking` once, as if while the
    /// prompt is up.
    @MainActor
    private final class Prompts {
        private(set) var reasons: [String] = []
        var refuses = false
        var whileAsking: (@MainActor () -> Void)?

        func verify(_ reason: String) async throws {
            reasons.append(reason)
            if let action = whileAsking {
                whileAsking = nil
                action()
            }
            if refuses {
                throw WebsiteAuthenticatorError.notAllowed
            }
        }
    }

    private static let reason = String(localized: "show weak and reused passwords")

    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let prompts: Prompts
        let model: CredentialSettingsModel
        let audit = VaultReadAudit()

        @MainActor init(healthDelay: Duration) async throws {
            let profile = Profile(id: UUID(), name: "Password health", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            let prompts = Prompts()
            self.prompts = prompts
            model = CredentialSettingsModel(
                profile: profile, manager: vault.manager, verifyUser: { reason in try await prompts.verify(reason) }, healthDelay: healthDelay
            )
            CredentialManager.readAuditsForTesting[profile.id] = audit
        }

        @MainActor var healthReads: Int {
            audit.reads.filter { $0 == .health }.count
        }

        @MainActor func cleanup() async {
            CredentialManager.readAuditsForTesting[profile.id] = nil
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(healthDelay: Duration = .milliseconds(10), _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture(healthDelay: healthDelay)
        do {
            try await body(fixture)
        } catch {
            await fixture.cleanup()
            throw error
        }
        await fixture.cleanup()
    }

    /// Until Show Password Health passes its prompt, the page reads no report and flags nothing, however the list changes.
    @Test func nothingIsReadOrShownBeforeShowPasswordHealth() async throws {
        try await withFixture { f in
            var all = accounts()
            try await VaultManagerFixture.save(all, in: f.vault)
            await f.model.load()
            all[3].password = "Zt4$pL8"
            _ = try await f.model.save(all[3], expectedRevision: f.model.revision)

            #expect(!f.model.showsHealth && f.model.healthTask == nil, "no report was asked for")
            #expect(f.healthReads == 0 && flagged(f.model.summaries).isEmpty)
            #expect(f.prompts.reasons.isEmpty)
        }
    }

    /// Show Password Health asks once per unlock, reads nothing while its prompt is up, and then flags the list: the rows, the chips'
    /// counts and the credentials that share a password.
    @Test func showPasswordHealthAsksOnceThenFlagsTheList() async throws {
        try await withFixture { f in
            let all = accounts()
            try await VaultManagerFixture.save(all, in: f.vault)
            await f.model.load()
            var whileAsked: Int?
            f.prompts.whileAsking = { whileAsked = f.healthReads }

            try await f.model.revealHealth()
            #expect(f.prompts.reasons == [Self.reason])
            #expect(whileAsked == 0, "nothing was read while the prompt was up")
            #expect(f.model.showsHealth)
            #expect(await waitUntil { f.model.healthRevision == f.model.revision })
            #expect(Set(flagged(f.model.summaries)) == [all[0].id, all[1].id, all[2].id])
            #expect(f.healthReads == 1)
            let shared = try #require(f.model.summaries.first { $0.id == all[1].id })
            #expect(f.model.sharingPassword(with: shared).map(\.id) == [all[2].id])
            let strong = try #require(f.model.summaries.first { $0.id == all[3].id })
            #expect(f.model.sharingPassword(with: strong).isEmpty)

            try await f.model.revealHealth()
            #expect(f.prompts.reasons.count == 1, "one prompt per unlock")
        }
    }

    @Test func aRefusedPromptReadsAndShowsNothing() async throws {
        try await withFixture { f in
            try await VaultManagerFixture.save(accounts(), in: f.vault)
            await f.model.load()
            f.prompts.refuses = true

            await #expect(throws: WebsiteAuthenticatorError.self) { try await f.model.revealHealth() }
            #expect(!f.model.showsHealth && f.model.healthTask == nil)
            #expect(f.healthReads == 0 && flagged(f.model.summaries).isEmpty)
            #expect(!f.model.isRevealingHealth)
        }
    }

    /// A lock drops the flags with the session. The next unlock shows none and reads nothing until Show Password Health asks again.
    @Test func aLockDropsTheFlagsAndTheNextUnlockAsksAgain() async throws {
        try await withFixture { f in
            let all = accounts()
            try await VaultManagerFixture.save(all, in: f.vault)
            await f.model.load()
            try await f.model.revealHealth()
            #expect(await waitUntil { f.model.healthRevision == f.model.revision })

            f.model.lock()
            #expect(f.model.summaries.isEmpty && f.model.healthRevision == nil && !f.model.showsHealth)

            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()
            #expect(!f.model.showsHealth && flagged(f.model.summaries).isEmpty)
            #expect(f.healthReads == 1, "the new unlock read nothing")

            try await f.model.revealHealth()
            #expect(f.prompts.reasons == [Self.reason, Self.reason])
            #expect(await waitUntil { f.model.healthRevision == f.model.revision })
            #expect(Set(flagged(f.model.summaries)) == [all[0].id, all[1].id, all[2].id])
            #expect(f.healthReads == 2)
        }
    }

    /// After the prompt, a write while the page waits to ask replaces the request: it asks once, for the newest revision, and the
    /// flags describe it.
    @Test func aWriteWhileThePageWaitsAsksOnceForTheNewerRevision() async throws {
        try await withFixture(healthDelay: .seconds(1)) { f in
            var all = accounts()
            try await VaultManagerFixture.save(all, in: f.vault)
            await f.model.load()
            try await f.model.revealHealth()
            #expect(await waitUntil { f.model.healthRevision == f.model.revision }, "the first report is read at once")
            #expect(f.healthReads == 1)

            all[3].password = "Zt4$pL8x"
            _ = try await f.model.save(all[3], expectedRevision: f.model.revision)
            all[3].password = "Zt4$pL8"
            _ = try await f.model.save(all[3], expectedRevision: f.model.revision)
            #expect(await waitUntil { f.model.healthRevision == f.model.revision })
            #expect(f.healthReads == 2, "one more read, for the newest revision")
            let shortened = try #require(f.model.summaries.first { $0.id == all[3].id })
            #expect(shortened.health?.weaknesses == [.short])
        }
    }
}
