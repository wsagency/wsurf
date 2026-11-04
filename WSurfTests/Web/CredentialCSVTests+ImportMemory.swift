// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// Importing the same Passwords export again, or a newer one, through the real parser, coordinator and vault: what the vault remembers
// of the last import decides what comes in. One test per case of the owner's question: (a) unchanged, (b) changed in Passwords,
// (c) deleted here, (d) merged here, (e) edited here. Case (f), a merge or delete synced in from another Mac, is in
// `VaultSyncDeviceTests`. Every value is synthetic.
@MainActor
extension CredentialCSVTests {
    static let otherSite = "https://other.test/login"

    /// Stages `rows` and imports them with the choices the review starts with: the user only clicks Import.
    func importDefaults(_ f: CredentialExchangeCoordinatorTests.Fixture, _ rows: [[String]]) async throws {
        try await stage(f, rows)
        _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
    }

    func review(_ f: CredentialExchangeCoordinatorTests.Fixture) throws -> CredentialImportReview {
        try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
    }

    /// The review item of CSV line `line` (the header is line 1).
    func item(_ review: CredentialImportReview, line: Int) throws -> CredentialImportReview.Candidate {
        try #require(review.candidates.first { $0.records.contains { $0.csvLine == line } })
    }

    func saved(_ f: CredentialExchangeCoordinatorTests.Fixture, _ username: String) async throws -> CredentialAccount {
        try #require(try await f.stored().accounts.first { $0.username == username })
    }

    func edit(
        _ f: CredentialExchangeCoordinatorTests.Fixture, _ id: UUID, _ change: (inout CredentialAccount) -> Void
    ) async throws {
        let snapshot = try await f.stored()
        var accounts = snapshot.accounts
        let at = try #require(accounts.firstIndex { $0.id == id })
        change(&accounts[at])
        _ = try await f.manager.commit(
            accounts, expectedRevision: snapshot.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch), changing: [id]
        )
    }

    func delete(_ f: CredentialExchangeCoordinatorTests.Fixture, _ id: UUID) async throws {
        _ = try await f.manager.delete(
            .account(id), expectedRevision: try await f.stored().revision, authorizedEpoch: try #require(f.manager.authorizationEpoch)
        )
    }

    /// Merges `others` into `survivor` with the default picks, as the merge sheet does.
    func merge(_ f: CredentialExchangeCoordinatorTests.Fixture, _ others: [CredentialAccount], into survivor: CredentialAccount) async throws {
        let snapshot = try await f.stored()
        let picks = try #require(CredentialMerge.defaultPicks(for: [survivor] + others, survivor: survivor.id))
        let merged = try CredentialMerge.merged([survivor] + others, picks: picks)
        let gone = Set(others.map(\.id))
        let result = snapshot.accounts.compactMap { $0.id == merged.id ? merged : (gone.contains($0.id) ? nil : $0) }
        _ = try await f.manager.commit(
            result, expectedRevision: snapshot.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch), cause: "merge",
            changing: gone.union([survivor.id]), merging: Dictionary(uniqueKeysWithValues: others.map { ($0.id, survivor.id) })
        )
    }

    func purgeTrash(_ f: CredentialExchangeCoordinatorTests.Fixture) async throws {
        _ = try await f.manager.purge(entryIDs: [], emptyAll: true, in: VaultManagerFixture.anchor())
    }

    func isPreviouslyRemoved(_ record: CredentialImportReview.Record, tombstone: Bool? = nil) -> Bool {
        guard case let .previouslyRemoved(_, isTombstone) = record.classification else { return false }
        return tombstone.map { $0 == isTombstone } ?? true
    }

    // MARK: (a) unchanged

    @Test func anUnchangedExportAsksNothingAndAddsNothingAfterEditsAndMergesHere() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            // Lines 2-4. Passwords numbered its duplicate login "ada (1)".
            let file = [row("ada", "pw-a"), row("ada (1)", "pw-a"), row("grace", "pw-g", url: Self.otherSite)]
            try await importDefaults(f, file)
            let ada = try await saved(f, "ada")
            try await merge(f, [try await saved(f, "ada (1)")], into: ada)
            try await edit(f, try await saved(f, "grace").id) { $0.password = "changed-here" }
            let before = try f.diskBytes()

            try await stage(f, file)
            let review = try review(f)
            #expect(review.isResolved, "nothing waits for a decision")
            #expect(review.tally.new == 0 && review.tally.writes == 0)
            #expect(try item(review, line: 3).group == .skipped, "the copy merged into ada stays merged")
            #expect(try item(review, line: 4).effect == .unchanged, "grace keeps the password changed here")
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .nothingImported)
            #expect(try f.diskBytes() == before)
            #expect(try await f.stored().accounts.map(\.username).sorted() == ["ada", "grace"])
        }
    }

    // MARK: (b) changed in Passwords

    @Test func aChangeInPasswordsIsProposedAsAnUpdateAndNeverAsADuplicate() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await importDefaults(f, [row("ada", "old"), row("grace", "pw-g", url: Self.otherSite)])

            // A new password for ada and a note added to grace, in Passwords.
            try await stage(f, [row("ada", "new"), row("grace", "pw-g", url: Self.otherSite, notes: "added in Passwords")])
            let review = try review(f)
            #expect(review.isResolved, "the vault can tell that only Passwords changed them")
            let ada = try item(review, line: 2)
            #expect(ada.group == .update && ada.effect == .update)
            let login = try #require(ada.records.first { $0.kind == .password })
            #expect(login.classification == .remoteChanged && login.choice == .replace)
            let grace = try item(review, line: 3)
            #expect(grace.effect == .update)
            #expect(grace.records.first { $0.kind == .password }?.classification == .unchanged)
            #expect(base.counts(base.planned(f)) == [0, 2])

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try await f.stored().accounts
            #expect(stored.count == 2, "updated in place, nothing added beside")
            #expect(stored.first { $0.username == "ada" }?.password == "new")
            let saved = try #require(stored.first { $0.username == "grace" })
            #expect(saved.password == "pw-g" && saved.notes?.map(\.text) == ["added in Passwords"])
        }
    }

    // MARK: (c) deleted here

    @Test func aDeletedEntryIsNotBroughtBackWhileInTrashOrOncePurgedUnlessChosen() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            let file = [row("ada", "pw-a"), row("grace", "pw-g", url: Self.otherSite)]
            try await importDefaults(f, file)
            try await delete(f, try await saved(f, "ada").id)

            try await stage(f, file)
            var review = try review(f)
            var ada = try item(review, line: 2)
            #expect(ada.group == .skipped && ada.effect == .skipped)
            #expect(ada.records.allSatisfy { isPreviouslyRemoved($0, tombstone: false) && $0.choice == .skip })
            #expect(review.isResolved && review.tally.new == 0)
            // Brought back only on purpose.
            #expect(ada.availableActions.contains(.importNew))
            try f.coordinator.chooseItem(.importNew, for: ada.id, owner: f.owner)
            #expect(base.counts(base.planned(f)) == [1, 0])
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)

            try await purgeTrash(f)
            try await stage(f, file)
            review = try self.review(f)
            ada = try item(review, line: 2)
            #expect(ada.group == .skipped && ada.records.allSatisfy { isPreviouslyRemoved($0, tombstone: true) })
            #expect(review.isResolved && review.tally.new == 0)
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.map(\.username) == ["grace"])
        }
    }

    // MARK: (d) merged here

    @Test func aMergedCopyBelongsToTheCredentialItWasMergedIntoAndItsChangeUpdatesIt() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await importDefaults(f, [row("ada", "pw"), row("ada (1)", "pw")])
            let ada = try await saved(f, "ada")
            try await merge(f, [try await saved(f, "ada (1)")], into: ada)

            // Unchanged: left out, and said to be merged.
            try await stage(f, [row("ada", "pw"), row("ada (1)", "pw")])
            var copy = try item(try review(f), line: 3)
            #expect(copy.group == .skipped && copy.records.allSatisfy { isPreviouslyRemoved($0) })
            #expect(copy.statusLine.contains("Merged into"))
            #expect(try review(f).tally.new == 0)
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)

            // Changed in Passwords since the merge, and once its Trash entry is gone: an update of the credential it went into, which
            // keeps that credential's username.
            try await purgeTrash(f)
            try await stage(f, [row("ada", "pw"), row("ada (1)", "pw-new")])
            copy = try item(try review(f), line: 3)
            let login = try #require(copy.records.first { $0.kind == .password })
            #expect(login.existing == .password(accountID: ada.id))
            #expect(login.classification == .remoteChanged && login.choice == .replace && copy.group == .update)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try await f.stored().accounts
            #expect(stored.count == 1 && stored.first?.username == "ada" && stored.first?.password == "pw-new")
        }
    }

    /// (c) and (d) for a later import from the Passwords app itself (Credential Exchange): its items carry ids the file never had, so the
    /// vault knows them by their login.
    @Test func aSystemImportDoesNotBringBackAnEntryDeletedAfterAFileImport() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await importDefaults(f, [row("ada", "pw")])
            try await delete(f, try await saved(f, "ada").id)

            try await f.stage(base.handBuilt([base.item(id: 1, scoped: true, [base.password("pw")])]))
            let review = try review(f)
            let item = try #require(review.candidates.first)
            #expect(item.group == .skipped && item.records.allSatisfy { isPreviouslyRemoved($0) })
            #expect(review.isResolved && review.tally.new == 0)
            #expect(item.availableActions.contains(.importNew), "brought back only on purpose")
        }
    }

    // MARK: (e) edited here

    @Test func anEditHereIsKeptAndAChangeOnBothSidesWaitsForTheUser() async throws {
        try await base.withFixture { f in
            try await f.seed([])
            try await importDefaults(f, [row("ada", "from-passwords")])
            try await edit(f, try await saved(f, "ada").id) { $0.password = "edited-here" }

            // Passwords still has what it had: the edit stays, and nothing asks.
            try await stage(f, [row("ada", "from-passwords")])
            var review = try review(f)
            let kept = try item(review, line: 2)
            #expect(review.isResolved && kept.effect == .unchanged)
            #expect(kept.records.first?.classification == .localChanged)
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)

            // Passwords changed it too: the user decides, nothing is replaced by default.
            try await stage(f, [row("ada", "changed-in-passwords")])
            review = try self.review(f)
            let both = try #require(try item(review, line: 2).records.first)
            #expect(!review.isResolved && both.classification == .bothChanged && both.choice == nil)
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)
            #expect(try await saved(f, "ada").password == "edited-here")
        }
    }
}
