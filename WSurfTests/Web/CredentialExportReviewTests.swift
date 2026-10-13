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

    @Test func anUnchangedVaultKeepsTheSelectionAndReportsNothing() {
        let kept = account("kept")
        let shown = [CredentialSummary(kept)]
        let review = CredentialExportReview.reconcile(selection: choose(kept), shown: shown, fresh: shown)
        #expect(review.isEmpty && review.selection[kept.id]?.password == true)
    }

    @Test func aDeletedSelectionIsNamedAndDroppedButAnUnselectedOneIsNotReported() {
        let gone = account("gone")
        let other = account("other")
        let review = CredentialExportReview.reconcile(
            selection: choose(gone), shown: [CredentialSummary(gone), CredentialSummary(other)], fresh: []
        )
        #expect(review.deleted == ["gone"] && review.changed.isEmpty && review.selection.isEmpty)
    }

    @Test func aRenamedSelectionKeepsItsPartsAndIsNamedAsItIsNow() {
        let before = account("before")
        var after = before
        after.displayName = "after"
        let review = CredentialExportReview.reconcile(
            selection: choose(before), shown: [CredentialSummary(before)], fresh: [CredentialSummary(after)]
        )
        #expect(review.changed == ["after"] && review.deleted.isEmpty && review.selection[before.id]?.password == true)
    }

    @Test func aPartThatNoLongerExistsIsDroppedAndTheCredentialIsNamed() {
        let before = account("login")
        var after = before
        after.password = nil
        after.username = ""
        let review = CredentialExportReview.reconcile(
            selection: choose(before), shown: [CredentialSummary(before)], fresh: [CredentialSummary(after)]
        )
        #expect(review.changed == ["login"] && review.selection.isEmpty)
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

            let review = CredentialExportReview.reconcile(selection: selection, shown: shown, fresh: model.summaries)
            #expect(review.deleted == ["gone"] && review.changed == ["renamed elsewhere"])
            #expect(Set(review.selection.keys) == [renamed.id])

            let retry = await model.exportCredentials(selection: Array(review.selection.values), epoch: epoch, in: NSWindow())
            #expect(retry == .transferred && sends.withLock { $0 } == 1)
        }
    }
}
