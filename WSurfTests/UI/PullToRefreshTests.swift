// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// The gate a pull must pass before the page starts moving: the document at
/// its top, and the pointer over the page itself - not over a chat, feed or
/// any other list scrolling inside it, where the wheel belongs to that list.
@MainActor
struct PullToRefreshGateTests {
    private func ancestor(
        overflowY: String,
        scrollHeight: Double = 2000,
        clientHeight: Double = 400
    ) -> PullStartProbe.Ancestor {
        PullStartProbe.Ancestor(
            overflowY: overflowY,
            scrollHeight: scrollHeight,
            clientHeight: clientHeight
        )
    }

    @Test func aPlainPageAtItsTopMayPull() {
        #expect(PullToRefreshMonitor.canBeginPull(PullStartProbe(scrollY: 0, ancestors: [])))
    }

    @Test func aScrolledPageMayNot() {
        #expect(!PullToRefreshMonitor.canBeginPull(PullStartProbe(scrollY: 480, ancestors: [])))
    }

    /// WebKit reports a fractional offset at rest because of the rubber band;
    /// that is still the top.
    @Test func theRubberBandFractionStillCountsAsTop() {
        #expect(PullToRefreshMonitor.canBeginPull(PullStartProbe(scrollY: 0.5, ancestors: [])))
    }

    /// The bug: a chat column at the page's top consumed the wheel, the
    /// document never moved, and the scrollY-only check read the gesture as
    /// a pull.
    @Test(arguments: ["auto", "scroll", "overlay"])
    func aPointerOverAnInnerScrollerMayNotPull(overflowY: String) {
        let probe = PullStartProbe(scrollY: 0, ancestors: [ancestor(overflowY: overflowY)])
        #expect(!PullToRefreshMonitor.canBeginPull(probe))
    }

    @Test func theInnerScrollerDisqualifiesFromAnywhereInTheChain() {
        let probe = PullStartProbe(scrollY: 0, ancestors: [
            ancestor(overflowY: "visible", scrollHeight: 400, clientHeight: 400),
            ancestor(overflowY: "auto"),
            ancestor(overflowY: "visible", scrollHeight: 3000, clientHeight: 3000),
        ])
        #expect(!PullToRefreshMonitor.canBeginPull(probe))
    }

    /// A scroll container with nothing to scroll gives the wheel nothing and
    /// the document moves - that is a pull.
    @Test func anInnerContainerWithNoOverflowDoesNotDisqualify() {
        let probe = PullStartProbe(scrollY: 0, ancestors: [
            ancestor(overflowY: "auto", scrollHeight: 400, clientHeight: 400),
        ])
        #expect(PullToRefreshMonitor.canBeginPull(probe))
    }

    /// `overflow: hidden` keeps its overflow but the wheel cannot reach it.
    @Test func hiddenOverflowDoesNotDisqualify() {
        let probe = PullStartProbe(scrollY: 0, ancestors: [ancestor(overflowY: "hidden")])
        #expect(PullToRefreshMonitor.canBeginPull(probe))
    }

    /// Tall content inside an ordinary element scrolls with the document.
    @Test func aTallElementWithVisibleOverflowDoesNotDisqualify() {
        let probe = PullStartProbe(scrollY: 0, ancestors: [ancestor(overflowY: "visible")])
        #expect(PullToRefreshMonitor.canBeginPull(probe))
    }

    /// The bug: a map cancels the wheel to zoom, the document never moves,
    /// and the gesture read as a pull.
    @Test func aPageThatClaimsTheWheelMayNotPull() {
        #expect(!PullToRefreshMonitor.canBeginPull(
            PullStartProbe(scrollY: 0, ancestors: [], wheelClaimed: true)
        ))
    }

    @Test func decodeReadsThePagesAnswerAndRefusesGarbage() {
        let decoded = PullStartProbe.decode(
            #"{"scrollY":12,"ancestors":[{"overflowY":"auto","scrollHeight":900,"clientHeight":300}],"wheelClaimed":true}"#
        )
        #expect(decoded == PullStartProbe(
            scrollY: 12,
            ancestors: [ancestor(overflowY: "auto", scrollHeight: 900, clientHeight: 300)],
            wheelClaimed: true
        ))
        #expect(PullStartProbe.decode("not json") == nil)
    }
}

/// The second gate: which view the wheel landed on. A sidebar peeking over the
/// page, and a side panel standing on top of it, both sit inside the page's
/// rectangle, so the pointer being within those bounds proves nothing.
@MainActor
struct PullToRefreshOwnershipTests {
    private func page() -> NSView {
        NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }

    @Test func theWheelOnThePageItselfIsAPull() {
        let page = page()
        #expect(PullToRefreshMonitor.pageOwnsScroll(hit: page, page: page))
    }

    /// WebKit hit-tests to its own inner content view, never the WKWebView.
    @Test func theWheelOnAViewInsideThePageIsAPull() {
        let page = page()
        let content = NSView(frame: page.bounds)
        page.addSubview(content)
        #expect(PullToRefreshMonitor.pageOwnsScroll(hit: content, page: page))
    }

    /// The bug: chrome standing over the page kept the page's bounds check
    /// true, so scrolling the sidebar or the side panel pulled the tab.
    @Test func theWheelOnChromeOverThePageIsNot() {
        let page = page()
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 268, height: 600))
        #expect(!PullToRefreshMonitor.pageOwnsScroll(hit: chrome, page: page))
    }

    @Test func aWheelThatLandsOnNothingIsNot() {
        #expect(!PullToRefreshMonitor.pageOwnsScroll(hit: nil, page: page()))
    }

    /// A split's other pane is a sibling, not an ancestor: only the active
    /// tab's view may pull.
    @Test func theWheelOnTheOtherSplitPaneIsNot() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let active = page()
        let other = page()
        host.addSubview(active)
        host.addSubview(other)
        #expect(!PullToRefreshMonitor.pageOwnsScroll(hit: other, page: active))
    }
}

/// The probe's JavaScript against a real page, so the DOM walk the decision
/// rests on is pinned too.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PullToRefreshProbeTests {
    private func loadedPage(_ body: String, installsWatch: Bool = true) async -> BrowserPage {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(
            webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration),
            context: BrowserProfileContext(profile: .privateBrowsing())
        )
        if installsWatch {
            PullToRefreshMonitor.install(in: page)
        }
        await load(body, in: page)
        return page
    }

    private func load(_ body: String, in page: BrowserPage) async {
        _ = page.loadHTMLString(
            "<!doctype html><html><body style=\"margin:0\">\(body)</body></html>",
            baseURL: nil
        )
        #expect(await PageSettle.untilIdle(page, timeout: .seconds(30)))
    }

    private func answer(_ script: String, from page: BrowserPage) async throws -> PullStartProbe {
        let answer = try #require(
            (try? await page.evaluateJavaScript(script, in: nil, contentWorld: PullToRefreshMonitor.world)) as? String
        )
        return try #require(PullStartProbe.decode(answer))
    }

    private func probe(_ page: BrowserPage, x: CGFloat, y: CGFloat) async throws -> PullStartProbe {
        try await answer(PullToRefreshMonitor.startProbeScript(x: x, y: y), from: page)
    }

    private static let mapPage = """
    <div id="map" style="width: 500px; height: 400px"></div>
    <script>
    document.getElementById('map').addEventListener('wheel', e => e.preventDefault(), { passive: false });
    </script>
    """

    /// What a map does when it zooms on the wheel: the page's own world cancels the event.
    private func wheel(on page: BrowserPage) async {
        _ = try? await page.evaluateJavaScript(
            "document.getElementById('map').dispatchEvent(new WheelEvent('wheel', { deltaY: -40, bubbles: true, cancelable: true }))"
        )
    }

    /// A wheel event nothing cancels.
    private func quietWheel(on page: BrowserPage) async {
        _ = try? await page.evaluateJavaScript(
            "window.dispatchEvent(new WheelEvent('wheel', { deltaY: -40, cancelable: true }))"
        )
    }

    @Test func theProbeSeesTheInnerScrollerAndOnlyIt() async throws {
        let page = await loadedPage("""
        <div style="height: 3000px">
            <div id="chat" style="position: absolute; top: 50px; left: 0; width: 300px; height: 200px; overflow-y: auto">
                <div style="height: 2000px">messages</div>
            </div>
        </div>
        """)

        let overChat = try await probe(page, x: 150, y: 150)
        #expect(overChat.ancestors.contains { $0.consumesVerticalScroll })
        #expect(!PullToRefreshMonitor.canBeginPull(overChat))

        let overPage = try await probe(page, x: 450, y: 30)
        #expect(!overPage.ancestors.contains { $0.consumesVerticalScroll })
        #expect(PullToRefreshMonitor.canBeginPull(overPage))
    }

    @Test func theProbeReportsTheDocumentsOwnScroll() async throws {
        let page = await loadedPage("<div style=\"height: 3000px\">tall</div>")
        _ = try? await page.evaluateJavaScript("window.scrollTo(0, 700)")

        let scrolled = try await probe(page, x: 250, y: 200)
        #expect(scrolled.scrollY == 700)
        #expect(!PullToRefreshMonitor.canBeginPull(scrolled))
    }

    @Test func theProbeSeesAPageThatCancelsTheWheel() async throws {
        let page = await loadedPage(Self.mapPage)

        let before = try await probe(page, x: 250, y: 200)
        #expect(!before.wheelClaimed)
        #expect(PullToRefreshMonitor.canBeginPull(before))

        await wheel(on: page)
        let after = try await probe(page, x: 250, y: 200)
        #expect(after.wheelClaimed)
        #expect(!PullToRefreshMonitor.canBeginPull(after))

        let atFinish = try await answer(PullToRefreshMonitor.finishProbeScript, from: page)
        #expect(!PullToRefreshMonitor.canBeginPull(atFinish))
    }

    @Test func aWheelThePageLeavesAloneIsNotAClaim() async throws {
        let page = await loadedPage("<div id=\"map\" style=\"width: 500px; height: 400px\"></div>")

        await wheel(on: page)
        let after = try await probe(page, x: 250, y: 200)
        #expect(!after.wheelClaimed)
        #expect(PullToRefreshMonitor.canBeginPull(after))
    }

    /// A tab can be handed a page that already holds a document. The probe
    /// starts the watch itself, so that document is covered from its first probe.
    @Test func aDocumentLoadedBeforeTheInstallIsWatchedFromItsFirstProbe() async throws {
        let page = await loadedPage(Self.mapPage, installsWatch: false)

        #expect(try await !probe(page, x: 250, y: 200).wheelClaimed)
        await wheel(on: page)
        #expect(try await probe(page, x: 250, y: 200).wheelClaimed)
    }

    @Test func aNewDocumentStartsWithoutTheLastOnesClaim() async throws {
        let page = await loadedPage(Self.mapPage)
        await wheel(on: page)
        #expect(try await probe(page, x: 250, y: 200).wheelClaimed)

        await load("<div style=\"height: 400px\">plain</div>", in: page)
        #expect(try await !probe(page, x: 250, y: 200).wheelClaimed)
    }

    /// The claim lasts a moment after the page's cancelled wheel, not until some other wheel arrives.
    @Test func aClaimExpiresWhenNoOtherWheelFollows() async throws {
        let page = await loadedPage(Self.mapPage)
        await wheel(on: page)
        #expect(try await probe(page, x: 250, y: 200).wheelClaimed)

        #expect(await waitUntil(timeout: .seconds(10)) {
            try await !probe(page, x: 250, y: 200).wheelClaimed
        })
        let atFinish = try await answer(PullToRefreshMonitor.finishProbeScript, from: page)
        #expect(PullToRefreshMonitor.canBeginPull(atFinish))
    }

    /// The bug: the next wheel stamped the old cancelled one with its own time, so a pull
    /// started long after the map was used still read as claimed.
    @Test func aPullLongAfterTheMapWasUsedIsNotClaimed() async throws {
        let page = await loadedPage(Self.mapPage)
        await wheel(on: page)
        #expect(await waitUntil(timeout: .seconds(10)) {
            try await !probe(page, x: 250, y: 200).wheelClaimed
        })

        await quietWheel(on: page)
        let pull = try await probe(page, x: 250, y: 200)
        #expect(!pull.wheelClaimed)
        #expect(PullToRefreshMonitor.canBeginPull(pull))
    }

    @Test func aCancelledWheelFollowedByAnotherKeepsTheClaim() async throws {
        let page = await loadedPage(Self.mapPage)
        await wheel(on: page)
        await wheel(on: page)
        #expect(try await probe(page, x: 250, y: 200).wheelClaimed)
    }
}
