// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// "Not the Same" on a merge suggestion, and the suggestions sheet keeping its place. The choice is vault data of the entries
// (`CredentialAccount.notSameAs`), keyed on their ids. Synthetic credentials, test-only in-memory unlock keys, a private pasteboard.

@MainActor
struct CredentialNotTheSameTests {
    private func login(_ username: String = "root", _ password: String = "pw", on host: String = "dev5.example.test") -> CredentialAccount {
        VaultFixtures.account(username: username, password: password, origin: "https://\(host)")
    }

    private func apart(_ accounts: inout [CredentialAccount], _ lhs: Int, _ rhs: Int) {
        accounts[lhs].notSameAs = ((accounts[lhs].notSameAs ?? []) + [accounts[rhs].id])
        accounts[rhs].notSameAs = ((accounts[rhs].notSameAs ?? []) + [accounts[lhs].id])
    }

    private func index(_ accounts: [CredentialAccount]) -> CredentialMergeIndex {
        CredentialMergeSuggestions.index(for: accounts, revision: 1)
    }

    // MARK: The rule

    @Test func aDismissedPairIsNeverSuggestedAgainWhateverIsEdited() {
        var accounts = [login(), login()]
        #expect(index(accounts).suggestions.count == 1)
        apart(&accounts, 0, 1)
        #expect(index(accounts).suggestions.isEmpty)
        #expect(index(accounts).dismissed == [accounts.map(\.id)])
        // Keyed on the entries, not on what they hold: a new password, name or an extra address changes nothing.
        accounts[0].password = "changed"
        accounts[1].displayName = "Renamed"
        accounts[1].origins.append("https://www.dev5.example.test")
        #expect(index(accounts).suggestions.isEmpty)
        // Either entry alone remembers it (a write that reached only one of them).
        accounts[1].notSameAs = nil
        #expect(index(accounts).suggestions.isEmpty)
        #expect(index(accounts).dismissed == [accounts.map(\.id)])
    }

    @Test func aThirdEntryThatJoinsShowsOnlyTheNewPair() {
        var accounts = [login(), login()]
        apart(&accounts, 0, 1)
        accounts.append(login())
        let found = index(accounts)
        #expect(found.suggestions.map(\.ids) == [[accounts[0].id, accounts[2].id]])
        #expect(found.dismissed == [[accounts[0].id, accounts[1].id]])
        // Once that pair is dismissed too, the last one is the pair that was never dismissed.
        apart(&accounts, 0, 2)
        #expect(index(accounts).suggestions.map(\.ids) == [[accounts[1].id, accounts[2].id]])
        #expect(index(accounts).dismissed == [accounts.map(\.id)])
        // A Merge All Identical never takes a dismissed pair either.
        apart(&accounts, 1, 2)
        #expect(index(accounts).identical.isEmpty)
    }

    @Test func aDismissalOutlivesAMergeOfEitherEntry() {
        var accounts = [login(), login(), login()]
        apart(&accounts, 0, 1)
        // The first is merged into the third: its id is now one of the third's merged items, and the second still names it.
        var survivor = accounts[2]
        survivor.mergedFrom = [MergedItemLink(accountID: accounts[0].id, exchangeAccountID: Data([1]), exchangeItemID: Data([2]))]
        let left = [accounts[1], survivor]
        #expect(index(left).suggestions.isEmpty)
        #expect(index(left).dismissed == [[accounts[1].id, survivor.id]])
    }

    @Test func aDismissalOfAnEntryInTheTrashNamesNobody() {
        var accounts = [login(), login(), login()]
        apart(&accounts, 0, 1)
        let left = [accounts[0], accounts[2]]
        #expect(index(left).dismissed.isEmpty)
        #expect(index(left).suggestions.map(\.ids) == [left.map(\.id)])
    }

    @Test func theVaultRefusesAMalformedList() {
        var account = login()
        account.notSameAs = []
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        account.notSameAs = [account.id]
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        let other = UUID()
        account.notSameAs = [other, other]
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        account.notSameAs = (0...CredentialAccount.notSameAsLimit).map { _ in UUID() }
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        account.notSameAs = [other]
        #expect(throws: Never.self) { try account.validate() }
    }

    // MARK: Keeping the sheet's place

    /// Three suggestions on three websites, in vault order.
    private func threeSuggestions() -> (accounts: [CredentialAccount], ids: [Set<UUID>]) {
        let accounts = ["a", "b", "c"].flatMap { site in [login(on: "\(site).example.test"), login(on: "\(site).example.test")] }
        return (accounts, stride(from: 0, to: 6, by: 2).map { [accounts[$0].id, accounts[$0 + 1].id] })
    }

    /// What a merge of the suggestion at `position` leaves: its first credential, the survivor, alone on its website.
    private func merging(_ position: Int, in accounts: [CredentialAccount]) -> [CredentialAccount] {
        accounts.enumerated().filter { $0.offset != position * 2 + 1 }.map(\.element)
    }

    @Test func afterAMergeTheNextSuggestionIsSelectedAndTheListStaysWhereItWas() {
        let (accounts, ids) = threeSuggestions()
        let state = CredentialMergeState()
        state.show(index(accounts), summaries: accounts.map(CredentialSummary.init))
        #expect(state.shown == ids)
        state.focus = ids[1]
        state.scrollAnchor = ids[0]

        let after = merging(1, in: accounts)
        state.show(index(after), summaries: after.map(CredentialSummary.init))
        #expect(state.shown == [ids[0], ids[2]])
        #expect(state.focus == ids[2], "the one after the merged one, by identity")
        #expect(state.scrollAnchor == ids[0], "the top of the list is kept")
    }

    @Test func afterMergingTheLastSuggestionTheOneBeforeItIsSelected() {
        let (accounts, ids) = threeSuggestions()
        let state = CredentialMergeState()
        state.show(index(accounts), summaries: accounts.map(CredentialSummary.init))
        state.focus = ids[2]
        state.scrollAnchor = ids[2]

        let after = merging(2, in: accounts)
        state.show(index(after), summaries: after.map(CredentialSummary.init))
        #expect(state.focus == ids[1])
        #expect(state.scrollAnchor == ids[1], "a top row that was merged moves to its neighbour, not to the start")
    }

    @Test func aSuggestionStillThereKeepsTheSelectionWhateverMovesAroundIt() {
        let (accounts, ids) = threeSuggestions()
        let state = CredentialMergeState()
        state.show(index(accounts), summaries: accounts.map(CredentialSummary.init))
        state.focus = ids[2]
        let after = merging(0, in: accounts)
        state.show(index(after), summaries: after.map(CredentialSummary.init))
        #expect(state.focus == ids[2], "not the one now at its index")
        #expect(CredentialMergeState.kept(ids[1], from: ids, in: []) == nil)
    }

    // MARK: The model and the vault

    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Not the same", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        }

        @MainActor func seed(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.save(accounts, in: vault)
            await model.load()
        }

        @MainActor func stored() async throws -> [UUID: CredentialAccount] {
            Dictionary(uniqueKeysWithValues: try await vault.manager.snapshot().accounts.map { ($0.id, $0) })
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

    @Test func notTheSameIsKeptInTheVaultThroughAReloadAndARelaunch() async throws {
        try await withFixture { f in
            let pair = [login(), login()]
            try await f.seed(pair)
            #expect(try await f.model.mergeSuggestions().suggestions.map(\.id) == [Set(pair.map(\.id))])
            let counts = try await f.vault.manager.historyCounts()

            try await f.model.markNotTheSame(pair.map(\.id))

            #expect(try await f.model.mergeSuggestions().suggestions.isEmpty)
            #expect(try await f.model.mergeSuggestions().dismissed.map(\.members) == [Set(pair.map(\.id))])
            let stored = try await f.stored()
            #expect(stored[pair[0].id]?.notSameAs == [pair[1].id] && stored[pair[1].id]?.notSameAs == [pair[0].id])
            #expect(stored[pair[0].id]?.password == "pw", "nothing else changed")
            #expect(try await f.vault.manager.historyCounts() == counts, "no History version, nothing in Trash")

            // Read again from the sealed rows after a lock, as at the next launch.
            f.vault.manager.lock(reason: .manual)
            try await VaultManagerFixture.unlock(f.vault)
            let relaunched = CredentialSettingsModel(
                profile: f.profile, pasteboard: NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)")),
                manager: f.vault.manager
            )
            await relaunched.load()
            #expect(try await relaunched.mergeSuggestions().suggestions.isEmpty)
            #expect(try await relaunched.mergeSuggestions().dismissed.map(\.members) == [Set(pair.map(\.id))])
        }
    }

    @Test func suggestAgainBringsTheSuggestionBackAndBothAreOneUndoStep() async throws {
        try await withFixture { f in
            let pair = [login(), login()]
            try await f.seed(pair)
            try await f.model.markNotTheSame(pair.map(\.id))
            #expect(f.model.live?.undoSteps.map(\.kind) == [.notTheSame])

            // A write may move the entries in the vault's order: a suggestion is its members, in any order.
            await f.model.undo()
            #expect(try await f.model.mergeSuggestions().suggestions.map(\.id) == [Set(pair.map(\.id))])
            await f.model.redo()
            #expect(try await f.model.mergeSuggestions().suggestions.isEmpty)

            try await f.model.suggestAgain(pair.map(\.id))
            #expect(try await f.model.mergeSuggestions().suggestions.map(\.id) == [Set(pair.map(\.id))])
            #expect(try await f.model.mergeSuggestions().dismissed.isEmpty)
            #expect(try await f.stored().values.allSatisfy { $0.notSameAs == nil })
            #expect(f.model.live?.undoSteps.last?.kind == .suggestAgain)
        }
    }

    @Test func aThirdEntryAddedLaterIsSuggestedWithOnlyOneOfThePair() async throws {
        try await withFixture { f in
            let pair = [login(), login()]
            try await f.seed(pair)
            try await f.model.markNotTheSame(pair.map(\.id))
            let third = login()
            _ = try await f.model.save(third, expectedRevision: f.model.revision)

            let found = try await f.model.mergeSuggestions()
            #expect(found.suggestions.map(\.id) == [[pair[0].id, third.id]] || found.suggestions.map(\.id) == [[pair[1].id, third.id]])
            #expect(found.dismissed.map(\.members) == [Set(pair.map(\.id))])
        }
    }
}
