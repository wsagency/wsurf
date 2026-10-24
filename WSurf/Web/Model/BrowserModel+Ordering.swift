// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

extension BrowserModel {
    // MARK: - Pinning

    func pin(_ tab: BrowserTab) {
        guard let url = URL(string: tab.urlString), !tab.urlString.isEmpty else { return }
        setPin(url, title: tab.title, for: tab)
    }

    func unpin(_ tab: BrowserTab) {
        guard tab.pinnedURL != nil else { return }
        tab.pinnedURL = nil
        tab.pinnedTitle = ""
        tab.isFavorite = false
        moveToPinnedBoundary(tab)
        scheduleSave()
    }

    /// Pins `tab` to `url`. A tab already above the line keeps its place, and a new pinned page is one undo step.
    func setPin(_ url: URL, title: String? = nil, for tab: BrowserTab) {
        let wasPinned = isPinned(.tab(tab.id))
        let previous = tab.pinnedURL.map { (url: $0, title: tab.pinnedTitle) }
        tab.pinnedURL = url
        tab.pinnedTitle = title ?? (tab.pinnedTitle.isEmpty ? tab.title : tab.pinnedTitle)
        if !wasPinned {
            moveToPinnedBoundary(tab)
        } else if let previous, previous.url != url {
            let id = tab.id
            registerSidebarUndo(named: String(localized: "Update Pinned URL")) { model in
                guard let tab = model.tab(id: id) else { return }
                model.setPin(previous.url, title: previous.title, for: tab)
            }
        }
        scheduleSave()
    }

    func renameTab(_ tab: BrowserTab, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != tab.customTitle else { return }
        tab.customTitle = trimmed == tab.pageTitle ? "" : trimmed
        scheduleSave()
    }

    func isKept(_ item: SidebarItem) -> Bool {
        switch item {
        case .tab(let id):
            tabsByID[id]?.pinnedURL != nil
        case .folder(let id):
            foldersByID[id]?.isPinned == true
        }
    }

    /// The pin line: a root row is above it when it is kept, and everything inside a kept root folder is above it at any
    /// depth. Everything above the line is pinned.
    func isPinned(_ item: SidebarItem) -> Bool {
        let tree = reconciledTree()
        var top = item
        while let parent = tree.parent(of: top) {
            top = .folder(parent)
        }
        return isKept(top)
    }

    /// Settles the pinned pages after a change lands: a tab inside a pinned folder that has no pinned page takes the page
    /// it shows now, and a tab inside a folder below the line has none. A root tab is a pin exactly when it has a pinned
    /// page, so it settles itself. Never called while a row is in the air; a drag settles when it lands.
    func settlePinnedPages() {
        let tree = reconciledTree()
        let liveTabs = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for case .folder(let id) in tree.root {
            let pinned = liveFolders[id]?.isPinned == true
            for case .tab(let tabID) in tree.descendants(ofFolder: id) {
                guard let tab = liveTabs[tabID] else { continue }
                if pinned, tab.pinnedURL == nil, !tab.urlString.isEmpty, let url = URL(string: tab.urlString) {
                    tab.pinnedURL = url
                    tab.pinnedTitle = tab.title
                    changed = true
                } else if !pinned, tab.pinnedURL != nil {
                    tab.pinnedURL = nil
                    tab.pinnedTitle = ""
                    tab.isFavorite = false
                    changed = true
                }
            }
        }
        if changed {
            scheduleSave()
        }
    }

    func keptRunAtTop() -> [SidebarItem] {
        var run: [SidebarItem] = []
        for item in sidebarTree.rows(in: nil) {
            guard isKept(item) else { break }
            run.append(item)
        }
        return run
    }

    private func pinnedBoundary(in root: [SidebarItem], ignoring moved: Set<SidebarItem>) -> Int {
        for (index, item) in root.enumerated() where !moved.contains(item) {
            guard isKept(item) else { return index }
        }
        return root.count
    }

    private func moveToPinnedBoundary(_ tab: BrowserTab) {
        let item = SidebarItem.tab(tab.id)
        let rest = reconciledTree().root.filter { $0 != item }
        let boundary = pinnedBoundary(in: rest, ignoring: [])
        move([item], into: nil, before: rest.indices.contains(boundary) ? rest[boundary] : nil)
    }

    func pinAtTop(_ items: [SidebarItem]) {
        let moved = Set(items)
        let rest = reconciledTree().root.filter { !moved.contains($0) }
        let boundary = pinnedBoundary(in: rest, ignoring: [])
        // Pin first: a child of a pinned folder with no pinned page yet would otherwise leave the profile's pins for a moment.
        if flagPinned(true, for: items) {
            scheduleSave()
        }
        move(items, into: nil, before: rest.indices.contains(boundary) ? rest[boundary] : nil, settlingPins: false)
        settlePinnedPages()
    }

    func setPinned(_ pinned: Bool, for items: some Sequence<SidebarItem>) {
        if flagPinned(pinned, for: items) {
            scheduleSave()
        }
        settlePinnedPages()
    }

    /// Pins or unpins the rows themselves; what a folder holds settles afterwards.
    private func flagPinned(_ pinned: Bool, for items: some Sequence<SidebarItem>) -> Bool {
        var changed = false
        for item in items {
            switch item {
            case .folder(let id):
                guard let folder = foldersByID[id], folder.isPinned != pinned else { continue }
                folder.isPinned = pinned
                changed = true
            case .tab(let id):
                guard let tab = tabsByID[id] else { continue }
                if pinned, tab.pinnedURL == nil {
                    guard let url = URL(string: tab.urlString), !tab.urlString.isEmpty else { continue }
                    tab.pinnedURL = url
                    tab.pinnedTitle = tab.title
                    changed = true
                } else if !pinned, tab.pinnedURL != nil {
                    tab.pinnedURL = nil
                    tab.pinnedTitle = ""
                    tab.isFavorite = false
                    changed = true
                }
            }
        }
        return changed
    }

    func pin(_ folder: TabFolder) {
        pinAtTop([.folder(folder.id)])
    }

    func unpin(_ folder: TabFolder) {
        guard folder.isPinned else { return }
        let item = SidebarItem.folder(folder.id)
        let rest = reconciledTree().root.filter { $0 != item }
        let boundary = pinnedBoundary(in: rest, ignoring: [])
        folder.isPinned = false
        move(
            [item],
            into: nil,
            before: rest.indices.contains(boundary) ? rest[boundary] : nil,
            settlingPins: false
        )
        settlePinnedPages()
        scheduleSave()
    }

    func returnToPin(_ tab: BrowserTab) {
        guard let url = tab.pinnedURL else { return }
        activeTabID = tab.id
        tab.load(url)
    }

    // MARK: - Split view

    var activeSplit: TabSplit? {
        guard let activeTabID else { return nil }
        return splits.split(containing: activeTabID)
    }

    var splitPanes: [BrowserTab]? {
        guard let split = activeSplit else { return nil }
        let resolved = split.tabs.compactMap { tabsByID[$0] }
        return resolved.count == split.count ? resolved : nil
    }

    func isVisibleInSplit(_ tab: BrowserTab) -> Bool {
        activeSplit?.contains(tab.id) == true
    }

    func anchorID(of tabID: UUID) -> UUID {
        splits.split(containing: tabID)?.leader ?? tabID
    }

    var activeAnchorID: UUID? {
        activeTabID.map(anchorID(of:))
    }

    func anchorTabs(_ anchorID: UUID) -> [BrowserTab] {
        guard let split = splits.splitLed(by: anchorID) else {
            return tabsByID[anchorID].map { [$0] } ?? []
        }
        return split.tabs.compactMap { tabsByID[$0] }
    }

    func splitOthers(of tab: BrowserTab) -> [BrowserTab] {
        splits.others(of: tab.id).compactMap { tabsByID[$0] }
    }

    func splitFollowers(of tab: BrowserTab) -> [BrowserTab]? {
        guard let split = splits.splitLed(by: tab.id) else { return nil }
        let resolved = split.tabs.dropFirst().compactMap { tabsByID[$0] }
        return resolved.count == split.count - 1 ? resolved : nil
    }

    var hiddenSidebarTabIDs: Set<UUID> {
        splits.followerTabs
    }

    func withSplitMembers(_ items: [SidebarItem]) -> [SidebarItem] {
        items.flatMap { item -> [SidebarItem] in
            guard case .tab(let id) = item, let split = splits.splitLed(by: id) else { return [item] }
            return split.tabs.map(SidebarItem.tab)
        }
    }

    func split(_ anchor: BrowserTab, with tab: BrowserTab, axis: SplitAxis) {
        guard anchor !== tab else { return }
        splits = splits.splitting(anchor.id, with: tab.id, axis: axis)
        settleSplit(containing: anchor)
    }

    func insertIntoSplit(_ tab: BrowserTab, beside anchor: BrowserTab, edge: SplitDropZone) {
        guard anchor !== tab else { return }
        splits = splits.inserting(tab.id, beside: anchor.id, edge: edge)
        settleSplit(containing: anchor)
    }

    func moveSplitPane(_ tab: BrowserTab, beside anchor: BrowserTab, edge: SplitDropZone) {
        guard anchor !== tab else { return }
        splits = splits.moving(tab.id, beside: anchor.id, edge: edge)
        settleSplit(containing: anchor)
    }

    func replaceSplitPane(_ replaced: BrowserTab, with tab: BrowserTab) {
        splits = splits.replacing(replaced.id, with: tab.id)
        settleSplit(containing: tab)
    }

    func removeFromSplit(_ tab: BrowserTab) {
        guard let survivor = splits.others(of: tab.id).first.flatMap({ tabsByID[$0] }) else { return }
        splits = splits.removing(tab.id)
        settleSplit(containing: survivor)
    }

    func dissolveSplit(containing tab: BrowserTab) {
        guard splits.contains(tab.id) else { return }
        splits = splits.dissolving(containing: tab.id)
        scheduleSave()
    }

    func swapSplitRow(containing tab: BrowserTab) {
        splits = splits.swappingRow(containing: tab.id)
        settleSplit(containing: tab)
    }

    func setSplitAxis(_ axis: SplitAxis, containing tab: BrowserTab) {
        splits = splits.setting(axis: axis, containing: tab.id)
        settleSplit(containing: tab)
    }

    func setSplitSeam(_ seam: SplitSeam, containing tab: BrowserTab, leading: CGFloat, minimum: CGFloat) {
        splits = splits.setting(
            seam: seam.index,
            inGroupAt: seam.groupPath,
            containing: tab.id,
            leading: leading,
            minimum: minimum
        )
    }

    private func settleSplit(containing tab: BrowserTab) {
        if let split = splits.split(containing: tab.id) {
            // Favorites are single-tab shortcuts; split groups stay in the sidebar.
            for id in split.tabs {
                tabsByID[id]?.isFavorite = false
            }
            gather(split.tabs)
        }
        reconcileAnchors()
        scheduleSave()
    }

    private func gather(_ ids: [UUID]) {
        guard let leader = ids.first else { return }
        let tree = reconciledTree()
        let anchor = SidebarItem.tab(leader)
        let followers = ids.dropFirst().map(SidebarItem.tab)
        guard !followers.isEmpty else { return }
        move(
            followers,
            into: tree.parent(of: anchor).flatMap(folder(id:)),
            before: tree.successor(of: anchor)
        )
    }

    func close(_ tab: BrowserTab, recordForReopening: Bool = true) {
        guard !tab.isClosed, tabsByID[tab.id] === tab else { return }
        if tab.isMaterialised {
            AutofillSuggestions.shared.dismiss(in: tab.page)
        }
        tab.autofillSave.clear()
        if recordForReopening, !tab.isPrivate {
            let record = ClosedTab(tab, in: self)
            closedTabs.append(record)
            if closedTabs.count > Self.closedTabMemory {
                closedTabs.removeFirst()
            }
            registerSidebarUndo(named: String(localized: "Close Tab")) { model in
                model.restoreClosedTab(record)
            }
        }

        let survivor = splits.others(of: tab.id).first.flatMap { tabsByID[$0] }
        splits = splits.removing(tab.id)
        if activeTabID == tab.id {
            activeTabID = (survivor ?? neighbor(of: tab))?.id
        }
        tabs.removeAll { $0 === tab }
        storedTree = reconciledTree().removing([.tab(tab.id)])
        sidebarDidChange()
        lastVisitID[tab.id] = nil
        openerByTab[tab.id] = nil
        recentlyActive.removeAll { $0 == tab.id }
        onTabClosed?(tab)
        scheduleSave()

        tab.detach()
    }

    private func neighbor(of tab: BrowserTab) -> BrowserTab? {
        let peers = currentSpaceID == nil ? tabs : tabs.filter { $0 === tab || isShown($0) }
        guard let index = peers.firstIndex(where: { $0 === tab }) else {
            return peers.first { $0 !== tab }
        }
        let hidden = hiddenSidebarTabIDs
        let below = peers[peers.index(after: index)...]
        let above = peers[..<index].reversed()
        return below.first { !hidden.contains($0.id) }
            ?? above.first { !hidden.contains($0.id) }
            ?? below.first
            ?? above.first
    }

    static func isPlayingMedia(_ webView: BrowserPage) async -> Bool {
        let script = """
        !!Array.from(document.querySelectorAll('video, audio'))
            .find(m => !m.paused && !m.ended && m.currentTime > 0
                       && !m.muted && m.volume > 0)
        """
        return (try? await webView.evaluateJavaScript(script)) as? Bool ?? false
    }

    /// Pins, and what a pinned folder holds, stay: the person removes those one by one. Other spaces stay too.
    func closeOthers(_ kept: BrowserTab) {
        close(tabs.filter { $0 !== kept && !$0.isPinnedForProfile && isShown($0) }.map { .tab($0.id) })
    }

    func closeActiveTab() {
        if let activeTab {
            close(activeTab)
        }
    }

    func activate(_ tab: BrowserTab) {
        activeTabID = tab.id
        scheduleSave()
    }

    // MARK: - Reopening and cycling

    struct ClosedTab {
        let id: UUID
        let title: String
        let pageTitle: String
        let customTitle: String
        let url: String
        let state: Data?
        let pinnedURL: URL?
        let pinnedTitle: String
        let isFavorite: Bool
        let pinID: UUID?
        let spaceID: UUID?
        let wasActive: Bool
        let folderID: UUID?
        let before: SidebarItem?
        let index: Int
        let split: TabSplit?

        init(_ tab: BrowserTab, in model: BrowserModel) {
            id = tab.id
            title = tab.title
            pageTitle = tab.pageTitle
            customTitle = tab.customTitle
            url = tab.urlString
            state = tab.sessionState
            pinnedURL = tab.pinnedURL
            pinnedTitle = tab.pinnedTitle
            isFavorite = tab.isFavorite
            pinID = tab.pinID
            spaceID = tab.spaceID
            wasActive = model.activeTabID == tab.id
            folderID = model.folder(containing: tab)?.id
            before = model.sidebarTree.successor(of: .tab(tab.id))
            index = model.tabs.firstIndex { $0 === tab } ?? 0
            split = model.splits.split(containing: tab.id)
        }
    }

    private static let closedTabMemory = 20

    var canReopenClosedTab: Bool {
        !closedTabs.isEmpty
    }

    func reopenLastClosedTab() {
        guard let record = closedTabs.popLast() else { return }
        restoreClosedTab(record)
    }

    func activateTab(at index: Int) {
        let tabs = currentSpaceTabs
        guard tabs.indices.contains(index) else { return }
        activate(tabs[index])
    }

    func activateLastTab() {
        if let last = currentSpaceTabs.last {
            activate(last)
        }
    }

    func cycleTab(forward: Bool) {
        let tabs = currentSpaceTabs
        guard tabs.count > 1, let current = tabs.firstIndex(where: { $0.id == activeTab?.id }) else { return }
        let next = forward
            ? (current + 1) % tabs.count
            : (current - 1 + tabs.count) % tabs.count
        activate(tabs[next])
    }

    // MARK: - Folders

    static let defaultFolderName = String(localized: "New Folder")

    @discardableResult
    func createFolder(
        named name: String = defaultFolderName,
        containing items: [SidebarItem] = [],
        requestingRename: Bool = false
    ) -> TabFolder {
        let tree = reconciledTree()
        let order = tree.walk()
        let topmost = tree.normalized(items).min {
            (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max)
        }
        let folder = TabFolder(name: name)
        folders.append(folder)
        if requestingRename {
            folderRenameID = folder.id
            sidebarSelection.dropMarks()
        }
        storedTree = tree.moving(
            [.folder(folder.id)],
            into: topmost.flatMap { tree.parent(of: $0) },
            before: topmost ?? tree.root.first
        ) ?? tree
        sidebarDidChange()
        if !items.isEmpty {
            move(items, into: folder)
            autoName(folder)
        }
        scheduleSave()
        return folder
    }

    @discardableResult
    func createFolder(named name: String = defaultFolderName, containing tabs: [BrowserTab]) -> TabFolder {
        createFolder(named: name, containing: tabs.map { .tab($0.id) })
    }

    func autoName(_ folder: TabFolder) {
        guard folderRenameID != folder.id,
              folder.name == Self.defaultFolderName,
              LLMSettings.$scoped.withValue(context.modelSettings, operation: { FolderNamer.isAvailable })
        else { return }
        let titles = tabs(in: folder).map(\.title)
        let revision = folder.nameRevision
        let context = context
        Task { [weak self, weak folder] in
            guard let suggestion = await LLMSettings.$scoped.withValue(context.modelSettings, operation: {
                await FolderNamer.suggestName(forTitles: titles)
            }) else { return }
            guard let self, let folder, self.context === context, context.isRegistered(self),
                  folders.contains(where: { $0 === folder }),
                  folderRenameID != folder.id,
                  folder.nameRevision == revision,
                  folder.name == Self.defaultFolderName
            else { return }
            folder.name = suggestion
            scheduleSave()
        }
    }

    func renameFolder(_ folder: TabFolder, to name: String) {
        folder.nameRevision += 1
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        folder.name = trimmed
        scheduleSave()
    }

    func setFolderColor(_ color: TabFolderColor, for folder: TabFolder) {
        guard folder.color != color else { return }
        folder.color = color
        scheduleSave()
    }

    /// One undo step. A pinned folder's size goes to the profile with the rest of its row.
    func setFolderSize(_ size: TabFolderSize, for folder: TabFolder) {
        guard foldersByID[folder.id] === folder, folder.size != size else { return }
        let previous = folder.size
        let id = folder.id
        registerSidebarUndo(named: String(localized: "Change Folder Size")) { model in
            guard let folder = model.folder(id: id) else { return }
            model.setFolderSize(previous, for: folder)
        }
        folder.size = size
        scheduleSave()
    }

    func deleteFolder(_ folder: TabFolder) {
        let tree = reconciledTree()
        guard foldersByID[folder.id] === folder else { return }
        let parentID = tree.parent(of: .folder(folder.id))
        let before = tree.successor(of: .folder(folder.id))
        let children = tree.rows(in: folder.id)
        registerSidebarUndo(named: String(localized: "Delete Folder")) { model in
            model.restoreFolder(folder, parentID: parentID, before: before, children: children)
        }
        let next = tree.dissolving(folder.id)
        storedTree = tree.parent(of: .folder(folder.id)) == nil
            ? next.keepingPinsAtRootTop(isKept)
            : next
        folders.removeAll { $0 === folder }
        syncTabOrder()
        settlePinnedPages()
        scheduleSave()
        finishFolderRename(folder.id)
        sidebarSelection.takeKeyboard()
    }

    func move(_ tab: BrowserTab, to folder: TabFolder?) {
        if let folder {
            move([.tab(tab.id)], into: folder)
        } else {
            moveOut([.tab(tab.id)])
        }
    }

    func move(
        _ items: [SidebarItem],
        into folder: TabFolder?,
        before target: SidebarItem? = nil,
        settlingPins: Bool = true
    ) {
        let tree = reconciledTree()
        let moved = tree.normalized(items)
        guard !moved.isEmpty, let next = tree.moving(moved, into: folder?.id, before: target) else { return }
        storedTree = next
        if let folder {
            folder.isExpanded = true
            autoName(folder)
        }
        syncTabOrder()
        // A page filed in a pinned folder is pinned and one filed below the line is not; a drag settles when it lands.
        if settlingPins {
            settlePinnedPages()
        }
        scheduleSave()
    }

    func moveOut(_ items: [SidebarItem]) {
        let tree = reconciledTree()
        let moved = tree.normalized(items)
        guard let first = moved.first, let left = tree.parent(of: first) else { return }
        let folder = SidebarItem.folder(left)
        let destination = tree.parent(of: folder)
        guard let next = tree.moving(moved, into: destination, before: tree.successor(of: folder))
        else { return }
        storedTree = destination == nil ? next.keepingPinsAtRootTop(isKept) : next
        syncTabOrder()
        settlePinnedPages()
        scheduleSave()
    }

    // MARK: - Sorting a folder

    enum FolderSort {
        case byName
        case foldersFirst
    }

    /// The rows the sidebar draws in a folder. A split's other panes sit behind their leader and are not rows.
    private func drawnRows(in folder: TabFolder) -> [SidebarItem] {
        reconciledTree().rows(in: folder.id).filter {
            guard case .tab(let id) = $0 else { return true }
            return !splits.isFollower(id)
        }
    }

    func canSortChildren(of folder: TabFolder) -> Bool {
        drawnRows(in: folder).count > 1
    }

    /// One-time reorder of the folder's direct children. Subfolders keep their own order. Both sorts are stable.
    func sortChildren(of folder: TabFolder, _ sort: FolderSort) {
        guard foldersByID[folder.id] === folder else { return }
        let rows = drawnRows(in: folder)
        let sorted: [SidebarItem]
        switch sort {
        case .byName:
            let names = rows.map { item -> String in
                switch item {
                case .tab(let id):
                    tabsByID[id]?.title ?? ""
                case .folder(let id):
                    foldersByID[id]?.name ?? ""
                }
            }
            sorted = rows.indices.sorted {
                switch names[$0].localizedStandardCompare(names[$1]) {
                case .orderedAscending:
                    true
                case .orderedDescending:
                    false
                case .orderedSame:
                    $0 < $1
                }
            }.map { rows[$0] }
        case .foldersFirst:
            let isFolder: (SidebarItem) -> Bool = {
                if case .folder = $0 {
                    return true
                }
                return false
            }
            sorted = rows.filter(isFolder) + rows.filter { !isFolder($0) }
        }
        setChildOrder(of: folder.id, to: sorted)
    }

    /// Reorders a folder's children in place, as one undo step. A child that has left the folder since `order`
    /// was recorded stays out, and one that joined keeps its place behind the others, so an undo cannot pull rows back.
    private func setChildOrder(of folderID: UUID, to order: [SidebarItem]) {
        let tree = reconciledTree()
        let current = tree.rows(in: folderID)
        let live = Set(current)
        var placed: Set<SidebarItem> = []
        let wanted = withSplitMembers(order).filter { live.contains($0) && placed.insert($0).inserted }
        guard let next = tree.moving(wanted + current.filter { !placed.contains($0) }, into: folderID, before: nil)
        else { return }
        registerSidebarUndo(named: String(localized: "Sort Folder")) { model in
            model.setChildOrder(of: folderID, to: current)
        }
        storedTree = next
        syncTabOrder()
        scheduleSave()
    }

    func close(_ items: [SidebarItem]) {
        sidebarUndoManager.beginUndoGrouping()
        defer { sidebarUndoManager.endUndoGrouping() }
        let all = sidebarTree.walk().filter(sidebarTree.expanded(Set(items)).contains)
        for case .tab(let id) in all {
            if let tab = tabsByID[id] {
                close(tab)
            }
        }
        for case .folder(let id) in all {
            if let folder = foldersByID[id] {
                deleteFolder(folder)
            }
        }
        sidebarSelection.takeKeyboard()
    }

    func tabs(under items: [SidebarItem]) -> [BrowserTab] {
        let wanted = sidebarTree.expanded(Set(items))
        return sidebarTree.walk().compactMap { item in
            guard wanted.contains(item), case .tab(let id) = item else { return nil }
            return tabsByID[id]
        }
    }

    func tabCount(in items: [SidebarItem]) -> Int {
        sidebarTree.expanded(Set(items)).filter { if case .tab = $0 { true } else { false } }.count
    }

    func folder(id: UUID) -> TabFolder? {
        foldersByID[id]
    }

    func folder(containing tab: BrowserTab) -> TabFolder? {
        sidebarTree.parent(of: .tab(tab.id)).flatMap(folder(id:))
    }

    func folder(containing folder: TabFolder) -> TabFolder? {
        sidebarTree.parent(of: .folder(folder.id)).flatMap(folder(id:))
    }

    var sidebarItems: [SidebarItem] {
        sidebarTree.root.filter { !isFavorite($0) }
    }

    func reconciledTree() -> SidebarTree {
        SidebarTree.reconcile(stored: storedTree, folders: folders.map(\.id), tabs: tabs.map(\.id))
    }

    func place(_ items: [SidebarItem], in parent: UUID?, before target: SidebarItem?) {
        guard let next = reconciledTree().moving(items, into: parent, before: target) else { return }
        storedTree = next
    }

    func tab(id: UUID) -> BrowserTab? {
        tabsByID[id]
    }

    func sidebarDidChange() {
        tabsByID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tree = reconciledTree()
        settleSpaces(in: tree)
        sidebarTree = currentSpaceID == nil ? tree : tree.keepingRoot(where: isShown)
        splits = splits.reconciled(against: Set(tabsByID.keys))
        reconcileAnchors()
    }

    private func reconcileAnchors() {
        let current = Dictionary(tabs.map { ($0.id, anchorID(of: $0.id)) }, uniquingKeysWith: { first, _ in first })
        let previous = tabAnchors
        tabAnchors = current
        guard !previous.isEmpty, let onAnchorChanged else { return }

        let names = Set(current.values)
        for name in Set(previous.values) where !names.contains(name) {
            let members = previous.filter { $0.value == name }.keys
            let successors = Set(members.compactMap { current[$0] })
            guard successors.count == 1, let successor = successors.first, successor != name else { continue }
            onAnchorChanged(name, successor)
        }
    }

    func syncTabOrder() {
        let byID = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = reconciledTree().flattenedTabs(known: Set(byID.keys))
        let placed = Set(ordered)
        tabs = ordered.compactMap { byID[$0] } + tabs.filter { !placed.contains($0.id) }
        sidebarDidChange()
    }

    func rows(in folder: TabFolder?) -> [SidebarItem] {
        sidebarTree.rows(in: folder?.id).filter { !isFavorite($0) }
    }

    func tabs(in folder: TabFolder) -> [BrowserTab] {
        rows(in: folder).compactMap { item in
            guard case .tab(let id) = item else { return nil }
            return tabsByID[id]
        }
    }

    func allTabs(in folder: TabFolder) -> [BrowserTab] {
        sidebarTree.descendants(ofFolder: folder.id).compactMap { item in
            guard case .tab(let id) = item else { return nil }
            return tabsByID[id]
        }
    }

    var ungroupedTabs: [BrowserTab] {
        sidebarTree.root.compactMap { item in
            guard case .tab(let id) = item else { return nil }
            return tabsByID[id]
        }
    }
}
