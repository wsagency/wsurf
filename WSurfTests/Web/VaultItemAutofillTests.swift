// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Cards and addresses of the credentials vault, as the fill panel offers them and the page receives them. Synthetic values only.
struct VaultItemAutofillTests {
    private typealias Fixtures = SecureItemFixtures

    private let june2030 = Date(timeIntervalSince1970: 1_906_502_400)

    @Test func aCardMapsToThePaymentCardThatFills() throws {
        let card = try #require(VaultItemAutofill.paymentCard(Fixtures.card()))

        #expect(card.number == Fixtures.cardNumber)
        #expect(card.cardholder == "Ada Lovelace")
        #expect(card.securityCode == Fixtures.cardCode)
        #expect(card.month == 7 && card.year == 2031)
    }

    @Test func aCardNumberWithSpacesStillFills() throws {
        let card = try #require(VaultItemAutofill.paymentCard(Fixtures.card(number: "4242 4242 4242 4242")))
        #expect(card.number == Fixtures.cardNumber)
    }

    @Test func aNumberThatFailsTheCardCheckIsNotOfferedButTheItemStays() throws {
        let invalid = Fixtures.card(number: "4242424242424241")
        #expect(VaultItemAutofill.paymentCard(invalid) == nil)
        let account = Fixtures.account([invalid])
        #expect(VaultItemAutofill.cards(in: [account], now: june2030).isEmpty)
        // The vault keeps it as it is: only filling needs a valid number.
        try account.validate()
    }

    @Test func aSecurityCodeOrExpiryThatDoesNotReadIsLeftOutNotTheCard() throws {
        var item = Fixtures.card(code: "12")
        item.fields[3].value = "2031-13"
        let card = try #require(VaultItemAutofill.paymentCard(item))
        #expect(card.number == Fixtures.cardNumber && card.securityCode == nil)
        #expect(card.month == nil && card.year == nil)
    }

    @Test func expiredCardsAreNotOffered() {
        var expired = Fixtures.card()
        expired.fields[3].value = "2020-01"
        let accounts = [Fixtures.account([Fixtures.card(), expired, Fixtures.wifi()])]

        let offers = VaultItemAutofill.cards(in: accounts, now: june2030)

        #expect(offers.map(\.item) == [0])
        #expect(offers.first?.accountID == accounts[0].id)
    }

    @Test func aRowShowsOnlyTheNetworkAndLastFourDigits() throws {
        let offer = try #require(VaultItemAutofill.cards(in: [Fixtures.account([Fixtures.card()])], now: june2030).first)

        let row = AutofillSuggestion(.card(offer.value))

        #expect(row.title.hasSuffix("•••• 4242"))
        #expect(!row.title.contains(Fixtures.cardNumber) && !row.detail.contains(Fixtures.cardNumber))
        #expect(!row.title.contains(Fixtures.cardCode) && !row.detail.contains(Fixtures.cardCode))
        #expect(row.month == 7 && row.year == 2031)
    }

    @Test func aNameAndAnAddressFillAsOneContact() throws {
        var account = Fixtures.account([Fixtures.name(), Fixtures.address()], name: "Home")
        account.secureItems?.append(Fixtures.address(street: "2 Other Road", city: "Elsewhere"))

        let contact = try #require(VaultItemAutofill.contact(of: account))

        #expect(contact.label == "Home")
        #expect(contact.givenName == "Ada" && contact.familyName == "Lovelace")
        // The first address of the credential, never a mix of two.
        #expect(contact.street == "1 Synthetic Way" && contact.city == "Testville")
        #expect(contact.postalCode == "10000" && contact.countryCode == "HR" && contact.phone == "+385 1 000 0000")
        #expect(contact.fields["given-name"] == "Ada" && contact.fields["address-level2"] == "Testville")
        let offers = VaultItemAutofill.contacts(in: [account])
        #expect(offers.count == 1 && offers[0].item == 0 && offers[0].accountID == account.id)
    }

    @Test func aCountryThatIsNotARegionCodeIsLeftOut() throws {
        var address = Fixtures.address()
        address.fields[3].value = "Croatia"
        let contact = try #require(VaultItemAutofill.contact(of: Fixtures.account([address])))
        #expect(contact.countryCode.isEmpty && contact.street == "1 Synthetic Way")
    }

    @Test func credentialsWithoutAnAddressOrANameOfferNoContact() {
        let accounts = [Fixtures.account([Fixtures.card(), Fixtures.wifi()]), VaultFixtures.account()]
        #expect(VaultItemAutofill.contacts(in: accounts).isEmpty)
        #expect(VaultItemAutofill.contact(of: accounts[0]) == nil)
    }

    @Test func yearMonthReadsTheExchangeFormat() {
        let parsed = VaultItemAutofill.yearMonth("2031-07")
        #expect(parsed.year == 2031 && parsed.month == 7)
        let yearOnly = VaultItemAutofill.yearMonth("2031")
        #expect(yearOnly.year == nil && yearOnly.month == nil)
        #expect(VaultItemAutofill.yearMonth(nil).year == nil)
    }

    @Test func aTabStartsWithoutAssistantControl() {
        // The tab sets the real answer when it installs its page; until then the panel treats the page as the person's own.
        #expect(AutofillSaveSession().isUnderAssistantControl() == false)
    }
}
