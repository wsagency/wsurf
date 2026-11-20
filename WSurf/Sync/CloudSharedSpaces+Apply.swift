// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
    func applyCatalog(to opening: BrowserModel? = nil) {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        for (id, profile) in profiles where links[id] != nil && !profile.isPrivate {
            var models = regularWindows(profile)
            if let opening, opening.context.profile.id == id, opening.windowKind == .standard,
               !opening.opensPrivately, opening.sessionClosedAt == nil, !models.contains(where: { $0 === opening }) {
                models.append(opening)
            }
            if isEnabled(.spaces, for: profile), catalog.ready.contains(.spaces), let store = spaces(profile), var link = links[id] {
                for (local, shared) in link.spaces {
                    guard let item = catalog.item(shared, in: .spaces), item.profileID == link.profile, var space = store.space(id: local) else { continue }
                    if item.removed {
                        if store.canRemove(space) {
                            store.remove(space)
                        }
                        link.spaces[local] = nil
                    } else {
                        space.name = item.title
                        space.symbol = item.symbol ?? Space.defaultSymbol
                        space.color = .init(rawValue: item.color ?? "") ?? .gray
                        store.update(space)
                    }
                }
                for model in models where model.knownSpaceIDs != Set(store.spaces.map(\.id)) {
                    model.adoptSpaces(store.spaces.map(\.id))
                }
                applyRows(to: models, profile: profile, link: &link, opening: opening)
                if links[id] != link {
                    links[id] = link
                    persistLinks()
                }
            }
            if isEnabled(.pins, for: profile), catalog.ready.contains(.pins) {
                applyPins(profile, models: models)
            }
        }
    }

    func originalSpace(of localTab: UUID, in profile: Profile) -> UUID? {
        guard let link = links[profile.id], let slot = link.slots[localTab], slot.pinID != nil,
              let membership = slot.last?.spaceID else { return nil }
        return link.spaces.first { $0.value == membership }?.key
    }

    private func applyPins(_ profile: Profile, models: [BrowserModel]) {
        guard var link = links[profile.id] else { return }
        let store = pins(profile)
        guard store.isAvailable else { return }
        if isEnabled(.spaces, for: profile) {
            let associated = catalog.items(.pins).filter { !$0.removed && $0.sharedTabID != nil && $0.profileID == link.profile }
            for pin in associated where link.skippedPins?.contains(pin.id) != true {
                guard let local = link.slots.first(where: { $0.value.cloudID == pin.sharedTabID }),
                      local.value.last?.removed == false, link.spaces.values.contains(where: { $0 == local.value.last?.spaceID }),
                      let browser = models.first(where: { $0.windowID == local.value.window }),
                      let tab = browser.tab(id: local.key) else { continue }
                let id = link.pins.first(where: { $0.value == pin.id })?.key ?? pin.id
                if let existing = tab.pinID, existing != id {
                    continue
                }
                if tab.pinID == nil, store.pins.contains(where: { $0.id == id }) {
                    continue
                }
                tab.pinID = id
                link.slots[local.key]?.pinID = id
                link.pins[id] = pin.id
            }
        }
        if links[profile.id] != link {
            links[profile.id] = link
            persistLinks()
        }
        let linked = link.pins
        guard !linked.isEmpty else { return }
        var next = Dictionary(uniqueKeysWithValues: store.pins.map { ($0.id, $0) })
        for (local, shared) in linked {
            guard let item = catalog.item(shared, in: .pins) else { continue }
            if item.removed {
                next.removeValue(forKey: local)
                continue
            }
            guard let url = item.url.flatMap(URL.init(string:)) else { continue }
            let parent = materializeAncestors(of: item, link: &link, local: &next)
            guard item.parentID == nil || parent != nil else { continue }
            var pin = next[local] ?? ProfilePin(id: local, orderKey: item.order, kind: .tab)
            pin.parentID = parent
            pin.url = url.absoluteString
            pin.pinnedURL = url
            pin.title = item.title
            pin.pinnedTitle = item.title
            pin.customTitle = item.customTitle
            pin.isFavorite = item.favorite
            pin.orderKey = item.order
            next[local] = pin
        }
        if links[profile.id] != link {
            links[profile.id] = link
            persistLinks()
        }
        store.publish(ProfilePin.depthFirst(Array(next.values)))
    }

    /// Only the ancestors needed by a linked pin materialize. A sibling with its own private URL is never requested.
    private func materializeAncestors(
        of item: SharedSpaceItem, link: inout SharedProfileLinks, local: inout [UUID: ProfilePin]
    ) -> UUID? {
        var chain: [SharedSpaceItem] = []
        var visited = Set([item.id])
        var parent = item.parentID
        while let id = parent {
            guard visited.insert(id).inserted, let folder = catalog.item(id, in: .pins),
                  folder.kind == .pinFolder, !folder.removed, folder.profileID == item.profileID else { return nil }
            chain.append(folder)
            parent = folder.parentID
        }
        var folderIDs = link.pinFolders ?? [:]
        var above: UUID?
        for folder in chain.reversed() {
            let id = folderIDs.first(where: { $0.value == folder.id })?.key ?? (local[folder.id] == nil ? folder.id : UUID())
            var pin = local[id] ?? ProfilePin(id: id, orderKey: folder.order, kind: .folder)
            pin.parentID = above
            pin.orderKey = folder.order
            pin.title = folder.title
            pin.color = folder.color.flatMap(TabFolderColor.init(rawValue:))
            pin.symbol = folder.symbol
            pin.isPinned = above == nil
            local[id] = pin
            folderIDs[id] = folder.id
            above = id
        }
        link.pinFolders = folderIDs
        return above
    }

    private func applyRows(to models: [BrowserModel], profile: Profile, link: inout SharedProfileLinks, opening: BrowserModel?) {
        let spaces = Dictionary(uniqueKeysWithValues: link.spaces.map { ($0.value, $0.key) })
        var localIDs = Dictionary(uniqueKeysWithValues: link.slots.map { ($0.value.cloudID, $0.key) })
        let records = catalog.items(.spaces).filter { $0.kind == .tab || $0.kind == .folder }
        let active = records.filter { !$0.removed && $0.profileID == link.profile && $0.spaceID.flatMap { spaces[$0] } != nil }
        let activeIDs = Set(active.map(\.id))
        for (local, slot) in link.slots where !activeIDs.contains(slot.cloudID) {
            guard slot.last?.removed != true, let model = models.first(where: { $0.windowID == slot.window }),
                  catalog.item(slot.cloudID, in: .spaces) != nil else { continue }
            if model.removeSharedRow(local) {
                link.slots[local]?.closedAfterRevision = model.sessionRevision
                link.slots[local]?.last = slot.last?.tombstone
            } else {
                link.slots[local] = nil
            }
        }
        var pinsByTab: [UUID: UUID] = [:]
        if isEnabled(.pins, for: profile) {
            for (local, shared) in link.pins {
                guard let pin = catalog.item(shared, in: .pins), !pin.removed, pin.profileID == link.profile,
                      let tab = pin.sharedTabID else { continue }
                pinsByTab[tab] = local
            }
        }
        let unmapped = active.filter { localIDs[$0.id] == nil }
        let occupied = unmapped.isEmpty ? Set<UUID>() : BrowserModel.occupiedSidebarIDs(in: models)
        let windows = Dictionary(models.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        for item in unmapped {
            let owner = folderWindow(for: item) { localIDs[$0].flatMap { link.slots[$0]?.window } } ?? models.first?.windowID
            guard let owner, let target = windows[owner] else { continue }
            if let pin = pinsByTab[item.id], let page = target.tabs.first(where: { $0.pinID == pin }), link.slots[page.id] == nil {
                localIDs[item.id] = page.id
                link.slots[page.id] = .init(cloudID: item.id, window: target.windowID, last: item, pinID: pin)
                continue
            }
            let id = occupied?.contains(item.id) == false && link.slots[item.id] == nil ? item.id : UUID()
            localIDs[item.id] = id
            link.slots[id] = .init(cloudID: item.id, window: target.windowID)
        }
        let placed = placeRows(active, ids: localIDs, windows: windows, link: &link)
        for model in models {
            let rows = placed.filter { item in
                guard let id = localIDs[item.id] else { return false }
                guard let slot = link.slots[id], slot.window == model.windowID else { return false }
                return slot.pinID == nil || model.tab(id: id)?.pinID == nil
            }
            let changed = rows.contains { row in
                guard let id = localIDs[row.id] else { return false }
                return link.slots[id]?.last != row || (model.tab(id: id) == nil && model.folder(id: id) == nil)
            }
            guard changed || (model === opening && !rows.isEmpty) else { continue }
            model.applySharedRows(rows, spaces: spaces, ids: localIDs)
            for row in rows {
                if let id = localIDs[row.id] {
                    link.slots[id]?.last = row
                }
            }
        }
    }
}
