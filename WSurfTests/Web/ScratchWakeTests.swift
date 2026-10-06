// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct ScratchWakeTests {
    private func window() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    /// The window stays off screen. A page that renders to a display takes a
    /// display link with it, and dropping a rendering view - which is what
    /// discarding a tab does - crashes WebKit's display-link thread on a
    /// virtual display. A view in a window still presents, which is all the
    /// test asks of it.
    private func host(_ page: BrowserPage, in window: NSWindow) {
        page.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        window.contentView?.addSubview(page)
    }

    @Test(arguments: [false, true])
    func wakingADiscardedTabBringsThePageBack(attachBeforeActivate: Bool) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/a": .html("<title>Page A</title><h1>A</h1>"),
            "/b": .html("<title>Page B</title><h1>B</h1>"),
        ])
        let a = try server.url("/a")
        let b = try server.url("/b")
        let permissions = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("Wake-\(UUID().uuidString).json")
        )
        let model = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let sleeper = model.newTab(url: a)
        let keeper = model.newTab(url: b)
        let win = window()
        defer {
            win.contentView?.subviews.forEach { $0.removeFromSuperview() }
            sleeper.detach()
            keeper.detach()
        }
        host(sleeper.page, in: win)
        #expect(await PageSettle.untilIdle(sleeper.page, timeout: .seconds(30)))
        #expect(await waitUntil { sleeper.urlString == a.absoluteString })

        model.activate(keeper)
        host(keeper.page, in: win)
        model.discardBackgroundTabs()
        #expect(sleeper.isDeferred, "the background tab must be asleep for this test to mean anything")

        if attachBeforeActivate {
            host(sleeper.page, in: win)
            model.activate(sleeper)
        } else {
            model.activate(sleeper)
            host(sleeper.page, in: win)
        }

        let woke = await waitUntil(timeout: .seconds(15)) {
            sleeper.page.url?.absoluteString == a.absoluteString
        }
        #expect(woke, "the woken tab never loaded its page back (url = \(sleeper.page.url?.absoluteString ?? "nil"))")
        #expect(await waitUntil { sleeper.hasPresentedContent }, "the woken tab never painted")
    }
}
