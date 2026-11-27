// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Testing
import WebKit

@testable import WSurf

extension ChromiumHistoryRestoreTests {
    @MainActor private struct Favorite {
        let browser: BrowserModel
        let tab: BrowserTab
        let window: NSWindow
        let container: WebViewContainer
        let site: HTTPFixtureServer

        func click(_ url: URL) async throws {
            let hit = try await tab.page.callAsyncJavaScript("""
                const link = document.createElement('a');
                link.href = destination; link.textContent = "Follow";
                link.style.cssText = "position:fixed;inset:0;z-index:999;background:white";
                document.body.appendChild(link);
                return document.elementFromPoint(innerWidth / 2, innerHeight / 2) === link;
                """, arguments: ["destination": url.absoluteString], in: nil, contentWorld: .page)
            try #require(hit as? Bool == true)
            let view = tab.page
            let point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            try #require(await waitUntil { PageDriver.pageReceivesPointer(at: view.convert(point, to: nil), in: view, window: window) })
            for phase in ["down", "up"] {
                try PageDriver.computerMouse(point: point, button: "left", phase: phase, in: view, window: window)
            }
        }

        func shows(_ url: URL) async -> Bool {
            await waitUntil {
                guard let page = tab.liveView else { return false }
                container.install(page)
                return page.url == url && !page.isLoading && page.backForwardList.currentItem?.url == url
            }
        }

        func hasSessionCookie() async throws -> Bool {
            try await tab.page.evaluateJavaScript("document.cookie.includes('favorite_session=fixture')") as? Bool == true
        }
    }

    private func withRestoredFavorite(_ body: (Favorite) async throws -> Void) async throws {
        try await withRig(engine: .webKit) { rig, _ in
            let home = try rig.server.url("/b")
            let source = try await history(in: rig, back: 1)
            try #require(await settles(source, at: "/b", back: ["/a"], forward: ["/c"]))
            source.engineOverride = nil
            rig.browser.addFavorite(source)
            let signIn = try #require(URL(string: "https://accounts.google.com/ServiceLogin"))
            try #require(source.permitsEngineNavigation(URLRequest(url: signIn), isMainFrame: true))
            rig.browser.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: home))
            _ = try await source.page.evaluateJavaScript("document.cookie = 'favorite_session=fixture; path=/'; true")
            rig.browser.closeAllTabs()
            let browser = BrowserModel(context: rig.browser.context, windowID: rig.browser.windowID)
            defer { browser.closeAllTabs(saving: false) }
            browser.restoreSession()
            let tab = try #require(browser.activeTab)
            let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let container = WebViewContainer(page: tab.page)
            window.contentView = container
            window.orderBack(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            try #require(await settles(tab, at: "/b", back: ["/a"], forward: ["/c"]))
            try #require(tab.loadedEngine == .webKit && tab.signInEngine == .webKit)
            try await body(Favorite(browser: browser, tab: tab, window: window, container: container, site: rig.server))
        }
    }

    @Test func aClickedLinkLeavesARestoredFavoritesSignInSessionOnAnotherWebsite() async throws {
        try await withRestoredFavorite { favorite in
            let home = try favorite.site.url("/b")
            let other = try await HTTPFixtureServer.start(routes: ["/outside": .html("Outside"), "/return": .redirect(to: home)])
            defer { withExtendedLifetime(other) {} }
            let outside = try other.url("/outside")
            favorite.browser.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: outside))
            try await favorite.click(favorite.site.url("/r"))
            try #require(await favorite.shows(favorite.site.url("/b2")))
            try #require(favorite.tab.loadedEngine == .webKit && favorite.tab.signInEngine == .webKit)
            #expect(try await favorite.hasSessionCookie())

            _ = try await favorite.tab.page.callAsyncJavaScript("""
                const next = document.createElement('a');
                next.href = address; next.click();
                """, arguments: ["address": try other.url("/return").absoluteString], in: nil, contentWorld: .page)
            try #require(await favorite.shows(home))
            try #require(favorite.tab.loadedEngine == .webKit && favorite.tab.signInEngine == .webKit)
            #expect(other.lastRequestHead(for: "/return")?.contains("favorite_session=fixture") == true)

            try await favorite.click(outside)
            try #require(await favorite.shows(outside))
            #expect(favorite.tab.loadedEngine == .chromium)
            #expect(favorite.tab.signInEngine == nil)

            favorite.browser.closeAllTabs()
            let reopened = BrowserModel(context: favorite.browser.context, windowID: favorite.browser.windowID)
            defer { reopened.closeAllTabs(saving: false) }
            reopened.restoreSession()
            let saved = try #require(reopened.activeTab)
            #expect(saved.id == favorite.tab.id && saved.loadedEngine == .chromium)
        }
    }

    @Test func backFromAnotherEngineReturnsToTheSignedInDocumentAndItsNativeHistory() async throws {
        try await withRestoredFavorite { favorite in
            let other = try await HTTPFixtureServer.start(routes: ["/outside": .html("Outside")])
            defer { withExtendedLifetime(other) {} }
            let outside = try other.url("/outside")
            favorite.browser.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: outside))
            try await favorite.click(outside)
            try #require(await favorite.shows(outside))
            try #require(favorite.tab.loadedEngine == .chromium && favorite.tab.canGoBack)

            favorite.tab.goBack()
            try #require(await favorite.shows(favorite.site.url("/b")))
            try #require(favorite.tab.loadedEngine == .webKit)
            #expect(try await favorite.hasSessionCookie())
            #expect(await settles(favorite.tab, at: "/b", back: ["/a"], forward: ["/c"]))
            let next = try favorite.site.url("/d")
            try await favorite.click(next)
            #expect(await favorite.shows(next))
            #expect(favorite.tab.loadedEngine == .webKit)
        }
    }

    @Test(arguments: ["attachment", "cancelled", "superseded", "committed"])
    func aWebKitDepartureEndsTheSignInOnlyWhenTheNewDocumentCommits(_ outcome: String) async throws {
        try await withRestoredFavorite { favorite in
            let gate = ResponseGate()
            let response: HTTPFixtureServer.Response = switch outcome {
            case "attachment":
                .download(Data([1, 2, 3]), filename: "fixture.bin")
            case "cancelled", "superseded":
                .html("Waiting", gate: gate)
            default:
                .html("Outside")
            }
            let other = try await HTTPFixtureServer.start(routes: ["/outside": response])
            defer {
                gate.open()
                withExtendedLifetime(other) {}
            }
            let outside = try other.url("/outside")
            var downloadURL: URL?
            favorite.tab.onDownload = { download, source, _ in
                downloadURL = source
                download.cancel { _ in }
            }
            try await favorite.click(outside)
            switch outcome {
            case "committed":
                try #require(await favorite.shows(outside))
                #expect(favorite.tab.signInEngine == nil)
                return
            case "cancelled":
                try #require(await waitUntil { gate.requestCount > 0 })
                favorite.tab.stopLoading()
                gate.open()
            case "superseded":
                try #require(await waitUntil { gate.requestCount > 0 })
                let next = try favorite.site.url("/a")
                try await favorite.click(next)
                try #require(await favorite.shows(next))
                gate.open()
                try #require(favorite.tab.loadedEngine == .webKit && favorite.tab.signInEngine == .webKit)
                #expect(try await favorite.hasSessionCookie())
                return
            default:
                try #require(await waitUntil { downloadURL == outside })
            }
            try #require(await favorite.shows(favorite.site.url("/b")))
            #expect(favorite.tab.signInEngine == .webKit)
            try await favorite.click(favorite.site.url("/d"))
            try #require(await favorite.shows(favorite.site.url("/d")))
            #expect(favorite.tab.loadedEngine == .webKit)
            #expect(try await favorite.hasSessionCookie())
        }
    }

    @Test(arguments: ["tab choice", "comparison tab"])
    func backToASignedInFavoriteRespectsAnExplicitChromiumChoice(_ choice: String) async throws {
        try await withRestoredFavorite { favorite in
            let other = try await HTTPFixtureServer.start(routes: ["/outside": .html("Outside")])
            defer { withExtendedLifetime(other) {} }
            let outside = try other.url("/outside")
            let home = try favorite.site.url("/b")
            favorite.browser.sitePermissions.setEngine(.chromium, for: SitePermissions.origin(for: outside))
            try await favorite.click(outside)
            try #require(await favorite.shows(outside) && favorite.tab.loadedEngine == .chromium)
            if choice == "comparison tab" {
                favorite.tab.engineOverride = .chromium
            } else {
                favorite.tab.pinnedEngine = (SitePermissions.origin(for: home), .chromium)
            }
            favorite.tab.goBack()
            try #require(await favorite.shows(home))
            #expect(favorite.tab.loadedEngine == .chromium && favorite.tab.signInEngine == nil)
            #expect(try await !favorite.hasSessionCookie())
        }
    }
}
