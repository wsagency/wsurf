// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension BrowserModel {
    var sharedSpaceService: CloudSharedSpaces? {
        sharedSpacesHost ?? CloudSync.shared?.sharedSpaces
    }

    @discardableResult
    func removeSharedRow(_ id: UUID) -> Bool {
        if let tab = tab(id: id) {
            guard !tab.isPinnedForProfile else { return false }
            close(tab, recordForReopening: false)
        } else if let folder = folder(id: id) {
            guard !folder.isPinned, !profileFolderIDs.contains(id) else { return false }
            storedTree = reconciledTree().dissolving(folder.id)
            folders.removeAll { $0 === folder }
            sidebarDidChange()
            scheduleSave()
        }
        return true
    }

    func applySharedRows(_ rows: [SharedSpaceItem], spaces: [UUID: UUID], ids: [UUID: UUID], anchors: [SidebarItem: SharedSpaceItem] = [:]) {
        let tree = reconciledTree()
        let priorActive = activeTabID
        let priorSpace = currentSpaceID
        var localRows = anchors
        for row in rows {
            guard let id = ids[row.id], let space = row.spaceID.flatMap({ spaces[$0] }) else { continue }
            let item: SidebarItem
            switch row.kind {
            case .folder:
                let folder = folder(id: id) ?? TabFolder(id: id, name: row.title)
                folder.name = row.title
                folder.spaceID = space
                folder.color = row.color.flatMap(TabFolderColor.init(rawValue:)) ?? .gray
                folder.symbol = row.symbol
                if !folders.contains(where: { $0 === folder }) {
                    folders.append(folder)
                }
                item = .folder(id)
            case .tab:
                guard let url = row.url.flatMap(URL.init(string:)) else { continue }
                let existing = tab(id: id)
                let tab = existing ?? makeTab(for: url, id: id, restoring: true)
                tab.spaceID = space
                if tab.urlString != url.absoluteString {
                    tab.applySharedURL(url)
                }
                tab.customTitle = row.customTitle ?? ""
                tab.pageTitle = row.title
                if existing == nil {
                    tabs.append(tab)
                    onTabOpened?(tab)
                }
                item = .tab(id)
            default:
                continue
            }
            localRows[item] = row
        }
        let shared = Set(localRows.keys)
        let foldersHere = Set(localRows.values.lazy.filter { $0.kind == .folder }.map(\.id))
        var root: [SidebarItem] = []
        var children: [UUID: [SidebarItem]] = [:]
        let sorted = localRows.sorted { ($0.value.order, $0.value.id.uuidString) < ($1.value.order, $1.value.id.uuidString) }
        for (item, row) in sorted {
            if let parent = row.parentID, foldersHere.contains(parent), let local = ids[parent],
               localRows[.folder(local)]?.spaceID == row.spaceID, !Self.cycles(row, in: localRows, ids: ids) {
                children[local, default: []].append(item)
            } else {
                root.append(item)
            }
        }
        // Root order keys are independent in each Space. Replace each participating row with one from that Space.
        func merged(_ prior: [SidebarItem], with wanted: [SidebarItem]) -> [SidebarItem] {
            var groups = Dictionary(grouping: wanted.reversed(), by: { localRows[$0]?.spaceID })
            var placed: Set<SidebarItem> = []
            let kept = prior.compactMap { row -> SidebarItem? in
                guard shared.contains(row) else { return row }
                guard let next = groups[localRows[row]?.spaceID]?.popLast() else { return nil }
                placed.insert(next)
                return next
            }
            return kept + wanted.filter { !placed.contains($0) }
        }

        var nested = tree.children
        for parent in Set(tree.children.keys).union(children.keys) {
            nested[parent] = merged(tree.rows(in: parent), with: children[parent] ?? [])
        }
        storedTree = SidebarTree(root: merged(tree.root, with: root), children: nested)
        syncTabOrder()
        // A remote move can carry the selected row out of this window's current Space.
        if let priorActive, let tab = tab(id: priorActive), !isShown(tab), currentSpaceID == priorSpace {
            activeTabID = firstShownTab?.id
        }
        scheduleSave()
    }

    private static func cycles(_ row: SharedSpaceItem, in rows: [SidebarItem: SharedSpaceItem], ids: [UUID: UUID]) -> Bool {
        guard row.kind == .folder else { return false }
        var visited = Set([row.id])
        var ancestor = row.parentID
        while let id = ancestor, let local = ids[id] {
            guard visited.insert(id).inserted else { return true }
            ancestor = rows[.folder(local)]?.parentID
        }
        return false
    }
}
