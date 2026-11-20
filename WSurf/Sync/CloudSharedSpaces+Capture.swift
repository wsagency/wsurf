// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
    static func spaceItem(_ space: Space, id: UUID, profile: UUID) -> SharedSpaceItem {
        .init(id: id, kind: .space, profileID: profile, title: space.name, symbol: space.symbol, color: space.color.rawValue)
    }

    static func pinItem(_ pin: ProfilePin, id: UUID, profile: UUID) -> SharedSpaceItem? {
        let url = pin.pinnedURL?.absoluteString ?? pin.url
        guard let page = SessionNode.tab(id: id, title: pin.pinnedTitle ?? pin.title, url: url) else { return nil }
        return .init(
            id: id, kind: .pin, profileID: profile, order: pin.orderKey, title: page.title,
            url: page.url, customTitle: pin.customTitle, favorite: pin.isFavorite
        )
    }

    func spaceChanged(_ space: Space, in profile: UUID, removed: Bool = false) {
        guard !applying, catalog.enabled(.spaces, for: profile),
              let link = links[profile], let id = link.spaces[space.id], let group = link.profile else { return }
        let value = Self.spaceItem(space, id: id, profile: group)
        catalog.stage(removed ? value.tombstone : value, for: profile)
        if removed {
            for slot in link.slots.values where slot.last?.spaceID == id {
                if let prior = slot.last {
                    catalog.stage(prior.tombstone, for: profile)
                }
            }
            links[profile]?.spaces[space.id] = nil
            persistLinks()
        }
    }

    func pinsChanged(in profile: Profile, store: ProfilePinStore) {
        guard !applying, isEnabled(.pins, for: profile), store.isAvailable,
              var link = links[profile.id], !link.pins.isEmpty, let group = link.profile else { return }
        let local = Dictionary(uniqueKeysWithValues: store.pins.map { ($0.id, $0) })
        var required: Set<UUID> = []
        for selected in link.pins.keys {
            var parent = local[selected]?.parentID
            while let id = parent, let folder = local[id], folder.kind == .folder, required.insert(id).inserted {
                parent = folder.parentID
            }
        }
        var folders = link.pinFolders ?? [:]
        for id in required where folders[id] == nil {
            folders[id] = catalog.item(id, in: .pins) == nil ? id : UUID()
        }
        var edits: [SharedSpaceItem] = []
        for id in required {
            guard let pin = local[id], let shared = folders[id] else { continue }
            edits.append(.init(
                id: shared, kind: .pinFolder, profileID: group, parentID: pin.parentID.flatMap { folders[$0] },
                order: pin.orderKey, title: pin.title, symbol: pin.symbol, color: pin.color?.rawValue
            ))
        }
        for (id, shared) in link.pins {
            if let pin = local[id], var item = Self.pinItem(pin, id: shared, profile: group) {
                item.sharedTabID = link.slots.values.first { $0.pinID == id }?.cloudID ?? catalog.item(shared, in: .pins)?.sharedTabID
                item.parentID = pin.parentID.flatMap { folders[$0] }
                edits.append(item)
            } else if let prior = catalog.item(shared, in: .pins), !prior.removed {
                edits.append(prior.tombstone)
            }
        }
        if link.pinFolders != folders {
            link.pinFolders = folders
            links[profile.id] = link
        }
        catalog.stage(edits, for: profile.id)
        persistLinks()
    }

    /// A row gone from an open window is ambiguous during teardown or transfer. Only an individual close supplies a deletion.
    func removed(_ id: UUID, in browser: BrowserModel) {
        let profile = browser.context.profile
        guard !applying, !browser.opensPrivately, !browser.isApplyingProfilePins, !browser.isReadingSharedSession, isEnabled(.spaces, for: profile),
              let entry = links[profile.id]?.slots[id], let prior = entry.last else { return }
        links[profile.id]?.slots[id]?.closedAfterRevision = browser.sessionRevision
        links[profile.id]?.slots[id]?.last = prior.tombstone
        catalog.stage(prior.tombstone, for: profile.id)
        persistLinks()
    }

    func sharesRow(_ id: UUID, in browser: BrowserModel) -> Bool {
        let profile = browser.context.profile
        guard isEnabled(.spaces, for: profile), let slot = links[profile.id]?.slots[id] else { return false }
        return slot.window == browser.windowID && slot.last?.removed == false
    }

    func applyPendingCloses(in browser: BrowserModel) {
        guard let slots = links[browser.context.profile.id]?.slots else { return }
        for (id, slot) in slots where slot.window == browser.windowID && slot.closedAfterRevision != nil {
            browser.removeSharedRow(id)
        }
    }

    func didSaveWindow(_ browser: BrowserModel, revision: Int64) {
        let profileID = browser.context.profile.id
        guard browser.sessionRevision == revision, let slots = links[profileID]?.slots else { return }
        let saved = slots.filter { id, slot in
            guard slot.window == browser.windowID, let closed = slot.closedAfterRevision, revision > closed else { return false }
            return browser.tab(id: id) == nil && browser.folder(id: id) == nil
        }
        guard !saved.isEmpty else { return }
        links[profileID]?.slots = slots.filter { saved[$0.key] == nil }
        persistLinks()
    }

    func capture(_ browser: BrowserModel) {
        let profile = browser.context.profile
        guard !applying, !browser.opensPrivately, !browser.isReadingSharedSession, browser.sessionClosedAt == nil,
              browser.windowKind == .standard, isEnabled(.spaces, for: profile),
              var link = links[profile.id], !link.spaces.isEmpty, let group = link.profile else { return }
        let tree = browser.reconciledTree()
        let parents = tree.parents()
        var groups: [UUID: [UUID]] = [:]
        var values: [UUID: SharedSpaceItem] = [:]
        var leaving: [SharedSpaceItem] = []
        var transferredPins: [SharedSpaceItem] = []
        var restoredMembership = false
        for row in tree.walk() {
            let local: UUID
            switch row {
            case .folder(let id), .tab(let id):
                local = id
            }
            // A restored stale row is removed before capture. An explicit Undo can publish a new shared tab.
            let previous = link.slots[local].flatMap { $0.closedAfterRevision == nil ? $0 : nil }
            let cloudID = previous?.cloudID ?? (catalog.item(local, in: .spaces) == nil ? local : UUID())
            if case .tab = row, let tab = browser.tab(id: local), let previous, previous.last?.removed == false {
                if let pinID = tab.pinID {
                    if previous.pinID != pinID, isEnabled(.pins, for: profile),
                       let pin = browser.pinStore.pins.first(where: { $0.id == pinID }),
                       var value = Self.pinItem(pin, id: link.pins[pinID] ?? pinID, profile: group) {
                        value.sharedTabID = previous.cloudID
                        link.pins[pinID] = value.id
                        transferredPins.append(value)
                    }
                    link.slots[local]?.pinID = pinID
                    continue
                } else if previous.pinID != nil {
                    if let destination = link.spaces.first(where: { $0.value == previous.last?.spaceID })?.key, destination != tab.spaceID {
                        tab.spaceID = destination
                        restoredMembership = true
                    }
                    link.slots[local]?.pinID = nil
                }
            }
            guard let space = browser.spaceID(ofItem: row).flatMap({ link.spaces[$0] }),
                  var item = Self.row(row, id: cloudID, space: space, profile: group, browser: browser) else {
                if let prior = previous?.last, !prior.removed {
                    leaving.append(prior.tombstone)
                    link.slots[local]?.last = prior.tombstone
                }
                continue
            }
            item.parentID = parents[row].flatMap { link.slots[$0]?.cloudID }
            item.order = previous?.last?.order ?? ""
            values[local] = item
            groups[item.parentID ?? space, default: []].append(local)
            link.slots[local] = .init(cloudID: cloudID, window: browser.windowID, last: previous?.last)
        }
        if restoredMembership {
            browser.sidebarDidChange()
        }
        var edits = leaving + transferredPins
        for ids in groups.values {
            var lower: String?
            for (i, local) in ids.enumerated() {
                guard var item = values[local] else { continue }
                if item.order.isEmpty || lower.map({ item.order <= $0 }) == true {
                    let upper = ids.dropFirst(i + 1).lazy.compactMap { values[$0]?.order }.first { next in
                        !next.isEmpty && lower.map { next > $0 } != false
                    }
                    item.order = OrderKey.between(lower, upper)
                }
                lower = item.order
                if link.slots[local]?.last != item {
                    edits.append(item)
                    link.slots[local]?.last = item
                }
            }
        }
        guard links[profile.id] != link else { return }
        links[profile.id] = link
        catalog.stage(edits, for: profile.id)
        if !transferredPins.isEmpty {
            pinsChanged(in: profile, store: browser.pinStore)
        }
        persistLinks()
    }

    private static func row(_ row: SidebarItem, id: UUID, space: UUID, profile: UUID, browser: BrowserModel) -> SharedSpaceItem? {
        switch row {
        case .folder(let local):
            guard let folder = browser.folder(id: local), !folder.isPinned, !browser.profileFolderIDs.contains(local) else { return nil }
            return .init(id: id, kind: .folder, profileID: profile, spaceID: space, title: folder.name, symbol: folder.symbol, color: folder.color.rawValue)
        case .tab(let local):
            guard let tab = browser.tab(id: local), !tab.isPrivate, tab.pinID == nil, tab.pinnedURL == nil, !tab.isFavorite,
                  tab.microTabID == nil, tab.extensionBaseURL == nil,
                  let page = SessionNode.tab(id: id, title: tab.pageTitle, url: tab.urlString) else { return nil }
            return .init(id: id, kind: .tab, profileID: profile, spaceID: space, title: page.title, url: page.url, customTitle: tab.customTitle)
        }
    }
}
