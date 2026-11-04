// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// What the lazy list guarantees beyond what the drive suite shows: only the rows near the window are drawn, a row that
/// leaves takes its frame with it, the frames stay right while the list scrolls, assistive technology gets every row,
/// and only the current tab is marked current.
@MainActor
@Suite(.serialized)
struct SidebarLazyRowsTests {
    // MARK: Which rows are drawn

    @Test func onlyTheRowsNearTheWindowAreDrawn() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(400)
        try await rig.settle()

        let drawn = tabs.filter { rig.frame(of: .tab($0.id)) != nil }
        #expect(drawn.count >= 15, "the rows in the window are drawn: \(drawn.count)")
        #expect(drawn.count < 120, "far fewer than the 400 rows are drawn: \(drawn.count)")
        #expect(rig.frame(of: .tab(tabs[200].id)) == nil)
        #expect(rig.frame(of: .tab(tabs[0].id)) != nil)
    }

    @Test func aRowThatScrollsAwayLeavesNoFrameAndOneThatScrollsInGetsOne() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(400)
        try await rig.settle()
        let first = SidebarItem.tab(tabs[0].id)
        let far = SidebarItem.tab(tabs[200].id)
        try #require(rig.frame(of: first) != nil)

        try await rig.scroll(to: 5_000)
        #expect(rig.frame(of: first) == nil, "the row that scrolled away is forgotten")
        let arrived = try #require(rig.frame(of: far), "the row that scrolled in is drawn")
        // 200 rows of one row height and one gap each, down the content, less what the list is scrolled by (the content
        // starts below the top chrome, which is what the 80 pt allows for).
        let settings = BrowserSettings.application
        let step = SidebarMetrics.rowHeight(settings: settings) + SidebarMetrics.rowVerticalSpacing(settings: settings)
        let content = try #require(rig.scrollView).contentView.bounds.origin.y
        #expect(abs((arrived.minY - rig.coordinator.sidebarDrag.listOriginInWindow.y) - (200 * step - content)) < 80)

        try await rig.scroll(to: 0)
        #expect(rig.frame(of: first) != nil)
        #expect(rig.frame(of: far) == nil)
    }

    @Test func theRowsOfAFolderThatClosesLeaveNoFramesBehind() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(10)
        let folder = rig.browser.createFolder(named: "Folder", containing: Array(tabs[0...3]))
        try await rig.settle()
        let child = SidebarItem.tab(tabs[1].id)
        try #require(rig.frame(of: child) != nil)

        folder.isExpanded = false
        try await rig.settle()
        #expect(rig.frame(of: child) == nil)
        #expect(rig.frame(of: .folder(folder.id)) != nil)
        #expect(rig.coordinator.sidebarDrag.frames.visible(in: rig.browser)[child] == nil)
    }

    /// SwiftUI brings a row back without measuring it again when nothing about its geometry changed, so the row has to
    /// record its frame itself: scrolling down and back up in small steps leaves every row on screen with a frame.
    @Test func everyRowOnScreenHasAFrameWhileScrollingDownAndBackUp() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(400)
        try await rig.settle()
        let settings = BrowserSettings.application
        let step = SidebarMetrics.rowHeight(settings: settings) + SidebarMetrics.rowVerticalSpacing(settings: settings)
        let offsets = Array(stride(from: 0, through: 5_100, by: 300)) + Array(stride(from: 4_800, through: 0, by: -300))
        for offset in offsets {
            try await rig.scroll(to: CGFloat(offset))
            let drawn = tabs.indices.filter { rig.frame(of: .tab(tabs[$0].id)) != nil }
            let first = try #require(drawn.first, "rows at \(offset)")
            let last = try #require(drawn.last)
            // The list shows content from 74 pt under its top to 40 pt above its bottom, 678 pt tall.
            #expect(first <= Int((CGFloat(offset) + 74) / step), "the top of the window at \(offset) starts at row \(first)")
            #expect(last >= Int((CGFloat(offset) + 638) / step) - 1, "the bottom of the window at \(offset) ends at row \(last)")
            #expect(drawn.count == last - first + 1, "no row is missing between them at \(offset)")
        }
    }

    @Test func switchingSpacesDropsTheFramesOfTheSpaceThatLeaves() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let spaces = [UUID(), UUID()]
        rig.browser.adoptSpaces(spaces)
        rig.browser.switchSpace(to: spaces[0])
        let first = rig.browser.addPage("https://a.example/")
        rig.browser.switchSpace(to: spaces[1])
        let second = rig.browser.addPage("https://b.example/")
        rig.browser.switchSpace(to: spaces[0])
        try await rig.settle()
        try #require(rig.frame(of: .tab(first.id)) != nil)

        rig.browser.switchSpace(to: spaces[1])
        try await rig.settle()
        #expect(rig.frame(of: .tab(second.id)) != nil)
        #expect(rig.frame(of: .tab(first.id)) == nil, "a row of another space cannot be picked up")
    }

    // MARK: Everything for assistive technology

    @Test func everyRowIsDrawnWhileVoiceOverIsOn() async throws {
        let rig = SidebarDriveRig(voiceOver: true)
        defer { rig.close() }
        let tabs = rig.addPages(400)
        try await rig.settle(rounds: 12)

        let drawn = tabs.filter { rig.frame(of: .tab($0.id)) != nil }
        #expect(drawn.count == 400, "VoiceOver walks every row, so every row exists: \(drawn.count)")
    }

    @Test func theListLoadsLazilyUnlessSomethingWalksEveryRow() {
        #expect(SidebarRowLoading.isLazy(voiceOver: false, switchControl: false, fullKeyboardAccess: false))
        #expect(!SidebarRowLoading.isLazy(voiceOver: true, switchControl: false, fullKeyboardAccess: false))
        #expect(!SidebarRowLoading.isLazy(voiceOver: false, switchControl: true, fullKeyboardAccess: false))
        #expect(!SidebarRowLoading.isLazy(voiceOver: false, switchControl: false, fullKeyboardAccess: true))
    }

    // MARK: Dragging while rows come and go

    @Test func aDragWorksOnARowThatScrolledIn() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.addPages(200)
        try await rig.settle()
        try await rig.scroll(to: 3_000)
        let visible = rig.onScreen()
        try #require(visible.count >= 6)
        let moving = visible[0]
        let target = visible[4]
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(target, 0.9)], steps: 14)

        let after = rig.browser.sidebarItems
        #expect(after.firstIndex(of: moving) == (after.firstIndex(of: target) ?? -2) + 1)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    @Test func aDragIntoAFolderFarDownTheListWorks() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(160)
        let folder = rig.browser.createFolder(named: "Far", containing: Array(tabs[120...123]))
        try await rig.settle()
        let header = SidebarItem.folder(folder.id)
        try #require(rig.frame(of: header) == nil, "the folder starts far below the window")
        try await rig.scroll(to: 3_000)
        try #require(rig.frame(of: header) != nil)
        let moving = try #require(rig.onScreen().last { $0 != header && rig.browser.sidebarTree.parent(of: $0) == nil })
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(header, 0.8)], steps: 14)

        #expect(rig.browser.sidebarTree.parent(of: moving) == folder.id)
        #expect(rig.browser.rows(in: folder).first == moving)
        #expect(rig.browser.rows(in: folder).count == 5)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    /// Below the last row that is drawn there are rows that are not, so the pointer there is not "below the list": the
    /// row stays where it is instead of jumping to the end.
    @Test func draggingPastTheRowsThatAreDrawnDoesNotSendTheRowToTheEnd() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.addPages(200)
        try await rig.settle()
        try await rig.scroll(to: 1_500)
        let visible = rig.onScreen()
        let moving = try #require(visible.first)
        let before = rig.browser.sidebarItems
        let bottom = CGPoint(x: try rig.spot(moving).x, y: 760)
        try await rig.drag(through: [try rig.spot(moving), bottom], steps: 24)

        let after = rig.browser.sidebarItems
        #expect(after.last != moving)
        #expect(after.count == before.count)
    }

    @Test func draggingBelowTheLastRowSendsTheRowToTheEnd() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.addPages(8)
        try await rig.settle()
        let moving = try #require(rig.browser.sidebarItems.first)
        let last = try #require(rig.browser.sidebarItems.last)
        let lastFrame = try #require(rig.frame(of: last))
        try await rig.drag(
            through: [try rig.spot(moving), CGPoint(x: lastFrame.midX, y: lastFrame.maxY + 60)],
            steps: 24
        )

        #expect(rig.browser.sidebarItems.last == moving)
    }

    // MARK: The preview follows its row

    @Test func thePreviewCardFollowsItsRowWhenTheListScrolls() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(60)
        try await rig.settle()
        let item = SidebarItem.tab(tabs[4].id)
        let row = try #require(rig.frame(of: item))
        rig.coordinator.tabPreview.hover(tabs[4], anchor: row)
        try await Task.sleep(for: .milliseconds(700))
        let shown = try #require(rig.coordinator.tabPreview.shown)
        #expect(shown.anchor == row)

        try await rig.scroll(to: 40)
        let moved = try #require(rig.frame(of: item))
        #expect(moved.minY != row.minY, "the list scrolled")
        #expect(rig.coordinator.tabPreview.shown?.anchor == moved, "the card's anchor is where the row is now")
    }

    // MARK: Only the current tab is current

    @Test func onlyTheActiveTabIsMarkedActive() {
        let browser = BrowserModel(database: .temporary())
        let first = browser.newTab()
        let second = browser.newTab()
        let third = browser.newTab(activate: false)
        defer { browser.cancelPendingSave() }
        #expect([first, second, third].filter(\.isSidebarActive) == [second])

        browser.activate(first)
        #expect([first, second, third].filter(\.isSidebarActive) == [first])
        browser.activate(third)
        #expect([first, second, third].filter(\.isSidebarActive) == [third])

        browser.close(third)
        #expect(third.isSidebarActive == false)
        #expect(browser.activeTab.map { [first, second].contains($0) } == true)
        #expect([first, second].filter(\.isSidebarActive) == browser.activeTab.map { [$0] })
    }

    /// Whatever moves the active tab (choosing one, closing one, a space, nothing chosen) leaves exactly that tab marked.
    @Test func theMarkFollowsWhateverMovesTheActiveTab() {
        let browser = BrowserModel(database: .temporary())
        let spaces = [UUID(), UUID()]
        browser.adoptSpaces(spaces)
        let first = browser.addPage("https://a.example/")
        browser.switchSpace(to: spaces[1])
        let second = browser.addPage("https://b.example/")
        defer { browser.cancelPendingSave() }
        func marked() -> [BrowserTab] {
            browser.tabs.filter(\.isSidebarActive)
        }
        func isTheActiveTabAlone(_ step: String) {
            #expect(marked() == browser.activeTab.map { [$0] } ?? [], "\(step)")
        }

        browser.activate(first)
        #expect(browser.currentSpaceID == spaces[0], "choosing a tab of another space takes the window there")
        #expect(marked() == [first])
        browser.activate(second)
        #expect(marked() == [second])
        browser.switchSpace(to: spaces[0])
        isTheActiveTabAlone("a space was chosen")
        #expect(browser.activeTab === first)
        browser.activeTabID = nil
        isTheActiveTabAlone("no tab is chosen: the first of the space shows")
        browser.close(first)
        isTheActiveTabAlone("the active tab closed")
        #expect(first.isSidebarActive == false)
        browser.hasNoActiveTab = true
        browser.activeTabID = nil
        isTheActiveTabAlone("nothing is on screen")
        #expect(marked().isEmpty)
    }

    @Test func aRowStyleReadsTheMark() {
        let browser = BrowserModel(database: .temporary())
        let first = browser.newTab()
        let second = browser.newTab(activate: false)
        defer { browser.cancelPendingSave() }
        func emphasis(_ tab: BrowserTab) -> SidebarRowStyle.Emphasis {
            browser.rowStyle(of: tab, isMarked: false, paletteOpen: false, increasedContrast: false).emphasis
        }
        #expect(emphasis(first) == .current)
        #expect(emphasis(second) == .resting)
        browser.activate(second)
        #expect(emphasis(first) == .resting)
        #expect(emphasis(second) == .current)
    }

    @Test func aCollapsedFolderSaysItHoldsTheCurrentTabFromTheMark() {
        let browser = BrowserModel(database: .temporary())
        let tabs = [browser.newTab(), browser.newTab(activate: false)]
        defer { browser.cancelPendingSave() }
        let folder = browser.createFolder(named: "Folder", containing: [tabs[1]])
        folder.isExpanded = false
        #expect(browser.collapsedContents(of: folder).containsCurrent == false)
        browser.activate(tabs[1])
        #expect(browser.collapsedContents(of: folder).containsCurrent)
    }
}

// MARK: The frames the list keeps

@MainActor
struct SidebarFramesTests {
    private let item = SidebarItem.tab(UUID())
    private let other = SidebarItem.folder(UUID())

    @Test func aFrameIsKeptInTheContentAndPlacedInTheList() {
        let frames = SidebarFrames()
        frames.record(item, at: CGRect(x: 8, y: 100, width: 200, height: 30))
        frames.contentOrigin = CGPoint(x: 0, y: -40)
        #expect(frames[item] == CGRect(x: 8, y: 60, width: 200, height: 30))
        frames.contentOrigin = CGPoint(x: 0, y: -90)
        #expect(frames[item] == CGRect(x: 8, y: 10, width: 200, height: 30), "scrolling moves it without a new record")
    }

    @Test func aWindowFrameAddsTheListsOrigin() {
        let frames = SidebarFrames()
        frames.record(item, at: CGRect(x: 8, y: 100, width: 200, height: 30))
        frames.contentOrigin = CGPoint(x: 0, y: -40)
        #expect(
            frames.windowFrame(of: item, listOrigin: CGPoint(x: 300, y: 50)) == CGRect(x: 308, y: 110, width: 200, height: 30)
        )
        #expect(frames.windowFrame(of: other, listOrigin: .zero) == nil)
    }

    @Test func onlyTheRowThatRecordedAFrameCanForgetIt() {
        let frames = SidebarFrames()
        let old = UUID()
        let new = UUID()
        frames.record(item, at: CGRect(x: 0, y: 0, width: 10, height: 10), by: old)
        // The row is rebuilt (a drag into a folder does it): the new view records before the old one disappears.
        frames.record(item, at: CGRect(x: 0, y: 5, width: 10, height: 10), by: new)
        frames.forget(item, recordedBy: old)
        #expect(frames[item]?.minY == 5, "the old view's goodbye does not take the new view's frame")
        frames.forget(item, recordedBy: new)
        #expect(frames[item] == nil)
    }

    @Test func aFrameThatNobodyOwnsStaysUntilItIsReplaced() {
        let frames = SidebarFrames()
        frames.record(item, at: CGRect(x: 0, y: 0, width: 10, height: 10))
        frames.forget(item, recordedBy: UUID())
        #expect(frames[item] != nil)
    }

    @Test func theVisibleFramesAreThoseOfRowsThatCanBeSeen() throws {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let tabs = (0..<6).map { browser.addPage("https://site\($0).example/") }
        let folder = browser.createFolder(named: "Folder", containing: Array(tabs[0...1]))
        let frames = SidebarFrames()
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        for tab in tabs {
            frames.record(.tab(tab.id), at: rect)
        }
        frames.record(.folder(folder.id), at: rect)
        let gone = SidebarItem.tab(UUID())
        frames.record(gone, at: rect)
        #expect(frames.visible(in: browser).count == 7, "the unknown row is not one of them")

        folder.isExpanded = false
        let shut = frames.visible(in: browser)
        #expect(shut[.tab(tabs[0].id)] == nil && shut[.tab(tabs[1].id)] == nil, "rows in a closed folder")
        #expect(shut[.folder(folder.id)] != nil && shut[.tab(tabs[2].id)] != nil)
    }
}
