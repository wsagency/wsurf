// SPDX-FileCopyrightText: 2026 wsagency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension BrowserModel {
    func registerSidebarUndo(named name: String, action: @escaping (BrowserModel) -> Void) {
        let ownsGroup = sidebarUndoManager.groupingLevel == 0
        if ownsGroup {
            sidebarUndoManager.beginUndoGrouping()
        }
        sidebarUndoManager.registerUndo(withTarget: self, handler: action)
        sidebarUndoManager.setActionName(name)
        if ownsGroup {
            sidebarUndoManager.endUndoGrouping()
        }
    }

    func restoreClosedTab(_ record: ClosedTab) {
        guard tabsByID[record.id] == nil else { return }
        let tab = makeTab(for: URL(string: record.url), id: record.id, restoring: true)
        tab.pageTitle = record.pageTitle
        tab.customTitle = record.customTitle
        tab.urlString = record.url
        tab.pinnedURL = record.pinnedURL
        tab.pinnedTitle = record.pinnedTitle
        tab.isFavorite = record.isFavorite
        tab.deferRestore(state: record.state, url: URL(string: record.url))
        tabs.insert(tab, at: min(record.index, tabs.count))
        let parent = record.folderID.flatMap { folder(id: $0) }
        let siblings = reconciledTree().rows(in: parent?.id)
        place([.tab(tab.id)], in: parent?.id, before: record.before.flatMap { siblings.contains($0) ? $0 : nil })
        if let split = record.split, sidebarUndoManager.isUndoing || sidebarUndoManager.isRedoing {
            let members = Set(split.tabs)
            splits = TabSplits(splits.splits.filter { members.isDisjoint(with: $0.tabs) } + [split])
                .reconciled(against: Set(tabs.map(\.id)))
        }
        closedTabs.removeAll { $0.id == record.id }
        sidebarDidChange()
        onTabOpened?(tab)
        if !sidebarUndoManager.isUndoing || record.wasActive {
            activeTabID = tab.id
        } else if isVisibleInSplit(tab) {
            tab.realizeDeferredSession()
        }
        registerSidebarUndo(named: String(localized: "Close Tab")) { model in
            guard let restored = model.tab(id: record.id) else { return }
            model.close(restored)
        }
        sidebarSelection.takeKeyboard()
        scheduleSave()
    }

    func restoreFolder(
        _ folder: TabFolder,
        parentID: UUID?,
        before: SidebarItem?,
        children: [SidebarItem]
    ) {
        guard foldersByID[folder.id] == nil else { return }
        folders.append(folder)
        let parent = parentID.flatMap { self.folder(id: $0) }
        let siblings = reconciledTree().rows(in: parent?.id)
        place([.folder(folder.id)], in: parent?.id, before: before.flatMap { siblings.contains($0) ? $0 : nil })
        let live = Set(reconciledTree().walk())
        place(children.filter(live.contains), in: folder.id, before: nil)
        syncTabOrder()
        registerSidebarUndo(named: String(localized: "Delete Folder")) { model in
            model.deleteFolder(folder)
        }
        sidebarSelection.takeKeyboard()
        scheduleSave()
    }

    @discardableResult
    func createFolderForRenaming(containing items: [SidebarItem]) -> TabFolder {
        let folder = createFolder(containing: items, requestingRename: true)
        var parent = sidebarTree.parent(of: .folder(folder.id))
        while let id = parent {
            self.folder(id: id)?.isExpanded = true
            parent = sidebarTree.parent(of: .folder(id))
        }
        scheduleSave()
        return folder
    }

    func finishFolderRename(_ id: UUID) {
        if folderRenameID == id {
            folderRenameID = nil
        }
    }

    var favorites: [BrowserTab] {
        sidebarTree.walk().compactMap { item in
            guard case .tab(let id) = item, let tab = tabsByID[id], tab.isFavorite else { return nil }
            return tab
        }
    }

    func isFavorite(_ item: SidebarItem) -> Bool {
        guard case .tab(let id) = item else { return false }
        return tabsByID[id]?.isFavorite == true
    }

    func addFavorite(_ tab: BrowserTab) {
        guard tabsByID[tab.id] === tab, !tab.isFavorite,
              let url = URL(string: tab.urlString), !tab.urlString.isEmpty
        else { return }
        dissolveSplit(containing: tab)
        if tab.pinnedURL == nil {
            setPin(url, title: tab.title, for: tab)
        }
        pinAtTop([.tab(tab.id)])
        tab.isFavorite = true
        tab.realizeDeferredSession()
        scheduleSave()
    }

    func removeFavorite(_ tab: BrowserTab) {
        guard tabsByID[tab.id] === tab, tab.isFavorite else { return }
        setFavorite(false, for: tab.id)
        sidebarSelection.takeKeyboard()
    }

    private func setFavorite(_ favorite: Bool, for id: UUID) {
        guard let tab = tabsByID[id], tab.isFavorite != favorite else { return }
        registerSidebarUndo(named: String(localized: "Remove from Favorites")) { model in
            model.setFavorite(!favorite, for: id)
        }
        if favorite {
            dissolveSplit(containing: tab)
        }
        tab.isFavorite = favorite
        scheduleSave()
    }
}
