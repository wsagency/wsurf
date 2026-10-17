// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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
}
