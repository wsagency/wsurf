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
            if let model = models.first {
                recoverGatheredWindows(in: model)
            }
            restoreKeptVersions(in: profile, models: models)
            if isEnabled(.spaces, for: profile), catalog.ready.contains(.spaces), let store = spaces(profile), var link = links[id] {
                for (local, shared) in link.spaces {
                    guard let item = catalog.item(shared, in: .spaces), item.profileID == link.profile, var space = store.space(id: local) else { continue }
                    if item.removed {
                        // Keep the local Space and its device-only contents available until its owner chooses a version.
                        if liveLocalEdit(item.recordID, in: id) != nil {
                            continue
                        }
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
                // Windows that share Space tabs show the owner's rows through the profile, never a copy of their own.
                var rowModels = models
                if let owner = spaceTabsOwner(of: profile, among: models) {
                    adoptSpaceTabSlots(into: owner, link: &link)
                    rowModels = [owner]
                }
                applyRows(to: rowModels, profile: profile, link: &link, opening: opening)
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

    /// A saved conflict can be resolved offline. Only the chosen local versions can be applied before account verification.
    private func restoreKeptVersions(in profile: Profile, models: [BrowserModel]) {
        guard isEnabled(.spaces, for: profile), let link = links[profile.id] else { return }
        let kept = catalog.state.pending.values.compactMap { edit -> SharedSpaceItem? in
            guard edit.profile == profile.id, edit.item.profileID == link.profile, edit.item.category == .spaces,
                  !edit.item.removed, edit.base?.removed == true else { return nil }
            return edit.item
        }
        // An upload may be acknowledged before the reserved local Space can be written.
        let reserved = (link.keepingSpaces ?? []).compactMap { id -> SharedSpaceItem? in
            guard let item = catalog.item(id, in: .spaces), item.kind == .space, !item.removed, item.profileID == link.profile else { return nil }
            return item
        }
        guard !kept.isEmpty || !reserved.isEmpty, let store = spaces(profile) else { return }
        let wanted = Dictionary((kept + reserved).filter { $0.kind == .space }.map { ($0.id, $0) }, uniquingKeysWith: { local, _ in local })
        for row in wanted.values where !link.spaces.values.contains(row.id) {
            try? materializeJoinedSpace(row, in: profile, store: store, keepingVersion: true)
        }
        if !wanted.isEmpty {
            let owned = store.spaces.map(\.id)
            for model in models where model.knownSpaceIDs != Set(owned) {
                model.adoptSpaces(owned)
            }
        }
        guard !catalog.ready.contains(.spaces) else { return }
        let ids = Set(kept.map(\.id))
        for model in models where link.slots.values.contains(where: { $0.window == model.windowID && $0.closedAfterRevision != nil && ids.contains($0.cloudID) }) {
            restoreWindowEdits(in: model, only: ids)
        }
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
                link.slots[local]?.editedAfterRevision = nil
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
        // Keep the owner's choice in a sleeping window even if its upload is acknowledged before it reopens.
        for row in active {
            guard let id = localIDs[row.id], let slot = link.slots[id], slot.closedAfterRevision != nil, windows[slot.window] == nil,
                  liveLocalEdit(row.recordID, in: profile.id) != nil else { continue }
            link.slots[id]?.last = row
        }
        let placed = placeRows(active, ids: localIDs, windows: windows, link: &link)
        for model in models {
            let rows = placed.filter { item in
                guard let id = localIDs[item.id] else { return false }
                guard let slot = link.slots[id], slot.window == model.windowID else { return false }
                return slot.pinID == nil || model.tab(id: id)?.pinID == nil
            }
            let changed = rows.contains { row in
                guard let id = localIDs[row.id], let membership = row.spaceID, let space = spaces[membership] else { return false }
                let item: SidebarItem = row.kind == .folder ? .folder(id) : .tab(id)
                return link.slots[id]?.closedAfterRevision != nil || link.slots[id]?.last != row || model.spaceID(ofItem: item) != space
            }
            guard changed || (model === opening && !rows.isEmpty) else { continue }
            model.applySharedRows(rows, spaces: spaces, ids: localIDs)
            for row in rows {
                guard let id = localIDs[row.id], let slot = link.slots[id] else { continue }
                if slot.last != row || slot.closedAfterRevision != nil {
                    link.slots[id]?.editedAfterRevision = liveLocalEdit(row.recordID, in: profile.id) != nil ? model.sessionRevision : nil
                }
                link.slots[id]?.closedAfterRevision = nil
                link.slots[id]?.last = row
            }
        }
    }
}
