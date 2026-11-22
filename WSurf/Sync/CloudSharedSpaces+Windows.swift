// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
    func gatherSharedRoots(_ roots: [SidebarItem], in entry: SpaceEntry, from source: BrowserModel, into target: BrowserModel) throws {
        let profile = entry.profile.id
        guard !applying, let original = links[profile], let space = original.spaces[entry.id],
              target.currentSpaceID == entry.id else { throw SharedCatalogError.unavailable }
        let members = source.reconciledTree().expanded(Set(roots))
        guard members.allSatisfy({ source.spaceID(ofItem: $0) == entry.id && !source.isKept($0) }) else {
            throw SharedCatalogError.unavailable
        }
        func localID(_ item: SidebarItem) -> UUID {
            switch item {
            case .tab(let id), .folder(let id):
                id
            }
        }
        let moving = Set(members.map(localID).filter { id in
            guard let slot = original.slots[id], slot.window == source.windowID, slot.pinID == nil,
                  slot.movingFrom == nil, slot.closedAfterRevision == nil, let row = catalog.item(slot.cloudID, in: .spaces) else { return false }
            return !row.removed && row.profileID == original.profile && row.spaceID == space
        })
        guard !moving.isEmpty, Set(roots.map(localID)).isSubset(of: moving) else { throw SharedCatalogError.unavailable }
        applying = true
        defer { applying = false }
        let saved = try source.savedSharedRowOwners(in: entry.id)
        if moving.contains(where: { saved[$0] != source.windowID }) {
            guard target.saveTransferredSession(from: source) else { throw SharedCatalogError.storage }
        }
        var reserved = original
        for id in moving {
            reserved.slots[id]?.movingFrom = source.windowID
            reserved.slots[id]?.window = target.windowID
        }
        links[profile] = reserved
        guard persistLinks() else {
            links[profile] = original
            throw SharedCatalogError.storage
        }

        let layouts = [source, target].map { model in
            (model: model, tree: model.reconciledTree(), active: model.activeTabID, splits: model.splits, recency: model.recentlyActive)
        }
        let tabIDs = Set(members.compactMap { item -> UUID? in
            guard case .tab(let id) = item else { return nil }
            return id
        })
        let splits = source.splits.splits.filter { $0.tabs.allSatisfy(tabIDs.contains) }
        let moved = target.adoptSharedRoots(roots, from: source)
        target.splits = TabSplits(target.splits.splits.filter { !splits.contains($0) } + splits)
        for id in moving where reserved.slots[id]?.editedAfterRevision != nil {
            reserved.slots[id]?.editedAfterRevision = target.sessionRevision
        }
        links[profile] = reserved
        let adoptedTree = target.reconciledTree()
        setGatheredOrder(in: target, space: space, link: reserved)
        guard moved.count == roots.count, target.saveTransferredSession(from: source) else {
            // A single-window save after a failed move must still contain all its original rows.
            target.storedTree = adoptedTree
            _ = source.adoptSharedRoots(moved, from: target)
            links[profile] = original
            persistLinks()
            for layout in layouts {
                let model = layout.model
                model.storedTree = layout.tree
                model.splits = layout.splits
                model.activeTabID = layout.active
                model.recentlyActive = layout.recency
                model.syncTabOrder()
                model.scheduleSave()
            }
            throw SharedCatalogError.storage
        }
        for id in moving {
            reserved.slots[id]?.movingFrom = nil
        }
        links[profile] = reserved
        guard persistLinks() else { throw SharedCatalogError.storage }
    }

    private func setGatheredOrder(in target: BrowserModel, space: UUID, link: SharedProfileLinks) {
        var rows: [SidebarItem: SharedSpaceItem] = [:]
        var ids: [UUID: UUID] = [:]
        for (id, slot) in link.slots where slot.window == target.windowID && slot.pinID == nil && slot.closedAfterRevision == nil {
            guard let row = catalog.item(slot.cloudID, in: .spaces), !row.removed, row.profileID == link.profile, row.spaceID == space else { continue }
            let item: SidebarItem = row.kind == .folder ? .folder(id) : .tab(id)
            guard target.spaceID(ofItem: item) == target.currentSpaceID else { continue }
            rows[item] = row
            ids[row.id] = id
        }
        // Order the existing rows without replaying metadata or publishing a change to the other Macs.
        target.applySharedRows([], spaces: [:], ids: ids, anchors: rows)
    }

    func recoverGatheredWindows(in browser: BrowserModel) {
        let profile = browser.context.profile.id
        guard var link = links[profile] else { return }
        let recovering = link.slots.filter { $0.value.movingFrom != nil }
        guard !recovering.isEmpty else { return }
        let reversedSpaces = Dictionary(uniqueKeysWithValues: link.spaces.map { ($0.value, $0.key) })
        let live = regularWindows(browser.context.profile)
        for shared in Set(recovering.values.compactMap { $0.last?.spaceID }) {
            guard let space = reversedSpaces[shared], let saved = try? browser.savedSharedRowOwners(in: space) else { continue }
            for (id, slot) in recovering where slot.last?.spaceID == shared {
                guard let source = slot.movingFrom, let savedOwner = saved[id], savedOwner == slot.window || savedOwner == source else { continue }
                if savedOwner != slot.window, live.contains(where: { model in
                    model.windowID == slot.window && (model.tab(id: id) != nil || model.folder(id: id) != nil)
                }) {
                    // A failed disk write still has the destination row in the running session.
                    continue
                }
                link.slots[id]?.window = savedOwner
                if savedOwner == slot.window {
                    link.slots[id]?.editedAfterRevision = nil
                }
                link.slots[id]?.movingFrom = nil
            }
        }
        if link != links[profile] {
            links[profile] = link
            persistLinks()
        }
    }

    /// A new row can arrive before its parent. Follow its folders to the first window this Mac already knows.
    func folderWindow(for row: SharedSpaceItem, ownerOf: (UUID) -> UUID?) -> UUID? {
        var parent = row.parentID
        var visited = Set([row.id])
        var window: UUID?
        while let id = parent, let folder = catalog.item(id, in: .spaces),
              folder.kind == .folder, !folder.removed, folder.profileID == row.profileID, folder.spaceID == row.spaceID {
            guard visited.insert(id).inserted else { return nil }
            if window == nil {
                window = ownerOf(id)
            }
            parent = folder.parentID
        }
        return window
    }

    /// Move living pages together with their folder, including their local split layout.
    func placeRows(_ rows: [SharedSpaceItem], ids: [UUID: UUID], windows: [UUID: BrowserModel], link: inout SharedProfileLinks) -> [SharedSpaceItem] {
        let folders = Set(rows.lazy.filter { $0.kind == .folder }.map(\.id))
        let children = Dictionary(grouping: rows, by: \.parentID)
        var ordered = rows.filter { $0.parentID.map { !folders.contains($0) } ?? true }
        var cursor = 0
        while cursor < ordered.count {
            let row = ordered[cursor]
            cursor += 1
            if row.kind == .folder, let nested = children[row.id] {
                ordered.append(contentsOf: nested)
            }
        }
        var visible: [SharedSpaceItem] = []
        // Two edits can detach a child while moving its former folder. Settle any earlier row that folder carried along.
        for _ in 0...folders.count {
            var checked: Set<UUID> = []
            var carriedEarlierRow = false
            visible.removeAll(keepingCapacity: true)
            for row in ordered {
                if let placed = placeRow(row, ids: ids, windows: windows, link: &link, checked: checked, carriedEarlierRow: &carriedEarlierRow) {
                    visible.append(placed)
                }
                if let id = ids[row.id] {
                    checked.insert(id)
                }
            }
            if !carriedEarlierRow {
                break
            }
        }
        if ordered.count != rows.count {
            // A cycle has no root. Let the sidebar display its rows at the top without moving their windows.
            let visited = Set(ordered.map(\.id))
            visible.append(contentsOf: rows.filter { !visited.contains($0.id) })
        }
        return visible
    }

    private func placeRow(
        _ row: SharedSpaceItem, ids: [UUID: UUID], windows: [UUID: BrowserModel], link: inout SharedProfileLinks,
        checked: Set<UUID>, carriedEarlierRow: inout Bool
    ) -> SharedSpaceItem? {
        guard let id = ids[row.id], let slot = link.slots[id], slot.pinID == nil,
              let owner = folderWindow(for: row, ownerOf: { ids[$0].flatMap { link.slots[$0]?.window } }), owner != slot.window else { return row }
        let source = windows[slot.window]
        let destination = windows[owner]
        let moved: Set<UUID>?
        if let source, let destination, source.tab(id: id) == nil, source.folder(id: id) == nil {
            // A new row or a completed session transfer whose window mapping had not yet reached disk.
            let alreadyThere = row.kind == .folder ? destination.folder(id: id) != nil : destination.tab(id: id) != nil
            moved = slot.last == nil || alreadyThere ? [id] : nil
        } else if let source, let destination, let folder = source.folder(id: id), row.kind == .folder {
            moved = destination.adoptSharedFolder(folder, from: source)
        } else if let source, let destination, let page = source.tab(id: id), page.pinID == nil, row.kind == .tab,
                  destination.adoptTab(page, from: source, activate: false) {
            moved = [id]
        } else {
            moved = nil
        }
        if let moved {
            carriedEarlierRow = carriedEarlierRow || !checked.isDisjoint(with: moved)
            for local in moved {
                link.slots[local]?.window = owner
            }
            link.slots[id]?.last = nil
            return row
        }
        // A closed window can still hold navigation state. Keep the current placement until it reopens.
        guard let source, let last = slot.last, source.tab(id: id) != nil || source.folder(id: id) != nil else { return nil }
        var visible = row.placed(as: last)
        if last.parentID == row.parentID {
            // Earlier builds could already have recorded a parent that this window never displayed.
            let item: SidebarItem = row.kind == .folder ? .folder(id) : .tab(id)
            visible.parentID = source.reconciledTree().parent(of: item).flatMap { link.slots[$0]?.cloudID }
        }
        return visible
    }

    /// A rename in the open window can travel while a move waits. Its temporary position is local to this Mac.
    func outgoingRow(_ row: SharedSpaceItem, after last: SharedSpaceItem?, window: UUID, link: SharedProfileLinks) -> SharedSpaceItem {
        guard let last, last.parentID == row.parentID, last.spaceID == row.spaceID,
              let incoming = catalog.item(row.id, in: .spaces), !incoming.removed, incoming.profileID == row.profileID,
              incoming.parentID != row.parentID,
              let owner = folderWindow(for: incoming, ownerOf: { id in link.slots.values.first { $0.cloudID == id }?.window }),
              owner != window else { return row }
        return row.placed(as: incoming)
    }
}

private extension SharedSpaceItem {
    func placed(as other: Self) -> Self {
        var row = self
        row.spaceID = other.spaceID
        row.parentID = other.parentID
        row.order = other.order
        return row
    }
}
