// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A loaded favorite stays alive behind the tab in front, as a background tab does, and it is not shown: the engines report its
/// page hidden and it runs no animation frames. What plays sound keeps playing. The window is the one the app builds (content
/// area and parking shelf) with the real sidebar, on each engine.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct KeptAliveFavoritesTests {
    // MARK: - Hidden

    /// The favorite is loaded and stays so (no reload when it comes back), but while another tab is in front its page is hidden
    /// and its frame counter stands still. In front it animates, and the tab in front is visible, so a hidden favorite is not an
    /// unshown window.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aFavoriteBehindAnotherTabIsHiddenAndStopsAnimating(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let favorite = try await rig.open("/page")
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)
            rig.browser.activate(favorite)
            try #require(await waitUntil { await rig.isAnimating(favorite) }, "in front the favorite is visible and animates")

            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            #expect(await waitUntil { await rig.state(of: front) == "visible" }, "the tab in front is visible")
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" }
            let reported = await rig.state(of: favorite) ?? "nothing"
            #expect(hidden, "\(engine): the favorite behind it reports \(reported)")
            let ran = await rig.framesInASecond(of: favorite)
            #expect(ran >= 0 && ran <= 2, "\(engine): the hidden favorite ran \(ran) frames in a second")

            #expect(favorite.isMaterialised && !favorite.isDeferred, "it stays loaded")
            #expect(favorite.page.window != nil, "and in its window")
            #expect(await rig.marker(of: favorite) == "loaded")

            rig.browser.activate(favorite)
            #expect(await waitUntil { await rig.isAnimating(favorite) }, "\(engine): back in front it is visible and animates again")
            #expect(await rig.marker(of: favorite) == "loaded", "it did not reload")
        }
    }

    /// A favorite that has just left the front stays shown for the wait, so going straight back is as quick as it always was, and
    /// is hidden when the wait is over.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aFavoriteStaysShownForTheWaitAndIsHiddenAfterIt(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let clock = TestClock()
            let favorite = try await rig.open("/page", grace: .seconds(10), clock: clock)
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)
            rig.browser.activate(favorite)
            try #require(await waitUntil { await rig.isAnimating(favorite) })

            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil { clock.pendingCount == 1 }, "the wait is running")
            #expect(await rig.isAnimating(favorite), "\(engine): within the wait the favorite is visible and animates")

            clock.advance(by: .seconds(10))
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" }
            let reported = await rig.state(of: favorite) ?? "nothing"
            #expect(hidden, "\(engine): when the wait ends it reports \(reported)")
            let ran = await rig.framesInASecond(of: favorite)
            #expect(ran >= 0 && ran <= 2, "\(engine): the hidden favorite ran \(ran) frames in a second")
        }
    }

    /// A favorite that opens behind the tab in front (the way every favorite does at launch) loads without being shown, and is
    /// hidden while it does.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aFavoriteThatOpensBehindTheTabInFrontLoadsHidden(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let front = try await rig.open("/still")
            let url = try rig.server.url("/page")
            let favorite = rig.browser.newTab(url: url, activate: false, engine: engine)
            favorite.page.ignoresWindowOcclusion = true
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)
            try #require(rig.browser.activeTab === front)

            #expect(
                await waitUntil(timeout: .seconds(60)) { favorite.page.url == url && !favorite.page.isLoading },
                "\(engine): the favorite loads without being shown"
            )
            #expect(await waitUntil { favorite.page.window === rig.window }, "in the window, where Chromium needs it")
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" }
            let reported = await rig.state(of: favorite) ?? "nothing"
            #expect(hidden, "\(engine): it reports \(reported)")
            let ran = await rig.framesInASecond(of: favorite)
            #expect(ran >= 0 && ran <= 2, "\(engine): it ran \(ran) frames in a second")

            rig.browser.activate(favorite)
            #expect(await waitUntil { await rig.isAnimating(favorite) }, "\(engine): shown, it animates")
            #expect(await rig.marker(of: favorite) == "loaded", "it did not reload")
        }
    }

    /// The preview in the sidebar comes from a snapshot of the page, which has to work on a page that is hidden: one is taken as
    /// the tab leaves the front, and one when the pointer rests on its row.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aHiddenFavoriteStillGivesItsPreview(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let favorite = try await rig.open("/page")
            rig.browser.addFavorite(favorite)
            rig.browser.activate(favorite)
            try #require(await waitUntil { await rig.isAnimating(favorite) })

            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" })
            #expect(await waitUntil(timeout: .seconds(15)) { favorite.preview != nil }, "\(engine): the preview taken as it left the front")

            let earlier = favorite.preview
            favorite.refreshPreview()
            #expect(await waitUntil(timeout: .seconds(15)) { favorite.preview !== earlier }, "\(engine): a new preview of the hidden page")
            let image = try #require(favorite.preview)
            #expect(LiveWindowRig.hasContent(image), "\(engine): the preview of the hidden page is not blank")
        }
    }

    // MARK: - Playing

    /// A favorite that plays keeps playing behind the tab in front, loaded and in its window, and stays in the list of tabs that
    /// are heard.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aFavoriteThatPlaysAudioKeepsPlayingBehindAnotherTab(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let favorite = try await rig.open("/page")
            try await rig.startPlaying(favorite)
            try #require(await waitUntil { favorite.isPlayingAudio }, "the page plays")
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)

            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try await Task.sleep(for: .seconds(2))

            #expect(favorite.isPlayingAudio, "\(engine): the favorite is still heard")
            #expect(rig.app.audibleTabs(for: rig.coordinator).contains { $0.tab === favorite })
            #expect(await rig.isPlaying(favorite) == true, "\(engine): its player was not paused")
            #expect(favorite.isMaterialised && !favorite.isDeferred)
            #expect(favorite.page.window != nil)
            #expect(await rig.marker(of: favorite) == "loaded", "it did not reload")
        }
    }

    /// A hidden favorite that starts to play is shown to the engine again, so what it plays is not cut short by being hidden.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aHiddenFavoriteThatStartsPlayingIsNoLongerHidden(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let favorite = try await rig.open("/page")
            rig.browser.addFavorite(favorite)
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "hidden" })

            try await rig.startPlaying(favorite)
            #expect(await waitUntil { favorite.isPlayingAudio }, "\(engine): the page plays")
            let shown = await waitUntil(timeout: .seconds(10)) { await rig.state(of: favorite) == "visible" }
            let reported = await rig.state(of: favorite) ?? "nothing"
            #expect(shown, "\(engine): the favorite that plays reports \(reported)")
            try await Task.sleep(for: .seconds(1))
            #expect(await rig.isPlaying(favorite) == true, "\(engine): its player was not paused")
            #expect(favorite.isPlayingAudio)
        }
    }
}
