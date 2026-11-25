// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// The access sheet, as data: which buttons it offers, in which order, and what each one grants.
@MainActor
struct MCPAccessConsentTests {
    private let pages = [MCPAccessConsent.Page(id: UUID(), title: "Docs", url: URL(string: "https://example.com/docs")!)]

    @Test func sheetOffersDevelopmentOnlyWhenAsked() {
        let plain = MCPAccessConsent.sheet(client: "Claude Code", pages: pages, development: false)
        let asked = MCPAccessConsent.sheet(client: "Claude Code", pages: pages, development: true)
        #expect(!plain.buttons.contains { $0.access == .development })
        #expect(!plain.message.contains("Allow Development"))
        #expect(asked.buttons.contains { $0.access == .development })
        #expect(asked.message.contains("Allow Development"))
    }

    @Test func buttonOrderMapsToAccessLevels() {
        let plain = MCPAccessConsent.sheet(client: "Claude Code", pages: pages, development: false)
        #expect(plain.buttons.map(\.access) == [.readOnly, .control, nil])
        #expect(plain.access(forButton: 0) == .readOnly)
        #expect(plain.access(forButton: 1) == .control)
        #expect(plain.access(forButton: 2) == nil)
        let asked = MCPAccessConsent.sheet(client: "Claude Code", pages: pages, development: true)
        #expect(asked.buttons.map(\.access) == [.readOnly, .control, .development, nil])
        #expect(asked.access(forButton: 2) == .development)
        #expect(asked.access(forButton: 3) == nil)
        // A response that names no button grants nothing.
        #expect(asked.access(forButton: 4) == nil)
        #expect(asked.access(forButton: -2002) == nil)
    }

    @Test func allowDeveloperIsOfferedOnlyForAnEligiblePageWhenDevelopmentIsAsked() {
        var eligible = pages
        eligible[0].developerEligible = true
        let offered = MCPAccessConsent.sheet(client: "Claude Code", pages: eligible, development: true)
        #expect(offered.buttons.map(\.access) == [.readOnly, .control, .development, .developer, nil])
        #expect(offered.message.contains("Allow Developer"))
        #expect(offered.access(forButton: 3) == .developer)
        #expect(offered.access(forButton: 4) == nil, "Don’t Allow stays last")
        #expect(offered.buttons.last?.isEscape == true)
        // Without a qualifying page, or without a development request, the sheet is the one it always was.
        for sheet in [
            MCPAccessConsent.sheet(client: "Claude Code", pages: pages, development: true),
            MCPAccessConsent.sheet(client: "Claude Code", pages: eligible, development: false),
        ] {
            #expect(!sheet.buttons.contains { $0.access == .developer })
            #expect(!sheet.message.contains("Allow Developer"))
        }
    }

    @Test(arguments: [false, true])
    func escapeDeclines(development: Bool) throws {
        let sheet = MCPAccessConsent.sheet(client: "Claude Code", pages: pages, development: development)
        let escapes = sheet.buttons.filter(\.isEscape)
        #expect(escapes.count == 1)
        #expect(escapes.first?.access == nil)
        #expect(sheet.buttons.last?.isEscape == true)
    }

    @Test func emptyPageListExplainsHowToShare() {
        let sheet = MCPAccessConsent.sheet(client: "codex-mcp-client", pages: [], development: true)
        #expect(sheet.buttons.count == 1)
        #expect(sheet.buttons.first?.access == nil)
        #expect(sheet.message.contains("Open a webpage in WSurf"))
        #expect(sheet.message.contains("Codex"), "the client is named the way the access sheet names it")
        #expect(sheet.access(forButton: 0) == nil)
    }

    @Test func theSheetNamesTheTabAndItsHost() {
        let sheet = MCPAccessConsent.sheet(client: "Claude Code", pages: pages, development: false)
        #expect(sheet.title.contains("Claude Code"))
        #expect(sheet.message.contains("Docs"))
        #expect(sheet.message.contains("example.com"))
    }

    @Test func loginSheetOffersAllFourVaultChoicesPickerAndModeFiltering() {
        let url = URL(string: "https://app.example.com/login")!
        let first = MCPAccessConsent.LoginAccount(id: UUID(), label: "ada@example.com")
        let second = MCPAccessConsent.LoginAccount(id: UUID(), label: "work@example.com")

        let single = MCPAccessConsent.loginSheet(
            client: "Claude Code", url: url, accounts: [first], allowsManualTakeOver: true, reason: "Sign in to check invoices")
        #expect(single.title.contains("app.example.com"))
        #expect(single.message.contains("ada@example.com"))
        #expect(single.message.contains("Sign in to check invoices"))
        #expect(!single.showsAccountPicker)
        #expect(single.buttons.map(\.action) == [.fill, .fillAndSignIn, .takeOver, .decline])
        #expect(single.choice(forButton: 0) == .fill(accountID: first.id))
        #expect(single.choice(forButton: 1) == .fillAndSignIn(accountID: first.id))
        #expect(single.choice(forButton: 2) == .takeOver)
        #expect(single.choice(forButton: 3) == .decline)
        #expect(single.choice(forButton: 99) == .decline)
        #expect(single.buttons.last?.isEscape == true)

        // Multiple accounts show the picker and return the user-selected account ID.
        let multi = MCPAccessConsent.loginSheet(
            client: "Claude Code", url: url, accounts: [first, second], allowsManualTakeOver: false, reason: nil)
        #expect(multi.showsAccountPicker)
        #expect(multi.buttons.map(\.action) == [.fill, .fillAndSignIn, .decline])
        #expect(multi.choice(forButton: 0, selectedAccountID: second.id) == .fill(accountID: second.id))
        #expect(multi.choice(forButton: 1, selectedAccountID: second.id) == .fillAndSignIn(accountID: second.id))
        #expect(multi.choice(forButton: 2, selectedAccountID: second.id) == .decline)
        // Missing or unrecognized selectedAccountID on a multi-account sheet fails closed to .decline.
        #expect(multi.choice(forButton: 0, selectedAccountID: nil) == .decline)
        #expect(multi.choice(forButton: 0, selectedAccountID: UUID()) == .decline)

        let withoutVault = MCPAccessConsent.loginSheet(
            client: "codex-mcp-client", url: url, accounts: [], allowsManualTakeOver: true, reason: nil)
        #expect(withoutVault.message.contains("Codex"))
        #expect(withoutVault.buttons.map(\.action) == [.takeOver, .decline])
        #expect(withoutVault.buttons.last?.isEscape == true)
    }

    @Test func accountPickerPreservesDuplicateLabelsAndMapsByRepresentedUUID() throws {
        let url = URL(string: "https://app.example.com/login")!
        let firstA = MCPAccessConsent.LoginAccount(id: UUID(), label: "alice@example.com")
        let middleB = MCPAccessConsent.LoginAccount(id: UUID(), label: "bob@example.com")
        let secondA = MCPAccessConsent.LoginAccount(id: UUID(), label: "alice@example.com")
        let accounts = [firstA, middleB, secondA]

        let sheet = MCPAccessConsent.loginSheet(
            client: "Claude Code", url: url, accounts: accounts, allowsManualTakeOver: true, reason: nil)
        let popup = MCPAccessConsent.makeAccountPicker(for: sheet.accounts)

        #expect(popup.numberOfItems == 3, "NSPopUpButton must never deduplicate identical account labels")
        #expect(popup.itemTitles == ["alice@example.com", "bob@example.com", "alice@example.com"])

        popup.selectItem(at: 0)
        #expect(MCPAccessConsent.selectedAccountID(from: popup) == firstA.id)
        #expect(sheet.choice(forButton: 0, selectedAccountID: MCPAccessConsent.selectedAccountID(from: popup)) == .fill(accountID: firstA.id))

        popup.selectItem(at: 1)
        #expect(MCPAccessConsent.selectedAccountID(from: popup) == middleB.id)
        #expect(sheet.choice(forButton: 0, selectedAccountID: MCPAccessConsent.selectedAccountID(from: popup)) == .fill(accountID: middleB.id))

        popup.selectItem(at: 2)
        #expect(MCPAccessConsent.selectedAccountID(from: popup) == secondA.id)
        #expect(sheet.choice(forButton: 1, selectedAccountID: MCPAccessConsent.selectedAccountID(from: popup)) == .fillAndSignIn(accountID: secondA.id))
    }

    @Test func vaultBridgeDisambiguatesDuplicateAccountLabels() {
        let personalID = UUID()
        let workID = UUID()
        let first = VaultBlindLoginBridge.Summary(id: UUID(), label: "alice@example.com", vaultID: personalID, revision: 1, epoch: 1)
        let unique = VaultBlindLoginBridge.Summary(id: UUID(), label: "bob@example.com", vaultID: personalID, revision: 1, epoch: 1)
        let workCopy = VaultBlindLoginBridge.Summary(id: UUID(), label: "alice@example.com", vaultID: workID, revision: 1, epoch: 1)

        let acrossVaults = VaultBlindLoginBridge.disambiguateLabels([
            (first, "Personal"),
            (unique, "Personal"),
            (workCopy, "Work"),
        ])
        #expect(acrossVaults.map(\.id) == [first.id, unique.id, workCopy.id])
        #expect(acrossVaults.map(\.label) == ["alice@example.com (Personal)", "bob@example.com", "alice@example.com (Work)"])

        let sameVaultCopy = VaultBlindLoginBridge.Summary(id: UUID(), label: "alice@example.com", vaultID: personalID, revision: 1, epoch: 1)
        let withinSameVault = VaultBlindLoginBridge.disambiguateLabels([
            (first, "Personal"),
            (sameVaultCopy, "Personal"),
        ])
        #expect(withinSameVault.map(\.id) == [first.id, sameVaultCopy.id])
        #expect(withinSameVault.map(\.label) == ["alice@example.com (Personal) #1", "alice@example.com (Personal) #2"])

        let hiddenOne = VaultBlindLoginBridge.Summary(id: UUID(), label: "app.example.com", vaultID: personalID, revision: 1, epoch: 1)
        let hiddenTwo = VaultBlindLoginBridge.Summary(id: UUID(), label: "app.example.com", vaultID: workID, revision: 1, epoch: 1)
        let unnamedVaults = VaultBlindLoginBridge.disambiguateLabels([
            (hiddenOne, nil),
            (hiddenTwo, ""),
        ])
        #expect(unnamedVaults.map(\.id) == [hiddenOne.id, hiddenTwo.id])
        #expect(unnamedVaults.map(\.label) == ["app.example.com #1", "app.example.com #2"])
    }
}
