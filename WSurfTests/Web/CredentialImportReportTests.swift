// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

// A re-import after local work: what the review says was changed in WSurf and kept, and what the transfer no longer holds. Real codec
// and a real vault, driven through the coordinator. Synthetic data only (`example.test` hosts, hand-built transfers).
@MainActor
extension CredentialExchangeCoordinatorTests {
    /// The kinds of change the report lists for the item called `title`, in order.
    func changeKinds(_ review: CredentialImportReview, _ title: String) -> [CredentialImportReview.LocalChange.Kind] {
        review.keptChanges.first { $0.title == title }?.changes.map(\.kind) ?? []
    }

    /// Changes the stored copy of the imported item `id` the way the editor (or a merge, with `cause`) would.
    func changeLocally(
        _ f: Fixture, item id: UInt8, cause: String? = nil, _ change: (inout CredentialAccount) -> Void
    ) async throws {
        let snapshot = try await f.stored()
        var accounts = snapshot.accounts
        let at = try #require(accounts.firstIndex { $0.exchangeItemID == Data([0xB0, id]) })
        change(&accounts[at])
        _ = try await f.manager.commit(
            accounts, expectedRevision: snapshot.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch), cause: cause
        )
    }

    /// The transfer of `threeItems()` as the other app sends it again, with the given items changed or left out.
    func resent(_ ids: [UInt8], changed: [UInt8: String] = [:]) -> ASExportedCredentialData {
        handBuilt(ids.map { id in
            var credentials = [password(changed[id] ?? "pw\(id)")]
            if id == 1 {
                credentials.append(plainNote("memo"))
            }
            if id == 2 {
                credentials.append(totpCredential())
            }
            return item(id: id, scoped: true, credentials)
        })
    }

    // MARK: - Changed in WSurf (kept)

    /// A note added here to a credential the other app holds without one is not in the transfer, so the import has nothing to say
    /// about it and the credential is not rewritten. The report names it.
    @Test func aNoteAddedHereSurvivesAReimportAndIsReported() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            try await changeLocally(f, item: 3) { $0.notes = [CredentialNote(text: "added-here-note", field: nil)] }
            let before = try await f.stored().accounts

            try await f.stage(resent([1, 2, 3], changed: [2: "pw2-remote"]))
            let staged = try review(f)
            #expect(staged.isResolved && changeKinds(staged, "Item 3") == [.notesAdded(1)])
            #expect(titles(of: .saved, in: staged).contains("Item 3"), "the three-way classification is as it was")

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            let item3 = try #require(after.first { $0.exchangeItemID == Data([0xB0, 3]) })
            #expect(item3.notes?.map(\.text) == ["added-here-note"])
            #expect(item3 == before.first { $0.id == item3.id }, "item 3 was compared, not rewritten")
            #expect(after.first { $0.exchangeItemID == Data([0xB0, 2]) }?.password == "pw2-remote")
        }
    }

    /// Every kind of change names its field. A date comes from the earlier version the change left. No value is in the report.
    @Test func theReportNamesFieldsAndDatesAndNeverAValue() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            try await changeLocally(f, item: 3) { $0.password = "secret-edited-here" }
            try await changeLocally(f, item: 2) { $0.notes = [CredentialNote(text: "secret-note-here", field: nil)] }
            try await changeLocally(f, item: 1) { $0.origins.append("https://other.example.test") }

            try await f.stage(threeItems())
            let staged = try review(f)
            #expect(staged.isResolved && staged.tally.writes == 0)
            #expect(staged.keptChanges.map(\.title) == ["Item 1", "Item 2", "Item 3"])
            #expect(changeKinds(staged, "Item 1") == [.websitesOrName])
            #expect(changeKinds(staged, "Item 2") == [.notesAdded(1)])
            #expect(changeKinds(staged, "Item 3") == [.password])
            #expect(staged.keptChanges.first { $0.title == "Item 3" }?.changes.first?.date != nil)
            #expect(staged.keptChanges.first { $0.title == "Item 1" }?.changes.first?.date != nil)

            let text = String(describing: staged.keptChanges)
            for value in ["secret-edited-here", "secret-note-here", "pw3", "other.example.test"] {
                #expect(!text.contains(value))
            }
            // Keeping them writes nothing.
            let before = try f.diskBytes()
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .nothingImported && (try f.diskBytes()) == before)
        }
    }

    /// An item the other app changed and nobody changed here is not a local change, and neither is an unchanged one.
    @Test func anUntouchedOrRemoteOnlyItemIsNotReported() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            try await f.stage(resent([1, 2, 3], changed: [2: "pw2-remote"]))
            #expect(try review(f).keptChanges.isEmpty)
        }
    }

    /// A merge says so in the earlier versions it leaves; an import does not count as an edit.
    @Test func aMergeShowsAsMergedAndAnImportIsNotAnEdit() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            try await changeLocally(f, item: 2, cause: "merge") { $0.password = "merged-in" }
            try await changeLocally(f, item: 1, cause: "import") { $0.origins.append("https://other.example.test") }
            let stored = try await f.stored().accounts
            let merged = try #require(stored.first { $0.exchangeItemID == Data([0xB0, 2]) })
            let log = try await f.manager.revisionLog()
            #expect(log[merged.id]?.map(\.cause) == ["merge"] && log[merged.id]?.map(\.subject) == [.password])

            try await f.stage(threeItems())
            let staged = try review(f)
            #expect(changeKinds(staged, "Item 2") == [.password, .merged])
            #expect(staged.keptChanges.first { $0.title == "Item 2" }?.changes.last?.date != nil)
            #expect(changeKinds(staged, "Item 1").isEmpty, "a refresh by an import is not a change made here")
        }
    }

    /// Moved to Trash: the item is skipped as before, and the report adds when.
    @Test func anItemMovedToTrashIsReportedWithItsDate() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            let stored = try await f.stored()
            let victim = try #require(stored.accounts.first { $0.exchangeItemID == Data([0xB0, 1]) })
            _ = try await f.manager.delete(.account(victim.id), expectedRevision: stored.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))

            try await f.stage(threeItems())
            let staged = try review(f)
            #expect(titles(of: .skipped, in: staged) == ["Item 1"], "the classification is as it was")
            #expect(changeKinds(staged, "Item 1") == [.movedToTrash(.password), .movedToTrash(.note)])
            #expect(staged.keptChanges.first { $0.title == "Item 1" }?.changes.allSatisfy { $0.date != nil } == true)
        }
    }

    // MARK: - No longer in Passwords

    /// Missing from a transfer is a question, not a removal: the credential is listed, kept, and Import writes nothing for it.
    @Test func anItemMissingFromTheTransferIsListedAndNeverRemovedUnlessChosen() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            let full = try await f.stored().accounts
            let victim = try #require(full.first { $0.exchangeItemID == Data([0xB0, 3]) })

            try await f.stage(resent([1, 2]))
            let staged = try review(f)
            #expect(staged.missing.map(\.title) == ["Item 3"] && staged.missing.allSatisfy { !$0.movesToTrash })
            #expect(staged.isResolved && !staged.transferIsComplete && staged.pendingWrites == 0)

            // A transfer does not say whether it is whole: nothing moves to Trash before the user does.
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                try f.coordinator.chooseMissing(moveToTrash: true, for: [victim.id], owner: f.owner)
            }

            // Keep is the default, also once the transfer is said to be whole, and it writes nothing.
            try f.coordinator.declareTransferComplete(true, owner: f.owner)
            #expect(try review(f).trashCount == 0 && planned(f)?.movedToTrash == 0)
            let before = try f.diskBytes()
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .nothingImported && (try f.diskBytes()) == before)

            // Moving it to Trash is the user's choice, and Import then does that and nothing else.
            let trashBefore = try await f.manager.historyCounts().trash.trashEntry
            try f.coordinator.chooseMissing(moveToTrash: true, for: [victim.id], owner: f.owner)
            let chosen = try review(f)
            #expect(chosen.trashCount == 1 && chosen.pendingWrites == 1 && planned(f)?.movedToTrash == 1)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            #expect(after.count == full.count - 1 && !after.contains { $0.id == victim.id })
            #expect(after.allSatisfy { account in account == full.first { $0.id == account.id } }, "every other account is as it was")
            #expect(try await f.manager.historyCounts().trash.trashEntry == trashBefore + 1, "it is in Trash, with its history")
        }
    }

    /// Taking the declaration back keeps everything, and a transfer from another exporter lists nothing.
    @Test func takingBackTheDeclarationKeepsEverythingAndAnotherExporterListsNothing() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            try await f.stage(resent([1]))
            try f.coordinator.declareTransferComplete(true, owner: f.owner)
            try f.coordinator.chooseMissing(moveToTrash: true, owner: f.owner)
            let all = try review(f)
            #expect(all.missing.count == 2 && all.trashCount == 2 && all.pendingWrites == 2)
            try f.coordinator.declareTransferComplete(false, owner: f.owner)
            let kept = try review(f)
            #expect(kept.trashCount == 0 && kept.pendingWrites == 0 && !kept.transferIsComplete)
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)

            let account = ASImportableAccount(
                id: Data([0xA0, 0x02]), userName: "ada", email: "ada@example.test", collections: [],
                items: [item(id: 9, scoped: true, [password("pw9")])]
            )
            let elsewhere = ASExportedCredentialData(
                accounts: [account],
                formatVersion: .v1,
                exporterRelyingPartyIdentifier: "example.test",
                exporterDisplayName: "Fixture",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try await f.stage(elsewhere)
            #expect(try review(f).missing.isEmpty)
        }
    }

    /// A credential that changed after the review was read is not moved to Trash: the choice was made about another version of it.
    @Test func aCredentialChangedAfterTheReviewIsNotMovedToTrash() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            let stored = try await f.stored()
            let victim = try #require(stored.accounts.first { $0.exchangeItemID == Data([0xB0, 3]) })

            try await f.stage(resent([1, 2]))
            try f.coordinator.declareTransferComplete(true, owner: f.owner)
            try f.coordinator.chooseMissing(moveToTrash: true, for: [victim.id], owner: f.owner)
            try await changeLocally(f, item: 3) { $0.password = "changed-meanwhile" }

            let before = try f.diskBytes()
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .discarded && (try f.diskBytes()) == before)
            #expect(try await f.stored().accounts.contains { $0.id == victim.id && $0.password == "changed-meanwhile" })
        }
    }

    @Test func aChoiceForACredentialThatIsNotListedIsRefused() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            try await f.stage(resent([1, 2]))
            try f.coordinator.declareTransferComplete(true, owner: f.owner)
            #expect(throws: CredentialExchangeCoordinatorError.unknownConflict) {
                try f.coordinator.chooseMissing(moveToTrash: true, for: [UUID()], owner: f.owner)
            }
            #expect(try review(f).trashCount == 0)
        }
    }
}

// MARK: - Which credentials are missing

struct CredentialImportMissingTests {
    private func saved(item: UInt8, exporter: UInt8? = 1) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: "ada", displayName: "Item \(item)", origins: ["https://example.test"], loginURLs: [], password: "pw",
            passkeys: [], totp: nil, exchangeAccountID: exporter.map { Data([0xA0, $0]) }, exchangeItemID: exporter == nil ? nil : Data([0xB0, item])
        )
    }

    @Test func onlyWhatAnEarlierImportBroughtFromThisExporterAndTheTransferLacksIsMissing() throws {
        let held = saved(item: 1)
        let gone = saved(item: 2)
        let otherExporter = saved(item: 3, exporter: 2)
        let native = saved(item: 4, exporter: nil)
        let sent = saved(item: 1)

        let missing = CredentialImportReport.missing(
            candidates: [sent], accounts: [held, gone, otherExporter, native], duplicateTargets: []
        )
        #expect(missing.map(\.accountID) == [gone.id])
        #expect(missing.allSatisfy { !$0.movesToTrash })

        let duplicated = CredentialImportReport.missing(candidates: [sent], accounts: [held, gone], duplicateTargets: [gone.id])
        #expect(duplicated.isEmpty, "a saved credential that an exact copy in the transfer stands for is not missing")
    }
}
