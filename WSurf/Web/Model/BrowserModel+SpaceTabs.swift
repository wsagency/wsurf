// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Where a row sits in the profile's tree. Two sets with the same shapes differ only in titles, addresses and looks.
struct SpaceRowShape: Equatable {
    var id: UUID
    var parentID: UUID?
    var orderKey: String
    var kind: SpaceRow.Kind
    var spaceID: UUID

    init(_ row: SpaceRow) {
        (id, parentID, orderKey, kind, spaceID) = (row.id, row.parentID, row.orderKey, row.kind, row.spaceID)
    }
}

/// What a linked tab last agreed with its row: see `BrowserModel.sharedPage(of:earlier:)`.
struct SpaceTabSeen: Equatable {
    var url: String
    var title: String
}

/// While `BrowserSettings.sharesSpaceTabsAcrossWindows` is on, every regular window of a profile shows the same ordinary
/// tabs and folders in each Space, the way it shows the profile's pins. The rows live in the profile's `ProfilePinStore`.
/// Each window holds its own `BrowserTab` for a row, linked by `BrowserTab.spaceTabID`, so a page is only ever in one
/// window: a copy another window has not shown stays unloaded. Each window keeps its own selection and Space on screen.
/// Private, micro and Agent Micro windows never attach.
extension BrowserModel {
    var sharesSpaceTabs: Bool {
        windowKind == .standard && !opensPrivately && !isEphemeralAgentWindow
            && (sharesSpaceTabsOverride ?? context.settings.sharesSpaceTabsAcrossWindows)
    }

    /// Shows the profile's Space rows in this window and adds the window's own rows that the profile lacks.
    func attachSpaceRows() {
        guard let store = attachedPinStore, store.spaceRowsAvailable, sharesSpaceTabs else { return }
        applySpaceRows(store.spaceRows)
        publishSpaceRows()
    }

    /// Sends this window's version of the rows to the profile when it differs. Called before every session save. A
    /// window that does not know the profile's Spaces yet sends nothing, so it can never replace the rows with fewer.
    func publishSpaceRows() {
        guard let store = attachedPinStore, store.spaceRowsAvailable, sharesSpaceTabs, sessionClosedAt == nil,
              !isApplyingProfilePins, !store.isApplying else { return }
        guard pendingSpaceStore == nil, !knownSpaceIDs.isEmpty else {
            // This window has no rows to add, so a pin it removed was closed, not unpinned: close what the other windows
            // kept for it, as they did before windows shared their tabs.
            store.closeUnclaimedPinPages(except: self)
            return
        }
        // A link the profile never received would read as a row another window closed.
        let links = Dictionary(tabs.map { ($0.id, $0.spaceTabID) }, uniquingKeysWith: { first, _ in first })
        var next = spaceRowProjection(previous: store.spaceRows)
        SpaceRow.assignOrderKeys(&next, previous: store.spaceRows)
        let ordered = SpaceRow.depthFirst(next)
        if store.publishSpaceRows(ordered, from: self) {
            spaceFolderIDs = Set(next.filter { $0.kind == .folder }.map(\.id))
            spaceRowShape = ordered.map(SpaceRowShape.init)
        } else {
            for tab in tabs where tab.spaceTabID != links[tab.id].flatMap({ $0 }) {
                tab.spaceTabID = links[tab.id].flatMap { $0 }
            }
        }
    }

    /// Publishes after a short wait. A page whose title keeps changing (an unread count, a timer) would otherwise rewrite
    /// the rows on every change. A change of the sidebar still publishes at once, from `scheduleSave`.
    func scheduleSpaceRowsPublish() {
        guard sharesSpaceTabs, attachedPinStore != nil, spaceRowsPublishTask == nil else { return }
        spaceRowsPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.spaceRowsPublishTask = nil
            self?.publishSpaceRows()
        }
    }

    /// The other attached windows' pages for `link`.
    func spaceTabCopies(of link: UUID) -> [(model: BrowserModel, tab: BrowserTab)] {
        (attachedPinStore?.attachedWindows ?? []).compactMap { model in
            guard model !== self, model.sharesSpaceTabs, let tab = model.tabs.first(where: { $0.spaceTabID == link }) else { return nil }
            return (model, tab)
        }
    }

    // MARK: - Projection

    /// Every ordinary root of a known Space, with what its folders hold, as rows in display order. Links each included
    /// tab to its row, giving a new row an ID, and unlinks every other tab. At the top level, a page that has never left
    /// the Start page, an internal page and a micro window's row stay this window's own until they show a page of their own.
    func spaceRowProjection(previous: [SpaceRow]) -> [SpaceRow] {
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveTabs = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tree = reconciledTree()
        var rows: [SpaceRow] = []
        var used: Set<UUID> = []
        var linked: Set<UUID> = []
        let pending = Set(pendingPinDemotions.values)

        func add(_ item: SidebarItem, under parent: UUID?, space: UUID) {
            switch item {
            case .tab(let id):
                // A folder's rows go with it, blank or not; at the top level only a page of its own joins.
                guard let tab = liveTabs[id], tab.extensionBaseURL == nil, !tab.isPrivate, tab.pinID == nil, tab.pinnedURL == nil,
                      !pending.contains(id),
                      tab.spaceTabID != nil || (Self.isOwnPage(tab) && !tab.staysInItsWindow) || (parent != nil && tab.microTabID == nil)
                else { return }
                var link = tab.spaceTabID ?? tab.id
                if !used.insert(link).inserted {
                    link = UUID()
                    used.insert(link)
                }
                if tab.spaceTabID != link {
                    tab.spaceTabID = link
                }
                linked.insert(id)
                let page = sharedPage(of: tab, earlier: known[link])
                rows.append(SpaceRow(
                    id: link, parentID: parent, orderKey: "", kind: .tab, spaceID: space,
                    url: page.url, title: page.title, customTitle: tab.customTitle.isEmpty ? nil : tab.customTitle
                ))
            case .folder(let id):
                guard let folder = liveFolders[id], !folder.isPinned, !profileFolderIDs.contains(id), used.insert(id).inserted else { return }
                rows.append(SpaceRow(
                    id: id, parentID: parent, orderKey: "", kind: .folder, spaceID: space,
                    title: folder.name, color: folder.color, isExpanded: folder.isExpanded,
                    sizeFactor: folder.size.storedFactor, tintsIcons: folder.tintsIcons ? true : nil,
                    customColor: folder.customColor?.hex, symbol: folder.symbol
                ))
                for child in tree.rows(in: id) {
                    add(child, under: id, space: space)
                }
            }
        }

        for item in tree.root where !unplacedSpaceRows.contains(item) {
            // What a folder holds belongs to the folder's Space.
            let space: UUID?
            switch item {
            case .tab(let id):
                space = liveTabs[id]?.pinnedURL == nil ? liveTabs[id]?.spaceID : nil
            case .folder(let id):
                space = liveFolders[id]?.isPinned == false ? liveFolders[id]?.spaceID : nil
            }
            // A shared row keeps a Space this window has not learned yet; a row of its own needs one it knows.
            guard let space, knownSpaceIDs.contains(space) || Self.isLinked(item, tabs: liveTabs, folders: spaceFolderIDs) else { continue }
            add(item, under: nil, space: space)
        }
        for tab in tabs where tab.spaceTabID != nil && !linked.contains(tab.id) && !pending.contains(tab.id) {
            tab.spaceTabID = nil
        }
        return rows
    }

    private static func isLinked(_ item: SidebarItem, tabs: [UUID: BrowserTab], folders: Set<UUID>) -> Bool {
        switch item {
        case .tab(let id):
            tabs[id]?.spaceTabID != nil
        case .folder(let id):
            folders.contains(id)
        }
    }

    private static func isOwnPage(_ tab: BrowserTab) -> Bool {
        tab.microTabID == nil && tab.internalPage == nil && !tab.urlString.isEmpty && !SystemPages.isStart(URL(string: tab.urlString))
    }

    /// The address and title a tab gives its row. Only a change this window made counts: a loaded copy that another
    /// window navigated keeps its own page and never sends it back, and a copy that is not loaded repeats its row.
    func sharedPage(of tab: BrowserTab, earlier: SpaceRow?) -> SpaceTabSeen {
        let seen = spaceTabSeen[tab.id]
        let current = SpaceTabSeen(url: tab.urlString, title: tab.pageTitle)
        spaceTabSeen[tab.id] = current
        guard let earlier, let seen else { return current }
        let url = tab.urlString != seen.url ? tab.urlString : earlier.url
        let title = url == tab.urlString && current != seen ? tab.pageTitle : earlier.title
        return SpaceTabSeen(url: url, title: title)
    }

    // MARK: - Applying the rows

    /// Makes this window show `rows`. A row this window has no page for gets an unloaded one; a page of a row that is gone
    /// closes. A page this window has loaded keeps its own address. The window's own rows keep their places.
    func applySpaceRows(_ rows: [SpaceRow]) {
        guard sharesSpaceTabs, attachedPinStore != nil else { return }
        isApplyingProfilePins = true
        defer { isApplyingProfilePins = false }
        let shape = rows.map(SpaceRowShape.init)
        let pages = Set(tabs.compactMap(\.spaceTabID))
        if pendingPinDemotions.isEmpty, shape == spaceRowShape,
           rows.allSatisfy({ $0.kind == .folder ? foldersByID[$0.id] != nil : pages.contains($0.id) }) {
            // Only titles, addresses or looks changed: the sidebar keeps its places.
            _ = upsertSpaceItems(rows)
            return
        }
        sidebarDidChange()

        let wanted = Set(rows.map(\.id))
        for tab in tabs where tab.spaceTabID.map(wanted.contains) == false {
            close(tab, recordForReopening: false)
        }
        for id in spaceFolderIDs where !wanted.contains(id) && !profileFolderIDs.contains(id) {
            guard foldersByID[id]?.isPinned == false else { continue }
            storedTree = reconciledTree().dissolving(id)
            folders.removeAll { $0.id == id }
            finishFolderRename(id)
        }
        let items = upsertSpaceItems(rows)
        sidebarDidChange()

        var root: [SidebarItem] = []
        var children: [UUID: [SidebarItem]] = [:]
        for row in rows {
            guard let item = items[row.id] else { continue }
            if let parent = row.parentID, items[parent] != nil {
                children[parent, default: []].append(item)
            } else {
                root.append(item)
            }
        }
        let shared = Set(items.values)
        // Each place a shared row held takes the next shared row in the profile's order; new rows come last.
        func merged(_ prior: [SidebarItem], with next: [SidebarItem]) -> [SidebarItem] {
            var queue = next[...]
            let kept = prior.compactMap { item -> SidebarItem? in
                shared.contains(item) ? queue.popFirst() : item
            }
            return kept + queue
        }
        let tree = reconciledTree()
        var nested = tree.children
        for parent in Set(tree.children.keys).union(children.keys) {
            nested[parent] = merged(tree.rows(in: parent), with: children[parent] ?? [])
        }
        storedTree = SidebarTree(root: merged(tree.root, with: root), children: nested)
        spaceFolderIDs = Set(rows.filter { $0.kind == .folder }.map(\.id))
        spaceRowShape = shape
        closeUnclaimedPinPages()
        syncTabOrder()
        // Another window can carry the selected row to a Space this window does not show.
        if let active = activeTab, !isShown(active) {
            activeTabID = firstShownTab?.id
        }
    }

    private func upsertSpaceItems(_ rows: [SpaceRow]) -> [UUID: SidebarItem] {
        var pages: [UUID: BrowserTab] = [:]
        for tab in tabs {
            guard let link = tab.spaceTabID else { continue }
            if pages[link] == nil {
                pages[link] = tab
            } else {
                tab.spaceTabID = nil
            }
        }
        // A row a window started has that window's tab ID. A session saved before its link (a crash between the two
        // writes) still holds that tab, so it takes the row instead of a second page. A page whose pin another window turned
        // into this row keeps its loaded state the same way.
        let tabRows = Set(rows.lazy.filter { $0.kind == .tab }.map(\.id))
        for tab in tabs where tab.spaceTabID == nil && pages[tab.id] == nil && tabRows.contains(tab.id) && Self.canTakeRow(tab) {
            tab.spaceTabID = tab.id
            pages[tab.id] = tab
        }
        for (pin, id) in pendingPinDemotions where tabRows.contains(pin) && pages[pin] == nil {
            guard let tab = tabs.first(where: { $0.id == id }), tab.spaceTabID == nil else { continue }
            tab.spaceTabID = pin
            pages[pin] = tab
            pendingPinDemotions[pin] = nil
        }
        var liveFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [UUID: SidebarItem] = [:]
        for row in rows {
            switch row.kind {
            case .folder:
                if liveFolders[row.id] == nil {
                    let folder = TabFolder(id: row.id, name: row.title)
                    folder.spaceID = row.spaceID
                    folders.append(folder)
                    liveFolders[row.id] = folder
                }
                guard let folder = liveFolders[row.id], !folder.isPinned else { continue }
                assign(\.name, to: row.title, on: folder)
                assign(\.spaceID, to: row.spaceID, on: folder)
                assign(\.color, to: row.color ?? .gray, on: folder)
                assign(\.isExpanded, to: row.isExpanded, on: folder)
                assign(\.size, to: .stored(row.sizeFactor), on: folder)
                assign(\.tintsIcons, to: row.tintsIcons ?? false, on: folder)
                assign(\.customColor, to: row.customColor.flatMap(CustomFolderColor.init(hex:)), on: folder)
                assign(\.symbol, to: row.symbol, on: folder)
                items[row.id] = .folder(row.id)
            case .tab:
                let tab = pages[row.id] ?? makeUnloadedPage(at: row.url, title: row.title) { page in
                    page.spaceTabID = row.id
                    page.spaceID = row.spaceID
                }
                pages[row.id] = tab
                assign(\.spaceID, to: row.spaceID, on: tab)
                assign(\.customTitle, to: row.customTitle ?? "", on: tab)
                // A micro window's row shows what that window's page shows (`AppCoordinator.mirror`), not the row's copy.
                if tab.microTabID == nil, tab.isDeferred || !tab.isMaterialised {
                    if tab.urlString != row.url, let url = URL(string: row.url), !row.url.isEmpty {
                        tab.applySharedURL(url)
                        if let host = url.host() {
                            dressRow(tab, fromHost: host)
                        }
                    }
                    assign(\.pageTitle, to: row.title.isEmpty ? tab.pageTitle : row.title, on: tab)
                }
                spaceTabSeen[tab.id] = SpaceTabSeen(url: tab.urlString, title: tab.pageTitle)
                unplacedSpaceRows.remove(.tab(tab.id))
                items[row.id] = .tab(tab.id)
            }
        }
        return items
    }

    func awaitsPinOutcome(_ item: SidebarItem) -> Bool {
        guard !pendingPinDemotions.isEmpty, case .tab(let id) = item else { return false }
        return pendingPinDemotions.values.contains(id)
    }

    private static func canTakeRow(_ tab: BrowserTab) -> Bool {
        tab.pinID == nil && tab.pinnedURL == nil && tab.microTabID == nil && tab.extensionBaseURL == nil && !tab.isPrivate
    }

    /// The window that removed a pin has published its rows. A page no row took was a pin it closed, so it closes here too.
    func closeUnclaimedPinPages() {
        let unclaimed = pendingPinDemotions.values
        pendingPinDemotions = [:]
        // Closing what the profile already removed records nothing for iCloud and publishes nothing.
        let applying = isApplyingProfilePins
        isApplyingProfilePins = true
        defer { isApplyingProfilePins = applying }
        for id in unclaimed {
            if let tab = tab(id: id) {
                close(tab, recordForReopening: false)
            }
        }
    }

    // MARK: - Turning sharing on and off

    /// Follows a change of the setting in every open window of one profile. Turning it on shows each window every other
    /// window's rows. Turning it off leaves the rows in `keeper`, the window whose rows iCloud follows when it does, and
    /// takes the copies out of every other window without closing anything the person sees as a tab.
    static func spaceTabSharingChanged(in models: [BrowserModel], keeper: BrowserModel?) {
        let windows = models.filter { $0.windowKind == .standard && !$0.opensPrivately && !$0.isEphemeralAgentWindow && $0.sessionClosedAt == nil }
        guard let first = windows.first else { return }
        if first.sharesSpaceTabs {
            for model in windows {
                model.attachSpaceRows()
                model.scheduleSave()
            }
            return
        }
        let keeper = keeper.flatMap { model in windows.first { $0 === model } } ?? first
        for model in windows where model !== keeper {
            model.dropSpaceCopies()
        }
        for tab in keeper.tabs {
            tab.spaceTabID = nil
        }
        keeper.spaceFolderIDs = []
        keeper.spaceTabSeen = [:]
        keeper.scheduleSave()
        keeper.attachedPinStore?.publishSpaceRows([])
    }

    private func dropSpaceCopies() {
        isApplyingProfilePins = true
        for tab in tabs where tab.spaceTabID != nil {
            close(tab, recordForReopening: false)
        }
        for id in spaceFolderIDs where !profileFolderIDs.contains(id) {
            storedTree = reconciledTree().dissolving(id)
            folders.removeAll { $0.id == id }
            finishFolderRename(id)
        }
        spaceFolderIDs = []
        spaceTabSeen = [:]
        sidebarDidChange()
        isApplyingProfilePins = false
        if activeTabID == nil {
            newTab()
        }
        scheduleSave()
    }
}
