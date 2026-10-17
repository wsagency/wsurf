// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A profile's pins, pinned folders and Favorites are shared by every regular window of the profile. Each window
/// holds its own `BrowserTab` for a pin, linked by `BrowserTab.pinID`, so navigating or unloading one window's page
/// never touches another's. Changing the set changes it in every open window at once.
extension BrowserModel {
    var pinStore: ProfilePinStore {
        .store(for: database)
    }

    /// Shows the profile's pins in this window and adopts the window's own kept items that the profile lacks.
    func attachProfilePins() {
        guard attachedPinStore == nil, sessionClosedAt == nil else { return }
        let store = pinStore
        guard store.isAvailable else { return }
        attachedPinStore = store
        store.subscribe(self)
        applyProfilePins(store.pins)
        publishProfilePins()
    }

    /// A window that leaves its profile or closes stops publishing, so it can never replace the set with an empty one.
    func detachProfilePins() {
        attachedPinStore?.unsubscribe(self)
        attachedPinStore = nil
        profileFolderIDs = []
    }

    /// Sends this window's version of the set to the profile when it differs. Called before every session save.
    func publishProfilePins() {
        guard let store = attachedPinStore, sessionClosedAt == nil, !isApplyingProfilePins else { return }
        var next = profilePinProjection(previous: store.pins)
        ProfilePin.assignOrderKeys(&next, previous: store.pins)
        profileFolderIDs = Set(next.filter { $0.kind == .folder }.map(\.id))
        store.publish(next, from: self)
    }

    /// The window's kept root items and everything inside its kept folders, as profile rows in display order.
    /// Links each included tab to its pin, giving a new pin an ID, and unlinks every other tab.
    func profilePinProjection(previous: [ProfilePin]) -> [ProfilePin] {
        let liveTabs = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let liveFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let followers = splits.followerTabs
        let tree = reconciledTree()
        var pins: [ProfilePin] = []
        var usedIDs: Set<UUID> = []
        var linked: Set<UUID> = []

        func add(_ item: SidebarItem, under parent: UUID?) {
            switch item {
            case .tab(let id):
                guard let tab = liveTabs[id], tab.extensionBaseURL == nil else { return }
                // A split pulls its panes together, so a loose pane can land inside a kept folder.
                if followers.contains(id), tab.pinID == nil, tab.pinnedURL == nil {
                    return
                }
                var pinID = tab.pinID ?? UUID()
                if !usedIDs.insert(pinID).inserted {
                    pinID = UUID()
                    usedIDs.insert(pinID)
                }
                if tab.pinID != pinID {
                    tab.pinID = pinID
                }
                linked.insert(id)
                let earlier = known[pinID]
                pins.append(ProfilePin(
                    id: pinID,
                    parentID: parent,
                    orderKey: "",
                    kind: .tab,
                    url: tab.pinnedURL?.absoluteString ?? earlier?.url ?? tab.urlString,
                    title: earlier?.title ?? tab.pageTitle,
                    customTitle: tab.customTitle.isEmpty ? nil : tab.customTitle,
                    pinnedURL: tab.pinnedURL,
                    pinnedTitle: tab.pinnedTitle.isEmpty ? nil : tab.pinnedTitle,
                    isFavorite: tab.isFavorite
                ))
            case .folder(let id):
                guard let folder = liveFolders[id], usedIDs.insert(id).inserted else { return }
                pins.append(ProfilePin(
                    id: id,
                    parentID: parent,
                    orderKey: "",
                    kind: .folder,
                    title: folder.name,
                    color: folder.color,
                    isExpanded: folder.isExpanded,
                    isPinned: folder.isPinned
                ))
                for child in tree.rows(in: id) {
                    add(child, under: id)
                }
            }
        }

        for item in tree.root where isKeptItem(item, tabs: liveTabs, folders: liveFolders) {
            add(item, under: nil)
        }
        for tab in tabs where tab.pinID != nil && !linked.contains(tab.id) {
            tab.pinID = nil
        }
        return pins
    }

    private func isKeptItem(_ item: SidebarItem, tabs: [UUID: BrowserTab], folders: [UUID: TabFolder]) -> Bool {
        switch item {
        case .tab(let id):
            tabs[id]?.pinnedURL != nil
        case .folder(let id):
            folders[id]?.isPinned == true
        }
    }

    // MARK: - Applying the set

    /// Makes this window show `pins`. A pin this window has no page for gets an unloaded one at its link; a
    /// page it has for a pin the profile no longer holds stays open as an ordinary tab when it is loaded and
    /// closes quietly when it is not. Kept items the profile does not hold yet stay, ahead of the loose tabs.
    func applyProfilePins(_ pins: [ProfilePin]) {
        isApplyingProfilePins = true
        defer { isApplyingProfilePins = false }
        sidebarDidChange()

        let wanted = Set(pins.map(\.id))
        let demoted = releaseGonePins(keeping: wanted)
        let items = upsertPinItems(pins)
        sidebarDidChange()

        var root: [SidebarItem] = []
        var children: [UUID: [SidebarItem]] = [:]
        for pin in pins {
            guard let item = items[pin.id] else { continue }
            if let parent = pin.parentID {
                children[parent, default: []].append(item)
            } else {
                root.append(item)
            }
        }
        let placed = Set(root + children.values.flatMap { $0 })
        let profileFolders = Set(pins.filter { $0.kind == .folder }.map(\.id))
        let reconciled = reconciledTree()
        let rest = reconciled.root.filter { !placed.contains($0) && !demoted.contains($0) }
        var nested = children
        for (folderID, rows) in reconciled.children where !profileFolders.contains(folderID) {
            nested[folderID] = rows.filter { !placed.contains($0) && !demoted.contains($0) }
        }
        // Kept items the profile does not hold yet come next, then the pages that stopped being pins, then the rest.
        let pending = rest.filter(isKept)
        let stopped = tabs.map { SidebarItem.tab($0.id) }.filter(demoted.contains)
        let loose = rest.filter { !isKept($0) }
        storedTree = SidebarTree(root: root + pending + stopped + loose, children: nested)
        profileFolderIDs = profileFolders
        syncTabOrder()
    }

    /// Unlinks every page whose pin is not in `wanted`, and removes the profile folders that are gone.
    /// Returns the loaded pages that stay open as ordinary tabs.
    private func releaseGonePins(keeping wanted: Set<UUID>) -> Set<SidebarItem> {
        var demoted: Set<SidebarItem> = []
        for tab in tabs {
            guard let pinID = tab.pinID, !wanted.contains(pinID) else { continue }
            tab.pinID = nil
            if tab.isMaterialised, !tab.isDeferred {
                tab.pinnedURL = nil
                tab.pinnedTitle = ""
                tab.isFavorite = false
                demoted.insert(.tab(tab.id))
            } else {
                close(tab, recordForReopening: false)
            }
        }
        for id in profileFolderIDs where !wanted.contains(id) {
            folders.removeAll { $0.id == id }
            finishFolderRename(id)
        }
        return demoted
    }

    /// Creates or updates the folder and the page behind each pin. Returns each pin's sidebar item.
    private func upsertPinItems(_ pins: [ProfilePin]) -> [UUID: SidebarItem] {
        var pages: [UUID: BrowserTab] = [:]
        for tab in tabs {
            guard let id = tab.pinID else { continue }
            if pages[id] == nil {
                pages[id] = tab
            } else {
                tab.pinID = nil
            }
        }
        var liveFolders = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var items: [UUID: SidebarItem] = [:]
        for pin in pins {
            switch pin.kind {
            case .folder:
                let folder: TabFolder
                if let existing = liveFolders[pin.id] {
                    folder = existing
                } else {
                    folder = TabFolder(id: pin.id, name: pin.title)
                    folders.append(folder)
                    liveFolders[pin.id] = folder
                }
                assign(\.name, to: pin.title, on: folder)
                assign(\.color, to: pin.color ?? .gray, on: folder)
                assign(\.isExpanded, to: pin.isExpanded, on: folder)
                assign(\.isPinned, to: pin.isPinned, on: folder)
                items[pin.id] = .folder(folder.id)
            case .tab:
                let tab = pages[pin.id] ?? makePinPage(pin)
                pages[pin.id] = tab
                assign(\.pinID, to: pin.id, on: tab)
                assign(\.pinnedURL, to: pin.pinnedURL, on: tab)
                assign(\.pinnedTitle, to: pin.pinnedTitle ?? "", on: tab)
                assign(\.customTitle, to: pin.customTitle ?? "", on: tab)
                let becameFavorite = pin.isFavorite && !tab.isFavorite
                assign(\.isFavorite, to: pin.isFavorite, on: tab)
                if becameFavorite {
                    tab.realizeDeferredSession()
                }
                items[pin.id] = .tab(tab.id)
            }
        }
        return items
    }

    /// Writes only a change, so a set that is already shown does not redraw the sidebar.
    private func assign<Object: AnyObject, Value: Equatable>(
        _ path: ReferenceWritableKeyPath<Object, Value>, to value: Value, on object: Object
    ) {
        if object[keyPath: path] != value {
            object[keyPath: path] = value
        }
    }

    /// An unloaded page at the pin's link, like a tab restored from a saved session.
    private func makePinPage(_ pin: ProfilePin) -> BrowserTab {
        let url = URL(string: pin.url)
        let tab = makeTab(for: url, restoring: true)
        tab.pinID = pin.id
        tab.pageTitle = url == nil || SystemPages.isStart(url)
            ? SystemPages.startTitle
            : (pin.title.isEmpty ? BrowserTab.placeholderTitle : pin.title)
        tab.urlString = url?.absoluteString ?? pin.url
        tab.deferRestore(state: nil, url: url)
        if let host = url?.host() {
            dressRow(tab, fromHost: host)
        }
        tabs.append(tab)
        writtenStateGeneration[tab.id] = tab.sessionStateGeneration
        onTabOpened?(tab)
        return tab
    }
}
