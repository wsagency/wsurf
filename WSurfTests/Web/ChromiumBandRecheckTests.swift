// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A Chromium tab coming to the front takes no band capture during the switch: the screenshot's UI-thread half runs on the main
/// thread. It shows the colour it has, and looks at its band once, after the switch has settled. The clock is a manual one, so
/// "during" and "after" do not depend on the machine.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ChromiumBandRecheckTests {
    /// Two tabs on Chromium; the first has measured its band at load and is waiting on `clock`.
    private func twoTabs(_ rig: LiveWindowRig, clock: TestClock) async throws -> (BrowserTab, BrowserTab) {
        let first = try await rig.open("/still")
        first.bandClock = clock
        let second = try await rig.open("/still")
        second.bandClock = clock
        // The load measured each band; let those captures end and any look they scheduled go by.
        try #require(await waitUntil { first.bandMeasureCount > 0 && !first.isMeasuringBand && !second.isMeasuringBand })
        first.cancelBandRecheck()
        second.cancelBandRecheck()
        return (first, second)
    }

    @Test func aSwitchTakesNoCaptureAndOneLookAfterItSettles() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let clock = TestClock()
            let (first, second) = try await twoTabs(rig, clock: clock)
            let before = first.bandMeasureCount
            rig.browser.activate(first)
            // The tab is shown: nothing has been captured, and the look waits for the delay.
            try #require(await waitUntil { clock.pendingCount == 1 })
            try? await Task.sleep(for: .milliseconds(300))
            #expect(first.bandMeasureCount == before, "no band capture during the switch")
            #expect(clock.pendingCount == 1, "one look is waiting, however many times the tab was told it is shown")

            clock.advance(by: BrowserTab.bandSettleDelay - .milliseconds(1))
            try? await Task.sleep(for: .milliseconds(100))
            #expect(first.bandMeasureCount == before)
            clock.advance(by: .milliseconds(1))
            try #require(await waitUntil { first.bandMeasureCount == before + 1 })
            try? await Task.sleep(for: .milliseconds(300))
            #expect(first.bandMeasureCount == before + 1, "exactly one")
            _ = second
        }
    }

    @Test func switchingAwayBeforeTheLookCancelsIt() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let clock = TestClock()
            let (first, second) = try await twoTabs(rig, clock: clock)
            let before = first.bandMeasureCount
            rig.browser.activate(first)
            try #require(await waitUntil { clock.pendingCount == 1 })
            rig.browser.activate(second)
            #expect(await waitUntil { first.bandRecheck == nil }, "the tab that left drops its look")
            clock.advance(by: BrowserTab.bandSettleDelay * 2)
            try? await Task.sleep(for: .milliseconds(300))
            #expect(first.bandMeasureCount == before)
        }
    }

    @Test func aChangeOfLightOrDarkLooksAgain() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let clock = TestClock()
            let (_, second) = try await twoTabs(rig, clock: clock)
            let before = second.bandMeasureCount
            // Light or dark mode reaches the page's view from the window or the app; setting it on the view is the same event for it.
            let view = second.page
            let wasDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            defer { view.appearance = nil }
            view.appearance = NSAppearance(named: wasDark ? .aqua : .darkAqua)
            try #require(await waitUntil { clock.pendingCount == 1 }, "the visible Chromium tab waits to look at its band")
            #expect(second.bandMeasureCount == before, "and takes no capture in the change itself")
            clock.advance(by: BrowserTab.bandSettleDelay)
            try #require(await waitUntil { second.bandMeasureCount == before + 1 })
        }
    }

    @Test func aWokenTabLooksOnceAfterItsPageHasLoadedAndBeenScrolledBack() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let clock = TestClock()
            let (first, second) = try await twoTabs(rig, clock: clock)
            rig.browser.activate(second)
            rig.coordinator.unloadTab(first)
            #expect(first.isDeferred)
            let before = first.bandMeasureCount
            first.bandClock = clock
            rig.browser.activate(first)
            _ = await first.waitForPendingNavigation()
            let url = try rig.server.url("/still")
            try #require(await waitUntil(timeout: .seconds(60)) { first.page.url == url && !first.page.isLoading })
            // The load finished, and the page was asked to scroll back (`restoreScrollOffsetIfNeeded`); the look waits behind that.
            try #require(await waitUntil { clock.pendingCount == 1 })
            try? await Task.sleep(for: .milliseconds(300))
            #expect(first.bandMeasureCount == before, "no capture at the load of a woken tab")
            clock.advance(by: BrowserTab.bandSettleDelay)
            try #require(await waitUntil { first.bandMeasureCount == before + 1 })
        }
    }
}
