// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// What a credential's cards, addresses and other items add to the list row, the filters and the editor's draft. Pure values: no vault
/// is read. Everything is synthetic; the card number is a published test number. The account id is fixed so a short secret such as a
/// security code can never appear in a printed summary by chance (a random UUID could hold it).
struct CredentialSecureItemSummaryTests {
    private static let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    private func summarize(_ items: [SecureItem], name: String? = "Synthetic item") -> CredentialSummary {
        CredentialSummary(SecureItemFixtures.account(items, id: Self.fixedID, name: name))
    }

    private func named(_ name: String, _ items: [SecureItem]) -> CredentialSummary {
        CredentialSummary(SecureItemFixtures.account(items, name: name))
    }

    /// An item of `kind` with no values: enough for a summary, which never reads a value.
    private func bare(_ kind: SecureItemKind) -> SecureItem {
        SecureItem(kind: kind, fields: [])
    }

    /// One credential per kind of item, one with two kinds, and a plain login: 12 credentials, 11 of them holding items.
    private func library() -> [CredentialSummary] {
        var login = VaultFixtures.account()
        login.displayName = "Login"
        return [
            named("Card", [SecureItemFixtures.card()]),
            named("Address", [SecureItemFixtures.address()]),
            named("Name", [SecureItemFixtures.name()]),
            named("License", [bare(.driversLicense)]),
            named("Passport", [bare(.passport)]),
            named("ID", [bare(.identityDocument)]),
            named("Wi-Fi", [SecureItemFixtures.wifi()]),
            named("API", [bare(.apiKey)]),
            named("SSH", [bare(.sshKey)]),
            named("Custom", [SecureItemFixtures.custom()]),
            named("Card and Wi-Fi", [SecureItemFixtures.card(), SecureItemFixtures.wifi()]),
            CredentialSummary(login),
        ]
    }

    /// A stored credential that also holds a login, so a draft that loses every item still has something to save.
    private func stored(_ items: [SecureItem]) -> CredentialAccount {
        var account = VaultFixtures.account()
        account.secureItems = items
        return account
    }

    /// Types `value` into the item's member the way the editor does.
    private func enter(_ value: String, into member: String, ofItem item: Int, in draft: inout CredentialDraft) throws {
        let position = try #require(draft.secureItems[item].fields.firstIndex { $0.name == member })
        draft.secureItems[item].fields[position].value = value
    }

    // MARK: - The summary

    @Test func aSummaryCarriesNoItemValueExceptTheLastFourDigits() {
        let secrets = [
            SecureItemFixtures.cardNumber, SecureItemFixtures.cardCode, SecureItemFixtures.wifiPassphrase, "Ada Lovelace", "Synthetic-Net",
        ]
        let names: [String?] = [nil, "Synthetic item"]
        for name in names {
            let summary = summarize([SecureItemFixtures.card(), SecureItemFixtures.wifi()], name: name)
            let shown = [String(describing: summary), summary.searchKey, summary.title] + summary.itemTitles
            for text in shown {
                for secret in secrets {
                    #expect(!text.localizedCaseInsensitiveContains(secret), "\(secret) leaked into \(text)")
                }
            }
            #expect(summary.itemTitles.count == 2)
            #expect(summary.itemTitles[0].hasSuffix("•••• 4242"))
            #expect(summary.itemTitles[1] == SecureItemKind.wifi.label, "a Wi-Fi network is called by its kind, never by its name")
        }
    }

    @Test func hiddenItemFieldsNameTheConcealedValuesAndTheirPositions() {
        let summary = summarize([SecureItemFixtures.card(), SecureItemFixtures.wifi(), SecureItemFixtures.address()])
        #expect(summary.hiddenItemFields == [
            SecureFieldReference(item: 0, field: 0, label: String(localized: "Card number")),
            SecureFieldReference(item: 0, field: 2, label: String(localized: "Security code")),
            SecureFieldReference(item: 1, field: 2, label: String(localized: "Password")),
        ])
        #expect(summarize([SecureItemFixtures.address()]).hiddenItemFields.isEmpty)
        #expect(summarize([SecureItemFixtures.name()]).hiddenItemFields.isEmpty)
        #expect(CredentialSummary(VaultFixtures.account()).hiddenItemFields.isEmpty)
    }

    @Test func hiddenItemFieldsFollowTheExportersTypeAndTheMember() {
        // The exporter marked a street hidden: a type decides, not only the member.
        let hiddenStreet = SecureItem(kind: .address, fields: [
            SecureItemFixtures.field("streetAddress", "1 Synthetic Way", type: .concealedString),
            SecureItemFixtures.field("city", "Testville", type: .string),
        ])
        #expect(summarize([hiddenStreet]).hiddenItemFields == [SecureFieldReference(item: 0, field: 0, label: String(localized: "Street"))])

        // An SSH private key is a plain SDK value (no field description) and is hidden because its member is.
        let key = SecureItem(kind: .sshKey, fields: [
            SecureItemField(name: "keyType", value: "ssh-ed25519", field: nil),
            SecureItemField(name: "privateKey", value: "c3ludGhldGlj", field: nil),
        ])
        #expect(summarize([key]).hiddenItemFields == [SecureFieldReference(item: 0, field: 1, label: String(localized: "Private key"))])

        // A custom field is called by its own label, and only its hidden values are listed.
        let custom = SecureItemFixtures.custom(values: [("Plain", "visible", false), ("Code", "4711", true)])
        let summary = summarize([custom])
        #expect(summary.hiddenItemFields == [SecureFieldReference(item: 0, field: 1, label: "Code")])
        #expect(summary.itemTitles == ["Locker"])
    }

    @Test func onlyCardsAndIdentityDocumentsAreSensitive() {
        let sensitive: Set<SecureItemKind> = [.creditCard, .driversLicense, .passport, .identityDocument]
        for kind in SecureItemKind.allCases {
            let summary = summarize([bare(kind)])
            #expect(summary.hasSensitiveItems == sensitive.contains(kind), "\(kind)")
            #expect(summary.itemKinds == [kind])
        }
        #expect(!summarize([SecureItemFixtures.wifi()]).hasSensitiveItems)
        #expect(summarize([SecureItemFixtures.wifi(), SecureItemFixtures.card()]).hasSensitiveItems)

        let plain = CredentialSummary(VaultFixtures.account())
        #expect(plain.itemKinds.isEmpty && plain.itemTitles.isEmpty && !plain.hasSensitiveItems)
    }

    @Test func eachKindIsListedOnceInOrderWhileEveryItemKeepsItsTitle() {
        let second = SecureItemFixtures.card(number: "5555555555554444")
        let summary = summarize([SecureItemFixtures.card(), second, SecureItemFixtures.wifi()])
        #expect(summary.itemKinds == [.creditCard, .wifi])
        #expect(summary.itemTitles.count == 3)
        #expect(summary.itemTitles[0].hasSuffix("•••• 4242") && summary.itemTitles[1].hasSuffix("•••• 4444"))
    }

    @Test func aCardsTitleNeedsFourDigits() {
        let short = SecureItemFixtures.card(number: "42")
        #expect(summarize([short]).itemTitles == [SecureItemKind.creditCard.label])
        #expect(summarize([short], name: nil).title == SecureItemKind.creditCard.label)
    }

    @Test func anUnnamedCredentialIsTitledByItsFirstItemOnlyWhenNothingElseNamesIt() {
        let card = SecureItemFixtures.card()
        let titled = summarize([card], name: nil)
        #expect(titled.title.hasSuffix("•••• 4242"))
        #expect(titled.title == titled.itemTitles.first)
        #expect(summarize([card], name: "").title == titled.title, "an empty name counts as none")
        #expect(summarize([card], name: "Work").title == "Work")

        var withUser = SecureItemFixtures.account([card], name: nil)
        withUser.username = "ada"
        #expect(CredentialSummary(withUser).title == "ada")
        var withSite = withUser
        withSite.origins = ["https://example.test"]
        #expect(CredentialSummary(withSite).title == "example.test")
    }

    // MARK: - Equality

    @Test func summariesDifferWhenOnlyTheirItemsDiffer() {
        let base = summarize([SecureItemFixtures.card()])
        #expect(summarize([SecureItemFixtures.card()]) == base)
        // A hidden value that changes no title, kind or hidden-field list is no row change: a summary carries no secret.
        #expect(summarize([SecureItemFixtures.card(code: "999")]) == base)

        let withoutCode = SecureItem(kind: .creditCard, fields: [SecureItemFixtures.field("number", SecureItemFixtures.cardNumber, type: .string)])
        let others: [[SecureItem]] = [
            [SecureItemFixtures.card(), SecureItemFixtures.wifi()],
            [SecureItemFixtures.card(number: "5555555555554444")],
            [SecureItemFixtures.card(), SecureItemFixtures.card(number: "5555555555554444")],
            [SecureItemFixtures.address()],
            [withoutCode],
            [],
        ]
        for items in others {
            #expect(summarize(items) != base)
        }
        // Same title and kind, fewer hidden values: only the hidden-field list tells them apart.
        #expect(summarize([withoutCode]).itemTitles == base.itemTitles)
        #expect(summarize([withoutCode]).itemKinds == base.itemKinds)
    }

    // MARK: - Filters, search and statistics

    @Test func eachItemFilterSelectsItsKinds() {
        let all = library()
        let expected: [CredentialListFilter: [String]] = [
            .cards: ["Card", "Card and Wi-Fi"],
            .addresses: ["Address", "Name"],
            .documents: ["License", "Passport", "ID"],
            .otherItems: ["Wi-Fi", "API", "SSH", "Custom", "Card and Wi-Fi"],
            .logins: ["Login"],
        ]
        let counts = CredentialListFilter.counts(all)
        for (filter, names) in expected {
            #expect(CredentialListFilter.visible(all, query: "", filter: filter).map(\.title) == names, "\(filter)")
            #expect(counts[filter] == names.count, "\(filter)")
        }
        for filter in CredentialListFilter.allCases {
            #expect(counts[filter] == CredentialListFilter.visible(all, query: "", filter: filter).count, "\(filter)")
        }
        #expect(counts[.all] == all.count)
        #expect(counts[.passkeys] == 0 && counts[.codes] == 0 && counts[.notes] == 0)
        #expect(Set(CredentialListFilter.allCases.filter(\.isItemKind)) == [.cards, .addresses, .documents, .otherItems])
    }

    @Test func searchFindsAnItemByItsTitleAndNeverByASecret() {
        let all = library()
        for filter in [CredentialListFilter.all, .cards] {
            #expect(CredentialListFilter.visible(all, query: "4242", filter: filter).map(\.title) == ["Card", "Card and Wi-Fi"])
        }
        #expect(CredentialListFilter.visible(all, query: "4242", filter: .addresses).isEmpty)
        #expect(CredentialListFilter.visible(all, query: SecureItemKind.wifi.label, filter: .all).map(\.title) == ["Wi-Fi", "Card and Wi-Fi"])

        let secrets = [
            SecureItemFixtures.cardNumber, SecureItemFixtures.cardCode, SecureItemFixtures.wifiPassphrase, "Ada Lovelace", "Synthetic-Net",
        ]
        for secret in secrets {
            #expect(CredentialListFilter.visible(all, query: secret, filter: .all).isEmpty, "\(secret)")
        }
    }

    @Test func statisticsCountCredentialsThatHoldItems() {
        let all = library()
        #expect(CredentialStatistics(all).credentials == 12)
        #expect(CredentialStatistics(all).items == 11)
        #expect(CredentialStatistics([]).items == 0)
        #expect(CredentialStatistics([CredentialSummary(VaultFixtures.account())]).items == 0)
        #expect(CredentialStatistics([summarize([SecureItemFixtures.card(), SecureItemFixtures.wifi()])]).items == 1, "counted once, not per item")
    }

    // MARK: - The editor's draft

    @Test func anAddedItemWithNothingTypedIsNoChangeAndNothingToSave() {
        var draft = CredentialDraft(editing: nil, revision: 0)
        for kind in SecureItemKind.addable {
            draft.addSecureItem(kind)
        }
        #expect(draft.secureItems.map(\.kind) == SecureItemKind.addable)
        #expect(!draft.hasUnsavedChanges)
        let untouched = draft
        #expect(throws: CredentialVaultError.invalidData) { try untouched.account() }

        // A stored credential: the empty item is dropped, so a save would write what is stored.
        var editing = CredentialDraft(editing: stored([SecureItemFixtures.wifi()]), revision: 1)
        editing.addSecureItem(.creditCard)
        #expect(editing.secureItems.count == 2)
        #expect(editing.changesNothing && !editing.hasUnsavedChanges)
    }

    @Test func typingIntoAnItemMakesTheDraftDirtyAndSavesOnlyTypedValues() throws {
        var draft = CredentialDraft(editing: nil, revision: 0)
        draft.addSecureItem(.creditCard)
        draft.addSecureItem(.address)
        try enter(SecureItemFixtures.cardNumber, into: "number", ofItem: 0, in: &draft)
        #expect(draft.hasUnsavedChanges)

        let first = try draft.account()
        #expect(first.secureItems?.count == 1, "the untouched address is dropped")
        #expect(first.secureItems?.first?.kind == .creditCard)
        #expect(first.secureItems?.first?.fields.map(\.name) == ["number"])
        #expect(first.secureItems?.first?.value("number") == SecureItemFixtures.cardNumber)

        // A second value joins in the member order, and a value typed in WSurf gets its member's type.
        try enter(SecureItemFixtures.cardCode, into: "verificationNumber", ofItem: 0, in: &draft)
        try enter("Synthetic Holder", into: "fullName", ofItem: 0, in: &draft)
        let second = try draft.account()
        let card = try #require(second.secureItems?.first)
        #expect(card.fields.map(\.name) == ["number", "fullName", "verificationNumber"])
        #expect(card.fields.first { $0.name == "verificationNumber" }?.field?.fieldType == .concealedString)
        #expect(card.isConcealed(card.fields[2]))
    }

    @Test func anImportedItemIsSavedByteForByteWhenItIsNotTouched() throws {
        // An exporter's description of a value (id, label) and an empty group title: both survive only if a save leaves the item alone.
        let number = SecureItemField(
            name: "number", value: SecureItemFixtures.cardNumber, field: .init(id: Data([7]), label: "Imported label", fieldType: .string)
        )
        let imported = SecureItem(kind: .creditCard, fields: [number, SecureItemFixtures.field("verificationNumber", "737", type: .concealedString)])
        let group = SecureItem(kind: .customFields, id: Data([0xC0, 0x01]), label: "", fields: [
            SecureItemField(name: "", value: "4711", field: .init(id: Data([9]), label: "Code", fieldType: .concealedString)),
        ])
        let record = stored([imported, group])

        let draft = CredentialDraft(editing: record, revision: 1)
        #expect(draft.changesNothing && !draft.hasUnsavedChanges)
        let built = try draft.account()
        #expect(built == record)
        #expect(try CredentialContent.canonicalJSON(built.secureItems) == CredentialContent.canonicalJSON(record.secureItems))

        // Changing something else leaves the items exactly as stored.
        var renamed = draft
        renamed.displayName = "Renamed"
        #expect(renamed.hasUnsavedChanges)
        #expect(try renamed.account().secureItems == record.secureItems)
    }

    @Test func removingItemsStoresTheRestOrNone() throws {
        var draft = CredentialDraft(editing: stored([SecureItemFixtures.wifi(), SecureItemFixtures.address()]), revision: 1)
        draft.removeSecureItem(at: 5)
        draft.removeSecureItem(at: -1)
        #expect(draft.secureItems.count == 2 && draft.changesNothing, "an index that is not there is ignored")

        draft.removeSecureItem(at: 0)
        #expect(draft.hasUnsavedChanges)
        #expect(try draft.account().secureItems == [SecureItemFixtures.address()])
        draft.removeSecureItem(at: 0)
        #expect(try draft.account().secureItems == nil, "the last item stores none, not an empty list")

        // A credential that held only items must keep one: saving it empty is refused rather than storing nothing.
        var only = CredentialDraft(editing: SecureItemFixtures.account([SecureItemFixtures.wifi()]), revision: 1)
        only.removeSecureItem(at: 0)
        let emptied = only
        #expect(throws: CredentialVaultError.invalidData) { try emptied.account() }
    }

    @Test func copyingAnEarlierVersionsItemsReplacesTheDraftsItems() throws {
        let version = stored([SecureItemFixtures.card(), SecureItemFixtures.address()])
        var draft = CredentialDraft(editing: stored([SecureItemFixtures.wifi()]), revision: 1)
        draft.take(.secureItems, from: version)
        #expect(draft.secureItems == version.secureItems)
        #expect(draft.hasUnsavedChanges)
        let built = try draft.account()
        #expect(built.secureItems == version.secureItems)
        #expect(built.password == "secret", "nothing but the items is copied")

        // A version without items empties the list.
        draft.take(.secureItems, from: VaultFixtures.account())
        #expect(draft.secureItems.isEmpty)
        #expect(try draft.account().secureItems == nil)
    }

    @Test func addingAMissingMemberAddsItOnceAndEmptyUntilTyped() throws {
        let partial = SecureItem(kind: .creditCard, fields: [SecureItemFixtures.field("number", SecureItemFixtures.cardNumber, type: .string)])
        var draft = CredentialDraft(editing: stored([partial]), revision: 1)
        let code = try #require(SecureItemKind.creditCard.member("verificationNumber"))
        draft.addMember(code, toItem: 0)
        draft.addMember(code, toItem: 0)
        draft.addMember(code, toItem: 3)
        #expect(draft.secureItems[0].fields.map(\.name) == ["number", "verificationNumber"])
        #expect(draft.secureItems[0].fields[1].value.isEmpty)
        #expect(draft.secureItems[0].fields[1].field?.fieldType == .concealedString)
        #expect(draft.changesNothing, "an empty member is dropped on save, so adding one changes nothing")

        try enter(SecureItemFixtures.cardCode, into: "verificationNumber", ofItem: 0, in: &draft)
        #expect(draft.hasUnsavedChanges)
        #expect(try draft.account().secureItems?.first?.value("verificationNumber") == SecureItemFixtures.cardCode)

        // An SDK plain value is not something a person types: it is never offered, so never added.
        var key = CredentialDraft(editing: nil, revision: 0)
        key.addSecureItem(.sshKey)
        let plain = try #require(SecureItemKind.sshKey.member("keyType"))
        key.addMember(plain, toItem: 0)
        #expect(key.secureItems[0].fields.allSatisfy { $0.name != "keyType" })
    }

    @Test func customFieldsDropEmptyValuesAndAnEmptyTitle() throws {
        var draft = CredentialDraft(editing: nil, revision: 0)
        draft.addSecureItem(.customFields)
        draft.addCustomField(toItem: 0)
        draft.addCustomField(toItem: 0)
        draft.addCustomField(toItem: 4)
        #expect(draft.secureItems[0].fields.count == 3, "the new item starts with one empty field")
        #expect(!draft.hasUnsavedChanges)

        draft.secureItems[0].fields[1].value = "4711"
        draft.secureItems[0].fields[1].field?.label = "Code"
        draft.secureItems[0].fields[1].field?.fieldType = .concealedString
        #expect(draft.hasUnsavedChanges)
        let built = try draft.account()
        let untitled = try #require(built.secureItems?.first)
        #expect(untitled.label == nil, "an empty title is not stored")
        #expect(untitled.fields.count == 1)
        #expect(untitled.fields[0].value == "4711")
        #expect(untitled.fields[0].field?.label == "Code" && untitled.isConcealed(untitled.fields[0]))

        draft.secureItems[0].label = "Locker"
        #expect(try draft.account().secureItems?.first?.label == "Locker")

        // A field is added only to a custom-fields item.
        var card = CredentialDraft(editing: nil, revision: 0)
        card.addSecureItem(.creditCard)
        let before = card.secureItems
        card.addCustomField(toItem: 0)
        #expect(card.secureItems == before)
    }

    @Test func aDraftStopsAtTheItemAndFieldLimits() {
        var draft = CredentialDraft(editing: nil, revision: 0)
        for _ in 0..<(SecureItem.itemLimit + 5) {
            draft.addSecureItem(.wifi)
        }
        #expect(draft.secureItems.count == SecureItem.itemLimit)

        var custom = CredentialDraft(editing: nil, revision: 0)
        custom.addSecureItem(.customFields)
        for _ in 0..<(SecureItem.fieldLimit + 5) {
            custom.addCustomField(toItem: 0)
        }
        #expect(custom.secureItems[0].fields.count == SecureItem.fieldLimit)
    }
}
