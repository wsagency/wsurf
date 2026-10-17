// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import os

/// One pinned item of a profile: a tab (a pin or a Favorite) or a folder, with its place in the profile's tree.
///
/// Every regular window of the profile shows the same pins, so they live in the profile's database instead of in
/// any window's session. A tab row holds the link a new window opens; each window keeps its own page for it.
nonisolated struct ProfilePin: Codable, Equatable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "profilePin"

    enum Kind: String, Codable, Sendable {
        case tab
        case folder
    }

    var id: UUID
    var parentID: UUID?
    /// Sorts among the siblings of one parent. See `OrderKey`.
    var orderKey: String
    var kind: Kind
    /// The link a new window opens for a tab.
    var url: String = ""
    /// The title captured when the tab joined the profile, shown until its page loads.
    var title: String = ""
    var customTitle: String?
    var pinnedURL: URL?
    var pinnedTitle: String?
    var isFavorite = false
    var color: TabFolderColor?
    var isExpanded = true
    var isPinned = false

    /// Parents before children, siblings by key. This is the order to insert rows in, because a child
    /// references its parent.
    static func depthFirst(_ rows: [ProfilePin]) -> [ProfilePin] {
        let groups = Dictionary(grouping: rows, by: \.parentID)
        var walked: [ProfilePin] = []
        var seen: Set<UUID> = []
        func visit(_ parent: UUID?) {
            let siblings = (groups[parent] ?? []).sorted {
                ($0.orderKey, $0.id.uuidString) < ($1.orderKey, $1.id.uuidString)
            }
            for pin in siblings where seen.insert(pin.id).inserted {
                walked.append(pin)
                visit(pin.id)
            }
        }
        visit(nil)
        return walked
    }

    // ponytail: greedy keep; moving an item to the front rekeys its followers - longest increasing
    // subsequence if sync churn matters.
    /// Gives each pin of `pins`, which are in display order, a key that sorts it among its siblings.
    /// A pin keeps its key from `previous` while the keys still ascend, so a move rewrites one row.
    static func assignOrderKeys(_ pins: inout [ProfilePin], previous: [ProfilePin]) {
        let before = Dictionary(previous.map { ($0.id, $0.orderKey) }, uniquingKeysWith: { first, _ in first })
        var groups: [UUID?: [Int]] = [:]
        for (index, pin) in pins.enumerated() {
            groups[pin.parentID, default: []].append(index)
        }
        for indices in groups.values {
            var last: String?
            for (offset, index) in indices.enumerated() {
                func follows(_ key: String) -> Bool {
                    last.map { key > $0 } ?? true
                }
                if let old = before[pins[index].id], follows(old) {
                    pins[index].orderKey = old
                    last = old
                    continue
                }
                var upper: String?
                for later in indices[(offset + 1)...] {
                    if let candidate = before[pins[later].id], follows(candidate) {
                        upper = candidate
                        break
                    }
                }
                let key = OrderKey.between(last, upper)
                pins[index].orderKey = key
                last = key
            }
        }
    }
}

/// The pins of one profile database, shared by every window that uses it.
@MainActor
final class ProfilePinStore {
    private struct Entry {
        weak var store: ProfilePinStore?
    }

    /// Keyed by the database writer. A store keeps its database, so a live entry's writer is never freed and reused.
    private static var registry: [ObjectIdentifier: Entry] = [:]

    private let database: AppDatabase
    private(set) var pins: [ProfilePin]
    /// False when the stored pins could not be read. Nothing may replace them then.
    let isAvailable: Bool

    private init(database: AppDatabase) {
        self.database = database
        do {
            pins = ProfilePin.depthFirst(try database.writer.read { try ProfilePin.fetchAll($0) })
            isAvailable = true
        } catch {
            Pipeline.log.error("pins: read failed")
            pins = []
            isAvailable = false
        }
    }

    static func store(for database: AppDatabase) -> ProfilePinStore {
        let key = ObjectIdentifier(database.writer as AnyObject)
        if let live = registry[key]?.store {
            return live
        }
        registry = registry.filter { $0.value.store != nil }
        let store = ProfilePinStore(database: database)
        registry[key] = Entry(store: store)
        return store
    }

    // ponytail: whole-set rewrite per change (a few hundred rows); write only changed rows if it shows up.
    /// Replaces the stored set with `next`, which must be depth first, in one transaction.
    func publish(_ next: [ProfilePin]) {
        guard isAvailable, next != pins else { return }
        do {
            try database.writer.write { db in
                try ProfilePin.deleteAll(db)
                for pin in next {
                    try pin.insert(db)
                }
            }
        } catch {
            Pipeline.log.error("pins: write failed")
        }
        pins = next
    }
}
