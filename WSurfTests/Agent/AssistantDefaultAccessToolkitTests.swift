// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import Testing
import WebKit

@testable import WSurf

/// The default through the real toolkit and a live page: what the assistant does on a website with no record.
@MainActor
@Suite(.boundedWebViews)
struct AssistantDefaultAccessToolkitTests {
    private static let plainPage = """
        <!doctype html><title>Plain</title><p>Plain page text</p>
        <button onclick="window.__clicked=(window.__clicked||0)+1">Add to cart</button>
        """
    private static let loginPage = """
        <!doctype html><title>Login</title><p>Welcome back</p>
        <input type="password" aria-label="Password">
        <button onclick="window.__clicked=(window.__clicked||0)+1">Add to cart</button>
        """

    private struct Fixture {
        let server: HTTPFixtureServer
        let store: SitePermissions
        let tab: BrowserTab
        let toolkit: AgentToolkit
    }

    private func fixture(default policy: AssistantAccessPolicy, html: String) async throws -> Fixture {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(html)])
        let store = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("DefaultAccess-\(UUID().uuidString).json"))
        store.setAssistantDefault(policy)
        let browser = BrowserModel(database: .temporary(), sitePermissions: store)
        let url = try server.url()
        let tab = browser.newTab(url: url)
        #expect(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        tab.assistantAccess.pageChanged(url: url)
        let toolkit = AgentToolkit(browser: browser, media: MediaCenter(), log: ConversationLog(database: .temporary()))
        return Fixture(server: server, store: store, tab: tab, toolkit: toolkit)
    }

    private func answering<T>(
        _ answer: AssistantAccessPolicy,
        _ body: (_ asked: () -> [AssistantPageCapability]) async -> T
    ) async -> T {
        var asked: [AssistantPageCapability] = []
        return await TabAssistantAccessCenter.$decisionForTesting.withValue(.init({ capability, _ in
            asked.append(capability)
            return answer
        })) {
            await body { asked }
        }
    }

    private func clicks(_ tab: BrowserTab) async throws -> Int {
        try await tab.page.evaluateJavaScript("window.__clicked || 0") as? Int ?? 0
    }

    @Test func readOnlyDefaultReadsAWebsiteWithoutAsking() async throws {
        let f = try await fixture(default: .readOnly, html: Self.plainPage)
        defer { _ = f.server }
        let toolkit = f.toolkit

        await answering(.ask) { asked in
            let output = await toolkit.readPage()
            #expect(output.contains("Plain page text"))
            #expect(asked().isEmpty)
        }
    }

    @Test func readOnlyDefaultAsksBeforeAClickAndKeepsTheAnswer() async throws {
        let f = try await fixture(default: .readOnly, html: Self.plainPage)
        defer { _ = f.server }
        let store = f.store
        let tab = f.tab
        let toolkit = f.toolkit

        await answering(.control) { asked in
            let output = await toolkit.clickOnPage(ref: 0, label: "Add to cart")
            #expect(output.contains("Clicked"))
            #expect(asked() == [.control])
        }
        #expect(try await clicks(tab) == 1)
        #expect(store.assistantRecord(for: tab.assistantAccess.origin) == .control)

        await answering(.ask) { asked in
            _ = await toolkit.clickOnPage(ref: 0, label: "Add to cart")
            #expect(asked().isEmpty)
        }
        #expect(try await clicks(tab) == 2)
    }

    @Test func aDeclinedControlQuestionLeavesThePageAlone() async throws {
        let f = try await fixture(default: .readOnly, html: Self.plainPage)
        defer { _ = f.server }
        let store = f.store
        let tab = f.tab
        let toolkit = f.toolkit

        await answering(.ask) { asked in
            let output = await toolkit.clickOnPage(ref: 0, label: "Add to cart")
            #expect(!output.contains("Clicked"))
            #expect(output.contains("wasn’t allowed"))
            #expect(asked() == [.control])
        }
        #expect(try await clicks(tab) == 0)
        #expect(store.assistantRecord(for: tab.assistantAccess.origin) == nil)
    }

    @Test func allowControlDefaultClicksWithoutAskingOnAPageWithoutSensitiveFields() async throws {
        let f = try await fixture(default: .control, html: Self.plainPage)
        defer { _ = f.server }
        let store = f.store
        let tab = f.tab
        let toolkit = f.toolkit

        await answering(.ask) { asked in
            #expect((await toolkit.readPage()).contains("Plain page text"))
            let output = await toolkit.clickOnPage(ref: 0, label: "Add to cart")
            #expect(output.contains("Clicked"))
            #expect(asked().isEmpty)
        }
        #expect(try await clicks(tab) == 1)
        #expect(store.assistantOrigins.isEmpty)
    }

    @Test func aPasswordFieldMakesTheClickAskUnderAllowControl() async throws {
        let f = try await fixture(default: .control, html: Self.loginPage)
        defer { _ = f.server }
        let store = f.store
        let tab = f.tab
        let toolkit = f.toolkit

        await answering(.ask) { asked in
            #expect((await toolkit.readPage()).contains("Welcome back"))
            #expect(asked().isEmpty)
            let output = await toolkit.clickOnPage(ref: 0, label: "Add to cart")
            #expect(!output.contains("Clicked"))
            #expect(asked() == [.control])
        }
        #expect(try await clicks(tab) == 0)
        #expect(tab.assistantAccess.isCappedBySensitiveField)

        // Allowing the site once lifts the cap for it.
        await answering(.control) { asked in
            let output = await toolkit.clickOnPage(ref: 0, label: "Add to cart")
            #expect(output.contains("Clicked"))
            #expect(asked() == [.control])
        }
        #expect(store.assistantRecord(for: tab.assistantAccess.origin) == .control)
        #expect(try await clicks(tab) == 1)
    }

    @Test func allowControlDefaultStillAsksBeforeAPurchase() async throws {
        let html = """
            <!doctype html><title>Shop</title>
            <button onclick="window.__paid=1">Place order</button>
            """
        let f = try await fixture(default: .control, html: html)
        defer { _ = f.server }
        let tab = f.tab
        let toolkit = f.toolkit

        var category: SensitiveAction.Category?
        let output = await AgentActionConsent.$decisionForTesting.withValue(.init({ _, asked, _, _ in
            category = asked
            return .decline
        })) {
            await toolkit.clickOnPage(ref: 0, label: "Place order")
        }

        #expect(category == .purchase)
        #expect(output.contains("declined"))
        #expect(try await tab.page.evaluateJavaScript("typeof window.__paid === 'undefined'") as? Bool == true)
    }

    @Test func allowControlDefaultStillAsksBeforeSigningInWithAnotherAccount() async throws {
        let html = """
            <!doctype html><title>Welcome</title>
            <button onclick="window.__google=1">Continue with Google</button>
            """
        let f = try await fixture(default: .control, html: html)
        defer { _ = f.server }
        let tab = f.tab
        let toolkit = f.toolkit

        var category: SensitiveAction.Category?
        let output = await AgentActionConsent.$decisionForTesting.withValue(.init({ _, asked, _, _ in
            category = asked
            return .decline
        })) {
            await toolkit.clickOnPage(ref: 0, label: "Continue with Google")
        }

        #expect(category == .accountAccess)
        #expect(output.contains("declined"))
        #expect(try await tab.page.evaluateJavaScript("typeof window.__google === 'undefined'") as? Bool == true)
    }

    @Test func aPlainSignInLinkNeedsNoQuestionUnderAllowControl() async throws {
        let html = """
            <!doctype html><title>Welcome</title>
            <button onclick="window.__signin=1">Sign in</button>
            """
        let f = try await fixture(default: .control, html: html)
        defer { _ = f.server }
        let tab = f.tab
        let toolkit = f.toolkit

        var asked = false
        let output = await AgentActionConsent.$decisionForTesting.withValue(.init({ _, _, _, _ in
            asked = true
            return .decline
        })) {
            await toolkit.clickOnPage(ref: 0, label: "Sign in")
        }

        #expect(!asked)
        #expect(output.contains("Clicked"))
        #expect(try await tab.page.evaluateJavaScript("window.__signin") as? Int == 1)
    }

    @Test func aRecordedNoAccessStillBlocksUnderAllowControl() async throws {
        let f = try await fixture(default: .control, html: Self.plainPage)
        defer { _ = f.server }
        let store = f.store
        let tab = f.tab
        let toolkit = f.toolkit
        store.setAssistantAccess(.deny, for: tab.assistantAccess.origin)

        let output = await toolkit.readPage()

        #expect(output.contains("Assistant access is off"))
        #expect(!output.contains("Plain page text"))
    }
}

/// A connection's own grant and the website's own record limit it; the in-app default never does.
@MainActor
@Suite(.boundedWebViews)
struct MCPDefaultAccessTests {
    private struct Fixture {
        let server: HTTPFixtureServer
        let store: SitePermissions
        let tab: BrowserTab
        let session: MCPBrowserSession
    }

    private func fixture(default policy: AssistantAccessPolicy) async throws -> Fixture {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<!doctype html><p>Shared</p>")])
        let store = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("MCPDefaultAccess-\(UUID().uuidString).json"))
        store.setAssistantDefault(policy)
        let browser = BrowserModel(database: .temporary(), sitePermissions: store)
        let url = try server.url()
        let tab = browser.newTab(url: url)
        #expect(await PageSettle.untilIdle(tab.page))
        tab.assistantAccess.pageChanged(url: url)
        let session = MCPBrowserSession(browser: browser, available: { true }, consent: { _, _, _ in .control })
        _ = try await session.call(name: "requestAccess", arguments: [:])
        return Fixture(server: server, store: store, tab: tab, session: session)
    }

    @Test(arguments: [AssistantAccessPolicy.ask, .readOnly, .control])
    func mcpCeilingIgnoresTheDefault(_ policy: AssistantAccessPolicy) async throws {
        let f = try await fixture(default: policy)
        defer { _ = f.server }
        let store = f.store
        let tab = f.tab
        let session = f.session
        let origin = tab.assistantAccess.origin

        #expect(session.permits(tab, capability: .read))
        #expect(session.permits(tab, capability: .control))

        store.setAssistantAccess(.readOnly, for: origin)
        #expect(session.permits(tab, capability: .read))
        #expect(!session.permits(tab, capability: .control))

        store.setAssistantAccess(.ask, for: origin)
        #expect(session.permits(tab, capability: .control))

        store.setAssistantAccess(nil, for: origin)
        #expect(session.permits(tab, capability: .control))
    }
}
