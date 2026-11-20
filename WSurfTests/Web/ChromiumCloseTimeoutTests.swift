// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// A Chromium tab's retirement waits for CEF to confirm the browser closed. When that answer never comes, the wait ends after
/// `ChromiumPage.closeTimeout` and the page is released all the same, instead of being held for as long as the app runs.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ChromiumCloseTimeoutTests {
    @Test func onlyAnAttachedBrowserViewFollowsThePageSize() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let tab = try await rig.open("/still")
            let chromium = try #require(tab.page.chromium)
            _ = try await rig.open("/still")
            do {
                let child = try #require(chromium.subviews.first)
                chromium.setFrameSize(NSSize(width: 410, height: 310))
                chromium.layout()
                #expect(child.frame == chromium.bounds)

                rig.coordinator.unloadTab(tab)
                try #require(await waitUntil { child.superview == nil })
                let detachedFrame = child.frame
                chromium.setFrameSize(NSSize(width: detachedFrame.width + 80, height: detachedFrame.height + 40))
                chromium.layout()
                #expect(child.frame == detachedFrame)
            }
            await tab.waitForRetirement()
        }
    }

    @Test func anUnansweredCloseReleasesThePageAfterTheTimeout() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let tab = try await rig.open("/still")
            _ = try await rig.open("/still")
            let clock = TestClock()
            weak var releasedPage: BrowserPage?
            weak var releasedChromium: ChromiumPage?
            do {
                let chromium = try #require(tab.page.chromium)
                chromium.closeClock = clock
                chromium.dropsCloseAnswerForTesting = true
                releasedPage = tab.page
                releasedChromium = chromium
            }

            rig.coordinator.unloadTab(tab)
            #expect(tab.isDeferred && !tab.isMaterialised)
            try #require(await waitUntil { clock.pendingCount == 1 }, "the close waits on the timeout")
            try? await Task.sleep(for: .seconds(1))
            #expect(releasedChromium?.isClosed == false, "CEF's answer was lost, so the page is not closed yet")
            #expect(releasedPage != nil, "and the retirement still holds it")

            clock.advance(by: ChromiumPage.closeTimeout)
            #expect(await waitUntil(timeout: .seconds(10)) { releasedPage == nil && releasedChromium == nil },
                    "the timeout ends the page and the retirement lets it go")

            // The tab comes back on a new page as usual.
            rig.browser.activate(tab)
            _ = await tab.waitForPendingNavigation()
            let url = try rig.server.url("/still")
            #expect(await waitUntil(timeout: .seconds(60)) { tab.page.url == url && !tab.page.isLoading })
        }
    }

    /// A close CEF answers in time is not touched by the timeout that follows it.
    @Test func anAnsweredCloseIgnoresTheTimeout() async throws {
        try await LiveWindowRig.with(engine: .chromium) { rig in
            let tab = try await rig.open("/still")
            _ = try await rig.open("/still")
            let clock = TestClock()
            weak var releasedChromium: ChromiumPage?
            do {
                let chromium = try #require(tab.page.chromium)
                chromium.closeClock = clock
                releasedChromium = chromium
            }
            rig.coordinator.unloadTab(tab)
            #expect(await waitUntil(timeout: .seconds(30)) { releasedChromium == nil }, "CEF's answer releases the page")
            clock.advance(by: ChromiumPage.closeTimeout)
            await Task {}.value
            #expect(tab.isDeferred)
        }
    }
}
