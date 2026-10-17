// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Testing

@testable import WSurf

// Exact duplicates in a system import (spec §13.3): an item no saved credential is linked to, whose login is the same site, username
// and password as a saved one, or whose passkey is saved already. Synthetic data only (`example.test` hosts).
@MainActor
extension CredentialExchangeCoordinatorTests {
    /// A saved login as the old Passwords list left it: no field descriptions, no name and no identity of an exporter's item.
    func legacyLogin(password: String = "pw1", origins: [String] = [Self.origin], notes: [String] = []) -> CredentialAccount {
        var saved = account(username: "ada", password: password)
        saved.origins = origins
        saved.notes = notes.isEmpty ? nil : notes.map { CredentialNote(text: $0, field: nil) }
        return saved
    }

    /// The passkey `saved`, as the other app sends it.
    func sent(_ saved: WebsitePasskey) -> ASImportableCredential {
        .passkey(.init(
            credentialID: saved.credentialID, relyingPartyIdentifier: saved.rpID, userName: saved.userName,
            userDisplayName: saved.userDisplayName, userHandle: saved.userHandle, key: saved.privateKeyPKCS8
        ))
    }

    // MARK: - Already saved

    /// The saved login is the one the other app sends. Nothing is added, and the import records the item, so the next one is unchanged.
    @Test func anIdenticalLegacyLoginIsAlreadySavedAndLinked() async throws {
        try await withFixture { f in
            let saved = legacyLogin()
            try await f.seed([saved] + neighbours(1))
            let transfer = handBuilt([item(id: 1, scoped: true, [password("pw1")])])
            try await f.stage(transfer)

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .saved, in: staged) == ["Item 1"] && staged.sections[.merge] == nil && staged.sections[.new] == nil)
            #expect(item.duplicate?.target == saved.id && item.duplicate?.additions.isEmpty == true && item.duplicate?.linksItem == true)
            #expect(staged.isResolved && item.effect == .linked && staged.tally.linked == 1 && staged.tally.writes == 1)
            #expect(counts(planned(f)) == [0, 0], "linking is not an update")

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            #expect(after.count == 2, "no second copy of the login")
            let linked = try #require(after.first { $0.id == saved.id })
            #expect(linked.username == "ada" && linked.password == "pw1" && linked.origins == saved.origins)
            #expect(linked.exchangeAccountID == Data([0xA0, 0x01]) && linked.exchangeItemID == Data([0xB0, 1]))
            #expect(linked.passwordBase?.itemID == Data([0xB0, 1]), "the import recorded what it brought in")

            // The same transfer again: the item is linked now, so it is compared like any other and nothing is a question.
            try await f.stage(transfer)
            let again = try review(f)
            #expect(again.isResolved && again.tally.unchanged == 1 && again.tally.writes == 0)
            #expect(again.candidates.first?.duplicate == nil && titles(of: .saved, in: again) == ["Item 1"])
        }
    }

    /// An item whose passkey is saved already is the same item, and a login that equals the saved one adds nothing.
    @Test func aPasskeyThatIsSavedAlreadyIsRecognized() async throws {
        try await withFixture { f in
            let held = try passkey(7)
            let saved = account(username: "ada", password: "pw1", passkeys: [held])
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), sent(held)])]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .saved, in: staged) == ["Item 1"] && item.duplicate?.target == saved.id)
            #expect(item.duplicate?.additions.isEmpty == true && item.records.first { $0.kind == .passkey }?.choice == .skip)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            #expect(after.count == 2 && after.first { $0.id == saved.id }?.passkeys.count == 1)
        }
    }

    /// An item with no login is found by its passkey alone, and what it adds goes into the credential that holds the passkey.
    @Test func anItemWithOnlyASavedPasskeyAndANoteMergesIntoTheCredentialThatHoldsIt() async throws {
        try await withFixture { f in
            let held = try passkey(7)
            let saved = account(username: "ada", password: "pw1", passkeys: [held])
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([item(id: 2, scoped: true, [sent(held), plainNote("from the passkey item")])]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .merge, in: staged) == ["Item 2"] && item.duplicate?.target == saved.id)
            #expect(item.duplicate?.additions == [.notes(1)] && staged.isResolved)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            let merged = try #require(after.first { $0.id == saved.id })
            #expect(after.count == 2 && merged.passkeys.count == 1 && merged.notes?.map(\.text) == ["from the passkey item"])
            #expect(merged.password == "pw1" && merged.exchangeItemID == Data([0xB0, 2]))
        }
    }

    /// A passkey that is saved is never a reason to import the rest of the item twice.
    @Test func aSavedPasskeyOnItsOwnIsAlreadySaved() async throws {
        try await withFixture { f in
            let held = try passkey(7)
            let saved = account(username: "", password: nil, passkeys: [held])
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([item(id: 2, scoped: true, [sent(held)])]))

            let staged = try review(f)
            #expect(titles(of: .saved, in: staged) == ["Item 2"] && staged.isResolved && staged.tally.unchanged == 1)
            #expect(staged.candidates.first?.duplicate?.isMergeable == false && staged.tally.writes == 0)
        }
    }

    // MARK: - Suggested merges

    /// The item brings a note the saved login lacks: the merge adds it and replaces nothing.
    @Test func anItemWithAnExtraNoteIsASuggestedMergeThatOnlyAddsTheNote() async throws {
        try await withFixture { f in
            let saved = legacyLogin(notes: ["mine"])
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), plainNote("memo")])]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .merge, in: staged) == ["Item 1"] && staged.isResolved)
            #expect(item.duplicate?.target == saved.id && item.duplicate?.additions == [.notes(1)] && item.effect == .merge)
            #expect(item.records.first { $0.kind == .note }?.choice == .merge(into: saved.id))
            #expect(item.records.first { $0.kind == .password }?.choice == .merge(into: saved.id), "the login is the same, and is kept")
            #expect(counts(planned(f)) == [0, 1])

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            let merged = try #require(after.first { $0.id == saved.id })
            #expect(after.count == 2 && merged.notes?.map(\.text) == ["mine", "memo"] && merged.password == "pw1")
            #expect(merged.exchangeItemID == Data([0xB0, 1]))
        }
    }

    @Test func aMergeAddsThePasskeyTheCodeAndTheWebsitesTheSavedLoginLacks() async throws {
        try await withFixture { f in
            let saved = legacyLogin(origins: ["https://www.example.test"])
            let extra = try passkey(9)
            try await f.seed([saved] + neighbours(1))
            let transfer = handBuilt([item(id: 1, scoped: true, url: "https://login.example.test/signin", [password("pw1"), totpCredential(), sent(extra)])])
            try await f.stage(transfer)

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .merge, in: staged) == ["Item 1"] && staged.isResolved)
            #expect(item.duplicate?.additions == [.passkeys(1), .code, .websites(1)])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            let merged = try #require(after.first { $0.id == saved.id })
            #expect(after.count == 2 && merged.passkeys.map(\.credentialID) == [extra.credentialID] && merged.totp != nil)
            #expect(merged.origins == ["https://www.example.test", "https://login.example.test"], "its own website stays first")
            #expect(merged.loginURLs.map(\.absoluteString) == ["https://login.example.test/signin"])
            #expect(merged.passwordBase != nil && merged.totpBase != nil)

            // Next time the item is known, and unchanged.
            try await f.stage(transfer)
            let again = try review(f)
            #expect(again.isResolved && again.tally.unchanged == 1 && again.tally.writes == 0)
        }
    }

    /// Only the same registrable site counts; a site that shares a public suffix does not.
    @Test func publicSuffixSiblingsAreNotDuplicates() async throws {
        try await withFixture { f in
            try await f.seed([legacyLogin(origins: ["https://a.github.io"])] + neighbours(1))
            try await f.stage(handBuilt([item(id: 1, scoped: true, url: "https://b.github.io/", [password("pw1")])]))
            let staged = try review(f)
            #expect(titles(of: .new, in: staged) == ["Item 1"] && staged.candidates.first?.duplicate == nil)
            #expect(counts(planned(f)) == [1, 0])
        }
    }

    // MARK: - Not duplicates

    /// The same site and username with another password is a different login, as it always was: no default merges it.
    @Test func aDifferentPasswordIsNotADuplicate() async throws {
        try await withFixture { f in
            let saved = legacyLogin()
            try await f.seed([saved] + neighbours(1))
            let before = try f.diskBytes()
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("another-password"), plainNote("memo")])]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .new, in: staged) == ["Item 1"] && item.duplicate == nil && staged.sections[.merge] == nil)
            #expect(item.records.allSatisfy { $0.choice == nil && $0.destination == .newAccount(origins: [Self.origin]) })
            #expect(counts(planned(f)) == [1, 0])
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)
            #expect(try f.diskBytes() == before)
        }
    }

    /// Another username on the same site is another login.
    @Test func aDifferentUsernameIsNotADuplicate() async throws {
        try await withFixture { f in
            try await f.seed([legacyLogin()] + neighbours(1))
            let other = ASImportableCredential.basicAuthentication(.init(
                userName: .init(id: nil, fieldType: .string, value: "grace", label: nil),
                password: .init(id: nil, fieldType: .concealedString, value: "pw1", label: nil)
            ))
            try await f.stage(handBuilt([item(id: 1, scoped: true, [other])]))
            #expect(titles(of: .new, in: try review(f)) == ["Item 1"])
        }
    }

    /// A saved code is never replaced: an item with another code is left as it was.
    @Test func anItemWithAnotherCodeThanTheSavedOneIsNotADuplicate() async throws {
        try await withFixture { f in
            var saved = legacyLogin()
            saved.totp = generator()
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), totpCredential()])]))
            let staged = try review(f)
            #expect(titles(of: .new, in: staged) == ["Item 1"] && staged.candidates.first?.duplicate == nil)
        }
    }

    /// Two items cannot fill one saved credential's code: the first merges, and the other stays as it was.
    @Test func twoItemsCannotFillOneSavedCode() async throws {
        try await withFixture { f in
            try await f.seed([legacyLogin()] + neighbours(1))
            try await f.stage(handBuilt([
                item(id: 1, scoped: true, [password("pw1"), totpCredential(period: 30)]),
                item(id: 2, scoped: true, [password("pw1"), totpCredential(period: 60)]),
            ]))
            let staged = try review(f)
            #expect(titles(of: .merge, in: staged) == ["Item 1"] && titles(of: .new, in: staged) == ["Item 2"] && staged.isResolved)
            #expect(counts(planned(f)) == [1, 1])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            #expect(after.count == 3 && after.filter { $0.password == "pw1" }.count == 2)
            #expect(after.first { $0.exchangeItemID == Data([0xB0, 1]) }?.totp?.period == 30)
        }
    }

    /// A saved credential that is another item's keeps that link. What the item adds still goes in.
    @Test func aSavedCredentialLinkedElsewhereKeepsItsLinkAndStillTakesWhatIsMissing() async throws {
        try await withFixture { f in
            var saved = legacyLogin()
            saved.exchangeAccountID = Data([0x01])
            saved.exchangeItemID = Data([0x02])
            try await f.seed([saved] + neighbours(1))

            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1")])]))
            let contained = try review(f)
            #expect(titles(of: .saved, in: contained) == ["Item 1"] && contained.candidates.first?.duplicate?.linksItem == false)
            #expect(contained.isResolved && contained.tally.unchanged == 1 && contained.tally.writes == 0)
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)

            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), plainNote("memo")])]))
            #expect(titles(of: .merge, in: try review(f)) == ["Item 1"])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let merged = try #require(try await f.stored().accounts.first { $0.id == saved.id })
            #expect(merged.notes?.map(\.text) == ["memo"] && merged.exchangeItemID == Data([0x02]) && merged.exchangeAccountID == Data([0x01]))
            #expect(merged.passwordBase == nil, "it was not the other app's item")
        }
    }

    // MARK: - Websites

    /// An item with websites on several sites, for the tests of what a merge may add. The importer keeps them sorted.
    func item(id: UInt8, sites: [String], _ credentials: [ASImportableCredential]) -> ASImportableItem {
        ASImportableItem(
            id: Data([0xB0, id]), created: .distantPast, lastModified: .distantPast, title: "Item \(id)", subtitle: nil, favorite: false,
            scope: ASImportableCredentialScope(urls: sites.compactMap { URL(string: $0) }, androidApps: []), credentials: credentials, tags: []
        )
    }

    /// An item that is found by its passkey takes the websites on the passkey's own site by default.
    @Test func aPasskeyMatchAddsAWebsiteOnTheRelyingPartysSiteByDefault() async throws {
        try await withFixture { f in
            let held = try passkey(7)
            let saved = account(username: "ada", password: "pw1", passkeys: [held])
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([item(id: 3, sites: ["https://login.example.test/signin"], [sent(held), plainNote("n")])]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .merge, in: staged) == ["Item 3"] && staged.isResolved)
            #expect(item.duplicate?.additions == [.notes(1), .websites(1)] && item.duplicate?.notAdded == [] && item.effect == .merge)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let merged = try #require(try await f.stored().accounts.first { $0.id == saved.id })
            #expect(merged.origins == [Self.origin, "https://login.example.test"] && merged.password == "pw1")
        }
    }

    /// A website on another site is not carried, and the item waits for the user: the merge is not the default. Even decided, the
    /// merge leaves it out, so the saved password is never filled there.
    @Test func aPasskeyMatchDoesNotCarryAnotherSiteAndWaitsForADecision() async throws {
        try await withFixture { f in
            let held = try passkey(7)
            let saved = account(username: "ada", password: "pw1", passkeys: [held])
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([
                item(id: 3, sites: ["https://login.example.test/signin", "https://other.test/"], [sent(held), plainNote("n")]),
            ]))

            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .decide, in: staged) == ["Item 3"] && !staged.isResolved && item.effect == .undecided)
            #expect(item.duplicate?.origins == ["https://login.example.test"] && item.duplicate?.notAdded == ["https://other.test"])
            #expect(item.statusLine.contains("other.test") && item.statusLine.contains("a note"), "the row says what is and is not added")
            await #expect(throws: CredentialExchangeCoordinatorError.unresolvedConflicts) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }

            try f.coordinator.chooseItem(.mergeIntoSaved, for: item.id, owner: f.owner)
            let decided = try review(f)
            #expect(decided.isResolved && decided.candidates.first?.effect == .merge && counts(planned(f)) == [0, 1])
            #expect(decided.candidates.first?.statusLine.contains("other.test") == true, "still listed as not added")
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let merged = try #require(try await f.stored().accounts.first { $0.id == saved.id })
            #expect(merged.origins == [Self.origin, "https://login.example.test"], "nothing on other.test")
            #expect(merged.notes?.map(\.text) == ["n"] && merged.password == "pw1")
        }
    }

    /// A login match has the same rule: a website on a site the two did not match on is never carried into a saved password's
    /// credential, whichever way the user decides the item.
    @Test func aSavedPasswordNeverGainsASiteItWasNotMatchedOn() async throws {
        for action in [CredentialImportReview.ItemAction.mergeIntoSaved, .skip, .importNew] {
            try await withFixture { f in
                let saved = legacyLogin()
                try await f.seed([saved] + neighbours(1))
                let before = try #require(try await f.stored().accounts.first { $0.id == saved.id })
                let diskBefore = try f.diskBytes()
                try await f.stage(handBuilt([
                    item(id: 1, sites: [Self.origin + "/login", "https://other.test/"], [password("pw1"), plainNote("memo")]),
                ]))

                let staged = try review(f)
                let item = try #require(staged.candidates.first)
                #expect(titles(of: .decide, in: staged) == ["Item 1"] && !staged.isResolved, "nothing is merged by default")
                #expect(item.duplicate?.origins == [] && item.duplicate?.notAdded == ["https://other.test"])
                try f.coordinator.chooseItem(action, for: item.id, owner: f.owner)

                switch action {
                case .skip:
                    #expect(counts(planned(f)) == [0, 0])
                    f.coordinator.cancelImport(for: f.manager, owner: f.owner)
                    #expect(try f.diskBytes() == diskBefore)
                case .importNew:
                    _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
                    let after = try await f.stored().accounts
                    #expect(after.first { $0.id == saved.id } == before, "the saved credential is untouched")
                    #expect(after.first { $0.exchangeItemID == Data([0xB0, 1]) }?.origins == ["https://example.test", "https://other.test"])
                default:
                    _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
                    let merged = try #require(try await f.stored().accounts.first { $0.id == saved.id })
                    #expect(merged.origins == [Self.origin] && merged.notes?.map(\.text) == ["memo"] && merged.password == "pw1")
                }
            }
        }
    }

    /// Linking is the merge too: an item that adds nothing but lists another site waits as well. One that can't be merged at all
    /// has nothing to decide, and says what it leaves out.
    @Test func otherSitesAskForADecisionOnlyWhereTheMergeWouldBeTheDefault() async throws {
        try await withFixture { f in
            try await f.seed([legacyLogin()] + neighbours(1))
            try await f.stage(handBuilt([item(id: 1, sites: [Self.origin, "https://other.test/"], [password("pw1")])]))
            let linking = try review(f)
            #expect(titles(of: .decide, in: linking) == ["Item 1"] && linking.candidates.first?.duplicate?.additions == [])
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)
        }
        try await withFixture { f in
            var saved = legacyLogin()
            saved.exchangeAccountID = Data([0x01])
            saved.exchangeItemID = Data([0x02])
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([item(id: 1, sites: [Self.origin, "https://other.test/"], [password("pw1")])]))
            let staged = try review(f)
            let item = try #require(staged.candidates.first)
            #expect(titles(of: .saved, in: staged) == ["Item 1"] && staged.isResolved && item.duplicate?.isMergeable == false)
            #expect(item.statusLine.contains("other.test"))
        }
    }

    // MARK: - Deciding

    @Test func theUserCanImportADuplicateAsNewOrSkipItOrMergeItAgain() async throws {
        try await withFixture { f in
            let saved = legacyLogin()
            try await f.seed([saved] + neighbours(1))
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), plainNote("memo")])]))
            let id = try #require(try review(f).candidates.first).id
            let owner = f.owner

            try f.coordinator.chooseItem(.importNew, for: id, owner: owner)
            #expect(try review(f).candidates.first?.effect == .new && counts(planned(f)) == [1, 0])
            try f.coordinator.chooseItem(.skip, for: id, owner: owner)
            let skipped = try review(f)
            #expect(skipped.candidates.first?.effect == .unchanged && skipped.tally.writes == 0)
            #expect(try f.coordinator.chooseAll(.mergeIntoSaved, in: .merge, owner: owner) == 1)
            #expect(try review(f).candidates.first?.effect == .merge && counts(planned(f)) == [0, 1])

            _ = try await f.coordinator.commitImport(into: f.manager, owner: owner)
            #expect(try await f.stored().accounts.count == 2)
        }
    }

    /// Imported as a new credential, the item takes nothing from the saved one and gives it nothing.
    @Test func aDuplicateImportedAsNewLeavesTheSavedCredentialAlone() async throws {
        try await withFixture { f in
            let saved = legacyLogin()
            try await f.seed([saved] + neighbours(1))
            let before = try #require(try await f.stored().accounts.first { $0.id == saved.id })
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("pw1"), plainNote("memo")])]))
            try f.coordinator.chooseItem(.importNew, for: try #require(try review(f).candidates.first).id, owner: f.owner)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            #expect(after.count == 3 && after.first { $0.id == saved.id } == before)
            #expect(after.first { $0.exchangeItemID == Data([0xB0, 1]) }?.notes?.map(\.text) == ["memo"])
        }
    }

    // MARK: - Scale

    /// A library whose every login is saved already, as the old list left it: the other app's copy of each is found with one lookup and
    /// not a search, whatever the size. Half the items add a note, and every twentieth a code. The time limit catches a step that grows
    /// with the square of the library.
    @Test(.timeLimit(.minutes(5)))
    func importOf20000ItemsThatAreAllSavedAlreadyIsLinear() async throws {
        let clock = ContinuousClock()
        let count = 20_000
        func format(_ duration: Duration) -> String {
            duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        }
        // As the old list left them: a login each, on the website the other app sends, with no identity of an exporter's item.
        let saved = (0..<count).map { index in
            CredentialAccount(
                id: UUID(), username: "user\(index)", displayName: nil, origins: ["https://site\(index).example.test"], loginURLs: [],
                password: "password-\(index)", passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
            )
        }
        // The same logins under the other app's identities. The even ones also hold a note, and every twentieth a code.
        let sent = ExchangeScale.transfer((0..<count).map { index in
            var credentials = [ExchangeScale.login(index)]
            if index.isMultiple(of: 2) {
                credentials.append(ExchangeScale.note(index, bytes: 100))
            }
            if index.isMultiple(of: 20) {
                credentials.append(ExchangeScale.totp(index))
            }
            return ExchangeScale.item(index, credentials: credentials)
        })
        try await withFixture { f in
            try await f.seed(saved)
            #expect(try await f.stored().accounts.count == count)

            let staging = try await clock.measure { try await f.stage(sent) }
            print("[scale] stage 20,000 duplicates: \(format(staging))")
            let staged = try review(f)
            #expect(staged.candidates.count == count && staged.isResolved)
            #expect(staged.sections[.saved]?.count == count / 2 && staged.sections[.merge]?.count == count / 2)
            #expect(staged.sections[.new] == nil && staged.tally.linked == count / 2 && staged.tally.merges == count / 2)

            var outcome: CredentialImportOutcome?
            let planning = clock.measure { outcome = planned(f) }
            print("[scale] plan 20,000 duplicates: \(format(planning))")
            #expect(counts(outcome) == [0, count / 2], "the contents of half of them change; the rest are only linked")
            let committing = try await clock.measure { _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner) }
            print("[scale] commit 20,000 duplicates: \(format(committing))")

            let after = try await f.stored().accounts
            #expect(after.count == count, "not one login was saved twice")
            #expect(after.allSatisfy { $0.exchangeItemID != nil && $0.passwordBase != nil })
            #expect(after.filter { $0.notes?.count == 1 }.count == count / 2 && after.filter { $0.totp != nil }.count == count / 20)

            // The next import of it is unchanged.
            try await f.stage(sent)
            let next = try review(f)
            #expect(next.isResolved && next.tally.unchanged == count && next.tally.writes == 0)
        }
    }
}
