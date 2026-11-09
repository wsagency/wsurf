// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A tab that is no longer in front waits hidden: its page reports `hidden` and runs no animation frames, as a background tab does
/// in any browser, while it stays loaded and in its window. What plays sound, is held by the assistant or a connected app, uses
/// a device or has its video in a picture is shown. The window is the one the app builds (content area and parking shelf) with
/// the real sidebar, on each engine.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct BackgroundTabHidingTests {
    /// Something that makes a tab's page stay as it was. `apply` starts it or ends it on a tab with nothing else going on.
    nonisolated enum Reason: CaseIterable, Sendable, CustomTestStringConvertible {
        case pictureOut, microphone, screenShare, editedForm, assistantWorking, connectedApp, mediaDock, siteKeptActive

        var testDescription: String {
            "\(self)"
        }

        /// One connection, so ending its hold finds the grant it made.
        private static let connection = UUID()

        @MainActor
        func apply(_ on: Bool, to tab: BrowserTab, in model: BrowserModel) {
            switch self {
            case .pictureOut:
                tab.isPictureOut = on
            case .microphone:
                tab.permissions.setLive(.microphone, on)
            case .screenShare:
                tab.notePageActivity(.init(kind: .screenShare, token: "main", isActive: on))
            case .editedForm:
                tab.notePageActivity(.init(kind: .editedForm, token: "main", isActive: on))
            case .assistantWorking:
                tab.setAgentWorking(on)
            case .connectedApp:
                tab.processState.setExternalController(Self.connection, holds: on)
            case .mediaDock:
                tab.isControlledByMediaDock = on
            case .siteKeptActive:
                model.setKeepsActive(on, for: tab)
            }
        }
    }

    /// The tab is loaded and stays so (no reload when it comes back), but while another tab is in front its page is hidden and
    /// its frame counter stands still. In front it animates, and the tab in front is visible, so a hidden tab is not an unshown
    /// window.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aTabBehindAnotherTabIsHiddenAndStopsAnimating(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let background = try await rig.open("/page")
            let stamp = try await rig.stamp(background)
            try #require(await waitUntil { await rig.isAnimating(background) }, "in front the tab is visible and animates")

            let front = try await rig.open("/page")
            try #require(rig.browser.activeTab === front)
            #expect(await waitUntil { await rig.state(of: front) == "visible" }, "the tab in front is visible")
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: background) == "hidden" }
            let reported = await rig.state(of: background) ?? "nothing"
            #expect(hidden, "\(engine): the tab behind it reports \(reported)")
            let ran = await rig.frames(of: background, whileFramesOf: front)
            #expect(ran.map { (0.0...1.0).contains($0) } == true, "\(engine): the hidden tab ran \(ran.map { "\($0)" } ?? "no") frames while the front tab ran 20")

            #expect(background.page.isParked, "it waits on the shelf")
            #expect(background.isMaterialised && !background.isDeferred, "it stays loaded")
            #expect(background.page.window != nil, "and in its window")
            #expect(await rig.stampSurvived(background, stamp), "it did not reload while it was hidden")

            rig.browser.activate(background)
            #expect(
                await waitUntil { background.page.window === rig.window && !background.page.isParked && !background.page.isHidden },
                "\(engine): in front it is shown the moment it is in the content area"
            )
            #expect(await waitUntil { await rig.isAnimating(background) }, "\(engine): back in front it is visible and animates again")
            #expect(await rig.stampSurvived(background, stamp), "it did not reload")
        }
    }

    // MARK: - The wait

    /// A tab that is switched away from and back within the wait never reports hidden, and is still drawing when it is back, so
    /// going straight back finds it as it left it.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aTabSwitchedAwayFromAndBackWithinTheWaitIsNeverHidden(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let clock = TestClock()
            let first = try await rig.open("/page", grace: .seconds(10), clock: clock)
            let stamp = try await rig.stamp(first)
            let front = try await rig.open("/still")
            for round in 1...3 {
                rig.browser.activate(first)
                #expect(await waitUntil { await rig.isAnimating(first) }, "\(engine), round \(round): back in front it animates")
                rig.browser.activate(front)
                // The wait is registered on the manual clock once the switch away has been processed, and nothing advances that
                // clock here, so no hide can have run: one read of the state after that is the whole negative.
                try #require(await waitUntil { clock.pendingCount == 1 }, "\(engine), round \(round): the wait is running")
                let reported = await rig.state(of: first)
                #expect(reported == "visible", "\(engine), round \(round): left behind, within the wait, it reports \(reported ?? "nothing")")
                #expect(await rig.isAnimating(first), "\(engine), round \(round): and it is still drawing")
            }
            #expect(await rig.stampSurvived(first, stamp), "it did not reload")
        }
    }

    /// A tab still in the background when the wait ends is hidden and runs no frames.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aTabStillInTheBackgroundWhenTheWaitEndsIsHidden(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let clock = TestClock()
            let background = try await rig.open("/page", grace: .seconds(10), clock: clock)
            let stamp = try await rig.stamp(background)
            let front = try await rig.open("/page")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil { clock.pendingCount == 1 }, "the wait is running")
            #expect(await rig.isAnimating(background), "\(engine): within the wait it is visible and animates")

            clock.advance(by: .seconds(9))
            #expect(await rig.isAnimating(background), "\(engine): a second before the end it still does")

            clock.advance(by: .seconds(1))
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: background) == "hidden" }
            let reported = await rig.state(of: background) ?? "nothing"
            #expect(hidden, "\(engine): when the wait ends it reports \(reported)")
            let ran = await rig.frames(of: background, whileFramesOf: front)
            #expect(ran.map { (0.0...1.0).contains($0) } == true, "\(engine): the hidden tab ran \(ran.map { "\($0)" } ?? "no") frames while the front tab ran 20")
            #expect(await rig.stampSurvived(background, stamp), "it did not reload")
        }
    }

    /// Coming back ends a pending hide and the next wait starts from zero; so does a reason to stay shown.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func comingBackOrBecomingNeededEndsAPendingHide(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let clock = TestClock()
            let first = try await rig.open("/page", grace: .seconds(10), clock: clock)
            let front = try await rig.open("/still")
            try #require(await waitUntil { clock.pendingCount == 1 })
            clock.advance(by: .seconds(9))

            rig.browser.activate(first)
            #expect(await waitUntil { clock.pendingCount == 0 }, "\(engine): coming back cancels the wait")
            clock.advance(by: .seconds(10))
            #expect(await waitUntil { await rig.isAnimating(first) }, "\(engine): and nothing hides it")

            rig.browser.activate(front)
            try #require(await waitUntil { clock.pendingCount == 1 }, "leaving again starts a new wait")
            clock.advance(by: .seconds(9))
            #expect(await rig.isAnimating(first), "\(engine): the nine seconds before do not count")

            first.isPictureOut = true
            #expect(await waitUntil { clock.pendingCount == 0 }, "\(engine): a reason to stay shown cancels the wait")
            clock.advance(by: .seconds(10))
            #expect(await rig.isAnimating(first), "\(engine): and the page stays as it is")

            first.isPictureOut = false
            try #require(await waitUntil { clock.pendingCount == 1 }, "\(engine): the wait starts over when the reason ends")
            clock.advance(by: .seconds(10))
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: first) == "hidden" }
            #expect(hidden, "\(engine): and the page hides when it is over")
        }
    }

    /// Going back and forth between two tabs hides one and shows the other every time, with the page left as it was.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func twoTabsTakeTurnsBeingHiddenAndShown(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let first = try await rig.open("/page")
            let firstStamp = try await rig.stamp(first)
            let second = try await rig.open("/page")
            let secondStamp = try await rig.stamp(second)
            for round in 1...3 {
                rig.browser.activate(first)
                #expect(await waitUntil { await rig.isAnimating(first) }, "\(engine), round \(round): the first is shown")
                #expect(await waitUntil(timeout: .seconds(10)) { await rig.state(of: second) == "hidden" }, "\(engine), round \(round): the second waits")
                rig.browser.activate(second)
                #expect(await waitUntil { await rig.isAnimating(second) }, "\(engine), round \(round): the second is shown")
                #expect(await waitUntil(timeout: .seconds(10)) { await rig.state(of: first) == "hidden" }, "\(engine), round \(round): the first waits")
            }
            #expect(await rig.stampSurvived(first, firstStamp), "the first did not reload")
            #expect(await rig.stampSurvived(second, secondStamp), "the second did not reload")
        }
    }

    /// The preview in the sidebar and in the tab switcher comes from a snapshot of the page, which has to work on a page that is
    /// hidden: one is taken as the tab leaves the front, and one when the pointer rests on its row.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aHiddenTabStillGivesItsPreview(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let background = try await rig.open("/page")
            try #require(await waitUntil { await rig.isAnimating(background) })

            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil(timeout: .seconds(10)) { await rig.state(of: background) == "hidden" })
            #expect(await waitUntil(timeout: .seconds(15)) { background.preview != nil }, "\(engine): the preview taken as it left the front")
            if let leaving = background.preview {
                #expect(LiveWindowRig.hasContent(leaving), "\(engine): the preview taken as it left is not blank")
            }

            let earlier = background.preview
            background.refreshPreview()
            #expect(await waitUntil(timeout: .seconds(15)) { background.preview !== earlier }, "\(engine): a new preview of the hidden page")
            let image = try #require(background.preview)
            #expect(LiveWindowRig.hasContent(image), "\(engine): the preview of the hidden page is not blank")
        }
    }

    /// A tab that is held for any of these reasons is shown while it waits on the shelf, whenever the reason starts, and hidden
    /// again when it ends.
    @Test(arguments: [BrowserEngine.webKit, .chromium], Reason.allCases)
    func aTabIsShownWhileSomethingNeedsItAndHiddenAgainAfter(engine: BrowserEngine, reason: Reason) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let background = try await rig.open("/page")
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil(timeout: .seconds(10)) { await rig.state(of: background) == "hidden" })
            try #require(background.page.isParked)

            reason.apply(true, to: background, in: rig.browser)
            let shown = await waitUntil(timeout: .seconds(10)) { await rig.state(of: background) == "visible" }
            #expect(shown, "\(engine), \(reason): the tab is shown while it holds")
            #expect(await rig.isAnimating(background), "\(engine), \(reason): and it animates")

            reason.apply(false, to: background, in: rig.browser)
            let hidden = await waitUntil(timeout: .seconds(10)) { await rig.state(of: background) == "hidden" }
            #expect(hidden, "\(engine), \(reason): the tab hides again when it ends")
        }
    }

    /// A tab behind the one in front that plays keeps playing, loaded and in its window, and stays in the list of tabs that are
    /// heard.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aTabThatPlaysAudioKeepsPlayingBehindAnotherTab(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let background = try await rig.open("/page")
            let stamp = try await rig.stamp(background)
            try await rig.startPlaying(background)
            try #require(await waitUntil { background.isPlayingAudio }, "the page plays")
            let hiding = HidingWatch(background)

            // A silent tab leaves the front after the one that plays did, and goes through the same hide path. Once it reports
            // `hidden` that path has run, so what it would have done to the tab that plays has been done.
            let silent = try await rig.open("/page")
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(
                await waitUntil(timeout: .seconds(10)) { await rig.state(of: silent) == "hidden" },
                "\(engine): the hide path ran for the silent tab"
            )

            // A tab that plays is kept shown (it is protected from hiding), and it draws: a hidden page still loads and plays, so
            // the player alone would not tell the difference.
            #expect(!hiding.hid, "\(engine): the tab that plays was never marked hidden (the media dock may have taken it since)")
            #expect(await rig.state(of: background) == "visible", "\(engine): the tab that plays is not hidden")
            #expect(await waitUntil { await rig.isAnimating(background) }, "\(engine): and it still draws")
            #expect(background.isPlayingAudio, "\(engine): the tab is still heard")
            #expect(rig.app.audibleTabs(for: rig.coordinator).contains { $0.tab === background })
            #expect(await rig.isPlaying(background) == true, "\(engine): its player was not paused")
            #expect(background.isMaterialised && !background.isDeferred)
            #expect(background.page.window != nil)
            #expect(await rig.stampSurvived(background, stamp), "it did not reload")
        }
    }

    /// A hidden tab that starts to play is shown again, so what it plays is not cut short by being hidden.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aHiddenTabThatStartsPlayingIsNoLongerHidden(engine: BrowserEngine) async throws {
        try await LiveWindowRig.with(engine: engine) { rig in
            let background = try await rig.open("/page")
            let front = try await rig.open("/still")
            try #require(rig.browser.activeTab === front)
            try #require(await waitUntil(timeout: .seconds(10)) { await rig.state(of: background) == "hidden" })

            try await rig.startPlaying(background)
            #expect(await waitUntil { background.isPlayingAudio }, "\(engine): the page plays")
            let shown = await waitUntil(timeout: .seconds(10)) { await rig.state(of: background) == "visible" }
            let reported = await rig.state(of: background) ?? "nothing"
            #expect(shown, "\(engine): the tab that plays reports \(reported)")
            #expect(await waitUntil { await rig.isAnimating(background) }, "\(engine): shown, it draws again")
            #expect(await rig.isPlaying(background) == true, "\(engine): its player was not paused")
            #expect(background.isPlayingAudio)
        }
    }

    /// Each rig is a profile of its own, but the rigs share one WebKit store, emptied in between: a store per rig spent the test
    /// host's limited persistent stores (`Profile.dataStoreForTesting`), and the cases after the last one could not open a database.
    @Test func rigsShareOneEmptiedWebKitStore() async throws {
        var stores: [WKWebsiteDataStore] = []
        var profiles: [UUID] = []
        for mark in ["first", "second"] {
            try await LiveWindowRig.with(engine: .webKit) { rig in
                stores.append(rig.browser.context.dataStore)
                profiles.append(rig.browser.context.profile.id)
                let tab = try await rig.open("/still")
                // A cookie is the host's whatever the port, so the second rig's server sees the first one's unless it was emptied.
                let before = try await tab.page.evaluateJavaScript("document.cookie") as? String
                #expect(before == "", "\(mark) rig: \(before ?? "nil")")
                _ = try await tab.page.evaluateJavaScript("document.cookie = 'mark=\(mark); max-age=3600; path=/'; true")
                #expect(try await tab.page.evaluateJavaScript("document.cookie") as? String == "mark=\(mark)")
            }
        }
        #expect(stores.count == 2 && stores[0] === stores[1] && stores[0].isPersistent)
        #expect(profiles.count == 2 && profiles[0] != profiles[1])
    }
}
