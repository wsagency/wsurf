// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct BrowserResourceLifetimeTests {
    @Test func repeatedTabClosureReleasesTabsAndWebViews() async throws {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        for index in 0..<20 {
            weak var releasedTab: BrowserTab?
            weak var releasedView: WKWebView?
            do {
                let tab = browser.newTab()
                let view = try #require(tab.page.webKit)
                releasedTab = tab
                releasedView = view
                view.loadHTMLString("<title>Resource fixture \(index)</title><p>Static page</p>", baseURL: nil)
                try #require(await waitUntil { !view.isLoading && view.title == "Resource fixture \(index)" })
                browser.close(tab, recordForReopening: false)
            }
            try #require(await waitUntil { releasedTab == nil && releasedView == nil })
        }
        #expect(browser.tabs.isEmpty)
    }

    @Test func discardingContentReleasesTheViewButPreservesTheTab() async throws {
        let browser = BrowserModel(database: .temporary())
        let tab = browser.newTab()
        defer { browser.close(tab, recordForReopening: false); browser.cancelPendingSave() }
        weak var releasedView: WKWebView?
        do {
            let view = try #require(tab.page.webKit)
            releasedView = view
            view.loadHTMLString("<title>Discard fixture</title>", baseURL: URL(string: "https://fixture.example/"))
            try #require(await waitUntil { !view.isLoading && view.title == "Discard fixture" })
            tab.urlString = "https://fixture.example/"
            try #require(tab.canDiscardWebContent)
            tab.discardWebContent()
        }
        #expect(await waitUntil { releasedView == nil })
        #expect(!tab.isMaterialised)
        #expect(browser.tabs.contains { $0 === tab })
    }

    /// `contentProcessDidTerminate()` is the tab's public lifecycle entry point, not a real
    /// web-content crash; these tests prove the tab's reaction, not WebKit's crash delivery.
    @Test func aBackgroundTabWhoseProcessDiesWaitsUntilItIsShown() async throws {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let background = browser.newTab()
        let front = browser.newTab()
        defer {
            browser.close(background, recordForReopening: false)
            browser.close(front, recordForReopening: false)
        }
        let view = try #require(background.page.webKit)
        view.loadHTMLString("<title>Background fixture</title>", baseURL: URL(string: "https://fixture.example/"))
        try #require(await waitUntil { !view.isLoading && view.title == "Background fixture" })
        background.urlString = "https://fixture.example/"
        try #require(browser.activeTab === front)

        background.contentProcessDidTerminate()

        #expect(!background.isMaterialised)
        #expect(background.isDeferred)

        browser.activate(background)
        #expect(background.isMaterialised)
        #expect(!background.isDeferred)
    }

    @Test func theShownTabReloadsAsSoonAsItsProcessDies() async throws {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let tab = browser.newTab()
        defer { browser.close(tab, recordForReopening: false) }
        let view = try #require(tab.page.webKit)
        view.loadHTMLString("<title>Front fixture</title>", baseURL: URL(string: "https://fixture.example/"))
        try #require(await waitUntil { !view.isLoading && view.title == "Front fixture" })
        tab.urlString = "https://fixture.example/"
        try #require(browser.activeTab === tab)

        tab.contentProcessDidTerminate()

        #expect(tab.isMaterialised)
        #expect(!tab.isDeferred)
        #expect(tab.page.webKit === view)
    }

    @Test func aTabBesideTheShownOneInASplitReloadsAtOnce() async throws {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let anchor = browser.newTab()
        let beside = browser.newTab()
        defer {
            browser.close(anchor, recordForReopening: false)
            browser.close(beside, recordForReopening: false)
        }
        let view = try #require(beside.page.webKit)
        view.loadHTMLString("<title>Split fixture</title>", baseURL: URL(string: "https://fixture.example/"))
        try #require(await waitUntil { !view.isLoading && view.title == "Split fixture" })
        beside.urlString = "https://fixture.example/"
        browser.split(anchor, with: beside, axis: .sideBySide)
        browser.activate(anchor)
        try #require(browser.isVisibleInSplit(beside))
        try #require(browser.activeTab === anchor)

        beside.contentProcessDidTerminate()

        #expect(beside.isMaterialised)
        #expect(!beside.isDeferred)
    }

    @Test func aClosedTabIsNotRevivedByALateTermination() async throws {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let tab = browser.newTab()
        let front = browser.newTab()
        defer { browser.close(front, recordForReopening: false) }
        tab.urlString = "https://fixture.example/"
        browser.close(tab, recordForReopening: false)

        tab.contentProcessDidTerminate()

        #expect(!tab.isMaterialised)
        #expect(!tab.isDeferred)
    }

    @Test func privateCEFContextsSurviveOtherWindowClose() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Private CEF lifetime</title>"),
        ])
        let url = try server.url("/")
        let profile = Profile.privateBrowsing()
        let contextA = BrowserProfileContext.shared(for: profile)
        let contextB = BrowserProfileContext.shared(for: profile)
        let runtime = ChromiumRuntime.shared
        let pageA = BrowserPage(chromium: ChromiumPage(context: contextA))
        let pageB = BrowserPage(chromium: ChromiumPage(context: contextB))
        let windowA = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                               styleMask: .borderless, backing: .buffered, defer: false)
        let windowB = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                               styleMask: .borderless, backing: .buffered, defer: false)
        windowA.isReleasedWhenClosed = false
        windowB.isReleasedWhenClosed = false
        windowA.contentView = pageA
        windowB.contentView = pageB
        windowA.orderFront(nil)
        windowB.orderFront(nil)

        do {
            #expect(contextA.profile.id == contextB.profile.id)
            #expect(contextA.contextID != contextB.contextID)
            pageA.load(URLRequest(url: url))
            pageB.load(URLRequest(url: url))
            try #require(await waitUntil {
                pageA.url == url && pageA.title == "Private CEF lifetime" && !pageA.isLoading &&
                    pageB.url == url && pageB.title == "Private CEF lifetime" && !pageB.isLoading
            })
            _ = try await pageA.evaluateJavaScript("document.cookie = 'owner=windowA; Path=/; SameSite=Lax'; true")
            _ = try await pageB.evaluateJavaScript("document.cookie = 'owner=windowB; Path=/; SameSite=Lax'; true")
            #expect(try await pageA.evaluateJavaScript("document.cookie") as? String == "owner=windowA")
            #expect(try await pageB.evaluateJavaScript("document.cookie") as? String == "owner=windowB")
            #expect(runtime.hasContext(contextID: contextA.contextID))
            #expect(runtime.hasContext(contextID: contextB.contextID))

            await contextA.endPrivateSession()
            windowA.close()

            #expect(pageA.isClosed, "page closure returns after CEF OnBeforeClose acknowledgement")
            #expect(!runtime.hasContext(contextID: contextA.contextID))
            #expect(runtime.hasContext(contextID: contextB.contextID))
            #expect(!pageB.isClosed)
            #expect(try await pageB.evaluateJavaScript("document.cookie") as? String == "owner=windowB")
            #expect(try await pageB.evaluateJavaScript("document.title") as? String == "Private CEF lifetime")
        } catch {
            await pageA.close()
            await pageB.close()
            await contextA.endPrivateSession()
            await contextB.endPrivateSession()
            windowA.close()
            windowB.close()
            throw error
        }
        await pageB.close()
        await contextB.endPrivateSession()
        windowB.close()
    }
}
