// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Testing

@testable import WSurf

/// The browser window is full-size content under a transparent titlebar with an empty unified toolbar, so the top of the page
/// lies in the titlebar. A press there reaches the page only over views AppKit's private
/// `_opaqueRectForWindowMoveWhenInTitlebar` names; everywhere else the window server moves the window and the app never sees
/// the click. A Chromium page named nothing, so the top of every Chromium page took no clicks (a Google avatar in the Minimal
/// window). The press itself is the window server's, so the case checks what AppKit hands it.
@MainActor
@Suite(.serialized)
struct TitlebarPageClickTests {
    private static let hook = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")
    private typealias Hook = @convention(c) (AnyObject, Selector) -> NSRect

    private func opaqueRect(of view: NSView) -> NSRect {
        unsafeBitCast(view.method(for: Self.hook), to: Hook.self)(view, Self.hook)
    }

    @Test func theTopOfAChromiumPageTakesClicksInTheTitlebar() async throws {
        try #require(NSView.instancesRespond(to: Self.hook), "AppKit no longer asks views for their titlebar click area")
        // As `BrowserHost` makes it.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "wsurf.test.frame")
        window.toolbarStyle = .unified
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = root

        // A pop-up waiting for its browser makes none, so no Chromium runtime is needed.
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page = BrowserPage(chromium: ChromiumPage(context: context, popup: URL(string: "https://example.com/")))
        // The Minimal window's page starts at the theme's page spacing.
        let spacing = LoomChrome.canvasInset
        page.frame = NSRect(x: 0, y: 0, width: 800, height: 500 - spacing)
        root.addSubview(page)
        let shelf = WebViewParkingShelf(frame: .zero)
        root.addSubview(shelf)
        defer { window.close() }

        let titlebarDepth = window.frame.height - window.contentLayoutRect.height
        #expect(titlebarDepth > spacing + 20, "the titlebar must reach over the top of the page for this case to mean anything")
        #expect(opaqueRect(of: page) == page.bounds)
        #expect(opaqueRect(of: NSView(frame: page.frame)) == .zero, "a plain view is still a place to move the window from")

        // Parked, the page is off screen and leaves the titlebar to move the window.
        page.removeFromSuperview()
        shelf.addSubview(page)
        #expect(opaqueRect(of: page).isEmpty)

        await page.close()
        await context.endPrivateSession()
    }
}
