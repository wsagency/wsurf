// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Observation
import SwiftUI

enum SidebarDestination: Hashable {
    case tab(UUID)

    static func resolve(activeTabID: UUID?) -> SidebarDestination? {
        activeTabID.map(SidebarDestination.tab)
    }
}

/// Every drawn row reads `items` (`isSelected`), and `@Observable` reports a write even when the value does not change, so a
/// write that changes nothing would draw every row again. Each change below writes only what it changes.
@MainActor
@Observable
final class SidebarSelection {
    private(set) var items: Set<SidebarItem> = []
    private(set) var anchor: SidebarItem?
    private(set) var ownsKeyboard = false
    private(set) var keyboardRequestID = 0

    var isEmpty: Bool {
        items.isEmpty
    }
    var count: Int {
        items.count
    }

    func contains(_ item: SidebarItem) -> Bool {
        items.contains(item)
    }

    func select(_ item: SidebarItem) {
        mark([item])
        setAnchor(item)
    }

    func hold(_ active: SidebarItem?) {
        guard items.isEmpty, let active else { return }
        items = [active]
        if anchor == nil {
            anchor = active
        }
    }

    func toggle(_ item: SidebarItem) {
        if items.contains(item) {
            items.remove(item)
        } else {
            items.insert(item)
        }
        setAnchor(item)
        takeKeys(true)
    }

    func anchor(on item: SidebarItem) {
        mark([])
        setAnchor(item)
    }

    func dropMarks() {
        mark([])
        takeKeys(false)
    }

    func takeKeyboard() {
        mark([])
        setAnchor(nil)
        takeKeys(true)
        keyboardRequestID += 1
    }

    func extend(to item: SidebarItem, in tree: SidebarTree, isExpanded: @escaping (UUID) -> Bool) {
        guard let anchor, anchor != item else {
            select(item)
            return
        }
        mark(items.union(tree.range(from: anchor, to: item, isExpanded: isExpanded)))
        takeKeys(true)
    }

    func selectAll(in tree: SidebarTree, isExpanded: @escaping (UUID) -> Bool) {
        let rows = tree.visibleRows(isExpanded: isExpanded)
        items = Set(rows)
        anchor = rows.first
        ownsKeyboard = true
    }

    func clear() {
        mark([])
        setAnchor(nil)
        takeKeys(false)
    }

    func prune(to live: Set<SidebarItem>) {
        guard !items.isSubset(of: live) else { return }
        items.formIntersection(live)
        if let anchor, !live.contains(anchor) {
            self.anchor = nil
        }
    }

    func excludeFavorites(_ favorites: [BrowserTab]) {
        let favorites = Set(favorites.map { SidebarItem.tab($0.id) })
        mark(items.subtracting(favorites))
        if let anchor, favorites.contains(anchor) {
            self.anchor = nil
        }
    }

    func carried(startingOn item: SidebarItem, in tree: SidebarTree) -> [SidebarItem] {
        guard items.contains(item) else {
            anchor(on: item)
            return [item]
        }
        return tree.normalized(items)
    }

    private func mark(_ marked: Set<SidebarItem>) {
        if items != marked {
            items = marked
        }
    }

    private func setAnchor(_ item: SidebarItem?) {
        if anchor != item {
            anchor = item
        }
    }

    private func takeKeys(_ owns: Bool) {
        if ownsKeyboard != owns {
            ownsKeyboard = owns
        }
    }
}

@MainActor
@Observable
final class SidebarNewFolderDrop {
    @ObservationIgnored var frame: CGRect = .zero
    var isArmed = false
}

@MainActor
@Observable
final class SidebarPinDrop {
    @ObservationIgnored var frame: CGRect = .zero
    var isArmed = false
}
