// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The rules of the import review that need no vault: what each classification does by default, where an item sits, and what it
// does. The review built from a real transfer is in `CredentialExchangeCoordinatorTests+ImportReview`.
@MainActor
struct CredentialImportReviewTests {
    typealias Record = CredentialImportReview.Record

    private func record(
        _ kind: Record.Kind = .password,
        _ classification: CredentialImportClass,
        conflict: Bool = false,
        needsChoice: Bool? = nil,
        choice: CredentialImportChoice? = nil,
        destination: Record.Destination? = .newAccount(origins: []),
        removesPassword: Bool = false,
        canAddSeparately: Bool = true
    ) -> Record {
        let owner = UUID()
        let incoming: CredentialIdentity = kind == .password ? .password(accountID: owner) : .totp(accountID: owner)
        return Record(
            incoming: incoming,
            existing: conflict ? .password(accountID: UUID()) : nil,
            kind: kind,
            title: "Item",
            existingTitle: conflict ? "Saved" : nil,
            relyingParty: nil,
            destination: destination,
            canAddSeparately: canAddSeparately,
            removesStoredPasswordOnReplace: removesPassword,
            classification: classification,
            needsChoice: needsChoice ?? conflict,
            csvLine: nil,
            choice: choice
        )
    }

    // MARK: Defaults

    @Test func eachClassificationHasItsDefault() {
        let removed = CredentialImportClass.previouslyRemoved(entryID: UUID(), isTombstone: false)
        func choice(_ classification: CredentialImportClass, conflict: Bool = true, drops: Bool = false) -> CredentialImportChoice? {
            CredentialImportDefaults.choice(for: classification, isConflict: conflict, removesStoredPasswordOnReplace: drops)
        }
        // Nothing to ask: the saved copy stays.
        #expect(choice(.unchanged) == .skip && choice(.localChanged) == .skip)
        // Only the other app changed it: take it, unless that would drop a saved password.
        #expect(choice(.remoteChanged) == .replace && choice(.remoteChanged, drops: true) == nil)
        // Left out until the user says otherwise.
        #expect(choice(removed, conflict: false) == .skip && choice(.passkeyHardConflict) == .skip)
        // The user's call.
        for undecided in [CredentialImportClass.bothChanged, .noCommonBase, .ambiguous, .new] {
            #expect(choice(undecided) == nil)
        }
        // A part with nothing saved to compare with is not a conflict, so it needs no default.
        #expect(choice(.unchanged, conflict: false) == nil && choice(.remoteChanged, conflict: false) == nil)
    }

    @Test func groupsAreOrderedMostUrgentFirst() {
        #expect(CredentialImportReview.Group.allCases == [.decide, .merge, .new, .update, .saved, .skipped])
        #expect(CredentialImportReview.Group.decide < .new && CredentialImportReview.Group.update < .saved && CredentialImportReview.Group.saved < .skipped)
    }

    @Test func aRecordThatNeedsAChoiceAndHasNoneIsAlwaysInTheDecideGroup() {
        for classification in [CredentialImportClass.bothChanged, .noCommonBase, .ambiguous, .unchanged, .remoteChanged, .new] {
            #expect(CredentialImportDefaults.group(for: classification, needsChoice: true, choice: nil) == .decide)
        }
        #expect(CredentialImportDefaults.group(for: .bothChanged, needsChoice: true, choice: .skip) == .new, "decided, it keeps its place")
        let removed = CredentialImportClass.previouslyRemoved(entryID: UUID(), isTombstone: true)
        #expect(CredentialImportDefaults.group(for: removed, needsChoice: false, choice: .skip) == .skipped)
        #expect(CredentialImportDefaults.group(for: .passkeyHardConflict, needsChoice: true, choice: .skip) == .skipped)
        #expect(CredentialImportDefaults.group(for: .unchanged, needsChoice: true, choice: .skip) == .saved)
        #expect(CredentialImportDefaults.group(for: .localChanged, needsChoice: true, choice: .skip) == .saved)
        #expect(CredentialImportDefaults.group(for: .remoteChanged, needsChoice: true, choice: .replace) == .update)
        #expect(CredentialImportDefaults.group(for: .new, needsChoice: false, choice: nil) == .new)
    }

    @Test func anItemIsInTheMostUrgentGroupOfItsParts() {
        let unchanged = record(.password, .unchanged, conflict: true, choice: .skip, destination: .skipped)
        let added = record(.totp, .new)
        let undecided = record(.password, .bothChanged, conflict: true, destination: nil)
        #expect(CredentialImportDefaults.group(of: [unchanged]) == .saved)
        #expect(CredentialImportDefaults.group(of: [unchanged, added]) == .new, "a saved login with a new code still has something to import")
        #expect(CredentialImportDefaults.group(of: [unchanged, added, undecided]) == .decide)
        #expect(CredentialImportDefaults.group(of: []) == .skipped)
    }

    // MARK: Effects

    @Test func anItemDoesWhatItsMostActivePartDoes() {
        let skipped = record(.password, .previouslyRemoved(entryID: UUID(), isTombstone: false), choice: .skip, destination: .skipped)
        let kept = record(.password, .unchanged, conflict: true, choice: .skip, destination: .skipped)
        let keptLocalChange = record(.password, .localChanged, conflict: true, choice: .skip, destination: .skipped)
        let updated = record(
            .password, .remoteChanged, conflict: true, choice: .replace,
            destination: .existing(accountID: UUID(), title: "Saved", origins: [], ignoredOrigins: [])
        )
        let merged = record(
            .totp, .new, choice: .merge(into: UUID()),
            destination: .existing(accountID: UUID(), title: "Saved", origins: [], ignoredOrigins: [])
        )
        let added = record(.totp, .new)
        let undecided = record(.password, .noCommonBase, conflict: true, destination: nil)

        #expect(CredentialImportDefaults.effect(of: [skipped]) == .skipped)
        #expect(CredentialImportDefaults.effect(of: [kept]) == .unchanged, "keeping what is saved is not leaving a credential out")
        #expect(CredentialImportDefaults.effect(of: [keptLocalChange]) == .unchanged)
        #expect(CredentialImportDefaults.effect(of: [skipped, kept]) == .unchanged)
        #expect(CredentialImportDefaults.effect(of: [kept, updated]) == .update)
        #expect(CredentialImportDefaults.effect(of: [updated, merged]) == .merge)
        #expect(CredentialImportDefaults.effect(of: [merged, added]) == .new)
        #expect(CredentialImportDefaults.effect(of: [added, undecided]) == .undecided, "one open question makes the item a question")
    }

    @Test func theTallyCountsEachItemOnceUnderItsEffect() {
        var tally = CredentialImportReview.Tally()
        for effect: CredentialImportReview.Effect in [.new, .new, .update, .merge, .unchanged, .skipped, .undecided] {
            tally.add(effect)
        }
        #expect(tally == CredentialImportReview.Tally(undecided: 1, new: 2, updates: 1, merges: 1, unchanged: 1, skipped: 1))
        #expect(tally.writes == 4)
        tally.add(.new, -1)
        tally.add(.skipped)
        #expect(tally.new == 1 && tally.skipped == 2 && tally.writes == 3)
    }

    // MARK: Actions

    private func candidate(_ records: [Record]) -> CredentialImportReview.Candidate {
        let account = CredentialAccount(
            id: UUID(), username: "ada", displayName: "Item", origins: ["https://example.test"], loginURLs: [], password: "pw",
            passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        return CredentialImportReview.Candidate(
            summary: CredentialSummary(account), needsManualAssociation: false, records: records, group: .decide, searchKey: "item",
            linkedAccountID: nil, omissions: [], effect: .undecided, action: nil
        )
    }

    @Test func anItemWithNothingSavedToCompareWithCanOnlyBeImportedOrSkipped() {
        let item = candidate([record(.password, .new), record(.totp, .new)])
        #expect(item.availableActions == [.importNew, .skip])
    }

    @Test func anItemWithAConflictCanKeepReplaceOrKeepBoth() {
        let item = candidate([record(.password, .bothChanged, conflict: true, destination: nil)])
        #expect(item.availableActions == [.keepSaved, .useIncoming, .keepBoth, .skip])
        #expect(item.hasConflict)
    }

    @Test func replacingIsNotOfferedWhereItWouldDropAPassword() {
        let item = candidate([record(.password, .bothChanged, conflict: true, destination: nil, removesPassword: true)])
        #expect(item.availableActions == [.keepSaved, .keepBoth, .skip])
    }

    @Test func keepingBothIsNotOfferedForAPartThatCannotBeAddedTwice() {
        let item = candidate([record(.password, .bothChanged, conflict: true, destination: nil, canAddSeparately: false)])
        #expect(item.availableActions == [.keepSaved, .useIncoming, .skip])
    }

    @Test func useIncomingKeepsWhatOnlyChangedHereAndKeepBothSkipsWhatIsTheSame() {
        let editedHere = record(.password, .localChanged, conflict: true, destination: nil)
        let changedThere = record(.totp, .remoteChanged, conflict: true, destination: nil)
        let same = record(.password, .unchanged, conflict: true, destination: nil)
        func choices(_ action: CredentialImportReview.ItemAction, _ records: [Record]) -> [CredentialImportChoice?]? {
            CredentialExchangeCoordinator.changes(for: action, records: records, replaced: [:])?.map(\.choice)
        }
        #expect(choices(.useIncoming, [editedHere, changedThere]) == [.skip, .replace])
        #expect(choices(.useIncoming, [editedHere]) == nil && choices(.useIncoming, [same]) == nil, "nothing there to use")
        #expect(CredentialImportReview.availableActions(for: [editedHere]) == [.keepSaved, .keepBoth, .skip])
        #expect(CredentialImportReview.availableActions(for: [same]) == [.keepSaved, .skip], "no second copy of what is the same")
        #expect(choices(.keepBoth, [same, changedThere]) == [.skip, .addSeparately])
    }

    @Test func changesFollowTheActionAndNeverReplaceAPassword() throws {
        let login = record(.password, .bothChanged, conflict: true, destination: nil)
        let code = record(.totp, .new)
        func choices(_ action: CredentialImportReview.ItemAction, _ records: [Record]) -> [CredentialImportChoice?]? {
            CredentialExchangeCoordinator.changes(for: action, records: records, replaced: [:])?.map(\.choice)
        }
        #expect(choices(.skip, [login, code]) == [.skip, .skip])
        #expect(choices(.keepSaved, [login, code]) == [.skip], "only a part that conflicts has a saved version to keep")
        #expect(choices(.useIncoming, [login, code]) == [.replace])
        #expect(choices(.keepBoth, [login, code]) == [.addSeparately])
        #expect(choices(.importNew, [login, code]) == nil, "an item with a saved counterpart is not imported as a second copy")
        let fresh = record(.password, .new)
        #expect(choices(.importNew, [fresh, code]) == [nil, nil], "parts without a conflict go where they go by default")
        #expect(choices(.keepSaved, [code]) == nil && choices(.useIncoming, [code]) == nil && choices(.keepBoth, [code]) == nil)

        let dropping = record(.password, .bothChanged, conflict: true, destination: nil, removesPassword: true)
        #expect(choices(.useIncoming, [dropping]) == nil)
        // Another item already replaces that saved login.
        let taken = [try #require(login.existing): CredentialIdentity.password(accountID: UUID())]
        #expect(CredentialExchangeCoordinator.changes(for: .useIncoming, records: [login], replaced: taken) == nil)
    }
}
