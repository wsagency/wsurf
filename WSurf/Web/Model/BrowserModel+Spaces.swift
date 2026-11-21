// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import GRDB
import os

/// A space is a view of this window: every tab stays in `tabs`, so the assistant, MCP clients, ⌘K and extensions keep
/// seeing all of them. Pins, pinned folders and Favorites belong to the profile and show in every space; settling gives
/// them no space, and gives every other row its own known space or the one on screen.
extension BrowserModel {
    // MARK: - What the window shows

    func isShown(_ tab: BrowserTab) -> Bool {
        currentSpaceID == nil || tab.spaceID == nil || tab.spaceID == currentSpaceID
    }

    func isShown(_ item: SidebarItem) -> Bool {
        guard let currentSpaceID, let space = spaceID(ofItem: item) else { return true }
        return space == currentSpaceID
    }

    /// The tabs of the space on screen and the profile's pins, in sidebar order.
    var currentSpaceTabs: [BrowserTab] {
        currentSpaceID == nil ? tabs : tabs.filter(isShown)
    }

    /// The tab on screen when none is chosen. Never a row that stands for a page in a micro window.
    var firstShownTab: BrowserTab? {
        tabs.first { $0.microTabID == nil && isShown($0) }
    }

    func spaceID(ofItem item: SidebarItem) -> UUID? {
        switch item {
        case .tab(let id):
            tabsByID[id]?.spaceID
        case .folder(let id):
            foldersByID[id]?.spaceID
        }
    }

    func lastActiveTab(inSpace id: UUID) -> BrowserTab? {
        recentlyActive.lazy.compactMap { self.tabsByID[$0] }.first { $0.spaceID == id }
            ?? tabs.first { $0.spaceID == id }
    }

    // MARK: - Choosing the space

    func adoptSpaces(from store: SpaceStore?) {
        if let store, !store.recoverMembership() {
            if pendingSpaceStore?.store !== store {
                pendingSpaceStore = (store, nil)
                adoptSpaces([])
            }
        } else {
            if let pending = pendingSpaceStore, pending.store === store {
                currentSpaceID = pending.selection
            }
            pendingSpaceStore = nil
            adoptSpaces(store?.spaces.map(\.id) ?? [])
        }
    }

    /// Takes the spaces of the window's profile; an empty list (private browsing) shows every tab. Keeps the space on
    /// screen when it still exists, else the active tab's, else the first.
    func adoptSpaces(_ owned: [UUID]) {
        selectOwnedSpaces(owned)
        sidebarDidChange()
    }

    private func selectOwnedSpaces(_ owned: [UUID]) {
        knownSpaceIDs = Set(owned)
        if currentSpaceID.map({ knownSpaceIDs.contains($0) }) != true {
            currentSpaceID = activeTab?.spaceID.flatMap { knownSpaceIDs.contains($0) ? $0 : nil } ?? owned.first
        }
    }

    /// Shows `id`, landing on `tab`, the space's last active tab, or a new tab when the space has none and the page on
    /// screen belongs to another space. A pin on screen stays: every space shows it.
    func switchSpace(to id: UUID, showing tab: BrowserTab? = nil) {
        guard id != currentSpaceID, knownSpaceIDs.contains(id) else { return }
        endTabSwitching()
        show(space: id)
        if let target = tab ?? lastActiveTab(inSpace: id) {
            activate(target)
        } else if activeTab.map({ $0.spaceID != nil }) ?? true {
            newTab()
        }
    }

    /// Activating a tab of another space, from ⌘K, a link or an agent, takes the window there.
    func followSpace(of tab: BrowserTab?) {
        guard let space = tab?.spaceID else { return }
        if pendingSpaceStore != nil {
            pendingSpaceStore?.selection = space
        } else if space != currentSpaceID, knownSpaceIDs.contains(space) {
            show(space: space)
        }
    }

    /// Choose from the saved rows before an unassigned tab can inherit the first Space.
    /// A pin belongs to every Space, so the most recently used ordinary tab decides where the window lands.
    func restoreSpace(for activeID: UUID?) {
        let saved = tabs.filter { tab in
            guard let space = tab.spaceID, !tab.isPinnedForProfile else { return false }
            return pendingSpaceStore != nil || knownSpaceIDs.contains(space)
        }
        guard let selection = (saved.first { $0.id == activeID } ?? saved.max { $0.lastActiveAt < $1.lastActiveAt })?.spaceID else { return }
        if pendingSpaceStore != nil {
            pendingSpaceStore?.selection = selection
        } else {
            currentSpaceID = selection
        }
    }

    /// A row that became unpinned since the last settle, or was pinned, settles in the space it was on screen in
    /// before the window leaves that space.
    private func show(space id: UUID) {
        settleSpaces(in: reconciledTree())
        sidebarSelection.clear()
        currentSpaceID = id
        sidebarDidChange()
    }

    // MARK: - Settling

    func settleSpaces(in tree: SidebarTree, isNew: (SidebarItem) -> Bool = { _ in false }) {
        if let pending = pendingSpaceStore {
            guard pending.store.recoverMembership() else {
                placeNewRows(in: tree, selectedSpace: pending.selection, isNew: isNew)
                return
            }
            pendingSpaceStore = nil
            currentSpaceID = pending.selection
            selectOwnedSpaces(pending.store.spaces.map(\.id))
        }
        guard let currentSpaceID else { return }
        for item in tree.root {
            let space: UUID? = isKept(item) ? nil : spaceID(ofItem: item).flatMap(knownSpace) ?? currentSpaceID
            assignSpace(space, to: item)
            guard case .folder(let id) = item else { continue }
            for held in tree.descendants(ofFolder: id) {
                assignSpace(space, to: held)
            }
        }
    }

    /// A new root inherits the selection at first placement. Children belong to their root,
    /// and a pre-existing ordinary row can still have an unknown SQLite membership.
    private func placeNewRows(in tree: SidebarTree, selectedSpace: UUID?, isNew: (SidebarItem) -> Bool) {
        guard !isReadingSharedSession, !isApplyingProfilePins else { return }
        for root in tree.root {
            let kept = isKept(root)
            let newRoot = isNew(root)
            let space = kept ? nil : spaceID(ofItem: root) ?? (newRoot ? selectedSpace : nil)
            guard kept || space != nil else { continue }
            if newRoot || kept {
                assignSpace(space, to: root)
            }
            guard case .folder(let id) = root else { continue }
            for child in tree.descendants(ofFolder: id) where kept || isNew(child) {
                assignSpace(space, to: child)
            }
        }
    }

    private func knownSpace(_ id: UUID) -> UUID? {
        knownSpaceIDs.contains(id) ? id : nil
    }

    private func assignSpace(_ space: UUID?, to item: SidebarItem) {
        switch item {
        case .tab(let id):
            if let tab = tabsByID[id], tab.spaceID != space {
                tab.spaceID = space
            }
        case .folder(let id):
            if let folder = foldersByID[id], folder.spaceID != space {
                folder.spaceID = space
            }
        }
    }

    // MARK: - Moving and closing

    /// Where Move to Space can take rows: the other spaces of this profile. Rows never change profile.
    var spaceMoveTargets: [Space] {
        guard let currentSpaceID, let store = context.spaces else { return [] }
        return store.spaces.filter { $0.id != currentSpaceID && knownSpaceIDs.contains($0.id) }
    }

    /// Moves rows of the space on screen to the top of space `id`, out of any folder. Both panes of a split go
    /// together; pins and what pinned folders hold stay, since every space shows them. Sidebar Undo forgets its steps:
    /// they name places in the space the rows left.
    func move(_ items: [SidebarItem], toSpace id: UUID) {
        guard id != currentSpaceID, knownSpaceIDs.contains(id) else { return }
        let tree = reconciledTree()
        let withPanes = items.flatMap { item -> [SidebarItem] in
            guard case .tab(let tabID) = item, let split = splits.split(containing: tabID) else { return [item] }
            return split.tabs.map(SidebarItem.tab)
        }
        let moved = tree.normalized(withPanes).filter { spaceID(ofItem: $0) != nil }
        guard !moved.isEmpty else { return }
        let carried = tree.expanded(Set(moved))
        let wasActive = activeTabID.map { carried.contains(.tab($0)) } ?? false
        for item in carried {
            assignSpace(id, to: item)
        }
        let boundary = tree.root.first { !carried.contains($0) && spaceID(ofItem: $0) == id }
        place(moved, in: nil, before: boundary)
        sidebarUndoManager.removeAllActions()
        sidebarSelection.clear()
        syncTabOrder()
        if wasActive {
            if let next = currentSpaceID.flatMap(lastActiveTab(inSpace:)) ?? firstShownTab {
                activate(next)
            } else {
                newTab()
            }
        }
        scheduleSave()
    }

    /// Closes the tabs and folders of space `id` without offering them to Reopen Closed Tab.
    func closeSpace(_ id: UUID) {
        for tab in tabs.reversed() where tab.spaceID == id {
            close(tab, recordForReopening: false)
        }
        let gone = folders.filter { $0.spaceID == id }.map(\.id)
        folders.removeAll { $0.spaceID == id }
        for folderID in gone {
            finishFolderRename(folderID)
        }
        sidebarDidChange()
        scheduleSave()
    }

    /// Removes the saved rows of space `id` from every window of the profile, open or not.
    static func forgetSpace(_ id: UUID, in database: AppDatabase) {
        do {
            try database.writer.write { db in
                try db.execute(sql: "DELETE FROM sessionTab WHERE spaceID = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM sessionFolder WHERE spaceID = ?", arguments: [id])
            }
        } catch {
            Pipeline.log.error("spaces: could not forget a deleted space's saved tabs")
        }
    }
}
