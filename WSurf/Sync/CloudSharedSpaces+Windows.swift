// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
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
