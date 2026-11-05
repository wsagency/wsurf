// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The owner's report: an invisible player at the top right of the page and clicks there never reach the site. The media
/// player moved to a corner (the video experiment) is drawn by the sidebar, offset over the page. The Minimal window's tab
/// list clips the whole sidebar to its rounded shape, which hides the player there, but SwiftUI does not clip hit testing,
/// so the hidden player still took every click and hover in its corner. Each case puts a page in a window the app's way,
/// makes the player active in the top right corner and asks AppKit what a click 40 pt in from the page's top right hits.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct FloatingPlayerClickTests {
    private func eventually(timeout: Duration = .seconds(8), _ condition: @MainActor () -> Bool) async -> Bool {
        await waitUntil(timeout: timeout, condition)
    }

    private struct Rig {
        let coordinator: AppCoordinator
        let page: BrowserPage
        let host: NSView

        /// Whether a click near the page's top right corner goes to the page itself.
        func clickHitsThePage() -> Bool {
            host.layoutSubtreeIfNeeded()
            let frame = page.convert(page.bounds, to: nil)
            let point = NSPoint(x: frame.maxX - 40, y: frame.maxY - 40)
            guard let superview = host.superview, let hit = host.hitTest(superview.convert(point, from: nil)) else { return false }
            return hit.isDescendant(of: page)
        }

        func showPlayer(_ isActive: Bool) {
            coordinator.media.model.title = "Fixture track"
            coordinator.media.model.isActive = isActive
        }
    }

    /// The player rests in the top right corner, as the owner left it. Both choices are app-wide, and turning the video on
    /// turns automatic Picture in Picture off, so all three are put back.
    private func withPlayerInTheTopRight(_ body: () async throws -> Void) async rethrows {
        let settings = BrowserSettings.application
        let video = settings.showsVideoInPlayer
        let automaticPiP = settings.automaticPictureInPicture
        let corner = settings.mediaPlayerCorner
        settings.showsVideoInPlayer = true
        settings.mediaPlayerCorner = .topRight
        defer {
            settings.mediaPlayerCorner = corner
            settings.showsVideoInPlayer = video
            settings.automaticPictureInPicture = automaticPiP
        }
        try await body()
    }

    private func withWindow(
        style: BrowserWindowStyle,
        engine: BrowserEngine,
        _ body: (Rig) async throws -> Void
    ) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Page</title><body style=\"margin:0\">Page</body>")])
        let url = try server.url("/")
        let profile = Profile(id: UUID(), name: "Floating player fixture", symbol: "person", color: .gray)
        let context = BrowserProfileContext.shared(for: profile)
        context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let browser = BrowserModel(context: context, windowID: UUID(), database: .temporary())
        let coordinator = AppCoordinator(browser: browser)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(
            BrowserView(browser: browser, coordinator: coordinator, style: style, keepsSidebarOpen: true)
        ))
        host.safeAreaRegions = []
        window.contentView = host
        window.orderFront(nil)
        var failure: (any Error)?
        do {
            let tab = browser.newTab(url: url)
            let page = tab.page
            try #require(await waitUntil { page.window === window && page.title == "Page" && !page.isLoading })
            #expect(page.engine == engine)
            try await body(Rig(coordinator: coordinator, page: page, host: host))
        } catch {
            failure = error
        }
        coordinator.media.model.isActive = false
        let tabs = browser.tabs
        browser.closeAllTabs(saving: false)
        for tab in tabs {
            await tab.waitForRetirement()
        }
        await ChromiumRuntime.shared.releaseContext(contextID: context.contextID)
        await context.sitePermissions.waitForPendingSave()
        window.close()
        browser.cancelPendingSave()
        BrowserProfileContext.forget(profile.id)
        ProfileSettingsStore.forget(profile.id)
        try? FileManager.default.removeItem(at: profile.supportDirectory)
        try? FileManager.default.removeItem(at: FaviconLoader.cacheDirectory(for: profile))
        withExtendedLifetime(server) {}
        if let failure {
            throw failure
        }
    }

    /// The owner's window: Minimal, with the tab list kept open. The player cannot be seen over the page there, so it must
    /// not take the page's clicks either. Five seconds is long past the player measuring itself and moving to its corner.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aPlayerTheMinimalListCannotShowTakesNoClicks(engine: BrowserEngine) async throws {
        try await withPlayerInTheTopRight {
            try await withWindow(style: .minimal, engine: engine) { rig in
                try #require(await eventually { rig.clickHitsThePage() }, "with no player, the click is the page's")
                // A player that appears while the window is still settling may wait to measure itself, and until then it is
                // transparent and takes nothing; the owner's window had long settled.
                _ = await waitUntil(timeout: .seconds(1)) { false }

                rig.showPlayer(true)
                let lost = await eventually(timeout: .seconds(5)) { !rig.clickHitsThePage() }
                #expect(!lost, "a player nobody can see took the click at the page's top right")
            }
        }
    }

    /// The Standard window draws the player in its corner, so there it is the player that takes the click, and the page gets
    /// it back once the player goes.
    @Test func theStandardWindowsPlayerStillTakesItsClicks() async throws {
        try await withPlayerInTheTopRight {
            try await withWindow(style: .standard, engine: .webKit) { rig in
                try #require(await eventually { rig.clickHitsThePage() }, "with no player, the click is the page's")

                rig.showPlayer(true)
                #expect(await eventually { !rig.clickHitsThePage() }, "the player in the corner takes the click")

                rig.showPlayer(false)
                #expect(await eventually { rig.clickHitsThePage() }, "the page gets it back once the player is gone")
            }
        }
    }
}
