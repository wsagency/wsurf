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

    @Test func aChangeOfLightOrDarkLooksAgainOnlyInTheTabOnScreen() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let clock = TestClock()
            let (first, second) = try await twoTabs(rig, clock: clock)
            try #require(second.isInFront && !first.isInFront, "the second tab is in front; the first is on the shelf")
            let before = second.bandMeasureCount
            let parkedBefore = first.bandMeasureCount
            // Light or dark mode reaches a page's view from the window or the app; setting it on the view is the same event for it.
            let wasDark = second.page.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            defer {
                second.page.appearance = nil
                first.page.appearance = nil
            }
            first.page.appearance = NSAppearance(named: wasDark ? .aqua : .darkAqua)
            try? await Task.sleep(for: .milliseconds(200))
            #expect(first.bandRecheck == nil && clock.pendingCount == 0, "a tab on the shelf waits for its next show")
            second.page.appearance = NSAppearance(named: wasDark ? .aqua : .darkAqua)
            try #require(await waitUntil { clock.pendingCount == 1 }, "the tab on screen waits to look at its band")
            #expect(second.bandMeasureCount == before, "and takes no capture in the change itself")
            clock.advance(by: BrowserTab.bandSettleDelay)
            try #require(await waitUntil { second.bandMeasureCount == before + 1 })
            try? await Task.sleep(for: .milliseconds(200))
            #expect(first.bandMeasureCount == parkedBefore, "and the tab on the shelf took none")
        }
    }

    @Test func aTabWithNoColourForItsModeKeepsItsColourAndCapturesOnceInTheSwitch() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let clock = TestClock()
            let (first, second) = try await twoTabs(rig, clock: clock)
            rig.browser.activate(second)
            first.pageColor = .systemRed
            first.bandMeasuredKey = BrowserTab.BandKey(url: first.urlString, isDark: !first.isDarkAppearance)
            let before = first.bandMeasureCount
            #expect(first.willCaptureBandOnShow)
            rig.browser.activate(first)
            #expect(first.pageColor != nil, "the colour it had is not replaced by the theme's while the capture runs")
            try #require(await waitUntil { first.bandMeasureCount == before + 1 })
            try? await Task.sleep(for: .milliseconds(200))
            #expect(clock.pendingCount == 0, "a fresh capture takes the place of the look")
            clock.advance(by: BrowserTab.bandSettleDelay * 2)
            try? await Task.sleep(for: .milliseconds(200))
            #expect(first.bandMeasureCount == before + 1, "one capture for the switch")
        }
    }

    @Test func theLookOfAWokenTabIsRestartedWhenTheScrollIsAskedFor() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let clock = TestClock()
            let (first, _) = try await twoTabs(rig, clock: clock)
            let before = first.bandMeasureCount
            first.scheduleBandRecheck()
            try #require(await waitUntil { clock.pendingCount == 1 })
            clock.advance(by: .milliseconds(600))
            first.scheduleBandRecheck(restart: true)
            try #require(await waitUntil { clock.pendingCount == 1 }, "the first wait was dropped, one new one waits")
            clock.advance(by: .milliseconds(600))
            try? await Task.sleep(for: .milliseconds(200))
            #expect(first.bandMeasureCount == before, "1.2 s after the first call, 0.6 s after the restart: no capture yet")
            clock.advance(by: .milliseconds(100))
            try #require(await waitUntil { first.bandMeasureCount == before + 1 })
        }
    }

    @Test func aWokenTabWaitsOutTheScrollScriptBeforeItsLook() {
        #expect(BrowserTab.bandWakeDelay >= .milliseconds(1300), "the scroll script tries for up to 1.2 s")
        #expect(BrowserTab.bandWakeDelay > BrowserTab.bandSettleDelay)
    }

    @Test func aColourIsCurrentOnlyForItsAddressAndMode() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let tab = try await rig.open("/still")
            let dark = tab.isDarkAppearance
            tab.pageColor = .systemBlue
            tab.bandMeasuredKey = .init(url: tab.urlString, isDark: dark)
            #expect(tab.holdsCurrentBandColour)
            tab.bandMeasuredKey = .init(url: tab.urlString, isDark: !dark)
            #expect(!tab.holdsCurrentBandColour, "measured in the other mode")
            tab.bandMeasuredKey = .init(url: tab.urlString + "x", isDark: dark)
            #expect(!tab.holdsCurrentBandColour, "measured for another address")
            tab.bandMeasuredKey = nil
            #expect(!tab.holdsCurrentBandColour)
            tab.bandMeasuredKey = .init(url: tab.urlString, isDark: dark)
            tab.pageColor = nil
            #expect(!tab.holdsCurrentBandColour, "no colour")
        }
    }

    @Test func aLeavingChromiumTabKeepsItsPreviewWhenAnotherCaptureIsInTheSwitch() {
        // isChromium, hasPreview, arrivingCaptures, isMeasuringBand
        #expect(BrowserTab.skipsPreview(isChromium: true, hasPreview: true, arrivingCaptures: true, isMeasuringBand: false))
        #expect(BrowserTab.skipsPreview(isChromium: true, hasPreview: true, arrivingCaptures: false, isMeasuringBand: true))
        #expect(!BrowserTab.skipsPreview(isChromium: true, hasPreview: true, arrivingCaptures: false, isMeasuringBand: false))
        #expect(!BrowserTab.skipsPreview(isChromium: true, hasPreview: false, arrivingCaptures: true, isMeasuringBand: true), "no preview yet: take one")
        #expect(!BrowserTab.skipsPreview(isChromium: false, hasPreview: true, arrivingCaptures: true, isMeasuringBand: true), "WebKit's snapshot is cheap")
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
            try? await Task.sleep(for: .milliseconds(200))
            #expect(first.bandMeasureCount == before, "the settle delay is not enough for a woken tab")
            clock.advance(by: BrowserTab.bandWakeDelay - BrowserTab.bandSettleDelay)
            try #require(await waitUntil { first.bandMeasureCount == before + 1 })
        }
    }
}
