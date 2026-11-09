// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// The micro window's chrome: what reveals the bar, what keeps it down, and where a new window opens. The security cases are
/// here too: with no address showing, a page must not be able to hold the window to itself.
@MainActor
@Suite(.serialized)
struct MicroShellTests {
    // MARK: - The sensor

    private func window(with sensor: MicroRevealSensor.SensorView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        sensor.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView?.addSubview(sensor)
        return window
    }

    private func controlsHidden(in window: NSWindow) -> [Bool] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0)?.isHidden }
    }

    @Test func theSensorShowsTheTrafficLightsOnlyWithTheBar() {
        let sensor = MicroRevealSensor.SensorView()
        let window = window(with: sensor)
        defer {
            sensor.removeFromSuperview()
            window.close()
        }

        #expect(controlsHidden(in: window) == [true, true, true])

        sensor.showsWindowControls = true
        #expect(controlsHidden(in: window) == [false, false, false])

        sensor.showsWindowControls = false
        #expect(controlsHidden(in: window) == [true, true, true])
    }

    @Test func leavingTheWindowGivesTheControlsBack() {
        let sensor = MicroRevealSensor.SensorView()
        let window = window(with: sensor)
        defer { window.close() }

        sensor.removeFromSuperview()

        #expect(controlsHidden(in: window) == [false, false, false])
    }

    @Test func theRevealZoneGrowsWhileTheBarShows() throws {
        let sensor = MicroRevealSensor.SensorView()
        let window = window(with: sensor)
        defer {
            sensor.removeFromSuperview()
            window.close()
        }
        sensor.updateTrackingAreas()

        let hidden = try #require(sensor.trackingAreas.first)
        #expect(sensor.trackingAreas.count == 1)
        #expect(hidden.rect == NSRect(x: 0, y: 584, width: 800, height: MicroShell.revealBand))
        #expect(MicroShell.revealBand == 16)
        #expect(hidden.options.contains(.activeAlways), "a floating window answers the pointer while another app is in front")
        #expect(hidden.options.contains(.mouseEnteredAndExited), "leaving it matters as much as entering it")

        sensor.zoneHeight = IslandBar.height + 8
        let shown = try #require(sensor.trackingAreas.first)
        #expect(sensor.trackingAreas.count == 1, "the old zone is replaced, not added to")
        #expect(shown.rect == NSRect(x: 0, y: 548, width: 800, height: 52))
        #expect(shown.options.contains(.activeAlways))
    }

    @Test func theSensorReportsEnteringAndLeavingTheZone() throws {
        let sensor = MicroRevealSensor.SensorView()
        var reports: [Bool] = []
        sensor.onPointerInZone = { reports.append($0) }
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))

        sensor.mouseEntered(with: event)
        sensor.mouseExited(with: event)

        #expect(reports == [true, false])
        #expect(sensor.hitTest(NSPoint(x: 10, y: 10)) == nil, "the sensor never takes a click from the page")
    }

    // MARK: - What keeps the bar down

    @Test func theBarStaysWhileThereIsSomethingToReadOrAnswer() {
        func keeps(
            hasPage: Bool = true, isEditing: Bool = false, isBusy: Bool = false, isAsking: Bool = false,
            hasSaveOffer: Bool = false, voiceOver: Bool = false
        ) -> Bool {
            MicroShell.keepsBar(
                hasPage: hasPage, isEditing: isEditing, isBusy: isBusy, isAsking: isAsking,
                hasSaveOffer: hasSaveOffer, voiceOver: voiceOver
            )
        }

        #expect(!keeps(), "a page and nothing to say: the page has the window")
        #expect(keeps(hasPage: false), "a window with no page has only its address")
        #expect(keeps(isEditing: true))
        #expect(keeps(isBusy: true), "listening, a reply, a notice, a status, a question")
        #expect(keeps(isAsking: true), "a permission prompt")
        #expect(keeps(hasSaveOffer: true), "a password or passkey save offer")
        #expect(keeps(voiceOver: true), "VoiceOver is not a way around it")
    }

    /// The truth table is only as good as what feeds it: the same answer from the real objects of a window.
    @Test func aPermissionPromptANoticeAndAMissingPageKeepTheBarOfALiveWindow() async throws {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer {
            coordinator.browser.closeAllTabs(saving: false)
            coordinator.closeWindow()
        }
        let tab = coordinator.browser.newTab()
        func keeps() -> Bool {
            MicroShell.keepsBar(browser: coordinator.browser, coordinator: coordinator, isEditing: false, voiceOver: false)
        }
        #expect(keeps(), "no page yet")

        tab.urlString = "https://example.com/"
        tab.permissions.pageChanged(url: URL(string: "https://example.com/"))
        #expect(!keeps())

        // The answer must not be written to the profile's site permissions.
        tab.permissions.persistsAnswers = false
        async let decision = tab.permissions.decide(.camera)
        try #require(await waitUntil { tab.permissions.currentAsk != nil })
        #expect(keeps(), "a page asking for the camera")
        tab.permissions.answer(.deny)
        let granted = await decision
        #expect(!granted)
        #expect(!keeps(), "the question is answered")

        coordinator.show(notice: "Link Copied")
        #expect(keeps(), "a notice has to be read")
    }

    /// What cannot be told keeps the bar: no window, and a page with no host to show.
    @Test func whatCannotBeToldKeepsTheBar() {
        #expect(MicroShell.isEditing(in: nil), "no window to look at")
        for address in ["about:blank", "data:text/html,hi", "file:///tmp/page.html", "", "not an address"] {
            #expect(MicroShell.host(of: address) == nil, "\(address)")
        }

        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer {
            coordinator.browser.closeAllTabs(saving: false)
            coordinator.closeWindow()
        }
        let tab = coordinator.browser.newTab()
        func keeps(_ address: String) -> Bool {
            tab.urlString = address
            return MicroShell.keepsBar(browser: coordinator.browser, coordinator: coordinator, isEditing: false, voiceOver: false)
        }
        #expect(!keeps("https://example.com/"))
        for address in ["about:blank", "data:text/html,hi", "file:///tmp/page.html", ""] {
            #expect(keeps(address), "no host, no reason to hide the address: \(address)")
        }
    }

    /// Everything the bar waits on is read from the live objects, not copied, and the window is watched by its own
    /// notifications: the source says so.
    @Test func theBarReadsEveryInputFromTheLiveWindow() throws {
        let shell = try source("WSurf/UI/Shell/Micro/MicroShell.swift")
        for line in [
            "autofillSave.current", "autofillSave.websiteOffer", "coordinator.statusMessage",
            "coordinator.pendingAgentQuestion(inChrome: true)", "firstResponder is NSTextView", "coordinator.hasPendingPagePrompt",
        ] {
            #expect(shell.contains(line), "\(line)")
        }
        let reveal = try source("WSurf/UI/Shell/Micro/MicroReveal.swift")
        for line in [
            "NSWindow.willBeginSheetNotification", "NSWindow.didEndSheetNotification", "NSPopover.didShowNotification",
            "NSPopover.didCloseNotification", "withObservationTracking", "watchPending", "queue: nil",
        ] {
            #expect(reveal.contains(line), "\(line)")
        }
        let micro = try source("WSurf/App/AppCoordinator+Micro.swift")
        for line in [
            "permissions.pendingAsks", "autofillSave.isPopoverPresented", "NSWorkspace.shared.isVoiceOverEnabled",
            "isEditing(in: nativeWindow)", "guard let self else { return true }",
        ] {
            #expect(micro.contains(line), "\(line)")
        }
    }

    // MARK: - The reveal

    /// The reveal runs on a clock the case moves, so the moments below are exact and no machine load can stretch one.
    private func eventually(_ clock: TestClock, _ condition: @MainActor () -> Bool) async -> Bool {
        await clock.run(upTo: .seconds(5), until: condition)
    }

    @Test func aNewSiteShowsTheAddressForAMomentAndThenGoesAway() async {
        let clock = TestClock()
        let reveal = MicroReveal(hideDelay: .milliseconds(40), hostFlash: .milliseconds(400), clock: clock)
        #expect(!reveal.isRevealed)

        reveal.siteChanged()
        #expect(reveal.isRevealed && reveal.isFlashing)
        await clock.run(for: .milliseconds(350))
        #expect(reveal.isRevealed, "still inside the moment the address is owed")

        #expect(await eventually(clock) { !reveal.isRevealed })
        #expect(!reveal.isFlashing)
        #expect(MicroShell.hostFlash == .seconds(2), "the owner-visible moment")
    }

    @Test func everySiteChangeShowsTheAddressAgain() async {
        let clock = TestClock()
        let reveal = MicroReveal(hideDelay: .milliseconds(40), hostFlash: .milliseconds(250), clock: clock)
        for _ in 0..<2 {
            reveal.siteChanged()
            #expect(reveal.isRevealed)
            #expect(await eventually(clock) { !reveal.isRevealed })
        }
    }

    @Test func aPageThatChangesSiteAgainKeepsTheAddressUpForAnotherMoment() async {
        let clock = TestClock()
        let reveal = MicroReveal(hideDelay: .milliseconds(40), hostFlash: .milliseconds(300), clock: clock)
        reveal.siteChanged()
        await clock.run(for: .milliseconds(200))
        reveal.siteChanged()
        await clock.run(for: .milliseconds(200))
        #expect(reveal.isRevealed, "the second change restarted the moment")
        #expect(await eventually(clock) { !reveal.isRevealed })
    }

    @Test func thePointerAtTheTopKeepsTheBarUntilItLeavesAndTheDelayPasses() async {
        let clock = TestClock()
        let reveal = MicroReveal(hideDelay: .milliseconds(120), hostFlash: .milliseconds(100), clock: clock)

        reveal.pointer(inZone: true)
        #expect(reveal.isRevealed)
        await clock.run(for: .milliseconds(300))
        #expect(reveal.isRevealed, "while the pointer is there it stays")

        reveal.pointer(inZone: false)
        #expect(reveal.isRevealed, "it does not vanish under the pointer the instant it leaves")
        await clock.run(for: .milliseconds(100))
        #expect(reveal.isRevealed, "and not before the delay has passed")
        #expect(await eventually(clock) { !reveal.isRevealed })
    }

    @Test func aPromptHoldsTheBarWhateverThePointerDoes() async {
        var asking = true
        let clock = TestClock()
        let reveal = MicroReveal(hideDelay: .milliseconds(40), hostFlash: .milliseconds(60), keeps: { asking }, clock: clock)

        reveal.update()
        #expect(reveal.isRevealed)
        reveal.pointer(inZone: false)
        reveal.siteChanged()
        await clock.run(for: .milliseconds(400))
        #expect(reveal.isRevealed, "a prompt, a save offer or a question is never left to a page's own drawing")

        // What ends it is not always something SwiftUI watches (the address losing the keyboard): the bar looks again by itself.
        asking = false
        #expect(await eventually(clock) { !reveal.isRevealed })
    }

    @Test func aWindowWithNoPageStartsWithItsBarDown() {
        let reveal = MicroReveal(keeps: { true })
        reveal.update()
        #expect(reveal.isRevealed)
    }

    @Test func theAddressCommandBringsTheBarDownBeforeTheFieldHasTheKeyboard() async {
        let clock = TestClock()
        let reveal = MicroReveal(hideDelay: .milliseconds(40), hostFlash: .milliseconds(60), clock: clock)
        reveal.show()
        #expect(reveal.isRevealed)
        #expect(await eventually(clock) { !reveal.isRevealed }, "and a command that came to nothing does not leave it there")
    }

    // MARK: - What counts as another site

    @Test func anotherSiteIsAnotherHost() {
        #expect(MicroShell.host(of: "https://Example.com/a?b=1") == "example.com")
        #expect(MicroShell.host(of: "https://example.com/other") == "example.com")
        #expect(MicroShell.host(of: "https://www.example.com/") == "www.example.com")
        #expect(MicroShell.host(of: "http://example.com:8080/") == "example.com")
        #expect(MicroShell.host(of: "") == nil)
        #expect(MicroShell.host(of: nil) == nil)
        #expect(MicroShell.host(of: "about:blank") == nil)
        #expect(MicroShell.host(of: "not an address") == nil)
    }

    // MARK: - Where a window opens

    @Test func aNewMicroWindowOpensWhereTheLastOneWas() {
        let visible = NSRect(x: 0, y: 25, width: 1_440, height: 875)

        let first = MicroWindowMetrics.openingFrame(visible: visible, last: nil)
        #expect(first.size == MicroWindowMetrics.defaultSize)
        #expect(first == NSRect(x: 1_440 - 560 - 24, y: 900 - 420 - 24, width: 560, height: 420), "top right")

        let second = MicroWindowMetrics.openingFrame(visible: visible, last: first)
        #expect(second.size == first.size)
        #expect(second.minX == first.minX + 24 && second.maxY == first.maxY - 24, "right of and below the last one")

        let moved = NSRect(x: 100, y: 300, width: 480, height: 300)
        let third = MicroWindowMetrics.openingFrame(visible: visible, last: moved)
        #expect(third == NSRect(x: 124, y: 276, width: 480, height: 300), "the size the last one had")
    }

    @Test func aNewMicroWindowAlwaysFitsTheScreen() {
        let visible = NSRect(x: 0, y: 25, width: 1_440, height: 875)
        let corner = NSRect(x: 1_440 - 560, y: 25, width: 560, height: 420)

        let clamped = MicroWindowMetrics.openingFrame(visible: visible, last: corner)
        #expect(visible.contains(clamped))

        let huge = MicroWindowMetrics.openingFrame(visible: visible, last: NSRect(x: 0, y: 0, width: 5_000, height: 4_000))
        #expect(visible.contains(huge))

        let small = NSRect(x: 0, y: 0, width: 300, height: 200)
        #expect(MicroWindowMetrics.openingFrame(visible: small, last: nil).size == NSSize(width: 300, height: 200))
        #expect(small.contains(MicroWindowMetrics.openingFrame(visible: small, last: nil)))
    }

    @Test func aMicroWindowNeverEntersFullScreenAndFloatingJoinsEveryDesktop() {
        #expect(MicroWindowMetrics.collectionBehavior(floating: false) == [.fullScreenNone])
        #expect(MicroWindowMetrics.collectionBehavior(floating: true) == [.fullScreenAuxiliary, .canJoinAllSpaces])
        #expect(MicroWindowMetrics.minSize == NSSize(width: 420, height: 240))
    }

    // MARK: - The badge

    @Test func theBadgeOffersMoveBackInAMicroWindowAndNothingOnInternalPages() throws {
        let app = BrowserApplication(defaults: InMemoryUserDefaults(inheriting: .standard), notifications: NotificationCenter())
        let context = BrowserProfileContext.shared(for: .original())
        let standard = AppCoordinator(browser: BrowserModel(context: context, windowID: UUID()))
        let microBrowser = BrowserModel(context: context, windowID: UUID())
        microBrowser.windowKind = .micro
        let micro = AppCoordinator(browser: microBrowser)
        app.register(standard)
        app.register(micro)
        defer {
            standard.closeWindow()
            micro.closeWindow()
        }
        let tab = standard.browser.newTab()
        let microTab = micro.browser.newTab()
        func offer(_ coordinator: AppCoordinator, _ tab: BrowserTab?) -> MicroWindowBadge.Offer? {
            MicroWindowBadge.offer(for: coordinator, tab: tab)
        }

        #expect(offer(standard, nil) == nil && offer(micro, nil) == nil, "no tab, no offer")
        #expect(offer(standard, tab) == nil && offer(micro, microTab) == nil, "no page yet")

        tab.urlString = "https://example.com/"
        microTab.urlString = "https://example.com/"
        #expect(offer(standard, tab) == .moveOut)
        #expect(offer(micro, microTab) == .moveBack, "the same slot moves it back")
        #expect(standard.canMoveToMicroWindow(tab) && !micro.canMoveToMicroWindow(microTab))

        for page in BrowserTab.InternalPage.allCases {
            tab.urlString = page.url.absoluteString
            #expect(tab.internalPage == page)
            #expect(offer(standard, tab) == nil, "\(page) never goes chromeless")
            #expect(!standard.canMoveToMicroWindow(tab))
        }

        // A private page moves too: its micro window joins the session.
        let privateWindow = AppCoordinator(
            browser: BrowserModel(context: .shared(for: .privateBrowsing()), windowID: UUID())
        )
        app.register(privateWindow)
        defer { privateWindow.closeWindow() }
        let privateTab = privateWindow.browser.newTab()
        privateTab.urlString = "https://example.com/"
        #expect(offer(privateWindow, privateTab) == .moveOut)

        // A tab that is not one of this window's cannot be moved by it.
        let stranger = micro.browser.newTab()
        stranger.urlString = "https://example.com/"
        #expect(!standard.canMoveToMicroWindow(stranger))
    }

    @Test func theBadgeSitsBesideReaderAndThePin() throws {
        let row = try source("WSurf/UI/Ask/AskSurfaceRow.swift")
        let pin = try #require(row.range(of: "PinBadge(browser: model.browser)"))
        let micro = try #require(row.range(of: "MicroWindowBadge(browser: model.browser, coordinator: model.coordinator)"))
        let reader = try #require(row.range(of: "ReaderBadge("))
        #expect(reader.lowerBound < pin.lowerBound && pin.lowerBound < micro.lowerBound)
        #expect(try source("WSurf/UI/Sidebar/SidebarTabRow.swift").contains("Label(\"Move to Micro Window\""))
    }

    // MARK: - Helpers

    private func source(_ path: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
