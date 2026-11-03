// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A link opened from the page of a micro window, by real input: the tab it makes goes to the main window, never into the micro
/// window, and the micro window keeps its one page.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct OpenInNewTabFromMicroWindowTests {
    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/": .html("""
            <!doctype html><title>Opener</title><style>body { margin: 0 }</style>
            <a id="blank" href="/target?via=blank" target="_blank"
               style="position: absolute; left: 20px; top: 130px; width: 240px; height: 30px; display: block">blank</a>
            <a id="plain" href="/target?via=plain"
               style="position: absolute; left: 20px; top: 170px; width: 240px; height: 30px; display: block">plain</a>
            """),
        "/target": .html("<!doctype html><title>Target</title><p>Target</p>"),
    ]

    private func withProfile(_ body: (Profile) async throws -> Void) async throws {
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let profile = catalog.add(name: "Links from micro windows")
        var failure: (any Error)?
        do {
            try await body(profile)
        } catch {
            failure = error
        }
        await catalog.remove(profile)
        catalog.markCurrent(previous)
        if let failure {
            throw failure
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aLinkOpenedInAMicroWindowLandsInTheMainWindow(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let url = try server.url("/")
        try await withProfile { profile in
            let context = BrowserProfileContext.shared(for: profile)
            context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: url))
            let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
            let main = app.newWindow(profile: profile, show: false)
            let tab = main.browser.newTab(url: url)
            let page = tab.page
            try #require(await waitUntil { page.url == url && !page.isLoading && page.mainDocumentID != nil })
            let micro = try #require(main.moveToMicroWindow(tab))
            let window = try #require(micro.nativeWindow)
            try #require(await waitUntil { page.window === window })
            let before = main.browser.tabs.count

            // A target=_blank link, as the page's script follows it while the person's click is replayed: in front.
            try await follow("blank", in: page)
            try #require(
                await waitUntil { main.browser.tabs.contains { $0.urlString.contains("via=blank") } },
                "the link opened a tab in the main window: \(main.browser.tabs.map(\.urlString)); the micro window has \(micro.browser.tabs.map(\.urlString))"
            )
            let landed = try #require(main.browser.tabs.first { $0.urlString.contains("via=blank") })
            #expect(main.browser.tabs.count == before + 1)
            #expect(micro.browser.tabs.map(\.id) == [tab.id], "the micro window keeps its one page")
            #expect(main.browser.activeTab === landed)
            #expect(page.url == url, "the micro window's page did not move")

            for window in app.windows {
                window.closeWindow()
            }
            await tab.waitForRetirement()
            await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
            withExtendedLifetime(server) {}
        }
    }

    /// Follows the link `id` with the person's click replayed in the page: a link click that carries a user gesture, which opens a
    /// tab as a click does. (A click on a window that is not on screen is not reliably delivered to WebKit; the main window's
    /// real clicks are in `OpenInNewTabTests`.)
    private func follow(_ id: String, in page: BrowserPage) async throws {
        _ = try await page.callAsyncJavaScript(
            "document.getElementById(id).click(); return true;", arguments: ["id": id], in: nil, contentWorld: .page, userGesture: true
        )
    }
}
