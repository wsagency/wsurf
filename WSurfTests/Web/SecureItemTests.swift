// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Secure items are an optional credential part: validated on their own, hashed as their own part, diffed and removed like notes, and
/// united (never doubled, never dropped) by a merge. Pure: no store. Synthetic values only.
struct SecureItemTests {
    private typealias Fixtures = SecureItemFixtures

    private nonisolated static let planted = [Fixtures.card(), Fixtures.address()]

    private let id = VaultFixtures.fixedAccountID

    private func rich() throws -> CredentialAccount {
        try VaultFixtures.richAccount()
    }

    private func withItems(_ edit: (inout CredentialAccount) -> Void = { _ in }) throws -> CredentialAccount {
        var account = try rich()
        account.secureItems = Self.planted
        edit(&account)
        return account
    }

    private func diff(old: CredentialAccount, new: CredentialAccount) throws -> CredentialChangePlan {
        try CredentialDiff.plan(old: [old], new: [new])
    }

    private func diff(editing edit: (inout CredentialAccount) throws -> Void) throws -> CredentialChangePlan {
        let old = try rich()
        var new = old
        try edit(&new)
        return try diff(old: old, new: new)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ revision: RevisionDraft) throws -> T {
        try JSONDecoder().decode(type, from: revision.superseded)
    }

    private func pick(_ subject: RecordSubject, in plan: CredentialChangePlan) throws -> RevisionDraft {
        let matches = plan.revisions.filter { $0.subject == subject }
        #expect(matches.count == 1)
        return try #require(matches.first)
    }

    private func expectNoWork(_ plan: CredentialChangePlan) {
        #expect(plan.revisions.isEmpty)
        #expect(plan.removals.isEmpty)
    }

    private func sshKey(privateKey: String) -> SecureItem {
        SecureItem(kind: .sshKey, fields: [Fixtures.field("keyType", "ssh-ed25519"), Fixtures.field("privateKey", privateKey)])
    }

    // MARK: Validation

    @Test func aCardOnlyAccountValidates() throws {
        try Fixtures.account([Fixtures.card()]).validate()
        try Fixtures.account([Fixtures.card(), Fixtures.address(), Fixtures.name(), Fixtures.wifi(), Fixtures.custom()]).validate()

        // Items sit beside a login too.
        var withLogin = VaultFixtures.account()
        withLogin.secureItems = [Fixtures.wifi()]
        try withLogin.validate()
    }

    @Test func anEmptyItemListIsRefused() {
        #expect(throws: (any Error).self) { try Fixtures.account([]).validate() }
        var withLogin = VaultFixtures.account()
        withLogin.secureItems = []
        #expect(throws: (any Error).self) { try withLogin.validate() }
    }

    @Test func moreThanTheItemLimitIsRefused() throws {
        let atLimit = (0..<SecureItem.itemLimit).map { Fixtures.name(given: "Given \($0)") }
        try Fixtures.account(atLimit).validate()
        #expect(throws: (any Error).self) { try Fixtures.account(atLimit + [Fixtures.name(given: "one more")]).validate() }
    }

    @Test func moreThanTheFieldLimitIsRefused() throws {
        func custom(_ count: Int) -> SecureItem {
            SecureItem(kind: .customFields, label: "Many", fields: (0..<count).map { Fixtures.field("", "value \($0)", type: .string) })
        }
        try custom(SecureItem.fieldLimit).validate()
        #expect(throws: (any Error).self) { try custom(SecureItem.fieldLimit + 1).validate() }
    }

    @Test func aMemberTheKindDoesNotHaveIsRefused() throws {
        var card = Fixtures.card()
        card.fields.append(Fixtures.field("ssid", "Synthetic-Net", type: .string))
        #expect(throws: (any Error).self) { try card.validate() }

        let unknown = SecureItem(kind: .wifi, fields: [Fixtures.field("nonsense", "x", type: .string)])
        #expect(throws: (any Error).self) { try unknown.validate() }

        // The same member under its own kind is fine.
        try SecureItem(kind: .wifi, fields: [Fixtures.field("ssid", "Synthetic-Net", type: .string)]).validate()
    }

    @Test func aMemberThatAppearsTwiceIsRefused() {
        var card = Fixtures.card()
        card.fields.append(Fixtures.field("number", "1111", type: .string))
        #expect(throws: (any Error).self) { try card.validate() }
    }

    @Test func aCustomFieldWithANameIsRefused() throws {
        try Fixtures.custom().validate()
        var custom = Fixtures.custom()
        custom.fields[0].name = "number"
        #expect(throws: (any Error).self) { try custom.validate() }
    }

    @Test func anItemOfAKindWithMembersCannotCarryAnIDOrALabel() throws {
        try Fixtures.card().validate()

        var withID = Fixtures.card()
        withID.id = Data([1])
        #expect(throws: (any Error).self) { try withID.validate() }

        var withLabel = Fixtures.card()
        withLabel.label = "Personal"
        #expect(throws: (any Error).self) { try withLabel.validate() }
    }

    @Test func anEmptyValueIsRefused() {
        var card = Fixtures.card()
        card.fields[1].value = ""
        #expect(throws: (any Error).self) { try card.validate() }

        var custom = Fixtures.custom()
        custom.fields[0].value = ""
        #expect(throws: (any Error).self) { try custom.validate() }
    }

    @Test func anItemWithNoFieldsAndNoLabelIsRefused() throws {
        #expect(throws: (any Error).self) { try SecureItem(kind: .address, fields: []).validate() }
        #expect(throws: (any Error).self) { try SecureItem(kind: .customFields, fields: []).validate() }

        // A custom group may be a title alone.
        try SecureItem(kind: .customFields, id: nil, label: "Empty group", fields: []).validate()
    }

    @Test func anSSHPrivateKeyMustBeBase64URL() throws {
        try sshKey(privateKey: WebAuthnWire.base64URL(Data([1, 2, 3]))).validate()

        // Standard base64 characters, padding and free text are not base64url.
        for notBase64URL in ["not base64url!", "AQ+/", "AQID="] {
            let key = sshKey(privateKey: notBase64URL)
            #expect(throws: (any Error).self) { try key.validate() }
        }
    }

    @Test func anSSHPlainMemberCannotCarryAFieldDescription() throws {
        let valid = WebAuthnWire.base64URL(Data([1, 2, 3]))
        let described = SecureItem(kind: .sshKey, fields: [Fixtures.field("keyType", "ssh-ed25519", type: .string)])
        #expect(throws: (any Error).self) { try described.validate() }

        let describedKey = SecureItem(kind: .sshKey, fields: [Fixtures.field("privateKey", valid, type: .concealedString)])
        #expect(throws: (any Error).self) { try describedKey.validate() }

        // Without the description both are valid.
        try sshKey(privateKey: valid).validate()
    }

    // MARK: Concealed

    @Test func aMemberThatIsAlwaysHiddenIsConcealedWhateverTypeTheExporterGaveIt() throws {
        let card = Fixtures.card()
        let number = try #require(card.fields.first { $0.name == "number" })
        #expect(number.field?.fieldType == .string)
        #expect(card.isConcealed(number))

        let code = try #require(card.fields.first { $0.name == "verificationNumber" })
        #expect(card.isConcealed(code))

        let holder = try #require(card.fields.first { $0.name == "fullName" })
        #expect(!card.isConcealed(holder))

        // A plain SSH private key has no description at all and is still hidden; the key type is not.
        let key = sshKey(privateKey: WebAuthnWire.base64URL(Data([1, 2, 3])))
        #expect(key.fields.allSatisfy { $0.field == nil })
        #expect(key.fields.map { key.isConcealed($0) } == [false, true])
    }

    @Test func aFieldTheExporterMarkedHiddenIsConcealedWhateverItsMember() {
        var wifi = Fixtures.wifi()
        #expect(!wifi.isConcealed(wifi.fields[0]))
        wifi.fields[0].field?.fieldType = .concealedString
        #expect(wifi.isConcealed(wifi.fields[0]))
    }

    @Test func aCustomFieldIsConcealedOnlyWhenItsTypeSaysSo() {
        let item = Fixtures.custom(values: [("Code", "4711", true), ("Hint", "blue", false)])
        #expect(item.isConcealed(item.fields[0]))
        #expect(!item.isConcealed(item.fields[1]))
    }

    @Test func valueFindsTheFirstValueOfAMember() {
        let card = Fixtures.card()
        #expect(card.value("fullName") == "Ada Lovelace")
        #expect(card.value("pin") == nil)
    }

    // MARK: Hash

    @Test func itemsNeverChangeTheHashOfAnotherPart() throws {
        let plain = try rich()
        var withItems = plain
        withItems.secureItems = Self.planted
        let others: [(CredentialAccount) -> CredentialPart] = [
            { .password($0) }, { .totp($0) }, { .passkey($0.passkeys[0]) }, { .note($0) }, { .metadata($0) },
        ]
        for part in others {
            #expect(try CredentialContent.hash(part(withItems)) == CredentialContent.hash(part(plain)))
        }

        // And no other part's change moves the items' hash.
        var edited = withItems
        edited.password = "other"
        edited.totp?.secret = Data([9])
        edited.displayName = "Home"
        edited.notes = [CredentialNote(text: "memo", field: nil)]
        #expect(try CredentialContent.hash(.secureItems(edited)) == CredentialContent.hash(.secureItems(withItems)))

        // An account that never had items hashes the same as one whose items were cleared.
        var cleared = withItems
        cleared.secureItems = nil
        #expect(try CredentialContent.hash(.secureItems(cleared)) == CredentialContent.hash(.secureItems(plain)))
    }

    @Test func theItemsHashCoversKindIDLabelFieldNameValueAndType() throws {
        func hash(_ items: [SecureItem]?) throws -> Data {
            var account = try rich()
            account.secureItems = items
            return try CredentialContent.hash(.secureItems(account))
        }
        func variant(_ edit: (inout SecureItem) -> Void) -> [SecureItem] {
            var item = Fixtures.name()
            edit(&item)
            return [item]
        }

        let hashes = try [
            hash(nil),
            hash([Fixtures.name()]),
            hash(variant { $0.kind = .address }),
            hash(variant { $0.id = Data([1]) }),
            hash(variant { $0.id = Data([2]) }),
            hash(variant { $0.label = "Home" }),
            hash(variant { $0.label = "Work" }),
            hash(variant { $0.fields[0].name = "given2" }),
            hash(variant { $0.fields[0].value = "Grace" }),
            hash(variant { $0.fields[0].field = nil }),
            hash(variant { $0.fields[0].field?.fieldType = .concealedString }),
            hash(variant { $0.fields[0].field?.label = "First" }),
            hash(variant { $0.fields[0].field?.id = Data([3]) }),
            hash(variant { $0.fields.swapAt(0, 1) }),
            hash(variant { _ = $0.fields.removeLast() }),
            hash([Fixtures.name(), Fixtures.address()]),
            hash([Fixtures.address(), Fixtures.name()]),
            // The exact UTF-8 counts: a composed and a decomposed "é" are two different values.
            hash(variant { $0.fields[0].value = "\u{e9}" }),
            hash(variant { $0.fields[0].value = "e\u{301}" }),
        ]
        #expect(Set(hashes).count == hashes.count)
    }

    // MARK: Diff

    @Test func anItemEditCreatesOneSecureItemRevisionOfTheEarlierList() throws {
        let old = try withItems()
        var new = old
        new.secureItems = [Fixtures.wifi()]

        let plan = try diff(old: old, new: new)

        #expect(plan.persistence == .semantic)
        #expect(plan.revisions.count == 1)
        let revision = try pick(.secureItem, in: plan)
        #expect(revision.ownerID == id)
        #expect(try decode([SecureItem].self, revision) == Self.planted)
        #expect(plan.removals.isEmpty)
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func addingTheFirstItemsSupersedesNothing() throws {
        let plan = try diff { $0.secureItems = Self.planted }

        #expect(plan.persistence == .semantic)
        expectNoWork(plan)
        #expect(plan.touched == [id])
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func clearingTheItemsKeepsThemAsAnEarlierVersion() throws {
        let plan = try diff(old: withItems(), new: rich())

        #expect(plan.persistence == .semantic)
        #expect(plan.removals.isEmpty)
        #expect(plan.revisions.count == 1)
        let revision = try pick(.secureItem, in: plan)
        #expect(revision.ownerID == id)
        #expect(try decode([SecureItem].self, revision) == Self.planted)
        #expect(plan.setsModifiedAt == [id])
    }

    @Test func onlyAnExplicitItemsDeleteMovesThemToTrash() throws {
        let itemsDelete = RemovalScope.credential(ownerID: id, subject: .secureItem, passkeyID: nil)
        let plan = try CredentialDiff.plan(old: [withItems()], new: [rich()], removing: itemsDelete)

        #expect(plan.removals == [itemsDelete])
        #expect(plan.revisions.isEmpty)
        #expect(plan.setsModifiedAt == [id])

        // A delete of another part, or of another account's items, does not turn an items edit into a removal.
        let other = [
            RemovalScope.credential(ownerID: id, subject: .totp, passkeyID: nil),
            RemovalScope.credential(ownerID: id, subject: .note, passkeyID: nil),
            RemovalScope.credential(ownerID: UUID(), subject: .secureItem, passkeyID: nil),
        ]
        for scope in other {
            let edit = try CredentialDiff.plan(old: [withItems()], new: [rich()], removing: scope)
            #expect(edit.removals.isEmpty && edit.revisions.map(\.subject) == [.secureItem])
        }
    }

    @Test func anItemEditLeavesEveryOtherPartAlone() throws {
        let old = try withItems()
        var new = old
        new.secureItems?[1].fields[0].value = "2 Synthetic Way"

        let plan = try diff(old: old, new: new)

        #expect(plan.revisions.map(\.subject) == [.secureItem])
        #expect(plan.removals.isEmpty)
    }

    @Test func aPasswordEditLeavesTheItemsAlone() throws {
        let old = try withItems()
        var new = old
        new.password = "changed"

        let plan = try diff(old: old, new: new)

        #expect(plan.revisions.map(\.subject) == [.password])
        #expect(plan.removals.isEmpty)
    }

    // MARK: Removing

    @Test func removingThePasswordKeepsAnAccountThatStillHasItems() throws {
        let owner = try withItems {
            $0.totp = nil
            $0.passkeys = []
        }
        let scope = RemovalScope.credential(ownerID: id, subject: .password, passkeyID: nil)

        let proposal = try ProfileVaultStore.removing(scope, from: [owner])

        #expect(proposal.requires == scope)
        let kept = try #require(proposal.accounts.first)
        #expect(proposal.accounts.count == 1 && kept.password == nil && kept.username.isEmpty)
        #expect(kept.secureItems == Self.planted)
        try kept.validate()

        // Without items the same removal leaves nothing valid, so the whole account goes.
        var itemless = owner
        itemless.secureItems = nil
        let whole = try ProfileVaultStore.removing(scope, from: [itemless])
        #expect(whole.accounts.isEmpty && whole.requires == .account(id))
    }

    @Test func removingTheItemsKeepsTheRestAndRefusesWhenThereAreNone() throws {
        let scope = RemovalScope.credential(ownerID: id, subject: .secureItem, passkeyID: nil)

        let proposal = try ProfileVaultStore.removing(scope, from: [withItems()])

        #expect(proposal.requires == scope)
        #expect(proposal.accounts.first?.secureItems == nil)
        #expect(proposal.accounts.first?.password == "s3cret")
        #expect(throws: CredentialVaultError.invalidData) { try ProfileVaultStore.removing(scope, from: [rich()]) }

        // A card-only account has nothing else, so removing its items removes the account.
        let cardOnly = Fixtures.account([Fixtures.card()], id: id)
        let whole = try ProfileVaultStore.removing(scope, from: [cardOnly])
        #expect(whole.accounts.isEmpty && whole.requires == .account(id))
    }

    // MARK: Uniting

    @Test func unitingKeepsIdenticalItemsOnceAndAppendsNewOnesInOrder() throws {
        let card = Fixtures.card()
        let wifi = Fixtures.wifi()
        let address = Fixtures.address()

        let united = try [card, wifi].uniting([wifi, address, card, Fixtures.name()])
        #expect(united == [card, wifi, address, Fixtures.name()])

        // Items that differ in one value are different items; a repeat inside the incoming list collapses.
        #expect(try [card].uniting([Fixtures.card(code: "000")]).count == 2)
        #expect(try [card].uniting([address, address]) == [card, address])
        #expect(try [card].uniting([]) == [card])
        #expect(try [SecureItem]().uniting([card]) == [card])
    }

    // MARK: Merge

    private func picks(_ survivor: CredentialAccount) -> MergePicks {
        MergePicks(survivor: survivor.id, name: survivor.id, login: survivor.id, code: survivor.id)
    }

    @Test func mergingACardOnlyCredentialKeepsTheCardOnTheSurvivor() throws {
        let keeper = VaultFixtures.account(username: "ada", password: "pw")
        let cardOnly = Fixtures.account([Fixtures.card()])

        let merged = try CredentialMerge.merged([keeper, cardOnly], picks: picks(keeper))

        #expect(merged.id == keeper.id)
        #expect(merged.password == "pw")
        #expect(merged.secureItems == [Fixtures.card()])
        #expect(merged.mergedFrom?.map(\.accountID) == [cardOnly.id])
    }

    @Test func mergingUnitesItemsWithoutDoublingOrDroppingOne() throws {
        var keeper = VaultFixtures.account(username: "ada", password: "pw")
        keeper.secureItems = [Fixtures.card(), Fixtures.wifi()]
        var other = VaultFixtures.account(username: "ada", password: "pw")
        other.secureItems = [Fixtures.wifi(), Fixtures.address()]
        let twin = Fixtures.account([Fixtures.card()])

        let merged = try CredentialMerge.merged([keeper, other, twin], picks: picks(keeper))

        #expect(merged.secureItems == [Fixtures.card(), Fixtures.wifi(), Fixtures.address()])
    }

    @Test func mergingTwoIdenticalCardsKeepsOneCard() throws {
        let keeper = Fixtures.account([Fixtures.card()])
        let other = Fixtures.account([Fixtures.card()])

        let merged = try CredentialMerge.merged([keeper, other], picks: picks(keeper))

        #expect(merged.secureItems == [Fixtures.card()])
    }

    @Test func mergeRefusesPastTheItemLimit() {
        var many = VaultFixtures.account(username: "ada", password: "pw")
        many.secureItems = (0..<SecureItem.itemLimit).map { Fixtures.name(given: "Given \($0)") }
        let oneMore = Fixtures.account([Fixtures.name(given: "one more")])

        #expect(throws: CredentialMergeError.itemLimit) { try CredentialMerge.merged([many, oneMore], picks: picks(many)) }
    }
}
