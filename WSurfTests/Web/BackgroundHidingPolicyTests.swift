// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// What makes a tab's page hidden once it is no longer in front, and what keeps it as it was.
@MainActor
@Suite(.boundedWebViews)
struct BackgroundHidingPolicyTests {
    private func makeModel() -> BrowserModel {
        BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundHiding-\(UUID().uuidString).json")
            )
        )
    }

    @Test func aTabWithNothingGoingOnHidesInTheBackground() {
        let model = makeModel()
        let tab = model.newTab(url: URL(string: "https://example.com/a"))
        #expect(tab.hidesInBackground)
        #expect(!tab.hidesPageInBackground, "in front its page is shown")
        #expect(!tab.page.hidesWhileParked)
    }

    /// Each reason on its own, on a tab with nothing else going on: the tab is not hidden while it holds, and is when it ends.
    @Test(arguments: BackgroundTabHidingTests.Reason.allCases)
    func whatTheTabIsDoingKeepsItShown(reason: BackgroundTabHidingTests.Reason) {
        let model = makeModel()
        let tab = model.newTab(url: URL(string: "https://example.com/a"))
        reason.apply(true, to: tab, in: model)
        #expect(!tab.hidesInBackground, "\(reason)")
        reason.apply(false, to: tab, in: model)
        #expect(tab.hidesInBackground, "\(reason) ended")
    }

    @Test func aPrivateTabIsNeverHidden() {
        let model = makeModel()
        model.adopt(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundHiding-\(UUID().uuidString).json")
            ),
            privately: true
        )
        let tab = model.newTab(url: URL(string: "https://example.com/a"))
        #expect(tab.isPrivate)
        #expect(!tab.hidesInBackground)
    }

    /// Two tabs, the first of which has left the front with its wait timed by `clock`.
    private func leaveTheFront(
        _ model: BrowserModel, clock: TestClock, grace: Duration = .seconds(10)
    ) -> (left: BrowserTab, front: BrowserTab) {
        let left = model.newTab(url: URL(string: "https://example.com/a"))
        left.backgroundClock = clock
        left.backgroundHidingGrace = grace
        let front = model.newTab(url: URL(string: "https://example.com/b"))
        front.backgroundHidingGrace = .zero
        return (left, front)
    }

    /// The page hears of a change while it waits, with no help from whoever changed it.
    @Test func theTabsPageFollowsWhatTheTabDoes() async {
        let model = makeModel()
        let left = model.newTab(url: URL(string: "https://example.com/a"))
        left.backgroundHidingGrace = .zero
        _ = model.newTab(url: URL(string: "https://example.com/b"))
        let page = left.page
        #expect(page.hidesWhileParked, "left behind with no wait, it is hidden at once")

        left.isPlayingAudio = true
        #expect(await waitUntil { !page.hidesWhileParked }, "a tab that plays is shown")
        left.isPlayingAudio = false
        #expect(await waitUntil { page.hidesWhileParked }, "and hides again when it stops")
    }

    // MARK: - The wait

    @Test func aTabThatLeavesTheFrontKeepsItsPageShownUntilTheWaitIsOver() async {
        let model = makeModel()
        let clock = TestClock()
        let (left, _) = leaveTheFront(model, clock: clock)
        #expect(!left.hidesPageInBackground && !left.page.hidesWhileParked, "the page is shown the moment the tab leaves")
        #expect(await waitUntil { clock.pendingCount == 1 }, "the wait is running")

        clock.advance(by: .seconds(9))
        #expect(!left.hidesPageInBackground && !left.page.hidesWhileParked, "still shown a second before the end")
        #expect(clock.pendingCount == 1)

        clock.advance(by: .seconds(1))
        #expect(await waitUntil { left.page.hidesWhileParked }, "hidden when the wait is over")
        #expect(left.hidesPageInBackground)
        #expect(clock.pendingCount == 0)
    }

    @Test func comingBackToTheFrontEndsTheWaitAndASecondWaitStartsFromZero() async {
        let model = makeModel()
        let clock = TestClock()
        let (left, front) = leaveTheFront(model, clock: clock)
        #expect(await waitUntil { clock.pendingCount == 1 })
        clock.advance(by: .seconds(9))

        model.activate(left)
        #expect(await waitUntil { clock.pendingCount == 0 }, "the wait is cancelled")
        clock.advance(by: .seconds(10))
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(!left.hidesPageInBackground && !left.page.hidesWhileParked, "a cancelled wait hides nothing")

        model.activate(front)
        #expect(await waitUntil { clock.pendingCount == 1 }, "leaving again starts a new wait")
        clock.advance(by: .seconds(9))
        #expect(!left.page.hidesWhileParked, "the nine seconds before do not count")
        clock.advance(by: .seconds(1))
        #expect(await waitUntil { left.page.hidesWhileParked })
    }

    @Test func aTabThatBecomesNeededEndsTheWaitAndWaitsAgainWhenItIsNot() async {
        let model = makeModel()
        let clock = TestClock()
        let (left, _) = leaveTheFront(model, clock: clock)
        #expect(await waitUntil { clock.pendingCount == 1 })

        left.isPlayingAudio = true
        #expect(await waitUntil { clock.pendingCount == 0 }, "a tab that plays needs its page, so the wait is cancelled")
        clock.advance(by: .seconds(10))
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(!left.hidesPageInBackground && !left.page.hidesWhileParked)

        left.isPlayingAudio = false
        #expect(await waitUntil { clock.pendingCount == 1 }, "when it stops, the wait starts over")
        clock.advance(by: .seconds(10))
        #expect(await waitUntil { left.page.hidesWhileParked })
    }

    @Test func aTabThatWasNeverInFrontHidesAtOnce() async {
        let model = makeModel()
        _ = model.newTab(url: URL(string: "https://example.com/a"))
        let loadedBehind = model.newTab(url: URL(string: "https://example.com/b"), activate: false)
        #expect(await waitUntil { loadedBehind.isMaterialised && loadedBehind.hidesPageInBackground }, "no one is waiting to switch to it")
        #expect(loadedBehind.page.hidesWhileParked)
    }

    @Test func aTabIsShownAtOnceWhenItComesBack() {
        let model = makeModel()
        let left = model.newTab(url: URL(string: "https://example.com/a"))
        left.backgroundHidingGrace = .zero
        let front = model.newTab(url: URL(string: "https://example.com/b"))
        front.backgroundHidingGrace = .zero
        #expect(left.page.hidesWhileParked)

        model.activate(left)
        #expect(!left.page.hidesWhileParked, "shown before the content area has attached it")
        #expect(!left.hidesPageInBackground)
        #expect(front.page.hidesWhileParked, "and the tab it replaced waits hidden, having no wait")
    }
}
