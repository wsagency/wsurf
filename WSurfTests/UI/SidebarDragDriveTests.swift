// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// The real sidebar in a real window, driven with mouse events the way a person drags a row: reordering, dropping into
/// folders and pinned folders, across the pin line, with several rows, onto the page. The rows are read from where they
/// are drawn, so the suite holds for any way the list lays its rows out (all at once or lazily).
@MainActor
final class SidebarDriveRig {
    let coordinator: AppCoordinator
    let window: NSWindow
    let host: NSHostingView<AnyView>
    var queued = false

    var browser: BrowserModel {
        coordinator.browser
    }

    /// Where rows count as on screen, in points from the top of the window: below the top chrome (the list starts at
    /// 84) and above the bottom chrome and the fade at the bottom of the list (the window is 700 high).
    static let viewport: ClosedRange<CGFloat> = 90...600

    /// The theme the rig found, put back by `close()` after `adjustTheme(_:)`.
    private var savedTheme: (id: String, adjustments: [String: ThemeAdjustment])?

    /// `floating` is how a peeking sidebar and the Minimal window's tab list draw the same `Sidebar`.
    init(
        width: CGFloat = 280, height: CGFloat = 700, style: SidebarStyle = .full, voiceOver: Bool = false,
        floating: Bool = false
    ) {
        coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        let browser = coordinator.browser
        let sidebar = Sidebar(browser: browser, coordinator: coordinator)
            .frame(width: width, height: height)
            .environment(\.sidebarStyle, style)
            .environment(\.sidebarIsFloating, floating)
            .environment(\.sidebarDrawsEveryRow, voiceOver)
        host = NSHostingView(rootView: AnyView(sidebar))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
    }

    /// Sets the knobs of the Standard theme, which the rig draws with, until `close()`.
    func adjustTheme(_ adjustment: ThemeAdjustment) {
        let settings = BrowserSettings.application
        if savedTheme == nil {
            savedTheme = (settings.themeID, settings.themeAdjustments)
        }
        settings.themeID = "standard"
        settings.themeAdjustments["standard"] = adjustment
        settings.refreshTheme()
    }

    func close() {
        if let savedTheme {
            let settings = BrowserSettings.application
            settings.themeAdjustments = savedTheme.adjustments
            settings.themeID = savedTheme.id
            self.savedTheme = nil
        }
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        browser.cancelPendingSave()
    }

    // MARK: Fixtures

    @discardableResult
    func addPages(_ count: Int, prefix: String = "site") -> [BrowserTab] {
        (0..<count).map { browser.addPage("https://\(prefix)\($0).example/") }
    }

    func tab(_ item: SidebarItem) throws -> BrowserTab {
        guard case .tab(let id) = item else { throw RigError.notATab }
        return try #require(browser.tab(id: id))
    }

    enum RigError: Error {
        case notATab
    }

    // MARK: Reading the list

    func settle(rounds: Int = 6) async throws {
        for _ in 0..<rounds {
            try await Task.sleep(for: .milliseconds(20))
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    var scrollView: NSScrollView? {
        func scrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
        return scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    func scroll(to offset: CGFloat) async throws {
        let scroll = try #require(scrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(rounds: 15)
    }

    /// Where `item` is drawn, in points from the window's top left, or nil while it is not drawn.
    func frame(of item: SidebarItem) -> CGRect? {
        let origin = coordinator.sidebarDrag.listOriginInWindow
        return coordinator.sidebarDrag.frames[item]?.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// The point `edge` (0 top, 1 bottom) of the way down the row of `item`.
    func spot(_ item: SidebarItem, _ edge: CGFloat = 0.5) throws -> CGPoint {
        let frame = try #require(frame(of: item), "\(item) is not drawn")
        return CGPoint(x: frame.midX, y: frame.minY + frame.height * edge)
    }

    func isOnScreen(_ item: SidebarItem) -> Bool {
        guard let frame = frame(of: item) else { return false }
        return Self.viewport.contains(frame.minY) && Self.viewport.contains(frame.maxY)
    }

    /// The rows the list shows, top to bottom, that sit in the viewport.
    func onScreen() -> [SidebarItem] {
        browser.sidebarTree.visibleRows(isExpanded: { [browser] in browser.folder(id: $0)?.isExpanded ?? false })
            .filter { isOnScreen($0) }
    }

    // MARK: Driving

    private func post(_ type: NSEvent.EventType, at point: CGPoint) {
        let flipped = CGPoint(x: point.x, y: window.contentView!.bounds.height - point.y)
        let event = NSEvent.mouseEvent(
            with: type, location: flipped, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
        if queued {
            NSApp.postEvent(event, atStart: false)
        } else {
            window.sendEvent(event)
        }
    }

    /// Presses on the first point, drags in a straight line through each of the others and lets go on the last.
    func drag(through points: [CGPoint], steps: Int = 10) async throws {
        post(.leftMouseDown, at: points[0])
        for (from, to) in zip(points, points.dropFirst()) {
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                try await Task.sleep(for: .milliseconds(16))
                window.layoutIfNeeded()
                window.displayIfNeeded()
            }
        }
        post(.leftMouseUp, at: points[points.count - 1])
        try await settle()
        try await Task.sleep(for: .milliseconds(400))
        try await settle()
    }
}

@MainActor
@Suite(.serialized)
struct SidebarDragDriveTests {
    // MARK: Reordering

    @Test(arguments: [false, true], [false, true])
    func draggingATabDropsItBelowTheTarget(scrolled: Bool, queued: Bool) async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.queued = queued
        rig.addPages(60)
        try await rig.settle()
        if scrolled {
            try await rig.scroll(to: 600)
        }
        let visible = rig.onScreen()
        try #require(visible.count >= 6)
        let moving = visible[0]
        let target = visible[4]
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(target, 0.9)], steps: 14)

        let after = rig.browser.sidebarItems
        #expect(after.firstIndex(of: moving) == (after.firstIndex(of: target) ?? -2) + 1)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    /// With VoiceOver on, every row exists, and the list drags the same.
    @Test func theListDragsTheSameWhileEveryRowIsDrawn() async throws {
        let rig = SidebarDriveRig(voiceOver: true)
        defer { rig.close() }
        rig.addPages(60)
        try await rig.settle(rounds: 12)
        let visible = rig.onScreen()
        try #require(visible.count >= 6)
        let moving = visible[0]
        let target = visible[4]
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(target, 0.9)], steps: 14)

        let after = rig.browser.sidebarItems
        #expect(after.firstIndex(of: moving) == (after.firstIndex(of: target) ?? -2) + 1)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    @Test func theIconsOnlySidebarReordersToo() async throws {
        let rig = SidebarDriveRig(width: 60, style: .icons)
        defer { rig.close() }
        rig.addPages(30)
        try await rig.settle()
        let visible = rig.onScreen()
        try #require(visible.count >= 6)
        let moving = visible[0]
        let target = visible[3]
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(target, 0.9)])

        let after = rig.browser.sidebarItems
        #expect(after.firstIndex(of: moving) == (after.firstIndex(of: target) ?? -2) + 1)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    // MARK: The pin line

    @Test(arguments: [false, true])
    func draggingATabAcrossThePinLinePinsIt(queued: Bool) async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.queued = queued
        let tabs = rig.addPages(20)
        rig.browser.pin(tabs[0])
        rig.browser.pin(tabs[1])
        try await rig.settle()
        let order = rig.browser.sidebarItems
        let kept = try #require(order.first { rig.browser.isKept($0) })
        let moving = try #require(rig.onScreen().last { !rig.browser.isKept($0) })
        try #require(rig.frame(of: moving) != nil)
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(kept, 0.1)], steps: 16)

        let tab = try rig.tab(moving)
        #expect(rig.browser.isKept(moving))
        #expect(rig.browser.isPinned(moving))
        #expect(tab.pinnedURL != nil)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    @Test(arguments: [false, true])
    func draggingAPinBelowTheLineUnpinsIt(queued: Bool) async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.queued = queued
        let tabs = rig.addPages(20)
        for tab in tabs.prefix(3) {
            rig.browser.pin(tab)
        }
        try await rig.settle()
        let order = rig.browser.sidebarItems
        let pinned = try #require(order.first { rig.browser.isKept($0) })
        let target = try #require(order.filter { !rig.browser.isKept($0) }.dropFirst(3).first)
        try await rig.drag(through: [try rig.spot(pinned), try rig.spot(target, 0.9)], steps: 14)

        let tab = try rig.tab(pinned)
        #expect(!rig.browser.isKept(pinned))
        #expect(tab.pinnedURL == nil)
        #expect(rig.coordinator.sidebarDrag.drag == nil)

        // A second drag lands: the list is still draggable after a drop that changed the line.
        let again = try #require(rig.browser.sidebarItems.filter { !rig.browser.isKept($0) }.dropFirst(5).first)
        let line = try #require(rig.browser.sidebarItems.first { rig.browser.isKept($0) })
        try await rig.drag(through: [try rig.spot(again), try rig.spot(line, 0.1)])
        #expect(rig.browser.isKept(again))
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    /// The seam between the pinned rows and the others, and the rows' gaps, do not depend on how the list is built.
    @Test func thePinLineSeamAndTheRowGapsKeepTheirSize() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(10)
        for tab in tabs.prefix(3) {
            rig.browser.pin(tab)
        }
        try await rig.settle()
        let settings = BrowserSettings.application
        let spacing = SidebarMetrics.rowVerticalSpacing(settings: settings)
        let height = SidebarMetrics.rowHeight(settings: settings)
        let order = rig.browser.sidebarItems
        let frames = try order.map { try #require(rig.frame(of: $0), "\($0)") }
        let pinned = order.prefix { rig.browser.isKept($0) }.count
        try #require(pinned == 3)

        for (index, frame) in frames.enumerated() {
            #expect(abs(frame.height - height) < 0.01, "row \(index) is \(frame.height) tall")
            #expect(abs(frame.minX - frames[0].minX) < 0.01, "row \(index) starts at \(frame.minX)")
            guard index > 0 else { continue }
            let gap = frame.minY - frames[index - 1].maxY
            // The seam is a 1 pt line with 3 pt above and below, and a row's gap on each side of it.
            let expected = index == pinned ? spacing * 2 + 7 : spacing
            #expect(abs(gap - expected) < 0.01, "row \(index) follows a gap of \(gap), expected \(expected)")
        }
    }

    // MARK: Folders

    @Test(arguments: [false, true])
    func draggingATabIntoAFolder(queued: Bool) async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.queued = queued
        let tabs = rig.addPages(14)
        let folder = rig.browser.createFolder(named: "Folder", containing: Array(tabs[2...4]))
        try await rig.settle()
        let header = SidebarItem.folder(folder.id)
        let loose = rig.browser.sidebarItems.filter { $0 != header && !rig.browser.sidebarTree.rows(in: folder.id).contains($0) }
        let moving = try #require(loose.last { rig.isOnScreen($0) })
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(header, 0.8)], steps: 14)

        let tab = try rig.tab(moving)
        #expect(rig.browser.sidebarTree.parent(of: moving) == folder.id)
        #expect(rig.browser.rows(in: folder).first == moving)
        #expect(rig.browser.rows(in: folder).count == 4)
        #expect(tab.pinnedURL == nil)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    @Test func draggingATabBetweenTheRowsOfAFolder() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(14)
        let folder = rig.browser.createFolder(named: "Folder", containing: Array(tabs[2...4]))
        try await rig.settle()
        let children = rig.browser.rows(in: folder)
        try #require(children.count == 3)
        let moving = try #require(rig.browser.sidebarItems.last { rig.isOnScreen($0) && $0 != .folder(folder.id) })
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(children[1], 0.1)], steps: 14)

        let after = rig.browser.rows(in: folder)
        #expect(after.count == 4)
        #expect(after.firstIndex(of: moving) == 1)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    @Test func draggingATabIntoAPinnedFolderPinsItsPage() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(14)
        let folder = rig.browser.createFolder(named: "Pinned", containing: Array(tabs[0...1]))
        rig.browser.pin(folder)
        try await rig.settle()
        let header = SidebarItem.folder(folder.id)
        try #require(rig.browser.isKept(header))
        let moving = try #require(rig.onScreen().last { item in
            !rig.browser.isPinned(item) && item != header
        })
        try await rig.drag(through: [try rig.spot(moving), try rig.spot(header, 0.8)], steps: 14)

        let tab = try rig.tab(moving)
        #expect(rig.browser.sidebarTree.parent(of: moving) == folder.id)
        #expect(rig.browser.isPinned(moving))
        #expect(tab.pinnedURL != nil)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    @Test func draggingATabOutOfAFolderUnpinsItsPage() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(14)
        let folder = rig.browser.createFolder(named: "Pinned", containing: Array(tabs[0...2]))
        rig.browser.pin(folder)
        try await rig.settle()
        let children = rig.browser.rows(in: folder)
        let child = try #require(children.last)
        let tab = try rig.tab(child)
        try #require(tab.pinnedURL != nil)
        let target = try #require(rig.browser.sidebarItems.dropFirst(1).first { rig.isOnScreen($0) && !rig.browser.isKept($0) })
        try await rig.drag(through: [try rig.spot(child), try rig.spot(target, 0.9)], steps: 14)

        #expect(rig.browser.sidebarTree.parent(of: child) == nil)
        let after = rig.browser.sidebarItems
        #expect(after.firstIndex(of: child) == (after.firstIndex(of: target) ?? -2) + 1)
        #expect(!rig.browser.isPinned(child))
        #expect(tab.pinnedURL == nil)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    @Test func draggingAFolderCarriesItsRowsAndOpensAgain() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(14)
        let folder = rig.browser.createFolder(named: "Folder", containing: Array(tabs[0...2]))
        try await rig.settle()
        let header = SidebarItem.folder(folder.id)
        let target = try #require(rig.onScreen().filter { $0 != header && rig.browser.sidebarTree.parent(of: $0) == nil }.dropFirst(3).first)
        try await rig.drag(through: [try rig.spot(header), try rig.spot(target, 0.9)], steps: 14)

        // The folder shuts as it is picked up, so the rows below come up and the pointer ends past `target`.
        let after = rig.browser.sidebarItems
        #expect((after.firstIndex(of: header) ?? -1) > (after.firstIndex(of: target) ?? .max))
        #expect(rig.browser.rows(in: folder).count == 3)
        #expect(folder.isExpanded)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    @Test func collapsingAndExpandingAFolderMovesTheRowsBelow() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(12)
        let folder = rig.browser.createFolder(named: "Folder", containing: Array(tabs[0...3]))
        try await rig.settle()
        let header = SidebarItem.folder(folder.id)
        let below = try #require(rig.browser.sidebarItems.last { rig.isOnScreen($0) })
        let child = SidebarItem.tab(tabs[1].id)
        let open = try #require(rig.frame(of: below))
        try #require(rig.frame(of: child) != nil)

        folder.isExpanded = false
        try await rig.settle()
        let shut = try #require(rig.frame(of: below))
        #expect(shut.minY < open.minY, "the rows below come up")

        folder.isExpanded = true
        try await rig.settle()
        let again = try #require(rig.frame(of: below))
        #expect(abs(again.minY - open.minY) < 0.01)
        #expect(rig.isOnScreen(child))
        #expect(rig.frame(of: header) != nil)
    }

    // MARK: Several rows

    @Test func draggingOneOfSeveralMarkedRowsCarriesThemAll() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        rig.addPages(30)
        try await rig.settle()
        let visible = rig.onScreen()
        try #require(visible.count >= 8)
        let first = visible[0]
        let second = visible[2]
        let target = visible[6]
        rig.browser.sidebarSelection.toggle(first)
        rig.browser.sidebarSelection.toggle(second)
        try await rig.drag(through: [try rig.spot(first), try rig.spot(target, 0.9)], steps: 14)

        let after = rig.browser.sidebarItems
        let targetIndex = try #require(after.firstIndex(of: target))
        #expect(after[targetIndex + 1] == first)
        #expect(after[targetIndex + 2] == second)
        #expect(rig.coordinator.sidebarDrag.drag == nil)
    }

    // MARK: The page

    @Test(.boundedWebViews, arguments: [false, true])
    func draggingATabOntoThePageSplitsIt(queued: Bool) async throws {
        let rig = SidebarDriveRig(width: 280)
        defer { rig.close() }
        rig.queued = queued
        let browser = rig.browser
        var tabs: [BrowserTab] = []
        for index in 0..<8 {
            let tab = browser.newTab(activate: index == 0)
            tab.urlString = "https://site\(index).example/"
            tab.title = "Site \(index)"
            tabs.append(tab)
        }
        let active = try #require(browser.activeTab)
        rig.coordinator.sidebarDrag.contentFrameInWindow = CGRect(x: 280, y: 0, width: 600, height: 700)
        rig.coordinator.sidebarDrag.planSource = { SplitDropPlan(singlePage: active.id, size: CGSize(width: 600, height: 700)) }
        try await rig.settle()
        let moving = try #require(tabs.dropFirst(3).first { rig.isOnScreen(.tab($0.id)) })
        let from = try rig.spot(.tab(moving.id))
        // The window is as wide as the sidebar, so the drag goes past its right edge to where the page would be.
        let end = CGPoint(x: 860, y: 350)
        try await rig.drag(through: [from, end], steps: 20)

        let split = try #require(browser.activeSplit)
        #expect(split.contains(moving.id))
        #expect(split.contains(active.id))
        #expect(rig.coordinator.sidebarDrag.drag == nil)
        for tab in tabs {
            browser.close(tab)
        }
    }

    // MARK: Renaming

    /// A folder made around a row far down the list is scrolled into view and asks for its name.
    @Test func aNewFolderFarDownTheListScrollsIntoViewAndAsksForItsName() async throws {
        let rig = SidebarDriveRig()
        defer { rig.close() }
        let tabs = rig.addPages(60)
        try await rig.settle()
        let far = SidebarItem.tab(tabs[50].id)
        let folder = rig.browser.createFolder(named: "Far Away", containing: [far], requestingRename: true)
        try await rig.settle(rounds: 20)

        let header = SidebarItem.folder(folder.id)
        #expect(rig.isOnScreen(header), "the new folder is in view: \(String(describing: rig.frame(of: header)))")
        #expect(rig.browser.folderRenameID == folder.id)
        func fields(in view: NSView) -> [NSTextField] {
            ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap { fields(in: $0) }
        }
        #expect(fields(in: rig.host).contains { $0.placeholderString == String(localized: "Folder name") })
    }
}
