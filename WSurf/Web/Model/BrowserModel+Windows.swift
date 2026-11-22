// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation

extension BrowserModel {
    /// Transfer the same live page; navigation and POST state belong to the tab. The page becomes the tab in front, unless
    /// `activate` is false: a page that was opened in the background stays there.
    @discardableResult
    func adoptTab(_ tab: BrowserTab, from source: BrowserModel, activate: Bool = true) -> Bool {
        guard adoptTabInMemory(tab, from: source, activate: activate) else { return false }
        saveTransferredSession(from: source)
        return true
    }

    private func adoptTabInMemory(_ tab: BrowserTab, from source: BrowserModel, activate: Bool, preservingSpace: Bool = false) -> Bool {
        guard canReceive(from: source), canReceive(tab, from: source) else { return false }
        source.onTabWillTransferOut?(tab)
        guard canReceive(from: source), canReceive(tab, from: source), let oldIndex = source.tabs.firstIndex(where: { $0 === tab }) else { return false }
        transfer(tab, from: source, oldIndex: oldIndex, preservingSpace: preservingSpace)
        source.onTabTransferredOut?(tab, oldIndex)
        onTabTransferredIn?(tab, source, oldIndex)
        if activate {
            activeTabID = tab.id
        }
        return true
    }

    private func canReceive(from source: BrowserModel) -> Bool {
        source !== self && source.windowID != windowID && source.context === context &&
            source.sessionClosedAt == nil && sessionClosedAt == nil && context.isRegistered(source) && context.isRegistered(self) &&
            (source.database.writer as AnyObject) === (database.writer as AnyObject)
    }

    private func canReceive(_ tab: BrowserTab, from source: BrowserModel) -> Bool {
        source.tabsByID[tab.id] === tab && tab.context === context && !tabs.contains(where: { $0.id == tab.id }) && !tab.isClosed
    }

    func adoptSharedRoots(_ roots: [SidebarItem], from source: BrowserModel) -> [SidebarItem] {
        guard canReceive(from: source) else { return [] }
        return roots.reversed().filter { item in
            switch item {
            case .tab(let id):
                source.tab(id: id).map { adoptTabInMemory($0, from: source, activate: false, preservingSpace: true) } ?? false
            case .folder(let id):
                source.folder(id: id).flatMap { adoptSharedFolder($0, from: source, saving: false) } != nil
            }
        }
    }

    private func transfer(_ tab: BrowserTab, from source: BrowserModel, oldIndex: Int, preservingSpace: Bool) {
        // The page leaves as an ordinary tab. Its pin stays in this window and every other one, so the source
        // gets a new unloaded page for it below.
        let wasPin = tab.pinID != nil
        // A micro window shows none of the profile's pins, so a page that reaches one is an ordinary tab even where this
        // window has no pin store to say it was a pin.
        if wasPin || windowKind == .micro {
            tab.pinID = nil
            tab.pinnedURL = nil
            tab.pinnedTitle = ""
            tab.isFavorite = false
        }
        if source.unplacedSpaceRows.remove(.tab(tab.id)) != nil {
            unplacedSpaceRows.insert(.tab(tab.id))
        }
        source.cancelPendingSave()
        cancelPendingSave()
        // Undo snapshots contain tab and tree ownership; neither old stack may replay across a move.
        source.sidebarUndoManager.removeAllActions()
        sidebarUndoManager.removeAllActions()
        source.closedTabs.removeAll { $0.id == tab.id }
        closedTabs.removeAll { $0.id == tab.id }
        func neighbor(in list: [BrowserTab]) -> BrowserTab? {
            let list = list.filter { $0 === tab || $0.microTabID == nil }
            guard let index = list.firstIndex(where: { $0 === tab }) else { return nil }
            return list.dropFirst(index + 1).first ?? list.prefix(index).last
        }
        // A neighbor in the space the source shows comes first, so the source window stays in that space.
        let survivor = source.splits.others(of: tab.id).first.flatMap { source.tabsByID[$0] }
            ?? neighbor(in: source.currentSpaceTabs)
            ?? neighbor(in: source.tabs)
        let wasActive = source.activeTabID == tab.id
        let visitID = source.lastVisitID.removeValue(forKey: tab.id)
        source.splits = source.splits.removing(tab.id)
        source.storedTree = source.reconciledTree().removing([.tab(tab.id)])
        source.tabs.remove(at: oldIndex)
        // The opener stays reachable across the move: here if it lives here, else in the window it stayed in.
        if let id = source.openerByTab.removeValue(forKey: tab.id) {
            if tabsByID[id] != nil {
                openerByTab[tab.id] = id
            } else {
                openerElsewhere[tab.id] = (WeakBrowserModel(model: source), id)
            }
        } else if let there = source.openerElsewhere.removeValue(forKey: tab.id) {
            if there.model.model === self, tabsByID[there.tab] != nil {
                openerByTab[tab.id] = there.tab
            } else {
                openerElsewhere[tab.id] = there
            }
        }
        source.recentlyActive.removeAll { $0 == tab.id }
        source.switcherRecency = nil
        if source.paneInAir == tab.id {
            source.paneInAir = nil
        }
        source.sidebarDidChange()
        if wasPin, let store = source.attachedPinStore {
            source.applyProfilePins(store.pins)
        }
        if wasActive {
            source.activeTabID = survivor?.id
        }
        if let page = tab.liveView {
            AutofillSuggestions.shared.dismiss(in: page)
            page.removeFromSuperview()
        }
        bindCallbacks(to: tab)
        if !preservingSpace {
            tab.spaceID = nil
        }
        insert(tab, after: nil)
        lastVisitID[tab.id] = visitID
        writtenStateGeneration[tab.id] = nil
    }

    /// Transfer a sidebar folder and its whole local subtree in one session write, including device-only pages.
    func adoptSharedFolder(_ folder: TabFolder, from source: BrowserModel, saving: Bool = true) -> Set<UUID>? {
        let root = SidebarItem.folder(folder.id)
        let members = source.reconciledTree().descendants(ofFolder: folder.id).union([root])
        let pages = source.tabs.filter { members.contains(.tab($0.id)) }
        let movedFolders = source.folders.filter { members.contains(.folder($0.id)) }
        func canMove() -> Bool {
            canReceive(from: source) && source.folder(id: folder.id) === folder &&
                members.count == pages.count + movedFolders.count &&
                source.reconciledTree().descendants(ofFolder: folder.id).union([root]) == members &&
                movedFolders.allSatisfy { source.folder(id: $0.id) === $0 && self.folder(id: $0.id) == nil && !$0.isPinned } &&
                pages.allSatisfy { canReceive($0, from: source) && $0.pinID == nil }
        }
        guard canMove() else { return nil }
        for page in pages {
            source.onTabWillTransferOut?(page)
        }
        guard canMove() else { return nil }

        let from = source.reconciledTree()
        let into = reconciledTree()
        let folderIDs = Set(movedFolders.map(\.id))
        let pageIDs = Set(pages.map(\.id))
        let groups = source.splits.splits.filter { $0.tabs.allSatisfy(pageIDs.contains) }
        let moving = source.tabs.enumerated().filter { pageIDs.contains($0.element.id) }
        if let active = source.activeTabID, pageIDs.contains(active) {
            source.activeTabID = source.currentSpaceTabs.first { !pageIDs.contains($0.id) && $0.microTabID == nil }?.id
        }
        for (index, page) in moving.reversed() {
            transfer(page, from: source, oldIndex: index, preservingSpace: !saving)
        }
        source.sidebarUndoManager.removeAllActions()
        sidebarUndoManager.removeAllActions()
        source.storedTree = from.removing(members)
        source.folders.removeAll { folderIDs.contains($0.id) }
        folders.append(contentsOf: movedFolders)
        storedTree = SidebarTree(root: into.root + [root], children: into.children.merging(from.children.filter { folderIDs.contains($0.key) }) { _, held in held })
        splits = TabSplits(splits.splits + groups)
        source.sidebarDidChange()
        syncTabOrder()
        for (index, page) in moving {
            if let opener = openerElsewhere[page.id], opener.model.model === source, pageIDs.contains(opener.tab) {
                openerByTab[page.id] = opener.tab
                openerElsewhere[page.id] = nil
            }
            source.onTabTransferredOut?(page, index)
            onTabTransferredIn?(page, source, index)
        }
        if saving {
            saveTransferredSession(from: source)
        }
        return folderIDs.union(pageIDs)
    }
}
