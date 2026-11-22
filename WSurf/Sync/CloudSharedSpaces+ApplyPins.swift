// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
    func applyPins(_ profile: Profile, models: [BrowserModel]) {
        guard let group = links[profile.id]?.profile else { return }
        let store = pins(profile)
        do {
            let local = try store.readForPublication()
            if links[profile.id]?.sharesPinLibrary == true {
                try capturePinLibrary(local, in: profile, group: group)
            }
            guard var link = links[profile.id] else { return }
            var next = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
            let incoming = catalog.items(.pins).filter { $0.profileID == group && !$0.removed }
            if link.sharesPinLibrary {
                try reserveIncomingPins(incoming, link: &link, local: &next, store: store, models: models)
            }
            let transfers = associatedTabs(incoming, profile: profile, link: &link, local: next, models: models)
            applyLinkedPins(link: &link, local: &next)
            if link.sharesPinLibrary {
                removeEmptyDeletedFolders(link: link, local: &next)
            }
            let rows = ProfilePin.depthFirst(Array(next.values))
            // An incoming favorite that already has a Space tab adopts that tab before any window inserts a copy.
            let attach = {
                for (tab, id) in transfers {
                    tab.pinID = id
                }
            }
            if link.sharesPinLibrary {
                try commitPinLibrary(rows, replacing: local, store: store, profile: profile, link: &link, beforeNotify: attach)
                pinLibraryFailures.remove(profile.id)
            } else {
                if links[profile.id] != link {
                    links[profile.id] = link
                    guard persistLinks() else { return }
                }
                store.publish(rows, replacing: local, beforeNotify: attach)
            }
        } catch {
            if links[profile.id]?.sharesPinLibrary == true {
                pinLibraryFailures.insert(profile.id)
            }
        }
    }

    private func reserveIncomingPins(
        _ items: [SharedSpaceItem], link: inout SharedProfileLinks, local: inout [UUID: ProfilePin], store: ProfilePinStore, models: [BrowserModel]
    ) throws {
        let folders = items.filter { $0.kind == .pinFolder }
        let knownFolders = Set((link.pinFolders ?? [:]).values)
        let newFolders = folders.filter { !knownFolders.contains($0.id) }
        var occupied = Set(local.keys).union(link.pins.keys).union((link.pinFolders ?? [:]).keys)
        if !newFolders.isEmpty {
            // Ordinary folders use their UUID as their sidebar identity even in a closed window.
            occupied.formUnion(try store.savedFolderIDs())
            for model in models {
                occupied.formUnion(model.folders.map(\.id))
            }
            var folderIDs = link.pinFolders ?? [:]
            for folder in newFolders {
                let id = occupied.contains(folder.id) ? UUID() : folder.id
                folderIDs[id] = folder.id
                occupied.insert(id)
            }
            link.pinFolders = folderIDs
        }
        for folder in folders {
            _ = materializeFolders(from: folder.id, profile: folder.profileID, link: &link, local: &local)
        }
        let known = Set(link.pins.values)
        for pin in items where pin.kind == .pin && !known.contains(pin.id) {
            let id = occupied.contains(pin.id) ? UUID() : pin.id
            link.pins[id] = pin.id
            occupied.insert(id)
        }
    }

    private func associatedTabs(
        _ items: [SharedSpaceItem], profile: Profile, link: inout SharedProfileLinks, local: [UUID: ProfilePin], models: [BrowserModel]
    ) -> [(BrowserTab, UUID)] {
        guard isEnabled(.spaces, for: profile) else { return [] }
        var transfers: [(BrowserTab, UUID)] = []
        for pin in items where pin.sharedTabID != nil && link.skippedPins?.contains(pin.id) != true {
            guard let slot = link.slots.first(where: { $0.value.cloudID == pin.sharedTabID }),
                  slot.value.last?.removed == false, link.spaces.values.contains(where: { $0 == slot.value.last?.spaceID }),
                  let browser = models.first(where: { $0.windowID == slot.value.window }), let tab = browser.tab(id: slot.key) else { continue }
            let id = link.pins.first(where: { $0.value == pin.id })?.key ?? pin.id
            if let existing = tab.pinID, existing != id {
                continue
            }
            if tab.pinID == nil, local[id] != nil {
                continue
            }
            link.slots[slot.key]?.pinID = id
            link.pins[id] = pin.id
            transfers.append((tab, id))
        }
        return transfers
    }

    private func applyLinkedPins(link: inout SharedProfileLinks, local: inout [UUID: ProfilePin]) {
        for (id, shared) in link.pins {
            guard let item = catalog.item(shared, in: .pins), item.profileID == link.profile, item.kind == .pin else { continue }
            if item.removed {
                local.removeValue(forKey: id)
                continue
            }
            guard let url = item.url.flatMap(URL.init(string:)) else { continue }
            let parent = materializeFolders(from: item.parentID, profile: item.profileID, link: &link, local: &local)
            guard item.parentID == nil || parent != nil else { continue }
            var pin = local[id] ?? ProfilePin(id: id, orderKey: item.order, kind: .tab)
            pin.parentID = parent
            pin.url = url.absoluteString
            pin.pinnedURL = url
            pin.title = item.title
            pin.pinnedTitle = item.title
            pin.customTitle = item.customTitle
            pin.isFavorite = item.favorite
            pin.orderKey = item.order
            local[id] = pin
        }
    }

    /// Wait for a complete parent chain. A folder deletion can arrive before the record that moves its child.
    private func materializeFolders(
        from first: UUID?, profile: UUID, link: inout SharedProfileLinks, local: inout [UUID: ProfilePin]
    ) -> UUID? {
        guard first != nil else { return nil }
        var chain: [SharedSpaceItem] = []
        var visited: Set<UUID> = []
        var parent = first
        while let id = parent {
            guard visited.insert(id).inserted, let folder = catalog.item(id, in: .pins),
                  folder.kind == .pinFolder, !folder.removed, folder.profileID == profile else { return nil }
            chain.append(folder)
            parent = folder.parentID
        }
        var folderIDs = link.pinFolders ?? [:]
        var above: UUID?
        for folder in chain.reversed() {
            let existing = folderIDs.first(where: { $0.value == folder.id })?.key
            let occupied = local[folder.id] != nil || link.pins[folder.id] != nil || folderIDs[folder.id] != nil
            let id = existing ?? (occupied ? UUID() : folder.id)
            var pin = local[id] ?? ProfilePin(id: id, orderKey: folder.order, kind: .folder)
            pin.parentID = above
            pin.orderKey = folder.order
            pin.title = folder.title
            pin.color = folder.color.flatMap(TabFolderColor.init(rawValue:))
            if link.sharesPinLibrary {
                pin.customColor = folder.pinFolderAppearance?.customColor
                pin.sizeFactor = folder.pinFolderAppearance?.sizeFactor
                pin.tintsIcons = folder.pinFolderAppearance?.tintsIcons == true ? true : nil
            }
            pin.symbol = folder.symbol
            pin.isPinned = above == nil
            local[id] = pin
            folderIDs[id] = folder.id
            above = id
        }
        link.pinFolders = folderIDs
        return above
    }

    private func removeEmptyDeletedFolders(link: SharedProfileLinks, local: inout [UUID: ProfilePin]) {
        let ordered = ProfilePin.depthFirst(Array(local.values))
        var parents: Set<UUID> = []
        for row in ordered.reversed() {
            if row.kind == .folder, !parents.contains(row.id), let shared = link.pinFolders?[row.id],
               let item = catalog.item(shared, in: .pins), item.profileID == link.profile, item.removed {
                local.removeValue(forKey: row.id)
            } else if let parent = row.parentID {
                parents.insert(parent)
            }
        }
    }
}
