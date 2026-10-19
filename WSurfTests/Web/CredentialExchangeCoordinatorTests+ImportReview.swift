// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Testing

@testable import WSurf

// The import review as the user meets it: which credentials need a decision, what is decided for them, and what a decision costs.
// Synthetic data only (`example.test` hosts, hand-built transfers).
@MainActor
extension CredentialExchangeCoordinatorTests {
    /// What Import would do now, or `nil` while a decision is missing or the choices don't fit together.
    func planned(_ f: Fixture) -> CredentialImportOutcome? {
        try? f.coordinator.plannedOutcome(for: f.manager, owner: f.owner)
    }

    func plainNote(_ text: String) -> ASImportableCredential {
        .note(.init(content: .init(id: nil, fieldType: .string, value: text, label: nil)))
    }

    /// Three items that have everything the review distinguishes: a login with a note, a login with a code, a bare login.
    func threeItems() -> ASExportedCredentialData {
        handBuilt([
            item(id: 1, scoped: true, [password("pw1"), plainNote("memo")]),
            item(id: 2, scoped: true, [password("pw2"), totpCredential()]),
            item(id: 3, scoped: true, [password("pw3")]),
        ])
    }

    /// Stages `data` and imports it with the choices the review starts with.
    func importOnce(_ f: Fixture, _ data: ASExportedCredentialData) async throws {
        try await f.stage(data)
        _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
    }

    /// Changes the stored login of the imported item `id` the way the user would in the editor.
    func editLocally(_ f: Fixture, item id: UInt8, password newPassword: String) async throws {
        let snapshot = try await f.stored()
        var accounts = snapshot.accounts
        let at = try #require(accounts.firstIndex { $0.exchangeItemID == Data([0xB0, id]) })
        accounts[at].password = newPassword
        _ = try await f.manager.commit(accounts, expectedRevision: snapshot.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))
    }

    func review(_ f: Fixture) throws -> CredentialImportReview {
        try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
    }

    /// The titles of the items in `group`, in transfer order.
    func titles(of group: CredentialImportReview.Group, in review: CredentialImportReview) -> [String] {
        (review.sections[group] ?? []).map { review.candidates[$0].summary.title }
    }

    // MARK: - Re-imports

    /// The same transfer, imported twice. The first import recorded what it brought in, so nothing in the second is a question.
    @Test func reimportOfAnUnchangedTransferNeedsNoDecision() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(threeItems())
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.count == 4)

            try await f.stage(threeItems())
            let again = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(again.candidates.count == 3)
            #expect(again.isResolved, "every item is the one that was imported before")
        }
    }

    /// Spec §13.3: no silent re-import from Trash. Removing an imported item and importing it again leaves it out until the user says so.
    @Test func previouslyRemovedItemIsSkippedByDefault() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(threeItems())
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            let stored = try await f.stored()
            let victim = try #require(stored.accounts.first { $0.exchangeItemID == Data([0xB0, 1]) })
            let epoch = try #require(f.manager.authorizationEpoch)
            _ = try await f.manager.delete(.account(victim.id), expectedRevision: stored.revision, authorizedEpoch: epoch)

            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), plainNote("memo")])]))
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.candidates.flatMap(\.records).allSatisfy { $0.destination == .skipped })
            #expect(counts(planned(f)) == [0, 0])
        }
    }

    /// An import writes the accounts it changes. An item saved before bases were recorded, and found unchanged, is not rewritten just
    /// to record one: a long review must not be discarded because an unrelated account changed meanwhile.
    @Test func anImportDoesNotRewriteAccountsItOnlyRecordedABaseFor() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            // As an earlier build saved them: linked to the items, but with nothing recorded about what they brought in.
            let snapshot = try await f.stored()
            let unbound = snapshot.accounts.map { account -> CredentialAccount in
                var copy = account
                copy.passwordBase = nil
                copy.totpBase = nil
                return copy
            }
            _ = try await f.manager.commit(unbound, expectedRevision: snapshot.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))

            // Nothing changed: identical content is the same credential, and there is nothing to write.
            try await f.stage(threeItems())
            let staged = try review(f)
            #expect(staged.isResolved && staged.tally.unchanged == 3 && staged.tally.writes == 0)
            #expect(counts(planned(f)) == [0, 0])
            let before = try f.diskBytes()
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            let afterwards = try f.diskBytes()
            #expect(failure?.message.kind == .nothingImported && afterwards == before)
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)

            // One item changed in the other app. With no base nobody can say who changed it, so the user decides, and only that item is
            // written; it is the one that gets its base.
            try await f.stage(handBuilt([
                item(id: 1, scoped: true, [password("pw1"), plainNote("memo")]),
                item(id: 2, scoped: true, [password("pw2-remote"), totpCredential()]),
                item(id: 3, scoped: true, [password("pw3")]),
            ]))
            let changed = try review(f)
            #expect(titles(of: .decide, in: changed) == ["Item 2"] && changed.tally.undecided == 1)
            try f.coordinator.chooseItem(.useIncoming, for: try #require(changed.candidates.first { $0.summary.title == "Item 2" }).id, owner: f.owner)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            let after = try await f.stored().accounts
            let item2 = try #require(after.first { $0.exchangeItemID == Data([0xB0, 2]) })
            #expect(item2.password == "pw2-remote" && item2.passwordBase != nil && item2.totpBase != nil)
            for id: UInt8 in [1, 3] {
                let account = try #require(after.first { $0.exchangeItemID == Data([0xB0, id]) })
                #expect(account == unbound.first { $0.id == account.id }, "item \(id) was compared, not rewritten")
            }
        }
    }

    // MARK: - Defaults

    /// Changed in the other app only: take it. The value it replaces stays as an earlier version.
    @Test func remoteOnlyChangeDefaultsToIncomingAndKeepsTheOldAsARevision() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            let changed = handBuilt([
                item(id: 1, scoped: true, [password("pw1"), plainNote("memo")]),
                item(id: 2, scoped: true, [password("pw2-remote"), totpCredential()]),
                item(id: 3, scoped: true, [password("pw3")]),
            ])
            try await f.stage(changed)

            let staged = try review(f)
            #expect(staged.isResolved)
            #expect(titles(of: .update, in: staged) == ["Item 2"] && titles(of: .saved, in: staged) == ["Item 1", "Item 3"])
            let record = try #require(staged.candidates.flatMap(\.records).first { $0.kind == .password && $0.classification == .remoteChanged })
            #expect(record.choice == .replace)
            #expect(counts(planned(f)) == [0, 1])

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try await f.stored()
            let updated = try #require(stored.accounts.first { $0.exchangeItemID == Data([0xB0, 2]) })
            #expect(updated.password == "pw2-remote")
            #expect(stored.accounts.first { $0.exchangeItemID == Data([0xB0, 1]) }?.password == "pw1")
            let versions = try await f.manager.revisionPage(accountID: updated.id, after: nil).items
            #expect(versions.map(\.subject) == [.password], "the replaced password is kept as an earlier version")
            #expect(versions.map(\.cause) == [CredentialChangeCause.import], "History says the import replaced it")
            // The next import compares with what this one brought in.
            try await f.stage(changed)
            #expect(try review(f).tally.unchanged == 3)
        }
    }

    /// Changed here only: the other app's copy is the old one, and the saved version stays.
    @Test func localOnlyChangeKeepsTheSavedVersion() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            try await editLocally(f, item: 3, password: "edited-here")
            try await f.stage(threeItems())

            let staged = try review(f)
            #expect(staged.isResolved && titles(of: .saved, in: staged).contains("Item 3") && staged.tally.writes == 0)
            #expect(staged.candidates.flatMap(\.records).first { $0.classification == .localChanged }?.choice == .skip)
        }
    }

    /// Both sides changed: nothing decides it for the user, and Import waits until they do.
    @Test func bothChangedBlocksImportUntilDecided() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            try await editLocally(f, item: 3, password: "edited-here")
            try await f.stage(handBuilt([
                item(id: 1, scoped: true, [password("pw1"), plainNote("memo")]),
                item(id: 3, scoped: true, [password("changed-there")]),
            ]))

            let staged = try review(f)
            #expect(!staged.isResolved && staged.tally.undecided == 1)
            #expect(titles(of: .decide, in: staged) == ["Item 3"])
            await #expect(throws: CredentialExchangeCoordinatorError.unresolvedConflicts) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))

            let item3 = try #require(staged.candidates.first { $0.summary.title == "Item 3" })
            try f.coordinator.chooseItem(.useIncoming, for: item3.id, owner: f.owner)
            #expect(try review(f).isResolved && counts(planned(f)) == [0, 1])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.first { $0.exchangeItemID == Data([0xB0, 3]) }?.password == "changed-there")
        }
    }

    /// Keeping the saved login because it didn't change is not skipping the item: a note the saved credential doesn't hold yet still
    /// comes in, and the login is not touched.
    @Test func keepingTheSavedLoginStillBringsInANoteItDoesNotHoldYet() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, handBuilt([item(id: 1, scoped: true, [password("pw1")])]))
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), plainNote("added in the other app")])]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(staged.isResolved && item.group == .new && item.effect == .update, "an update to the saved credential, not a merge")
            #expect(item.records.first { $0.kind == .password }?.choice == .skip)
            #expect(counts(planned(f)) == [0, 1])
            // The group is "New" because of the note, but "Import All New" must not add a second copy of the saved login.
            #expect(try f.coordinator.chooseAll(.importNew, in: .new, owner: f.owner) == 0)
            #expect(try review(f).tally == staged.tally)

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let all = try await f.stored().accounts
            #expect(all.filter { $0.password == "pw1" }.count == 1, "no second copy of the saved login")
            let stored = try #require(all.first { $0.exchangeItemID == Data([0xB0, 1]) })
            #expect(stored.password == "pw1" && stored.notes?.map(\.text) == ["added in the other app"])
            let versions = try await f.manager.revisionPage(accountID: stored.id, after: nil).items
            #expect(!versions.contains { $0.subject == .password }, "the login was not rewritten")
        }
    }

    /// The same when the user decides: Keep Saved keeps the conflicting login and still adds what is new next to it.
    @Test func keepSavedKeepsTheConflictingLoginAndAddsTheNewNote() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, handBuilt([item(id: 1, scoped: true, [password("pw1")])]))
            try await editLocally(f, item: 1, password: "edited-here")
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("changed-there"), plainNote("memo")])]))

            let item = try #require(try review(f).candidates.first)
            #expect(item.group == .decide && item.effect == .undecided)
            try f.coordinator.chooseItem(.keepSaved, for: item.id, owner: f.owner)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try #require(try await f.stored().accounts.first { $0.exchangeItemID == Data([0xB0, 1]) })
            #expect(stored.password == "edited-here" && stored.notes?.map(\.text) == ["memo"])
        }
    }

    /// Use Incoming takes the other app's version of what it changed, and keeps the saved version of what only changed here: the other
    /// app's copy of that is the old one.
    @Test func useIncomingKeepsAPartThatChangedOnlyHere() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, handBuilt([item(id: 2, scoped: true, [password("pw2"), totpCredential()])]))
            try await editLocally(f, item: 2, password: "edited-here")
            let newCode = ASImportableCredential.totp(.init(
                secret: Data("hand-built-seed".utf8), period: 60, digits: 6, userName: "ada", algorithm: .sha1, issuer: "Example"
            ))
            try await f.stage(handBuilt([item(id: 2, scoped: true, [password("pw2"), newCode])]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(staged.isResolved && item.group == .update, "the code changed in the other app only; the login changed here only")
            #expect(try f.coordinator.chooseAll(.useIncoming, in: .update, owner: f.owner) == 1)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try #require(try await f.stored().accounts.first { $0.exchangeItemID == Data([0xB0, 2]) })
            #expect(stored.password == "edited-here" && stored.totp?.period == 60)
        }
    }

    /// Nothing is dropped by default. The note of an item whose passkey a saved credential already holds has somewhere to go: that
    /// credential, which the item is a duplicate of. The review suggests the merge and imports the note with it.
    @Test func aNoteOfAnItemWhoseSavedPasskeyIsHeldGoesToTheCredentialThatHoldsIt() async throws {
        try await withFixture { f in
            let key = P256.Signing.PrivateKey()
            let pkcs8 = try PasskeyKeyEncoding.exportPKCS8(key)
            let saved = WebsitePasskey(
                id: UUID(), credentialID: Data([0xC0, 0x01]), rpID: "example.test", userHandle: Data([0x31]), userName: "ada",
                userDisplayName: "Ada", algorithm: -7, privateKeyPKCS8: pkcs8, backupEligible: true, backupState: false,
                exchangeFIDO2Metadata: nil
            )
            let holder = account(username: "", password: nil, passkeys: [saved])
            try await f.seed([holder] + neighbours(1))
            let incoming = ASImportableCredential.passkey(.init(
                credentialID: Data([0xC0, 0x01]), relyingPartyIdentifier: "example.test", userName: "ada", userDisplayName: "Ada",
                userHandle: Data([0x31]), key: pkcs8
            ))
            try await f.stage(handBuilt([item(id: 7, scoped: true, [incoming, plainNote("only in the other app")])]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(item.linkedAccountID == nil && item.records.map(\.kind) == [.passkey, .note])
            #expect(item.records.first { $0.kind == .passkey }?.classification == .unchanged)
            #expect(staged.isResolved && item.group == .merge && item.duplicate?.target == holder.id)
            #expect(item.records.first { $0.kind == .note }?.choice == .merge(into: holder.id), "the note is not dropped")
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try #require(try await f.stored().accounts.first { $0.id == holder.id })
            #expect(stored.notes?.map(\.text) == ["only in the other app"] && stored.passkeys.count == 1)
        }
    }

    /// A removed item stays out until the user brings it back, then it comes in like any other new item.
    @Test func aPreviouslyRemovedItemCanBeBroughtBack() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, threeItems())
            let stored = try await f.stored()
            let victim = try #require(stored.accounts.first { $0.exchangeItemID == Data([0xB0, 3]) })
            _ = try await f.manager.delete(.account(victim.id), expectedRevision: stored.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))

            try await f.stage(handBuilt([item(id: 3, scoped: true, [password("pw3")])]))
            let staged = try review(f)
            #expect(titles(of: .skipped, in: staged) == ["Item 3"] && staged.tally.skipped == 1)

            try f.coordinator.chooseItem(.importNew, for: try #require(staged.candidates.first).id, owner: f.owner)
            #expect(try review(f).tally.new == 1)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.filter { $0.password == "pw3" }.count == 1)
        }
    }

    // MARK: - Groups and rows

    @Test func reviewGroupsDecisionsFirstThenNewThenSaved() async throws {
        #expect(CredentialImportReview.Group.allCases == [.decide, .merge, .new, .update, .saved, .skipped])
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, handBuilt((1...5).map { item(id: UInt8($0), scoped: true, [password("pw\($0)")]) }))
            try await editLocally(f, item: 3, password: "edited-here")
            let stored = try await f.stored()
            let removed = try #require(stored.accounts.first { $0.exchangeItemID == Data([0xB0, 5]) })
            _ = try await f.manager.delete(.account(removed.id), expectedRevision: stored.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))

            try await f.stage(handBuilt([
                item(id: 1, scoped: true, [password("pw1")]),
                item(id: 2, scoped: true, [password("pw2")]),
                item(id: 3, scoped: true, [password("changed-there")]),
                item(id: 4, scoped: true, [password("changed-there-too")]),
                item(id: 5, scoped: true, [password("pw5")]),
                item(id: 6, scoped: true, [password("pw6")]),
            ]))
            let staged = try review(f)
            #expect(titles(of: .decide, in: staged) == ["Item 3"])
            #expect(titles(of: .merge, in: staged).isEmpty)
            #expect(titles(of: .new, in: staged) == ["Item 6"])
            #expect(titles(of: .update, in: staged) == ["Item 4"])
            #expect(titles(of: .saved, in: staged) == ["Item 1", "Item 2"])
            #expect(titles(of: .skipped, in: staged) == ["Item 5"])
            #expect(staged.candidates.count == staged.sections.values.reduce(0) { $0 + $1.count }, "every item is in exactly one group")
            #expect(staged.tally == CredentialImportReview.Tally(undecided: 1, new: 1, updates: 1, merges: 0, unchanged: 2, skipped: 1))
        }
    }

    /// An item is one row with all its parts. A note is a part of its item's row, never a row of its own.
    @Test func notesNeverGetTheirOwnRow() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(threeItems())
            let staged = try review(f)
            #expect(staged.candidates.count == 3)
            let withNote = try #require(staged.candidates.first { $0.summary.hasNotes })
            #expect(withNote.records.map(\.kind) == [.password, .note])
            #expect(staged.candidates.allSatisfy { $0.records.contains { $0.kind != .note } }, "no row is only a note")
            #expect(staged.sections.values.reduce(0) { $0 + $1.count } == 3)
        }
    }

    @Test func aDecisionRebuildsOnlyItsOwnItem() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(threeItems())
            let before = try review(f)
            let second = try #require(before.candidates.first { $0.summary.title == "Item 2" })

            try f.coordinator.chooseItem(.skip, for: second.id, owner: f.owner)
            let after = try review(f)
            for (old, new) in zip(before.candidates, after.candidates) where old.id != second.id {
                #expect(new.records.map(\.destination) == old.records.map(\.destination) && new.effect == old.effect)
            }
            let changed = try #require(after.candidates.first { $0.id == second.id })
            #expect(changed.records.allSatisfy { $0.destination == .skipped } && changed.effect == .skipped && changed.action == .skip)
            #expect(changed.group == second.group, "a decision never moves a row")
            #expect(after.tally.new == 2 && after.tally.skipped == 1)
            #expect(try f.coordinator.importCandidate(withID: second.id, for: f.manager, owner: f.owner)?.effect == .skipped)
        }
    }

    @Test func bulkImportAllNewAndKeepAllUnchangedTouchOnlyTheirGroup() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await importOnce(f, handBuilt((1...3).map { item(id: UInt8($0), scoped: true, [password("pw\($0)")]) }))
            try await f.stage(handBuilt((1...5).map { item(id: UInt8($0), scoped: true, [password("pw\($0)")]) }))
            let staged = try review(f)
            #expect(titles(of: .saved, in: staged).count == 3 && titles(of: .new, in: staged) == ["Item 4", "Item 5"])

            // Skip the new ones, then bring them back in one step; the saved group is not touched by either.
            #expect(try f.coordinator.chooseAll(.skip, in: .new, owner: f.owner) == 2)
            var now = try review(f)
            #expect(now.tally.skipped == 2 && now.tally.unchanged == 3 && now.tally.new == 0)
            #expect(try f.coordinator.chooseAll(.importNew, in: .new, owner: f.owner) == 2)
            now = try review(f)
            #expect(now.tally.new == 2 && now.tally.unchanged == 3)

            // Keep All Unchanged applies to the group of saved items, whatever was done to them.
            let first = try #require(now.candidates.first { $0.summary.title == "Item 1" })
            try f.coordinator.chooseItem(.skip, for: first.id, owner: f.owner)
            #expect(try f.coordinator.chooseAll(.keepSaved, in: .saved, owner: f.owner) == 3)
            now = try review(f)
            #expect(now.tally.unchanged == 3 && now.tally.new == 2)
            #expect(now.candidates.filter { $0.group == .saved }.allSatisfy { $0.action == .keepSaved })
        }
    }

    @Test func actionsThatDoNotApplyAreRefusedWithoutChangingTheReview() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(threeItems())
            let before = try review(f)
            let item = try #require(before.candidates.first)
            // Nothing saved to keep, replace or keep alongside.
            for action in [CredentialImportReview.ItemAction.keepSaved, .useIncoming, .keepBoth] {
                #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                    try f.coordinator.chooseItem(action, for: item.id, owner: f.owner)
                }
            }
            #expect(throws: CredentialExchangeCoordinatorError.unknownConflict) {
                try f.coordinator.chooseItem(.skip, for: UUID(), owner: f.owner)
            }
            #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) {
                try f.coordinator.chooseItem(.skip, for: item.id, owner: UUID())
            }
            #expect(try review(f).tally == before.tally)
            // Bulk actions skip what they don't apply to and say how many they changed.
            #expect(try f.coordinator.chooseAll(.useIncoming, in: .new, owner: f.owner) == 0)
        }
    }

    @Test func aSecondReplaceOfOneStoredCredentialIsRefused() async throws {
        try await withFixture { f in
            let saved = account(username: "ada", password: "saved-pw")
            try await f.seed([saved])
            // Two rows for the saved login's website and username, each with another password.
            let csv = CredentialCSV.encode([
                ["Title", "URL", "Username", "Password"],
                ["One", Self.origin, "ada", "first"],
                ["Two", Self.origin, "ada", "second"],
            ])
            try await f.coordinator.beginCSVImport(csv, into: f.manager, owner: f.owner) { _ in }
            let staged = try review(f)
            #expect(staged.conflicts.count == 2)
            let ids = staged.candidates.map(\.id)

            try f.coordinator.chooseItem(.useIncoming, for: ids[0], owner: f.owner)
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                try f.coordinator.chooseItem(.useIncoming, for: ids[1], owner: f.owner)
            }
            let second = try #require(staged.candidates[1].records.first)
            #expect(throws: CredentialExchangeCoordinatorError.replaceTaken) {
                try f.coordinator.choose(.replace, for: second.incoming, owner: f.owner)
            }
            // Freeing the first replacement frees the stored login for the second.
            try f.coordinator.chooseItem(.keepSaved, for: ids[0], owner: f.owner)
            try f.coordinator.chooseItem(.useIncoming, for: ids[1], owner: f.owner)
            #expect(try review(f).tally.updates == 1)
        }
    }

    /// Choices that pass every check on their own row but don't fit together are caught by the plan at Import. The review stays, so
    /// the user can change one; it is not dropped.
    @Test func anInvalidCombinationAtImportKeepsTheReview() async throws {
        try await withFixture { f in
            let bare = account(username: "", password: nil, totp: generator("bare-seed"))
            try await f.seed([bare])
            try await importOnce(f, handBuilt([item(id: 9, scoped: true, [password("old")])]))
            try await editLocally(f, item: 9, password: "edited-here")
            // Item 9 changed on both sides, so it must be decided; items 1 and 2 are new.
            try await f.stage(handBuilt([
                item(id: 9, scoped: true, [password("changed-there")]),
                item(id: 1, scoped: true, [password("one")]),
                item(id: 2, scoped: true, [password("two")]),
            ]))
            let staged = try review(f)
            let one = try #require(staged.candidates.first { $0.summary.title == "Item 1" }?.records.first)
            let two = try #require(staged.candidates.first { $0.summary.title == "Item 2" }?.records.first)
            let conflict = try #require(staged.conflicts.first)
            #expect(!staged.isResolved)

            // While something else is undecided the plan can't be proven, so both merges into the one empty account are kept...
            try f.coordinator.choose(.merge(into: bare.id), for: one.incoming, owner: f.owner)
            try f.coordinator.choose(.merge(into: bare.id), for: two.incoming, owner: f.owner)
            try f.coordinator.choose(.skip, for: conflict.incoming, owner: f.owner)
            #expect(try review(f).isResolved)

            // ...and Import refuses them, keeping the review and leaving the vault as it was.
            let before = try f.diskBytes()
            await #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(try f.diskBytes() == before)

            // Changing one of them makes it importable.
            try f.coordinator.choose(.addSeparately, for: two.incoming, owner: f.owner)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.contains { $0.password == "two" })
        }
    }

    // MARK: - Omissions and search

    @Test func omissionsAttachToTheirItem() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            let wifi = ASImportableCredential.wifi(.init(
                ssid: .init(id: nil, fieldType: .string, value: "network", label: nil),
                networkSecurityType: nil,
                passphrase: .init(id: nil, fieldType: .concealedString, value: "wifi-secret", label: nil)
            ))
            try await f.stage(handBuilt([
                item(id: 1, scoped: true, [password("valid"), wifi]),
                item(id: 2, scoped: true, [password("clean")]),
                item(id: 3, scoped: true, [wifi]),
            ]))
            let staged = try review(f)
            #expect(staged.candidates.count == 2)
            let first = try #require(staged.candidates.first { $0.summary.title == "Item 1" })
            #expect(first.omissions.map(\.reason) == [.unsupportedKind])
            #expect(staged.candidates.first { $0.summary.title == "Item 2" }?.omissions.isEmpty == true)
            // The item that held nothing storable is no row, so its omissions are listed apart; all of them stay in `omitted`.
            #expect(staged.unattachedOmissions.map(\.title) == ["Item 3", "Item 3"])
            #expect(staged.omitted.count == 3)
        }
    }

    @Test func searchKeyNeverHoldsASecret() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            let secret = "never-searchable-secret"
            try await f.stage(handBuilt([
                item(id: 1, scoped: true, [password(secret), totpCredential(), plainNote(secret)]),
            ]))
            let key = try #require(try review(f).candidates.first).searchKey
            #expect(!key.contains(secret) && !key.contains("hand-built-seed"))
            #expect(key.contains("item 1") && key.contains("ada") && key.contains("example.test"))
        }
    }
}
