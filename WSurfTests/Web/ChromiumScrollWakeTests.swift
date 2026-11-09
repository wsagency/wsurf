// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// A tab that sleeps while scrolled wakes at the same place, not at the top. WebKit keeps the position in the interaction state it
/// restores; a Chromium tab loads its address again, so it keeps the offset itself and applies it once, after that load.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ChromiumScrollWakeTests {
    private static let tall = """
        <!doctype html><title>Tall</title><body style="margin:0"><div style="height:6000px;background:linear-gradient(#fff,#888)">tall</div></body>
        """

    private func scrollY(of tab: BrowserTab) async -> Double? {
        let value = try? await tab.page.evaluateJavaScript("window.scrollY")
        return (value as? NSNumber)?.doubleValue
    }

    @Test func aSleepingChromiumTabWakesAtItsScrollOffset() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: ["/tall": .html(Self.tall)]) { rig in
            let tab = try await rig.open("/tall")
            // A hidden Chromium page does not run its rendering update, so it never fires the scroll event the report
            // hangs on: the tab scrolls and reports while it is the visible one, and only then goes to the background.
            _ = try? await tab.page.evaluateJavaScript("window.scrollTo(0, 1500)")
            try #require(await waitUntil { abs(tab.lastReportedScrollY - 1500) < 2 }, "the page reports where it is")
            _ = try await rig.open("/still")

            rig.coordinator.unloadTab(tab)
            #expect(tab.isDeferred && !tab.isMaterialised)
            #expect(tab.wakeScroll.isArmed)
            rig.browser.activate(tab)
            _ = await tab.waitForPendingNavigation()
            let url = try rig.server.url("/tall")
            try #require(await waitUntil(timeout: .seconds(60)) { tab.page.url == url && !tab.page.isLoading })

            var latest: Double?
            let restored = await waitUntil {
                latest = await self.scrollY(of: tab)
                return abs((latest ?? 0) - 1500) < 2
            }
            #expect(restored, "scrollY is \(String(describing: latest))")
            #expect(!tab.wakeScroll.isArmed, "and it is used once")
        }
    }

    @Test func aTabAtTheTopWakesAtTheTop() async throws {
        try await LiveWindowRig.with(engine: .chromium, routes: ["/tall": .html(Self.tall)]) { rig in
            let tab = try await rig.open("/tall")
            _ = try await rig.open("/still")
            rig.coordinator.unloadTab(tab)
            #expect(tab.isDeferred && !tab.wakeScroll.isArmed, "nothing to restore")
            rig.browser.activate(tab)
            _ = await tab.waitForPendingNavigation()
            let url = try rig.server.url("/tall")
            try #require(await waitUntil(timeout: .seconds(60)) { tab.page.url == url && !tab.page.isLoading })
            #expect(await scrollY(of: tab) == 0)
        }
    }

    @Test func theOffsetIsUsedOnceAndOnlyForTheAddressItWasSavedFor() {
        var wake = WakeScroll()
        wake.arm(offset: 1500, for: "https://a.test/page")
        #expect(wake.take(finishedAt: "about:blank") == nil, "a start-up page does not use it up")
        #expect(wake.take(finishedAt: nil) == nil)
        #expect(wake.isArmed)
        #expect(wake.take(finishedAt: "https://a.test/page") == 1500)
        #expect(wake.take(finishedAt: "https://a.test/page") == nil, "once")

        wake.arm(offset: 900, for: "https://a.test/page")
        #expect(wake.take(finishedAt: "https://b.test/other") == nil, "another web address ends the wait")
        #expect(!wake.isArmed)
        #expect(wake.take(finishedAt: "https://a.test/page") == nil)
    }

    @Test func aPageAtTheTopOrWithoutAnAddressIsNotArmed() {
        var wake = WakeScroll()
        wake.arm(offset: 1, for: "https://a.test/")
        #expect(!wake.isArmed)
        wake.arm(offset: 0, for: "https://a.test/")
        #expect(!wake.isArmed)
        wake.arm(offset: 500, for: "")
        #expect(!wake.isArmed)
        wake.arm(offset: 500, for: "https://a.test/")
        wake.arm(offset: 0, for: "https://a.test/")
        #expect(!wake.isArmed, "arming a page at the top clears what was kept")
    }
}
