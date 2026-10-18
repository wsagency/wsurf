// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Synchronization
import Testing

@testable import WSurf

/// What the export sheet does with a selection after the vault moved under it: it names what changed or vanished, keeps what is
/// still valid, and the retry sends exactly the reconciled selection.
@MainActor
struct CredentialExportReviewTests {
    private let base = CredentialExchangeCoordinatorTests()

    private func account(_ name: String, password: String? = "pw") -> CredentialAccount {
        var account = base.account(username: name, password: password)
        account.displayName = name
        return account
    }

    private func choose(_ account: CredentialAccount, password: Bool = true) -> [UUID: CredentialExportSelection] {
        [account.id: CredentialExportSelection(accountID: account.id, password: password, passkeyIDs: [], totp: false)]
    }

    /// The comparison the sheet makes when the page cannot vouch for stamps: summaries alone.
    private func summaryOnly(
        selection: [UUID: CredentialExportSelection], shown: [CredentialSummary], fresh: [CredentialSummary]
    ) -> CredentialExportReview {
        CredentialExportReview.reconcile(
            selection: selection, shown: shown, fresh: fresh, shownStamps: [:], freshStamps: nil
        )
    }

    @Test func anUnchangedVaultKeepsTheSelectionAndReportsNothing() {
        let kept = account("kept")
        let shown = [CredentialSummary(kept)]
        let review = summaryOnly(selection: choose(kept), shown: shown, fresh: shown)
        #expect(review.isEmpty && review.selection[kept.id]?.password == true)
    }

    @Test func aDeletedSelectionIsNamedAndDroppedButAnUnselectedOneIsNotReported() {
        let gone = account("gone")
        let other = account("other")
        let review = summaryOnly(
            selection: choose(gone), shown: [CredentialSummary(gone), CredentialSummary(other)], fresh: []
        )
        #expect(review.deleted == ["gone"] && review.changed.isEmpty && review.selection.isEmpty)
    }

    @Test func aRenamedSelectionKeepsItsPartsAndIsNamedAsItIsNow() {
        let before = account("before")
        var after = before
        after.displayName = "after"
        let review = summaryOnly(
            selection: choose(before), shown: [CredentialSummary(before)], fresh: [CredentialSummary(after)]
        )
        #expect(review.changed == ["after"] && review.deleted.isEmpty && review.selection[before.id]?.password == true)
    }

    @Test func aPartThatNoLongerExistsIsDroppedAndTheCredentialIsNamed() {
        let before = account("login")
        var after = before
        after.password = nil
        after.username = ""
        let review = summaryOnly(
            selection: choose(before), shown: [CredentialSummary(before)], fresh: [CredentialSummary(after)]
        )
        #expect(review.changed == ["login"] && review.selection.isEmpty)
    }

    @Test func aSelectedNotesPartThatNoLongerExistsIsDroppedAndTheCredentialIsNamed() {
        var before = account("memo")
        before.notes = [CredentialNote(text: "kept", field: nil)]
        var after = before
        after.notes = nil
        let selection = [before.id: CredentialExportSelection(accountID: before.id, password: true, passkeyIDs: [], totp: false, notes: true)]
        let review = summaryOnly(selection: selection, shown: [CredentialSummary(before)], fresh: [CredentialSummary(after)])

        #expect(review.changed == ["memo"])
        #expect(review.selection[before.id]?.password == true && review.selection[before.id]?.notes == false)

        // Notes alone are a selection; without them nothing is left to send.
        let onlyNotes = [before.id: CredentialExportSelection(accountID: before.id, password: false, passkeyIDs: [], totp: false, notes: true)]
        #expect(onlyNotes[before.id]?.hasParts == true)
        let gone = summaryOnly(selection: onlyNotes, shown: [CredentialSummary(before)], fresh: [CredentialSummary(after)])
        #expect(gone.selection.isEmpty && gone.changed == ["memo"])
    }

    @Test func theRetryOfAReconciledSelectionSendsOnlyWhatSurvived() async throws {
        try await base.withFixture { f in
            let gone = account("gone")
            let renamed = account("renamed")
            try await f.seed([gone, renamed])
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            await model.load()
            let epoch = try #require(f.manager.authorizationEpoch)
            let shown = model.summaries
            let shownStamps = try #require(model.exportStamps)
            let sends = Mutex(0)
            f.coordinator.requestSystemExport = { _ in
                CredentialExchangeCoordinator.SystemExport(format: .v1, send: { _ in sends.withLock { $0 += 1 } })
            }
            let selection = choose(gone).merging(choose(renamed)) { first, _ in first }

            // Another writer deletes one chosen credential and renames the other.
            var accounts = try await f.stored().accounts.filter { $0.id != gone.id }
            accounts[accounts.firstIndex { $0.id == renamed.id }!].displayName = "renamed elsewhere"
            _ = try await f.manager.commit(accounts, expectedRevision: model.revision, authorizedEpoch: epoch)

            let refused = await model.exportCredentials(selection: Array(selection.values), epoch: epoch, in: NSWindow())
            #expect(refused == nil && sends.withLock { $0 } == 0)
            #expect(model.transferMessage?.kind == .exportSelectionChanged)

            let review = CredentialExportReview.reconcile(
                selection: selection, shown: shown, fresh: model.summaries,
                shownStamps: shownStamps, freshStamps: model.exportStamps
            )
            #expect(review.deleted == ["gone"] && review.changed == ["renamed elsewhere"])
            #expect(Set(review.selection.keys) == [renamed.id])

            let retry = await model.exportCredentials(selection: Array(review.selection.values), epoch: epoch, in: NSWindow())
            #expect(retry == .transferred && sends.withLock { $0 } == 1)
        }
    }

    /// A password, TOTP seed or passkey key changed elsewhere moves no summary, but it moves the account's stamp.
    @Test func aSecretOnlyChangeIsNamedAndNothingIsSentUntilTheUserClicksAgain() async throws {
        try await base.withFixture { f in
            let login = account("login", password: "before")
            try await f.seed([login])
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            await model.load()
            let epoch = try #require(f.manager.authorizationEpoch)
            let shown = model.summaries
            let shownStamps = try #require(model.exportStamps)
            let sends = Mutex(0)
            f.coordinator.requestSystemExport = { _ in
                CredentialExchangeCoordinator.SystemExport(format: .v1, send: { _ in sends.withLock { $0 += 1 } })
            }
            let selection = choose(login)

            var accounts = try await f.stored().accounts
            accounts[0].password = "after"
            _ = try await f.manager.commit(accounts, expectedRevision: model.revision, authorizedEpoch: epoch)

            let refused = await model.exportCredentials(selection: Array(selection.values), epoch: epoch, in: NSWindow())
            #expect(refused == nil && sends.withLock { $0 } == 0)
            #expect(model.transferMessage?.kind == .exportSelectionChanged)
            #expect(model.summaries == shown)
            #expect(model.exportStamps != shownStamps)

            #expect(summaryOnly(selection: selection, shown: shown, fresh: model.summaries).isEmpty)
            let review = CredentialExportReview.reconcile(
                selection: selection, shown: shown, fresh: model.summaries,
                shownStamps: shownStamps, freshStamps: model.exportStamps
            )
            #expect(review.changed == ["login"] && review.deleted.isEmpty && review.selection[login.id]?.password == true)
            #expect(sends.withLock { $0 } == 0)

            let retry = await model.exportCredentials(selection: Array(review.selection.values), epoch: epoch, in: NSWindow())
            #expect(retry == .transferred && sends.withLock { $0 } == 1)
        }
    }

    @Test func aChangeToAnUnselectedAccountIsNotReportedAndStampsAfterThisPagesOwnWriteAreUnknown() async throws {
        try await base.withFixture { f in
            let chosen = account("chosen", password: "one")
            let other = account("other", password: "two")
            try await f.seed([chosen, other])
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            await model.load()
            let epoch = try #require(f.manager.authorizationEpoch)
            let shown = model.summaries
            let shownStamps = try #require(model.exportStamps)

            var accounts = try await f.stored().accounts
            accounts[accounts.firstIndex { $0.id == other.id }!].password = "changed"
            _ = try await f.manager.commit(accounts, expectedRevision: model.revision, authorizedEpoch: epoch)
            await model.load()
            let review = CredentialExportReview.reconcile(
                selection: choose(chosen), shown: shown, fresh: model.summaries,
                shownStamps: shownStamps, freshStamps: model.exportStamps
            )
            #expect(review.isEmpty && review.selection[chosen.id]?.password == true)

            var edited = accounts[accounts.firstIndex { $0.id == chosen.id }!]
            edited.displayName = "edited here"
            _ = try await model.save(edited, expectedRevision: model.revision)
            #expect(model.exportStamps == nil)
        }
    }

    // MARK: A credential as one unit

    /// A login with two passkeys, a verification code and notes: four kinds of part.
    private func whole(_ name: String) throws -> CredentialAccount {
        var whole = account(name)
        whole.passkeys = [
            try VaultFixtures.passkey(credentialID: Data(repeating: 1, count: 32)),
            try VaultFixtures.passkey(credentialID: Data(repeating: 2, count: 32)),
        ]
        whole.totp = VaultFixtures.totp()
        whole.notes = [CredentialNote(text: "note", field: nil)]
        return whole
    }

    @Test func selectingAnItemSelectsEveryPart() throws {
        let item = try whole("item")
        let summary = CredentialSummary(item)
        let selection = CredentialExportSelection(allOf: summary)
        #expect(selection.password && selection.totp && selection.notes)
        #expect(selection.passkeyIDs == Set(item.passkeys.map(\.id)))
        #expect(selection.parts(of: summary).selected == 5 && selection.parts(of: summary).offered == 5)

        // A mixed state counts only what is on; a CSV file offers a login and its notes.
        var some = selection
        some.totp = false
        some.passkeyIDs.removeFirst()
        #expect(some.parts(of: summary) == (3, 5))
        let csv = CredentialExportSelection(allOf: summary, csv: true)
        #expect(csv.password && csv.notes && !csv.totp && csv.passkeyIDs.isEmpty)
        #expect(csv.parts(of: summary, csv: true) == (2, 2))
        // A part the credential no longer has is not counted.
        let stale = CredentialExportSelection(accountID: summary.id, password: false, passkeyIDs: [UUID()], totp: false)
        #expect(stale.parts(of: summary) == (0, 5))
    }

    @Test func selectAllSelectsEveryPartOfEveryItem() throws {
        let items = [try whole("one"), account("two"), try whole("three")]
        let summaries = items.map(CredentialSummary.init)
        let all = CredentialExportSelection.setting(true, for: summaries, in: [:])
        #expect(all.count == 3)
        for summary in summaries {
            let selection = try #require(all[summary.id])
            #expect(selection.parts(of: summary).selected == selection.parts(of: summary).offered)
            #expect(selection.hasParts)
        }

        // Select None clears only what it is given, so a search can narrow it.
        let narrowed = CredentialExportSelection.setting(false, for: [summaries[0]], in: all)
        #expect(narrowed.keys.contains(summaries[0].id) == false && narrowed.count == 2)
        #expect(CredentialExportSelection.setting(false, for: summaries, in: all).isEmpty)
    }
}
