// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB

/// Builds the profile's first pins from what every window kept before pins belonged to the profile.
///
/// It reads the window rows, open and closed alike, and writes `profilePin` rows. The only thing it changes in a
/// window's rows is `pinID`, which links a window's tab or folder to its profile pin; it never deletes or rewrites
/// a session row. The migration runs in one transaction, and a profile that already has pins is left as it is.
nonisolated enum ProfilePinMigration {
    static func run(in db: Database) throws {
        guard try ProfilePin.fetchCount(db) == 0 else { return }
        var merge = Merge()
        for id in try UUID.fetchAll(db, sql: "SELECT id FROM sessionWindow ORDER BY lastActiveAt DESC, id") {
            merge.add(try SavedWindow(id: id, in: db))
        }
        try merge.write(in: db)
    }

    private enum Node: Hashable {
        case tab(UUID)
        case folder(UUID)
    }

    private struct SavedTab {
        var url: String
        var title: String
        var customTitle: String?
        var pinnedURL: URL?
        var pinnedTitle: String?
        var isFavorite: Bool

        /// The link a new window opens for this tab.
        var link: String {
            pinnedURL?.absoluteString ?? url
        }
    }

    private struct SavedFolder {
        var name: String
        var color: TabFolderColor
        var isExpanded: Bool
        var isPinned: Bool
    }

    private struct SavedWindow {
        var tabs: [UUID: SavedTab] = [:]
        var folders: [UUID: SavedFolder] = [:]
        var children: [UUID?: [Node]] = [:]

        init(id: UUID, in db: Database) throws {
            for row in try Row.fetchAll(db, sql: """
                SELECT id, url, title, customTitle, pinnedURL, pinnedTitle, isFavorite
                FROM sessionTab WHERE windowID = ?
                """, arguments: [id]) {
                let tabID: UUID = row["id"]
                let pinnedURL: String? = row["pinnedURL"]
                tabs[tabID] = SavedTab(
                    url: row["url"], title: row["title"], customTitle: row["customTitle"],
                    pinnedURL: pinnedURL.flatMap { URL(string: $0) },
                    pinnedTitle: row["pinnedTitle"], isFavorite: row["isFavorite"]
                )
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT id, name, color, isExpanded, isPinned FROM sessionFolder WHERE windowID = ?
                """, arguments: [id]) {
                let folderID: UUID = row["id"]
                let color: String? = row["color"]
                folders[folderID] = SavedFolder(
                    name: row["name"], color: color.flatMap(TabFolderColor.init(rawValue:)) ?? .gray,
                    isExpanded: row["isExpanded"], isPinned: row["isPinned"]
                )
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT tabID, folderID, parentID FROM sessionItem WHERE windowID = ? ORDER BY position
                """, arguments: [id]) {
                let parent: UUID? = row["parentID"]
                let tabID: UUID? = row["tabID"]
                let folderID: UUID? = row["folderID"]
                if let tabID, tabs[tabID] != nil {
                    children[parent, default: []].append(.tab(tabID))
                } else if let folderID, folders[folderID] != nil {
                    children[parent, default: []].append(.folder(folderID))
                }
            }
        }

        /// The root items the window keeps: tabs with a pin and pinned folders. Their folders bring everything inside.
        var kept: [Node] {
            (children[nil] ?? []).filter { node in
                switch node {
                case .tab(let id):
                    tabs[id]?.pinnedURL != nil
                case .folder(let id):
                    folders[id]?.isPinned == true
                }
            }
        }
    }

    private struct Link {
        var row: UUID
        var pin: UUID
    }

    private struct FolderKey: Hashable {
        var parent: UUID?
        var name: String
    }

    /// The profile's pins so far, and which window rows stand for them.
    private struct Merge {
        var pins: [ProfilePin] = []
        var tabLinks: [Link] = []
        var folderLinks: [Link] = []
        private var hasPrimary = false
        private var pinByLink: [String: UUID] = [:]
        private var folderByName: [FolderKey: UUID] = [:]

        /// The first window with pins is copied as it is. Every later one adds only what the set lacks: a tab joins
        /// the pin with its link, a folder joins the one with its name under the same parent.
        mutating func add(_ window: SavedWindow) {
            let kept = window.kept
            guard !kept.isEmpty else { return }
            let merging = hasPrimary
            hasPrimary = true
            append(kept, of: window, under: nil, merging: merging, path: [])
        }

        private mutating func append(
            _ nodes: [Node], of window: SavedWindow, under parent: UUID?, merging: Bool, path: Set<UUID>
        ) {
            for node in nodes {
                switch node {
                case .tab(let id):
                    guard let tab = window.tabs[id] else { continue }
                    if merging, !tab.link.isEmpty, let existing = pinByLink[tab.link] {
                        tabLinks.append(Link(row: id, pin: existing))
                        continue
                    }
                    let pin = ProfilePin(
                        id: UUID(), parentID: parent, orderKey: "", kind: .tab,
                        url: tab.link, title: tab.title,
                        customTitle: tab.customTitle?.isEmpty == false ? tab.customTitle : nil,
                        pinnedURL: tab.pinnedURL,
                        pinnedTitle: tab.pinnedTitle?.isEmpty == false ? tab.pinnedTitle : nil,
                        isFavorite: tab.isFavorite
                    )
                    pins.append(pin)
                    tabLinks.append(Link(row: id, pin: pin.id))
                    if !tab.link.isEmpty, pinByLink[tab.link] == nil {
                        pinByLink[tab.link] = pin.id
                    }
                case .folder(let id):
                    guard let folder = window.folders[id], !path.contains(id) else { continue }
                    let key = FolderKey(
                        parent: parent, name: folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    var pinID = merging ? folderByName[key] : nil
                    if pinID == nil {
                        let pin = ProfilePin(
                            id: UUID(), parentID: parent, orderKey: "", kind: .folder, title: folder.name,
                            color: folder.color, isExpanded: folder.isExpanded, isPinned: folder.isPinned
                        )
                        pins.append(pin)
                        pinID = pin.id
                        if folderByName[key] == nil {
                            folderByName[key] = pin.id
                        }
                    }
                    guard let pinID else { continue }
                    folderLinks.append(Link(row: id, pin: pinID))
                    append(
                        window.children[id] ?? [], of: window, under: pinID, merging: merging,
                        path: path.union([id])
                    )
                }
            }
        }

        /// Writes the pins, parents first, and links the window rows to them.
        func write(in db: Database) throws {
            var lastKey: [UUID?: String] = [:]
            for var pin in pins {
                pin.orderKey = OrderKey.between(lastKey[pin.parentID], nil)
                lastKey[pin.parentID] = pin.orderKey
                try pin.insert(db)
            }
            for link in tabLinks {
                try db.execute(sql: "UPDATE sessionTab SET pinID = ? WHERE id = ?", arguments: [link.pin, link.row])
            }
            for link in folderLinks {
                try db.execute(sql: "UPDATE sessionFolder SET pinID = ? WHERE id = ?", arguments: [link.pin, link.row])
            }
        }
    }
}
