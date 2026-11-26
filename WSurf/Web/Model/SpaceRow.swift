// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB

/// One ordinary tab or folder of a Space, with its place in the Space's tree.
///
/// While `BrowserSettings.sharesSpaceTabsAcrossWindows` is on, every regular window of the profile shows the same rows, so
/// they live in the profile's database next to its pins. Each window keeps its own `BrowserTab` for a tab row, linked by
/// `BrowserTab.spaceTabID`; a folder row is the same `TabFolder` ID in every window.
nonisolated struct SpaceRow: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "spaceRow"

    enum Kind: String, Codable, Sendable {
        case tab
        case folder
    }

    var id: UUID
    var parentID: UUID?
    /// Sorts among the siblings of one parent, across every Space. See `OrderKey`.
    var orderKey: String
    var kind: Kind
    var spaceID: UUID
    var url: String = ""
    var title: String = ""
    var customTitle: String?
    var color: TabFolderColor?
    var isExpanded = true
    var sizeFactor: Double?
    var tintsIcons: Bool?
    var customColor: String?
    var symbol: String?

    /// Parents before children, siblings by key. Rows whose parent is missing are dropped.
    static func depthFirst(_ rows: [SpaceRow]) -> [SpaceRow] {
        let groups = Dictionary(grouping: rows, by: \.parentID)
        var walked: [SpaceRow] = []
        var seen: Set<UUID> = []
        func visit(_ parent: UUID?) {
            let siblings = (groups[parent] ?? []).sorted { ($0.orderKey, $0.id.uuidString) < ($1.orderKey, $1.id.uuidString) }
            for row in siblings where seen.insert(row.id).inserted {
                walked.append(row)
                visit(row.id)
            }
        }
        visit(nil)
        return walked
    }

    /// The same greedy keying as `ProfilePin.assignOrderKeys`: a row keeps its key while the keys still ascend.
    static func assignOrderKeys(_ rows: inout [SpaceRow], previous: [SpaceRow]) {
        let before = Dictionary(previous.map { ($0.id, $0.orderKey) }, uniquingKeysWith: { first, _ in first })
        var groups: [UUID?: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            groups[row.parentID, default: []].append(index)
        }
        for indices in groups.values {
            var last: String?
            for (offset, index) in indices.enumerated() {
                func follows(_ key: String) -> Bool {
                    last.map { key > $0 } ?? true
                }
                if let old = before[rows[index].id], follows(old) {
                    rows[index].orderKey = old
                    last = old
                    continue
                }
                let ids = indices[(offset + 1)...].map { rows[$0].id }
                let upper = ids.lazy.compactMap { before[$0] }.first(where: follows)
                let key = OrderKey.between(last, upper)
                rows[index].orderKey = key
                last = key
            }
        }
    }
}
