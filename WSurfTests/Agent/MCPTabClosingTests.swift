// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// Closing a tab over MCP: when the connection is asked, what it never closes, and what Stop or a disconnect does. Sessions
/// use an in-memory trust store and pages parked on real addresses, so no keychain, network or native sheet is involved.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MCPTabClosingTests {
    /// Every question the sheet would have shown, and the answer to give.
    private final class Sheet {
        var asked: [AgentTabClosing.Question] = []
        var answer = AgentTabClosing.Answer.close
        var whenAsked: (@MainActor () -> Void)?
    }

    private struct Rig {
        let browser: BrowserModel
        let store: SitePermissions
        let trust: MCPTrustStore
        let session: MCPBrowserSession
        let tab: BrowserTab
    }

    /// A connection sharing a parked tab with control, or, with `standing`, the Developer profile's paired client sharing a
    /// developer site. The browser is on the everyday profile, so `Profile.originalID` is the explicit Developer profile.
    private func makeRig(
        address: String = "https://shop.invalid/", standing: PairedClient.Standing? = nil,
        default policy: AssistantAccessPolicy = .ask, closing: AssistantTabClosing = .ask
    ) async throws -> Rig {
        let store = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPTabClosing-\(UUID().uuidString).json"))
        store.setAssistantDefault(policy)
        store.setAssistantTabClosing(closing)
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        trust.loadIfNeeded()
        let browser = BrowserModel(database: .temporary(), sitePermissions: store)
        let tab = await parkTab(browser, at: try #require(URL(string: address)))
        let session = MCPBrowserSession(
            browser: browser, trust: trust, available: { true }, consent: { _, _, _ in .control }, openConsent: { _, _ in true })
        if let standing {
            let client = try trust.pair(token: SyntheticToken.first, name: "Claude Code", kind: .claudeCode)
            try trust.setStanding(standing, for: client.id)
            try trust.setDeveloperProfile(Profile.originalID)
            session.pairedClient = trust.client(id: client.id)
        }
        let rig = Rig(browser: browser, store: store, trust: trust, session: session, tab: tab)
        #expect(try await call(rig, "requestAccess").isError == false)
        return rig
    }

    private func call(_ rig: Rig, _ name: String, _ tab: BrowserTab? = nil, _ arguments: [String: Value] = [:]) async throws -> CallTool.Result {
        var arguments = arguments
        if let tab { arguments["tabID"] = .string(tab.id.uuidString) }
        return try await rig.session.call(name: name, arguments: arguments)
    }

    private func close(_ rig: Rig, _ tab: BrowserTab? = nil, sheet: Sheet) async throws -> CallTool.Result {
        try await AgentTabClosing.$decisionForTesting.withValue(.init { question in
            sheet.asked.append(question)
            sheet.whenAsked?()
            return sheet.answer
        }) {
            try await call(rig, "closeTab", tab ?? rig.tab)
        }
    }

    private func text(_ result: CallTool.Result) -> String {
        result.content.compactMap { block -> String? in
            guard case .text(let text, _, _) = block else { return nil }
            return text
        }.joined(separator: "\n")
    }

    private func isOpen(_ rig: Rig, _ tab: BrowserTab? = nil) -> Bool {
        rig.browser.tabs.contains { $0 === (tab ?? rig.tab) }
    }

    // MARK: When it asks

    @Test func closingAsksByDefault() async throws {
        let rig = try await makeRig()
        let sheet = Sheet()

        let result = try await close(rig, sheet: sheet)

        #expect(sheet.asked == [.init(title: rig.tab.title, isPrivate: false, client: rig.session.clientName)])
        #expect(result.isError == false)
        #expect(text(result) == "Tab closed.")
        #expect(!isOpen(rig))
    }

    @Test func decliningKeepsTheTabAndSaysSo() async throws {
        let rig = try await makeRig()
        let sheet = Sheet()
        sheet.answer = .keepOpen

        let result = try await close(rig, sheet: sheet)

        #expect(result.isError == true)
        #expect(text(result).contains("The user chose to keep this tab open"))
        #expect(isOpen(rig))
        #expect(rig.session.grants[rig.tab.id] != nil)
    }

    @Test(arguments: [AssistantAccessPolicy.ask, .readOnly, .control])
    func theProfilesAllowClosingSettingNeverSkipsTheQuestionForAConnection(policy: AssistantAccessPolicy) async throws {
        // The setting lives in the profile's own file, which a process with a shell can edit: only the assistant reads it.
        let rig = try await makeRig(default: policy, closing: .allow)
        let sheet = Sheet()

        _ = try await close(rig, sheet: sheet)

        #expect(sheet.asked.count == 1)
    }

    // MARK: What never asks, and what never closes

    @Test func aTabTheConnectionOpenedClosesWithoutAsking() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Opened</title><p>Opened</p>")])
        defer { _ = server }
        let rig = try await makeRig()
        let opened = try await openedTab(rig, url: try server.url().absoluteString)
        let sheet = Sheet()

        let result = try await close(rig, opened, sheet: sheet)

        #expect(result.isError == false)
        #expect(sheet.asked.isEmpty)
        #expect(!isOpen(rig, opened))
        #expect(isOpen(rig))
    }

    @Test func aTabAnotherConnectionOpenedAsks() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Opened</title><p>Opened</p>")])
        defer { _ = server }
        let rig = try await makeRig()
        let opened = try await openedTab(rig, url: try server.url().absoluteString)
        let other = MCPBrowserSession(browser: rig.browser, trust: rig.trust, available: { true }, consent: { _, _, _ in .control })
        other.grants[opened.id] = rig.session.grants[opened.id]
        let sheet = Sheet()

        let result = try await AgentTabClosing.$decisionForTesting.withValue(.init { question in
            sheet.asked.append(question)
            return .close
        }) {
            try await other.call(name: "closeTab", arguments: ["tabID": .string(opened.id.uuidString)])
        }

        #expect(result.isError == false)
        #expect(sheet.asked.count == 1)
    }

    @Test func pinnedTabsAreNeverClosedOrAskedAbout() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><title>Opened</title><p>Opened</p>")])
        defer { _ = server }
        let rig = try await makeRig()
        let opened = try await openedTab(rig, url: try server.url().absoluteString)
        let sheet = Sheet()
        rig.tab.pinID = UUID()
        opened.pinID = UUID()

        for tab in [rig.tab, opened] {
            let result = try await close(rig, tab, sheet: sheet)
            #expect(result.isError == true)
            #expect(text(result).contains("Pinned tabs must be closed by the user."))
            #expect(isOpen(rig, tab))
        }
        #expect(sheet.asked.isEmpty)
    }

    @Test func aTabPinnedWhileTheSheetIsOpenStaysOpen() async throws {
        let rig = try await makeRig()
        let sheet = Sheet()
        sheet.whenAsked = { rig.tab.pinID = UUID() }

        let result = try await close(rig, sheet: sheet)

        #expect(result.isError == true)
        #expect(isOpen(rig))
    }

    // MARK: Developer access

    @Test func developerAccessClosesWithoutAsking() async throws {
        let rig = try await makeRig(address: "http://localhost:5173/", standing: .developer)
        #expect(rig.session.permits(rig.tab, capability: .developer))
        let sheet = Sheet()

        let result = try await close(rig, sheet: sheet)

        #expect(result.isError == false)
        #expect(sheet.asked.isEmpty)
        #expect(!isOpen(rig))
    }

    @Test func developmentAccessStillAsks() async throws {
        let rig = try await makeRig(address: "http://localhost:5173/", standing: .development)
        #expect(!rig.session.permits(rig.tab, capability: .developer))
        let sheet = Sheet()

        _ = try await close(rig, sheet: sheet)

        #expect(sheet.asked.count == 1)
    }

    @Test func developerAccessEndsWhenTheTrustStoreLowersIt() async throws {
        let rig = try await makeRig(address: "http://localhost:5173/", standing: .developer)
        try rig.trust.setStanding(.off, for: try #require(rig.session.pairedClient).id)
        rig.session.refreshStanding()
        let sheet = Sheet()

        let result = try await close(rig, sheet: sheet)

        // The standing grant went with the setting, so the tab is no longer shared at all.
        #expect(result.isError == true)
        #expect(sheet.asked.isEmpty)
        #expect(isOpen(rig))
    }

    // MARK: Don't ask again

    @Test func dontAskAgainLastsOnlyForThisConnection() async throws {
        let rig = try await makeRig()
        let second = await parkTab(rig.browser, at: try #require(URL(string: "https://shop.invalid/second")))
        let third = await parkTab(rig.browser, at: try #require(URL(string: "https://shop.invalid/third")))
        for tab in [second, third] {
            rig.session.grants[tab.id] = .init(origin: SitePermissions.origin(for: tab.page.url), access: .control)
        }
        let sheet = Sheet()
        sheet.answer = .closeAndStopAsking

        _ = try await close(rig, sheet: sheet)
        _ = try await close(rig, second, sheet: sheet)
        #expect(sheet.asked.count == 1)
        #expect(!isOpen(rig, second))

        let another = MCPBrowserSession(browser: rig.browser, trust: rig.trust, available: { true }, consent: { _, _, _ in .control })
        another.grants[third.id] = .init(origin: SitePermissions.origin(for: third.page.url), access: .control)
        sheet.answer = .close
        let result = try await AgentTabClosing.$decisionForTesting.withValue(.init { question in
            sheet.asked.append(question)
            return .close
        }) {
            try await another.call(name: "closeTab", arguments: ["tabID": .string(third.id.uuidString)])
        }
        #expect(result.isError == false)
        #expect(sheet.asked.count == 2)
    }

    // MARK: Stop and disconnect

    @Test func aDisconnectWhileTheSheetIsOpenKeepsTheTab() async throws {
        let rig = try await makeRig()
        let sheet = Sheet()
        sheet.whenAsked = { rig.session.revoke() }

        let result = try await close(rig, sheet: sheet)

        #expect(result.isError == true)
        #expect(text(result) == "The tab was not closed.")
        #expect(isOpen(rig))
    }

    @Test func stoppingTheCallWhileTheSheetIsOpenKeepsTheTab() async throws {
        let rig = try await makeRig()
        let sheet = Sheet()
        let running = RunningCall()
        sheet.whenAsked = { running.task?.cancel() }
        running.task = Task { @MainActor in
            try await self.close(rig, sheet: sheet)
        }

        let result = try await #require(running.task).value

        #expect(result.isError == true)
        #expect(text(result) == "The tab was not closed.")
        #expect(isOpen(rig))
    }

    @Test func aDisconnectedConnectionClosesNothing() async throws {
        let rig = try await makeRig()
        let sheet = Sheet()
        rig.session.revoke()

        let result = try await close(rig, sheet: sheet)

        #expect(result.isError == true)
        #expect(sheet.asked.isEmpty)
        #expect(isOpen(rig))
    }

    // MARK: Helpers

    /// Opens a tab through the connection's own `newTab` and returns it.
    private func openedTab(_ rig: Rig, url: String) async throws -> BrowserTab {
        let before = Set(rig.browser.tabs.map(\.id))
        let opened = try await rig.session.call(name: "newTab", arguments: ["url": .string(url)])
        #expect(opened.isError == false, "\(text(opened))")
        let tab = try #require(rig.browser.tabs.first { !before.contains($0.id) })
        #expect(await waitUntil { rig.session.sharedTab(tab.id) != nil })
        return tab
    }
}

/// Lets a sheet stub reach the call that is waiting on it.
@MainActor
private final class RunningCall {
    var task: Task<CallTool.Result, Error>?
}
