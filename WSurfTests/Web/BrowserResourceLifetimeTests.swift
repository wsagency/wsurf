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
