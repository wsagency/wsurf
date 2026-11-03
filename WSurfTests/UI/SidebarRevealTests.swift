// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// Showing a tab that was just opened: which tab the sidebar is asked to show and when, where the list scrolls and when
/// it holds still, and how the row pulses. The model and the plan are checked on their own; the list is checked as the
/// real sidebar in a window, whose rows are lazy, so a row far down is not drawn until the scroll reaches it.
@MainActor
@Suite(.serialized)
struct SidebarRevealTests {
    // MARK: What the plan scrolls to

    @Test func aTopLevelTabIsTheTargetAtTheCenter() {
        let tab = UUID()
        let tree = SidebarTree(root: [.tab(UUID()), .tab(tab)])
        let steps = plan(for: tab, in: tree)
        #expect(steps == [SidebarRevealPlan.Step(item: .tab(tab), anchor: .center)])
    }

    @Test func aTabInsideAFolderThatIsNotDrawnGoesThroughTheTopLevelFolder() {
        let tab = UUID()
        let inner = UUID()
        let outer = UUID()
        let tree = SidebarTree(
            root: [.folder(outer)],
            children: [outer: [.folder(inner)], inner: [.tab(UUID()), .tab(tab)]]
        )
        #expect(SidebarRevealPlan.outermostFolder(above: .tab(tab), in: tree) == outer)
        #expect(plan(for: tab, in: tree) == [
            SidebarRevealPlan.Step(item: .folder(outer), anchor: .top),
            SidebarRevealPlan.Step(item: .tab(tab), anchor: .center),
        ])
        // With the folder drawn, its rows are, so the row is found by its own id.
        #expect(plan(for: tab, in: tree, drawn: [.folder(outer)]) == [
            SidebarRevealPlan.Step(item: .tab(tab), anchor: .center),
        ])
    }

    @Test func theListHoldsStillWhileARowIsDraggedOrRenamedOrTheListIsScrolled() {
        let tab = UUID()
        let tree = SidebarTree(root: [.tab(tab)])
        #expect(plan(for: tab, in: tree, isDragging: true).isEmpty)
        #expect(plan(for: tab, in: tree, isRenaming: true).isEmpty)
        #expect(plan(for: tab, in: tree, isScrolling: true).isEmpty)
        #expect(plan(for: tab, in: tree).count == 1)
    }

    private func plan(
        for tab: UUID, in tree: SidebarTree, drawn: Set<SidebarItem> = [],
        isDragging: Bool = false, isRenaming: Bool = false, isScrolling: Bool = false
    ) -> [SidebarRevealPlan.Step] {
        SidebarRevealPlan.steps(
            for: tab, in: tree, isDrawn: { drawn.contains($0) },
            isDragging: isDragging, isRenaming: isRenaming, isScrolling: isScrolling
        )
    }

    // MARK: The pulse

    @Test func theRowPulsesTwiceAndThenStops() {
        let samples = stride(from: 0.0, to: SidebarPulse.duration, by: 0.01).map {
            SidebarPulse.opacity(elapsed: $0, reduceMotion: false)
        }
        let peaks = samples.indices.filter { index in
            index > 0 && index < samples.count - 1 && samples[index] > samples[index - 1] && samples[index] >= samples[index + 1]
        }
        #expect(peaks.count == 2, "two swells: \(peaks)")
        #expect(abs(samples.max()! - SidebarPulse.peak) < 0.01)
        #expect(SidebarPulse.opacity(elapsed: 0, reduceMotion: false) == 0)
        #expect(SidebarPulse.opacity(elapsed: SidebarPulse.duration, reduceMotion: false) == 0)
        #expect(SidebarPulse.opacity(elapsed: -1, reduceMotion: false) == 0)
        #expect(SidebarPulse.opacity(elapsed: 5, reduceMotion: false) == 0)
        #expect(SidebarPulse.duration > 0.5 && SidebarPulse.duration < 1.2, "about 0.8 s")
        #expect(SidebarPulse.peak < 0.4, "a gentle wash")
    }

    @Test func withReduceMotionTheHighlightIsOneSteadyFade() {
        let samples = stride(from: 0.0, to: SidebarPulse.duration, by: 0.01).map {
            SidebarPulse.opacity(elapsed: $0, reduceMotion: true)
        }
        #expect(samples.first == SidebarPulse.peak, "lit from the first frame")
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 >= $1 }, "it only ever fades: nothing swells")
        #expect((samples.last ?? 1) < 0.01)
        #expect(SidebarPulse.opacity(elapsed: SidebarPulse.duration, reduceMotion: true) == 0)
    }

    // MARK: Which tab the sidebar is asked to show

    private func model() -> BrowserModel {
        BrowserModel(database: .temporary())
    }

    /// A page that is opened from `opener` and has an address, without a web view: the tab goes where a new tab goes.
    @discardableResult
    private func open(_ browser: BrowserModel, after opener: BrowserTab? = nil) -> BrowserTab {
        let address = "https://new-\(UUID().uuidString.prefix(8).lowercased()).example/"
        let url = URL(string: address)
        let tab = browser.makeTab(for: url, restoring: true)
        tab.urlString = address
        tab.pageTitle = address
        tab.deferRestore(state: nil, url: url)
        browser.insert(tab, after: opener)
        browser.revealInSidebar(tab)
        return tab
    }

    @Test func aNewTabWithAnAddressIsRevealed() {
        let browser = model()
        let first = open(browser)
        #expect(browser.sidebarReveal?.tabID == first.id)
        let token = browser.sidebarReveal?.token ?? 0
        let second = open(browser)
        #expect(browser.sidebarReveal?.tabID == second.id)
        #expect(browser.sidebarReveal?.token == token + 1)
    }

    @Test(.boundedWebViews) func newTabRevealsOnlyOnceItHasAnAddress() throws {
        let browser = model()
        let blank = browser.newTab()
        #expect(browser.sidebarReveal == nil, "a blank tab has nothing to type yet")
        blank.urlString = "https://typed.example/"
        #expect(browser.sidebarReveal?.tabID == blank.id)

        browser.sidebarReveal = nil
        blank.urlString = "https://typed.example/other"
        #expect(browser.sidebarReveal == nil, "only the first address counts")

        let withURL = browser.newTab(url: URL(string: "https://link.example/"))
        #expect(browser.sidebarReveal?.tabID == withURL.id)
    }

    @Test(.boundedWebViews) func aTabOpenedInTheBackgroundIsRevealedToo() {
        let browser = model()
        let active = browser.newTab(url: URL(string: "https://one.example/"))
        let background = browser.newTab(url: URL(string: "https://two.example/"), activate: false, after: active, transition: .link)
        #expect(browser.activeTab === active)
        #expect(browser.sidebarReveal?.tabID == background.id)
    }

    @Test(.boundedWebViews) func anAgentsTabIsNotRevealed() {
        let browser = model()
        browser.newTab(url: URL(string: "https://agent.example/"), transition: .agent)
        #expect(browser.sidebarReveal == nil)
        let blank = browser.newTab()
        blank.load(URL(string: "https://agent.example/page")!, transition: .agent)
        #expect(browser.sidebarReveal == nil)
    }

    @Test(.boundedWebViews) func choosingAnExistingTabDoesNotReveal() {
        let browser = model()
        let first = browser.newTab(url: URL(string: "https://one.example/"))
        browser.newTab(url: URL(string: "https://two.example/"))
        browser.sidebarReveal = nil
        browser.activate(first)
        browser.activeTabID = browser.tabs.last?.id
        #expect(browser.sidebarReveal == nil)
    }

    @Test func reopeningAClosedTabAndUndoingACloseRevealIt() {
        let browser = model()
        let pages = (0..<3).map { browser.addPage("https://closed\($0).example/") }
        browser.activate(pages[0])
        browser.close(pages[1])
        browser.sidebarReveal = nil

        browser.reopenLastClosedTab()
        #expect(browser.sidebarReveal?.tabID == pages[1].id, "Reopen Last Closed Tab shows the tab it brought back")

        browser.close(pages[2])
        browser.sidebarReveal = nil
        browser.sidebarUndoManager.undo()
        #expect(browser.sidebarReveal?.tabID == pages[2].id, "and so does undoing a close")
    }

    @Test func theRequestEndsWithThePulse() async throws {
        let browser = model()
        open(browser)
        try #require(browser.sidebarReveal != nil)
        try await Task.sleep(for: .seconds(SidebarPulse.duration + 0.4))
        #expect(browser.sidebarReveal == nil)
    }

    @Test func aTabThatLandsInAShutFolderOpensItAndOnlyThat() {
        let browser = model()
        let opener = browser.addPage("https://opener.example/")
        let outer = browser.createFolder(named: "Outer")
        let inner = browser.createFolder(named: "Inner")
        let other = browser.createFolder(named: "Other")
        browser.move([.folder(inner.id)], into: outer)
        browser.move([.tab(opener.id)], into: inner)
        outer.isExpanded = false
        inner.isExpanded = false
        other.isExpanded = false

        let tab = open(browser, after: opener)
        #expect(browser.sidebarTree.parent(of: .tab(tab.id)) == inner.id, "the new tab lands beside its opener")
        #expect(outer.isExpanded)
        #expect(inner.isExpanded)
        #expect(!other.isExpanded, "a folder the tab is not in stays as it was")
    }

    @Test func aTabAtTheTopLevelOpensNothing() {
        let browser = model()
        let folder = browser.createFolder(named: "Folder")
        folder.isExpanded = false
        open(browser)
        #expect(!folder.isExpanded)
    }

    // MARK: The list

    private func offset(of rig: SidebarDriveRig) throws -> CGFloat {
        try #require(rig.scrollView).contentView.bounds.origin.y
    }

    /// The top and the bottom of the list's scroll range: the content, and the room the bars above and below it take.
    private func range(of rig: SidebarDriveRig) throws -> ClosedRange<CGFloat> {
        let scroll = try #require(rig.scrollView)
        let content = try #require(scroll.documentView).frame.height
        return -scroll.contentInsets.top...(content + scroll.contentInsets.bottom - scroll.contentView.bounds.height)
    }

    /// How far the middle of the row is from the middle of the list, in points.
    private func distanceFromCenter(of item: SidebarItem, in rig: SidebarDriveRig) throws -> CGFloat {
        let frame = try #require(rig.frame(of: item), "\(item) is not drawn")
        let top = rig.coordinator.sidebarDrag.listOriginInWindow.y
        let height = try #require(rig.scrollView).contentView.bounds.height
        return abs(frame.midY - (top + height / 2))
    }

    fileprivate struct Variant: CustomStringConvertible, Sendable {
        let name: String
        let width: CGFloat
        let style: SidebarStyle
        let floating: Bool
        var description: String {
            name
        }
    }

    fileprivate nonisolated static let variants = [
        Variant(name: "full", width: 280, style: .full, floating: false),
        Variant(name: "floating", width: 280, style: .full, floating: true),
        Variant(name: "icons only", width: 60, style: .icons, floating: false),
    ]

    @Test(arguments: variants)
    fileprivate func aTabFarDownTheListScrollsToTheMiddle(variant: Variant) async throws {
        let rig = SidebarDriveRig(width: variant.width, style: variant.style, floating: variant.floating)
        defer { rig.close() }
        let pages = rig.addPages(160)
        try await rig.settle()
        let target = SidebarItem.tab(pages[80].id)
        try #require(rig.frame(of: target) == nil, "the row is far below the window, so it is not drawn")
        let before = try offset(of: rig)

        rig.browser.revealInSidebar(pages[80])
        try await rig.settle(rounds: 20)

        #expect(try offset(of: rig) > before + 1_000, "the list went down to it")
        let center = try distanceFromCenter(of: target, in: rig)
        #expect(center < 60, "the row sits \(center) pt from the middle of the list")
        #expect(rig.isOnScreen(target))
    }

    @Test func aTabAtTheTopStopsAtTheTopEvenFromFarDown() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.addPages(160)
        try await rig.settle()
        let range = try range(of: rig)
        try await rig.scroll(to: range.upperBound)
        try #require(try offset(of: rig) > range.lowerBound + 1_000, "the list starts far down")

        let tab = open(rig.browser)
        try await rig.settle(rounds: 20)

        let landed = try offset(of: rig)
        #expect(abs(landed - range.lowerBound) < 1, "the list is at its top, not past it: \(landed) of \(range)")
        let frame = try #require(rig.frame(of: .tab(tab.id)))
        let top = rig.coordinator.sidebarDrag.listOriginInWindow.y
        #expect(frame.minY >= top && frame.minY < top + 120, "the new tab is the first row, at \(frame.minY - top) pt from the top of the list")
    }

    @Test func aTabAtTheBottomStopsAtTheBottom() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let pages = rig.addPages(160)
        try await rig.settle()
        let range = try range(of: rig)

        rig.browser.revealInSidebar(pages[159])
        try await rig.settle(rounds: 20)

        // The list's content is estimated until its last rows are drawn, so its end is read where the list has landed.
        let landed = try offset(of: rig)
        let end = try self.range(of: rig).upperBound
        #expect(abs(landed - end) < 1, "the list is at its bottom, not past it: \(landed) of \(range.lowerBound)...\(end)")
        let frame = try #require(rig.frame(of: .tab(pages[159].id)))
        #expect(frame.maxY < (rig.window.contentView?.bounds.height ?? 0), "the last row is in the window")
    }

    @Test func aTabInAFolderFarDownTheListScrollsToTheRowAndOpensTheFolder() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let pages = rig.addPages(160)
        let folder = rig.browser.createFolder(named: "Far", containing: Array(pages[100...104]))
        folder.isExpanded = false
        try await rig.settle()
        let opener = pages[102]
        try #require(rig.frame(of: .folder(folder.id)) == nil)

        let tab = open(rig.browser, after: opener)
        try await rig.settle(rounds: 30)

        #expect(folder.isExpanded)
        let item = SidebarItem.tab(tab.id)
        #expect(rig.browser.sidebarTree.parent(of: item) == folder.id)
        let center = try distanceFromCenter(of: item, in: rig)
        #expect(center < 60, "the row inside the folder sits \(center) pt from the middle of the list")
    }

    @Test func theListHoldsStillWhileARowIsDragged() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let pages = rig.addPages(160)
        try await rig.settle()
        let before = try offset(of: rig)
        let dragged = SidebarItem.tab(pages[0].id)
        let frame = try #require(rig.frame(of: dragged))
        rig.coordinator.sidebarDrag.drag = SidebarDrag(
            items: [dragged], lead: dragged, origin: frame, tree: rig.browser.sidebarTree, keepsSection: false, wasKept: false
        )

        rig.browser.revealInSidebar(pages[80])
        try await rig.settle(rounds: 20)
        #expect(try offset(of: rig) == before, "the list did not move during the drag")

        rig.coordinator.sidebarDrag.drag = nil
        rig.browser.revealInSidebar(pages[80])
        try await rig.settle(rounds: 20)
        #expect(try offset(of: rig) > before + 1_000, "and moves for the next tab")
    }

    @Test func theListHoldsStillWhileATabTitleIsEdited() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let pages = rig.addPages(160)
        try await rig.settle()
        let before = try offset(of: rig)
        rig.browser.tabRenameID = pages[0].id

        rig.browser.revealInSidebar(pages[80])
        try await rig.settle(rounds: 20)
        #expect(try offset(of: rig) == before)

        rig.browser.tabRenameID = nil
        rig.browser.revealInSidebar(pages[80])
        try await rig.settle(rounds: 20)
        #expect(try offset(of: rig) > before + 1_000)
    }

    @Test func revealingDoesNotMoveKeyboardFocus() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let pages = rig.addPages(160)
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
        rig.host.addSubview(field)
        try await rig.settle()
        rig.window.makeFirstResponder(field)
        let editor = rig.window.firstResponder
        try #require(editor != nil)

        rig.browser.revealInSidebar(pages[80])
        try await rig.settle(rounds: 20)

        #expect(rig.window.firstResponder === editor, "typing goes on in the address field")
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    // MARK: The row

    @Test func theRevealedRowIsWashedInTheAccentAndTheOthersAreNot() throws {
        let rig = SidebarRowRig(space: "SidebarRevealTests")
        defer { rig.restore() }
        let browser = rig.browser
        // The first page is the current one, which draws on its own fill; the two under test are not.
        browser.addPage("https://current.example/")
        let tab = browser.addPage("https://revealed.example/")
        let other = browser.addPage("https://other.example/")
        func edgeWash(of tab: BrowserTab, inTheList: Bool = true) throws -> CGFloat {
            let row = rig.sidebar(SidebarTabRow(tab: tab, depth: 0, context: rig.context), height: rig.rowHeight)
                .environment(\.sidebarPulsesRevealedRows, inTheList)
            let picture = try rig.picture(of: row)
            // The row's left edge, where the pulse draws its outline.
            return try picture.distance(x: 0.75, y: rig.rowHeight / 2, from: SidebarRowRig.baseColor)
        }
        let before = try edgeWash(of: tab)
        // A quarter of the way through the pulse, where it is strongest.
        browser.sidebarReveal = SidebarReveal(tabID: tab.id, token: 1, start: .now.addingTimeInterval(-SidebarPulse.duration / 4))
        let revealed = try edgeWash(of: tab)
        let beside = try edgeWash(of: other)
        let outside = try edgeWash(of: tab, inTheList: false)
        #expect(revealed > before + 0.08, "the revealed row's edge is \(revealed) from the sidebar, was \(before)")
        #expect(abs(beside - before) < 0.01, "another row is as it was: \(beside)")
        #expect(abs(outside - before) < 0.01, "a row outside the sidebar's list does not pulse: \(outside)")
    }
}
