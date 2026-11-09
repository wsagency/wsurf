// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The Minimal bar floats over the end of the page, which is laid out the whole height of the window. It gets out of the way
/// while the page scrolls down, so the end can be read, and comes back when the page scrolls up, when the pointer rests at
/// the bar's edge, and whenever the micro window's rules want the address in sight. Views take the style as an input, so no
/// case writes the app-wide setting.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct MinimalBarScrollTests {
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        await waitUntil(timeout: .seconds(8), condition)
    }

    /// The model runs on a clock the case moves, so the margins below are exact and no machine load can stretch one.
    private func restingReveal(on clock: TestClock = TestClock(), keeps: @escaping () -> Bool = { false }) -> MicroReveal {
        MicroReveal(hideDelay: .milliseconds(40), hostFlash: .milliseconds(80), restsRevealed: true, keeps: keeps, clock: clock)
    }

    // MARK: - The model

    @Test func scrollingDownPutsTheBarAwayAndScrollingUpBringsItBack() {
        let reveal = restingReveal()
        #expect(reveal.isRevealed, "the Minimal bar starts shown, unlike the micro bar")

        reveal.scrolled(towardTop: false)
        #expect(!reveal.isRevealed, "at once, with the page, not a moment later")

        reveal.scrolled(towardTop: true)
        #expect(reveal.isRevealed)
        reveal.scrolled(towardTop: false)
        reveal.rest()
        #expect(reveal.isRevealed, "another tab or page starts at rest")
    }

    @Test func thePointerAtTheBarsEdgeShowsItUntilThePointerLeaves() async {
        let clock = TestClock()
        let reveal = restingReveal(on: clock)
        reveal.scrolled(towardTop: false)
        #expect(!reveal.isRevealed)

        reveal.pointer(inZone: true)
        #expect(reveal.isRevealed)
        reveal.scrolled(towardTop: false)
        #expect(reveal.isRevealed, "scrolling under the pointer does not pull the bar from under it")

        reveal.pointer(inZone: false)
        #expect(await clock.run(upTo: .seconds(5)) { !reveal.isRevealed }, "the page was scrolled down, so the bar goes again")
    }

    @Test func whatHoldsTheMicroBarHoldsTheMinimalBarWhileThePageScrolls() async {
        var asking = true
        let clock = TestClock()
        let reveal = restingReveal(on: clock, keeps: { asking })

        reveal.scrolled(towardTop: false)
        #expect(reveal.isRevealed, "a prompt, a save offer, a question or the address being edited wins over scrolling")
        await clock.run(for: .milliseconds(200))
        #expect(reveal.isRevealed)

        asking = false
        #expect(await clock.run(upTo: .seconds(5)) { !reveal.isRevealed }, "and once it is answered the scrolled page has the room again")
    }

    @Test func anotherSiteBringsTheBarBackAndLeavesItThere() async {
        let clock = TestClock()
        let reveal = restingReveal(on: clock)
        reveal.scrolled(towardTop: false)
        #expect(!reveal.isRevealed)

        reveal.siteChanged()
        #expect(reveal.isRevealed)
        await clock.run(for: .milliseconds(300))
        #expect(reveal.isRevealed, "past the micro window's moment: the new site's bar rests until the page scrolls")
    }

    /// The Minimal shell stops its reveal when it leaves the window (Standard style) and starts it when it comes back.
    @Test func aRevealThatComesBackWorksAgain() {
        let reveal = restingReveal()
        reveal.start()
        reveal.stop()
        reveal.scrolled(towardTop: false)
        #expect(reveal.isRevealed, "a stopped reveal changes nothing")
        reveal.start()
        reveal.scrolled(towardTop: false)
        #expect(!reveal.isRevealed, "a second start is a working start")
        reveal.rest()
        #expect(reveal.isRevealed)
        reveal.stop()
    }

    @Test func theMicroBarStillRestsHidden() {
        let reveal = MicroReveal(hideDelay: .milliseconds(40), hostFlash: .milliseconds(80))
        #expect(!reveal.isRevealed)
        reveal.scrolled(towardTop: true)
        #expect(!reveal.isRevealed, "scrolling up never shows the micro bar: only the pointer and its rules do")
    }

    // MARK: - The sensor

    @Test func theZoneIsThinWhileTheBarIsAwayAndAsDeepAsTheBarWhileItShows() throws {
        let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
        typealias Sensor = MinimalShellSensor.SensorView
        #expect(Sensor.zoneRect(edge: .bottom, height: MicroShell.revealBand, in: bounds) == NSRect(x: 0, y: 0, width: 800, height: 16))
        #expect(Sensor.zoneRect(edge: .top, height: MicroShell.revealBand, in: bounds) == NSRect(x: 0, y: 584, width: 800, height: 16))
        #expect(Sensor.zoneRect(edge: .bottom, height: 2_000, in: bounds).height == 600, "never taller than the window")

        let sensor = Sensor()
        let window = NSWindow(
            contentRect: bounds, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        sensor.frame = bounds
        window.contentView?.addSubview(sensor)
        defer {
            sensor.removeFromSuperview()
            window.close()
        }
        var inZone: [Bool] = []
        sensor.onPointerInZone = { inZone.append($0) }
        sensor.updateTrackingAreas()
        let hidden = try #require(sensor.trackingAreas.first)
        #expect(sensor.trackingAreas.count == 1)
        #expect(hidden.rect == NSRect(x: 0, y: 0, width: 800, height: 16))
        #expect(hidden.options.contains(.mouseEnteredAndExited), "leaving it puts the bar away again")
        #expect(hidden.options.contains(.activeAlways))

        sensor.zone = (.bottom, IslandBar.height + 22)
        let shown = try #require(sensor.trackingAreas.first)
        #expect(sensor.trackingAreas.count == 1, "the old zone is replaced, not added to")
        #expect(shown.rect.height == IslandBar.height + 22)

        sensor.mouseEntered(with: try #require(NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0
        )))
        sensor.mouseExited(with: try #require(NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0
        )))
        #expect(inZone == [true, false])
    }

    // MARK: - A real page, on each engine

    private struct Rig {
        let coordinator: AppCoordinator
        let tab: BrowserTab
        let page: BrowserPage
        let window: NSWindow
        let host: NSView
        /// The same page on another host name, so the window moves to another site.
        let otherSite: URL
    }

    /// The page: tall enough to scroll, with a 1 px row of its own color at the very end.
    private static let longPage = """
        <title>Long</title>
        <body style="margin:0">
        <div style="height:4000px;background:linear-gradient(#fff,#ccc)"></div>
        <div id="last" style="height:1px;background:rgb(255,0,0)"></div>
        </body>
        """

    private func withMinimalWindow(engine: BrowserEngine, _ body: (Rig) async throws -> Void) async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.longPage)])
        let url = try server.url("/")
        let otherSite = try #require(URL(string: url.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost")))
        let profile = Profile(id: UUID(), name: "Minimal fixture", symbol: "person", color: .gray)
        let context = BrowserProfileContext.shared(for: profile)
        for site in [url, otherSite] {
            context.sitePermissions.setEngine(engine, for: SitePermissions.origin(for: site))
        }
        let browser = BrowserModel(context: context, windowID: UUID(), database: .temporary())
        let coordinator = AppCoordinator(browser: browser)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnyView(
            BrowserView(browser: browser, coordinator: coordinator, style: .minimal, keepsSidebarOpen: false)
        ))
        host.safeAreaRegions = []
        window.contentView = host
        window.orderFront(nil)
        var failure: (any Error)?
        do {
            #expect(BrowserSettings.application.minimalBarHiding == .whileScrolling, "the default")
            let tab = browser.newTab(url: url)
            let page = tab.page
            try #require(await waitUntil { page.window === window && page.title == "Long" && !page.isLoading })
            #expect(page.engine == engine)
            try await body(Rig(coordinator: coordinator, tab: tab, page: page, window: window, host: host, otherSite: otherSite))
        } catch {
            failure = error
        }
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

    private func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        root.subviews.flatMap { subview -> [T] in
            let match: [T] = (subview as? T).map { [$0] } ?? []
            return match + descendants(of: subview, as: type)
        }
    }

    /// Where the bar's address field is, in window points (origin at the bottom left).
    private func barField(_ rig: Rig) -> NSRect? {
        rig.host.layoutSubtreeIfNeeded()
        return descendants(of: rig.host, as: MentionTextField.self).first.map { $0.convert($0.bounds, to: nil) }
    }

    /// The page's own view in window points: its lowest row is where the document's last row is drawn once it is scrolled to
    /// the end.
    private func pageFrame(_ rig: Rig) -> NSRect {
        rig.page.convert(rig.page.bounds, to: nil)
    }

    /// The whole bar is below the window's bottom edge: its ground is `IslandBar.height` tall around the field, which sits in
    /// its middle. Measured once it has finished sliding, not while it passes the edge.
    private func barIsAway(_ rig: Rig) -> Bool {
        barField(rig).map { $0.midY + IslandBar.height / 2 < 0 } ?? false
    }

    private func barIsShown(_ rig: Rig) -> Bool {
        barField(rig).map { $0.minY > 0 && $0.maxY < pageFrame(rig).maxY } ?? false
    }

    private func isAtTheEnd(_ page: BrowserPage) async throws -> Bool {
        try await page.evaluateJavaScript(
            "Math.ceil(window.scrollY + window.innerHeight) >= document.documentElement.scrollHeight - 1"
        ) as? Bool ?? false
    }

    /// The owner's report, measured: at rest the bar covers the last rows of the page; scrolled to the end it is gone and the
    /// page's last pixel row is the lowest row of the page's view, inside the window and clear of the bar by a whole bar.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func theLastRowOfThePageIsReadableAtTheEnd(engine: BrowserEngine) async throws {
        try await withMinimalWindow(engine: engine) { rig in
            try #require(await eventually { barIsShown(rig) }, "the bar rests shown")
            let field = try #require(barField(rig))
            let page = pageFrame(rig)
            #expect(page.minY >= 0 && page.minY < 20, "the page runs to the bottom of the window, under the bar: \(page)")
            #expect(field.minY > page.minY && field.minY < page.minY + 80, "at rest the bar sits over the page's end: \(field)")

            _ = try await rig.page.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight); true")
            try #require(await eventually { barIsAway(rig) }, "scrolled down, the bar goes")
            #expect(try await isAtTheEnd(rig.page))
            let away = try #require(barField(rig))
            let lastRow = pageFrame(rig).minY
            #expect(lastRow >= 0, "the page's last row is inside the window")
            #expect(away.midY + IslandBar.height / 2 < lastRow, "and the whole bar is below it: field \(away), last row at \(lastRow)")
            let height = try await rig.page.evaluateJavaScript("window.innerHeight") as? Double ?? 0
            #expect(abs(height * rig.page.pageZoom - pageFrame(rig).height) < 2, "the document's viewport is the page's view")

            _ = try await rig.page.evaluateJavaScript("window.scrollBy(0, -600); true")
            #expect(await eventually { barIsShown(rig) }, "scrolled up, the bar comes back")
        }
    }

    /// Space, ↓, Page Down and End scroll the page without a wheel; the page's own report moves the bar.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func theKeyboardScrollsTheBarAway(engine: BrowserEngine) async throws {
        try await withMinimalWindow(engine: engine) { rig in
            try #require(await eventually { barIsShown(rig) })
            try #require(rig.window.makeFirstResponder(rig.page.webKit ?? rig.page), "the page has the keyboard")
            if let webView = rig.page.webKit {
                // WebKit gives the page keyboard focus only in the key window, and the test host is never made the active app
                // (another app may be in front). So it gets what AppKit's key bindings turn the End key into.
                #expect(NSApp.sendAction(#selector(NSResponder.scrollToEndOfDocument(_:)), to: webView, from: nil))
            } else {
                let end = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: .function, timestamp: 0,
                    windowNumber: rig.window.windowNumber, context: nil,
                    characters: String(UnicodeScalar(NSEndFunctionKey)!), charactersIgnoringModifiers: String(UnicodeScalar(NSEndFunctionKey)!),
                    isARepeat: false, keyCode: 119
                ))
                rig.window.sendEvent(end)
            }
            #expect(await eventually { barIsAway(rig) }, "End scrolled the page, and the bar went with it")
            try #require(await waitUntil(timeout: .seconds(8)) { try await isAtTheEnd(rig.page) })
        }
    }

    /// With the bar away, a prompt on the window brings it back as the prompt appears, and the scrolled page gets the room
    /// back once it is answered; the pointer at the bottom edge brings it back while it rests there.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func thePointerAndPromptsBringTheBarBackOverAScrolledPage(engine: BrowserEngine) async throws {
        try await withMinimalWindow(engine: engine) { rig in
            _ = try await rig.page.evaluateJavaScript("window.scrollTo(0, 1500); true")
            try #require(await eventually { barIsAway(rig) })

            let sensor = try #require(descendants(of: rig.host, as: MinimalShellSensor.SensorView.self).first)
            sensor.onPointerInZone?(true)
            #expect(await eventually { barIsShown(rig) }, "the pointer resting at the bottom edge shows the bar")
            sensor.onPointerInZone?(false)
            #expect(await eventually { barIsAway(rig) }, "and it goes when the pointer leaves")

            let alert = NSAlert()
            alert.messageText = "A message from the page"
            alert.addButton(withTitle: "OK")
            let dialog = Task { await PageDialogs.present(alert, in: rig.window) }
            try #require(await waitUntil { rig.window.attachedSheet != nil })
            #expect(await eventually { barIsShown(rig) }, "a prompt shows the real address whatever the page did")
            if let sheet = rig.window.attachedSheet {
                rig.window.endSheet(sheet, returnCode: .cancel)
            }
            _ = await dialog.value
            #expect(await eventually { barIsAway(rig) }, "answered, the scrolled page has the room again")
        }
    }

    /// Another site shows its address for a moment however soon the page scrolls (the micro window's rule), and then the
    /// scrolled page has the room again. Without the rule the scroll would take the bar away at once.
    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func anotherSiteKeepsTheBarForAMomentWhateverThePageDoes(engine: BrowserEngine) async throws {
        try await withMinimalWindow(engine: engine) { rig in
            _ = try await rig.page.evaluateJavaScript("window.scrollTo(0, 1500); true")
            try #require(await eventually { barIsAway(rig) })

            rig.tab.load(rig.otherSite)
            try #require(await waitUntil { rig.tab.page.url?.host() == "localhost" && rig.tab.page.title == "Long" && !rig.tab.page.isLoading })
            let page = rig.tab.page
            _ = try await page.evaluateJavaScript("window.scrollTo(0, document.documentElement.scrollHeight); true")
            try #require(await waitUntil(timeout: .seconds(8)) { try await isAtTheEnd(page) })
            try? await Task.sleep(for: .milliseconds(300))
            #expect(barIsShown(rig), "the new site's address is in sight although the page scrolled down")
            #expect(await eventually { barIsAway(rig) }, "and after its moment the scrolled page has the room")
        }
    }
}
