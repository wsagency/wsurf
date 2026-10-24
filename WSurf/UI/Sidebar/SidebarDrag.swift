// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct SidebarDrag {
    let items: [SidebarItem]
    let lead: SidebarItem
    let origin: CGRect
    let originTree: SidebarTree
    let covered: Set<SidebarItem>
    let keepsSection: Bool
    let wasKept: Bool
    var translation: CGSize = .zero
    var landing = false

    init(
        items: [SidebarItem],
        lead: SidebarItem,
        origin: CGRect,
        tree: SidebarTree,
        keepsSection: Bool,
        wasKept: Bool
    ) {
        self.items = items
        self.lead = lead
        self.origin = origin
        originTree = tree
        self.keepsSection = keepsSection
        self.wasKept = wasKept
        covered = tree.expanded(Set(items))
    }

    var isSingle: Bool {
        items.count == 1
    }

    func carries(_ item: SidebarItem) -> Bool {
        covered.contains(item)
    }

    func settlesPin(of item: SidebarItem, in tree: SidebarTree) -> Bool {
        let parent = tree.parent(of: item)
        return parent == nil || parent != originTree.parent(of: item)
    }

    func settlePins(_ pinned: Bool, in browser: BrowserModel) {
        let tree = browser.sidebarTree
        browser.setPinned(pinned, for: items.lazy.filter { self.settlesPin(of: $0, in: tree) })
    }
}

enum SidebarDragGhost {
    static func liftScale(style: SidebarStyle) -> CGFloat {
        style == .icons ? 1 : 1.03
    }

    static let chipFillOpacity: Double = 0.55
}

@MainActor
@Observable
final class SidebarDragModel {
    var drag: SidebarDrag?

    let frames = SidebarFrames()

    var listOriginInWindow: CGPoint = .zero

    /// The space switcher's icons, in global coordinates, so a dragged row can be dropped on one.
    @ObservationIgnored var spaceDotFrames: [UUID: CGRect] = [:]
    /// The space whose icon a dragged row is over; dropping moves the row there.
    var armedSpaceID: UUID?

    func spaceDot(at point: CGPoint) -> UUID? {
        spaceDotFrames.first { $0.value.contains(point) }?.key
    }

    var contentFrameInWindow: CGRect = .zero

    var dropFrameInWindow: CGRect {
        contentFrameInWindow
    }

    var dropPlan: SplitDropPlan {
        planSource?() ?? SplitDropPlan()
    }

    @ObservationIgnored var planSource: (() -> SplitDropPlan)?

    var target: SplitDropPlan.Target?

    var zone: SplitDropZone {
        target?.edge ?? .none
    }
    var targetPaneID: UUID? {
        target?.anchor
    }

    func aim(at pointInWindow: CGPoint) {
        let origin = contentFrameInWindow.origin
        let local = CGPoint(
            x: pointInWindow.x - origin.x,
            y: pointInWindow.y - origin.y
        )
        let next = dropPlan.target(at: local)
        guard next != target else { return }
        target = next
    }

    func clearDrop() {
        target = nil
        source = .none
    }

    var source: PageDropSource = .none

    var panePointInWindow: CGPoint = .zero

    var carriedPaneID: UUID? {
        guard case .pane(let id) = source else { return nil }
        return id
    }

    enum PageDropSource: Equatable {
        case none
        case row
        case pane(UUID)
    }

    var carriedTabID: UUID? {
        guard let drag, drag.items.count == 1, case .tab(let id) = drag.lead else { return nil }
        return id
    }

    var acceptsPin: Bool {
        guard let drag, !drag.landing else { return false }
        return !drag.keepsSection
    }
}

/// Where the rows are, for drops, drags and the preview card. The list draws its rows lazily, so a row records its
/// frame while it exists and forgets it when it goes. Frames are kept in the list's content, which does not move as
/// it scrolls, and placed in the list by `contentOrigin`, which does: scrolling costs one update, not one per row.
@MainActor
final class SidebarFrames {
    private var slots: [SidebarItem: CGRect] = [:]
    private var owners: [SidebarItem: UUID] = [:]
    /// Where the content starts in the list's coordinates (above the list's top while it is scrolled down).
    var contentOrigin: CGPoint = .zero

    /// `owner` tells the row that drew the frame apart from the one that replaces it: a drop into a folder builds the
    /// row again, and the new view records before the old one disappears.
    func record(_ item: SidebarItem, at frame: CGRect, by owner: UUID? = nil) {
        slots[item] = frame
        owners[item] = owner
    }

    func forget(_ item: SidebarItem, recordedBy owner: UUID) {
        guard owners[item] == owner else { return }
        slots[item] = nil
        owners[item] = nil
    }

    /// The row's frame in the list's coordinates.
    subscript(item: SidebarItem) -> CGRect? {
        slots[item].map(placed)
    }

    /// The row's frame in the window's, given where the list starts in it.
    func windowFrame(of item: SidebarItem, listOrigin: CGPoint) -> CGRect? {
        self[item]?.offsetBy(dx: listOrigin.x, dy: listOrigin.y)
    }

    private func placed(_ frame: CGRect) -> CGRect {
        frame.offsetBy(dx: contentOrigin.x, dy: contentOrigin.y)
    }

    /// The frames, in the list's coordinates, of the rows a person can point at: drawn, in the space on screen, in a
    /// folder that is open, and not the hidden pane of a split.
    func visible(in browser: BrowserModel) -> [SidebarItem: CGRect] {
        let hidden = browser.hiddenSidebarTabIDs
        let parents = browser.sidebarTree.parents()
        var found: [SidebarItem: CGRect] = [:]
        found.reserveCapacity(slots.count)
        for (item, frame) in slots {
            switch item {
            case .tab(let id):
                guard browser.tabsByID[id] != nil, !hidden.contains(id) else { continue }
            case .folder(let id):
                guard browser.foldersByID[id] != nil else { continue }
            }
            guard browser.isShown(item), isInOpenFolders(item, parents: parents, in: browser) else { continue }
            found[item] = placed(frame)
        }
        return found
    }

    private func isInOpenFolders(_ item: SidebarItem, parents: [SidebarItem: UUID], in browser: BrowserModel) -> Bool {
        var parent = parents[item]
        while let id = parent {
            guard browser.foldersByID[id]?.isExpanded == true else { return false }
            parent = parents[.folder(id)]
        }
        return true
    }
}

/// What a row keeps for `SidebarFrames`: who it is, so a view that replaces it is not undone by its goodbye, and the last
/// frame it measured. SwiftUI can bring a row back without measuring it again (nothing about its geometry changed), and
/// then the row records that frame itself. A class, not state: remembering a frame must not redraw the row.
@MainActor
final class SidebarRowFrame {
    private let owner = UUID()
    private var measured: CGRect?

    func measure(_ item: SidebarItem, at frame: CGRect, in frames: SidebarFrames) {
        measured = frame
        frames.record(item, at: frame, by: owner)
    }

    func appear(_ item: SidebarItem, in frames: SidebarFrames) {
        guard let measured else { return }
        frames.record(item, at: measured, by: owner)
    }

    func forget(_ item: SidebarItem, in frames: SidebarFrames) {
        frames.forget(item, recordedBy: owner)
    }
}

struct SidebarRowContext {
    let browser: BrowserModel
    let coordinator: AppCoordinator
    let selection: SidebarSelection
    let drag: SidebarDrag?
    let pinsCarried: Bool
    let space: String
    let frames: SidebarFrames

    var refractsTabColor: Bool {
        BrowserSettings.application.refractsTabColor
    }

    func isLifted(_ item: SidebarItem) -> Bool {
        drag?.items.contains(item) == true
    }

    func dropMark(_ item: SidebarItem) -> SidebarDropMark.Kind? {
        guard let drag, drag.lead == item else { return nil }
        if drag.settlesPin(of: item, in: browser.sidebarTree), pinsCarried != browser.isKept(item) {
            return pinsCarried ? .pin : .unpin
        }
        return .move
    }

    func isSelected(_ item: SidebarItem) -> Bool {
        selection.contains(item)
    }

    var activeItem: SidebarItem? {
        guard case .tab(let id) = coordinator.sidebarDestination else { return nil }
        return .tab(browser.splits.split(containing: id)?.leader ?? id)
    }

    /// Where the row of `item` is in the window, or zero while it has no frame.
    func windowFrame(of item: SidebarItem) -> CGRect {
        frames.windowFrame(of: item, listOrigin: coordinator.sidebarDrag.listOriginInWindow) ?? .zero
    }

    /// Keeps the preview card of the row `id` names on that row when the row moves in the list (a folder above it
    /// opens, a row above it goes). Scrolling moves every row at once and is followed by the list itself.
    func followPreview(of item: SidebarItem, id: UUID) {
        guard coordinator.tabPreview.shown?.subject.id == id else { return }
        coordinator.tabPreview.moved(id, anchor: windowFrame(of: item))
    }
}

enum SidebarPinMetrics {
    static let hairline = Theme.chrome(0.14)
}

struct SidebarSectionSeam: View {
    var body: some View {
        Capsule()
            .fill(SidebarPinMetrics.hairline)
            .frame(height: 1)
            .padding(.horizontal, SidebarMetrics.rowContentPadding(style: .full))
            .padding(.vertical, 3)
    }
}

struct SidebarDropMark: View {
    enum Kind {
        case move
        case pin
        case unpin
    }

    let kind: Kind
    var isArmed = false

    @Environment(\.sidebarStyle) private var sidebarStyle

    private static let dash: [CGFloat] = [4, 3]

    private var calls: Bool {
        kind == .pin || kind == .unpin
    }

    private var tint: Color {
        isArmed && calls ? Theme.accent : Color.primary.opacity(0.45)
    }

    private var symbol: String {
        switch kind {
        case .move:
            "arrow.up.and.down"
        case .pin:
            "pin.fill"
        case .unpin:
            "pin.slash.fill"
        }
    }

    @ViewBuilder
    private var label: some View {
        switch kind {
        case .move:
            Text("Move")
        case .pin:
            Text("Pin")
        case .unpin:
            Text("Unpin")
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.hover, style: .continuous)
        HStack(spacing: SidebarMetrics.rowIconSpacing) {
            Image(systemName: symbol)
                .font(Theme.Font.control)
                .frame(width: SidebarMetrics.rowIconSize)
            if sidebarStyle == .full {
                label
                    .font(BrowserSettings.application.sidebarFont)
                    .lineLimit(1)
                    .sidebarTitleCentered()
                Spacer(minLength: 0)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, SidebarMetrics.rowContentPadding(style: sidebarStyle))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: sidebarStyle == .full ? .leading : .center)
        .background { shape.fill(Theme.accent.opacity(isArmed && calls ? 0.16 : 0)) }
        .overlay {
            shape.strokeBorder(
                tint.opacity(isArmed ? 1 : 0.5),
                style: StrokeStyle(lineWidth: 1, dash: isArmed && calls ? [] : Self.dash)
            )
        }
        .allowsHitTesting(false)
    }
}

/// The rows of one level: a top-level list is a `ForEach` inside the list's lazy stack, so each row is one lazy item
/// (the pin line's seam goes in the item of the last pinned row); a folder puts its rows in a stack of its own.
struct SidebarRows: View {
    let items: [SidebarItem]
    let depth: Int
    let context: SidebarRowContext
    /// The row that the pin line's seam follows.
    var seamAfter: SidebarItem?

    /// Rows that exist: a missing one or the hidden pane of a split takes no room, not even a gap.
    private var shown: [SidebarItem] {
        items.filter { item in
            switch item {
            case .folder(let id):
                context.browser.folder(id: id) != nil
            case .tab(let id):
                context.browser.tab(id: id) != nil && !context.browser.splits.isFollower(id)
            }
        }
    }

    var body: some View {
        ForEach(shown, id: \.self) { item in
            VStack(spacing: SidebarMetrics.rowVerticalSpacing(settings: BrowserSettings.application)) {
                row(item)
                    .overlay {
                        if let mark = context.dropMark(item) {
                            SidebarDropMark(kind: mark, isArmed: true)
                        }
                    }
                if item == seamAfter {
                    SidebarSectionSeam()
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: SidebarItem) -> some View {
        switch item {
        case .folder(let id):
            if let folder = context.browser.folder(id: id) {
                FolderSection(folder: folder, depth: depth, context: context)
            }
        case .tab(let id):
            if let tab = context.browser.tab(id: id) {
                if let grid = context.browser.splits.splitLed(by: id) {
                    SidebarSplitRow(leading: tab, split: grid, depth: depth, context: context)
                } else {
                    SidebarTabRow(tab: tab, depth: depth, context: context)
                }
            }
        }
    }
}
