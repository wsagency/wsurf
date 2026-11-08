// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// Sleep inactive tabs end to end: the configured delay is the one the window's sweep uses, a change applies without a relaunch,
/// idle time starts only once nothing keeps a tab loaded, and an unloaded tab gives its page back on either engine.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct TabSleepScheduleTests {
    typealias Reason = BackgroundTabHidingTests.Reason

    private func makeModel() -> BrowserModel {
        BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("TabSleepSchedule-\(UUID().uuidString).json")
            )
        )
    }

    // MARK: - Idle clock

    /// Whatever keeps a background tab loaded, it is spared while it lasts, and once it ends the tab still gets the whole limit:
    /// two hours of playing (or a picture, an assistant run, an edited form...) is not two hours of idle time.
    @Test(arguments: Reason.allCases)
    func idleTimeStartsWhenAProtectionEnds(reason: Reason) {
        let model = makeModel()
        let held = model.newTab(url: URL(string: "https://example.com/held"))
        let front = model.newTab(url: URL(string: "https://example.com/front"))
        model.activate(front)
        let limit = Duration.seconds(3600)
        let start = ContinuousClock.now
        held.lastForegroundAt = start - .seconds(7200)

        reason.apply(true, to: held, in: model)
        #expect(model.sleepIdleTabs(after: limit, now: start) == 0, "\(reason): spared while it lasts")
        #expect(model.sleepIdleTabs(after: limit, now: start + .seconds(7200)) == 0)
        #expect(!held.isDeferred)

        reason.apply(false, to: held, in: model)
        let released = start + .seconds(7200)
        #expect(model.sleepIdleTabs(after: limit, now: released + .seconds(60)) == 0, "\(reason): not idle a minute after it ended")
        #expect(!held.isDeferred)
        #expect(model.sleepIdleTabs(after: limit, now: released + .seconds(3661)) == 1, "\(reason): idle a full limit later")
        #expect(held.isDeferred)
    }

    /// A favorite stays loaded; one that stops being a favorite starts its idle time then, not when it last left the front.
    @Test func aFormerFavoriteStartsItsIdleTimeWhenItStopsBeingOne() {
        let model = makeModel()
        let tab = model.newTab(url: URL(string: "https://example.com/fav"))
        let front = model.newTab(url: URL(string: "https://example.com/front"))
        model.activate(front)
        let limit = Duration.seconds(3600)
        let start = ContinuousClock.now
        tab.lastForegroundAt = start - .seconds(7200)
        tab.isFavorite = true
        #expect(model.sleepIdleTabs(after: limit, now: start) == 0)

        tab.isFavorite = false
        #expect(model.sleepIdleTabs(after: limit, now: start + .seconds(60)) == 0)
        #expect(!tab.isDeferred)
        #expect(model.sleepIdleTabs(after: limit, now: start + .seconds(3601)) == 1)
    }

    /// Showing a sleeping tab twice brings it back once.
    @Test func wakingASleepingTabTwiceLoadsItOnce() {
        let model = makeModel()
        let tab = model.newTab(url: URL(string: "https://example.com/sleeper"))
        _ = model.newTab(url: URL(string: "https://example.com/front"))
        model.discardBackgroundTabs()
        #expect(tab.isDeferred)

        model.activate(tab)
        let page = tab.page
        tab.realizeDeferredSession()
        #expect(!tab.isDeferred)
        #expect(tab.page === page)
    }

    // MARK: - The window's sweep

    /// The window's timer ticks every quarter of the delay (at most a minute) and unloads a tab once it has been in the background
    /// for the configured delay; a new delay applies at once, and turning sleeping off, or back to memory pressure only, stops it.
    @Test func theSweepUsesTheConfiguredDelayAndFollowsAChange() async throws {
        try await LiveWindowRig.with(engine: .webKit) { rig in
            // The test host's own defaults (a suffixed bundle identifier), put back after.
            let settings = BrowserSettings.application
            let wasOn = settings.sleepsInactiveTabs
            let wasMinutes = settings.sleepAfterMinutes
            defer {
                settings.sleepsInactiveTabs = wasOn
                settings.sleepAfterMinutes = wasMinutes
            }
            let clock = TestClock()
            rig.coordinator.sleepTimer.stop()
            rig.coordinator.sleepTimer = TabSleepTimer(clock: clock)
            settings.sleepAfterMinutes = 1
            settings.sleepsInactiveTabs = true
            rig.coordinator.applySleepTimer()

            let stale = try await rig.open("/still")
            let fresh = try await rig.open("/still")
            _ = try await rig.open("/still")
            try #require(await waitUntil { clock.pendingCount == 1 })

            // One minute: the tick is every 15 s.
            stale.lastForegroundAt = .now - .seconds(61)
            fresh.lastForegroundAt = .now - .seconds(30)
            clock.advance(by: .seconds(14))
            try? await Task.sleep(for: .milliseconds(200))
            #expect(!stale.isDeferred, "no tick before a quarter of the delay")
            clock.advance(by: .seconds(1))
            #expect(await waitUntil { stale.isDeferred }, "past the delay at the tick")
            #expect(!fresh.isDeferred, "inside the delay")

            // Two minutes, set the way Settings sets it: no relaunch, the tick is now every 30 s.
            settings.sleepAfterMinutes = 2
            try #require(await waitUntil { clock.pendingCount == 1 })
            fresh.lastForegroundAt = .now - .seconds(90)
            clock.advance(by: .seconds(30))
            try? await Task.sleep(for: .milliseconds(200))
            #expect(!fresh.isDeferred, "90 s is inside the new delay")
            try #require(await waitUntil { clock.pendingCount == 1 })
            fresh.lastForegroundAt = .now - .seconds(121)
            clock.advance(by: .seconds(30))
            #expect(await waitUntil { fresh.isDeferred }, "past the new delay")

            settings.sleepAfterMinutes = 0
            #expect(!rig.coordinator.sleepTimer.isRunning, "memory pressure only: no timer")
            settings.sleepAfterMinutes = 5
            #expect(rig.coordinator.sleepTimer.isRunning)
            settings.sleepsInactiveTabs = false
            #expect(!rig.coordinator.sleepTimer.isRunning, "off: no timer")
        }
    }

    // MARK: - Unloading on each engine

    private static let routes: [String: HTTPFixtureServer.Response] = [
        "/long": .html("""
            <!doctype html><title>Long</title><div style="height:6000px">tall</div>
            <script>window.__marker = 'loaded';</script>
            """),
    ]

    /// Unload tab hands the engine's page back (WebKit view, or the CEF browser closed) and keeps the row; showing the tab again
    /// loads the same address. WebKit also brings back its history.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func unloadReleasesThePageAndShowingRestoresIt(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine, routes: Self.routes) { rig in
            let tab = try await rig.open("/still")
            let second = try rig.server.url("/page")
            tab.load(second)
            try #require(await waitUntil(timeout: .seconds(60)) { tab.page.url == second && !tab.page.isLoading })
            _ = try await rig.open("/still")

            weak var releasedPage: BrowserPage?
            weak var releasedWebKit: WKWebView?
            weak var releasedChromium: ChromiumPage?
            do {
                let page = tab.page
                releasedPage = page
                releasedWebKit = page.webKit
                releasedChromium = page.chromium
                #expect(page.engine == engine)
            }
            rig.coordinator.unloadTab(tab)
            #expect(tab.isDeferred && !tab.isMaterialised, "\(engine): unloaded")
            #expect(rig.browser.tabs.contains { $0 === tab }, "the row stays")
            #expect(await waitUntil(timeout: .seconds(30)) {
                releasedPage == nil && releasedWebKit == nil && releasedChromium == nil
            }, "\(engine): the page, its view and its CEF browser are released")

            rig.browser.activate(tab)
            _ = await tab.waitForPendingNavigation()
            #expect(await waitUntil(timeout: .seconds(60)) { tab.page.url == second && !tab.page.isLoading },
                    "\(engine): the same address comes back")
            #expect(await rig.marker(of: tab) == "loaded")
            if engine == .webKit {
                #expect(tab.canGoBack, "WebKit restores the history")
            }
        }
    }

    /// WebKit's saved state brings the scroll position back; a Chromium tab loads its address again and puts the offset it kept back
    /// once that load has finished (`WakeScroll`).
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func scrollPositionAfterReactivation(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine, routes: Self.routes) { rig in
            let tab = try await rig.open("/long")
            _ = try await tab.page.evaluateJavaScript("window.scrollTo(0, 1500); true")
            try #require(await waitUntil {
                ((try? await tab.page.evaluateJavaScript("window.scrollY")) as? Double ?? 0) >= 1400
            })
            _ = try await rig.open("/still")
            rig.coordinator.unloadTab(tab)
            try #require(tab.isDeferred)
            await tab.waitForRetirement()

            rig.browser.activate(tab)
            _ = await tab.waitForPendingNavigation()
            try #require(await waitUntil(timeout: .seconds(60)) { await rig.marker(of: tab) == "loaded" })
            @MainActor func scrollY() async -> Double {
                (try? await tab.page.evaluateJavaScript("window.scrollY")) as? Double ?? 0
            }
            if engine == .webKit {
                let restored = await waitUntil(timeout: .seconds(5)) { await scrollY() >= 1400 }
                #expect(restored, "WebKit restores the scroll position")
            } else {
                // The same tolerance as ChromiumScrollWakeTests: within 2 points of where the tab was.
                var latest = 0.0
                let restored = await waitUntil(timeout: .seconds(5)) {
                    latest = await scrollY()
                    return abs(latest - 1500) < 2
                }
                #expect(restored, "Chromium puts the kept offset back after the load (scrollY is \(latest))")
            }
        }
    }

    /// A favorite unloaded by hand stays unloaded: the kept-alive shelf does not build its page again.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func anUnloadedFavoriteStaysUnloaded(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let favorite = try await rig.open("/still")
            rig.browser.addFavorite(favorite)
            try #require(favorite.isFavorite)
            _ = try await rig.open("/still")
            weak var released: BrowserPage?
            do { released = favorite.page }

            rig.coordinator.unloadTab(favorite)
            #expect(favorite.isDeferred)
            #expect(await waitUntil(timeout: .seconds(30)) { released == nil }, "\(engine): its page is released")
            try? await Task.sleep(for: .seconds(1))
            #expect(favorite.isDeferred && !favorite.isMaterialised, "\(engine): and nothing loads it again")
        }
    }
}
