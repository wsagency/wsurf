// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import Observation
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
    /// A folder's size factor; nil is normal.
    var sizeFactor: Double?
    /// Whether a folder draws the icons inside it in its own color; nil is off.
    var tintsIcons: Bool?
    /// A folder's own color as `#RRGGBB`; nil is its preset.
    var customColor: String?
    /// A folder's own SF Symbol; nil is the plain folder icon.
    var symbol: String?
    /// Shared between this Mac's windows. Older pins have no evidence of their pre-pin Space.
    var requiresSpacePlacement: Bool? = false

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

    static func readTree(_ db: Database) throws -> [ProfilePin] {
        let stored = try fetchAll(db)
        let ordered = depthFirst(stored)
        guard ordered.count == stored.count else { throw CocoaError(.fileReadCorruptFile) }
        return ordered
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
@Observable
final class ProfilePinStore {
    private struct Entry {
        weak var store: ProfilePinStore?
    }

    /// Keyed by the database writer. A store keeps its database, so a live entry's writer is never freed and reused.
    private static var registry: [ObjectIdentifier: Entry] = [:]

    private let database: AppDatabase
    private let subscribers = NSHashTable<BrowserModel>.weakObjects()
    @ObservationIgnored private var isPublishing = false
    private(set) var pins: [ProfilePin]
    /// False when the stored pins could not be read. Nothing may replace them then.
    let isAvailable: Bool
    /// The ordinary tabs and folders every window shows while Space tabs are shared, depth first. See `SpaceRow`.
    private(set) var spaceRows: [SpaceRow]
    /// False when the stored Space rows could not be read. Nothing may replace them then.
    let spaceRowsAvailable: Bool

    private init(database: AppDatabase) {
        self.database = database
        do {
            pins = try database.writer.read { try ProfilePin.readTree($0) }
            isAvailable = true
        } catch {
            Pipeline.log.error("pins: read failed")
            pins = []
            isAvailable = false
        }
        do {
            spaceRows = try database.writer.read { db in SpaceRow.depthFirst(try SpaceRow.fetchAll(db)) }
            spaceRowsAvailable = true
        } catch {
            Pipeline.log.error("space rows: read failed")
            spaceRows = []
            spaceRowsAvailable = false
        }
    }

    /// True while a change is being shown in the attached windows, when no window may publish.
    var isApplying: Bool {
        isPublishing
    }

    /// The window that removed a pin had no row to add: what the other windows kept for it was a pin it closed.
    func closeUnclaimedPinPages(except source: BrowserModel?) {
        for model in attachedWindows where model !== source && !model.pendingPinDemotions.isEmpty {
            model.closeUnclaimedPinPages()
        }
    }

    /// The attached windows of the store, which see every change to its rows.
    var attachedWindows: [BrowserModel] {
        subscribers.allObjects.filter { $0.attachedPinStore === self }
    }

    /// Replaces the stored Space rows with `next`, which must be depth first, and shows them in every other attached
    /// window before this returns. Shares the guard of `publish`, so a window that applies one set publishes neither.
    @discardableResult
    func publishSpaceRows(_ next: [SpaceRow], from source: BrowserModel? = nil) -> Bool {
        guard spaceRowsAvailable, !isPublishing else { return false }
        guard next != spaceRows else {
            closeUnclaimedPinPages(except: source)
            return true
        }
        // Only the rows that changed: a title that changes writes one row. `next` is depth first, so a parent comes first.
        let previous = Dictionary(spaceRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(next.map(\.id))
        do {
            try database.writer.write { db in
                for row in spaceRows where !kept.contains(row.id) {
                    try SpaceRow.deleteOne(db, key: row.id)
                }
                for row in next where previous[row.id] != row {
                    try row.save(db)
                }
            }
        } catch {
            Pipeline.log.error("space rows: write failed")
            return false
        }
        spaceRows = next
        isPublishing = true
        defer { isPublishing = false }
        // A closed window's saved session catches up when it reopens (`pagesOfCurrentSpaceRows`).
        for model in attachedWindows where model !== source && model.sharesSpaceTabs && model.sessionClosedAt == nil {
            model.applySpaceRows(next)
            model.scheduleSave()
        }
        return true
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

    /// Publication needs committed rows, including edits made while sharing was paused.
    func readForPublication() throws -> [ProfilePin] {
        // The session owner falls back to a temporary database if its on-disk profile cannot open.
        guard isAvailable, !database.isEphemeral || !AppDatabase.ownsSession else { throw CocoaError(.fileReadUnknown) }
        return try database.writer.read { try ProfilePin.readTree($0) }
    }

    func savedFolderIDs() throws -> Set<UUID> {
        try database.writer.read { db in Set(try UUID.fetchAll(db, sql: "SELECT id FROM sessionFolder")) }
    }

    func subscribe(_ model: BrowserModel) {
        subscribers.add(model)
    }

    func unsubscribe(_ model: BrowserModel) {
        subscribers.remove(model)
    }

    // ponytail: whole-set rewrite per change (a few hundred rows); write only changed rows if it shows up.
    /// Replaces the stored set with `next`, which must be depth first, in one transaction. Every other window
    /// attached to the store shows it before this returns, so no window ever holds a change the others lack.
    @discardableResult
    func publish(
        _ next: [ProfilePin], from source: BrowserModel? = nil, replacing expected: [ProfilePin]? = nil,
        beforeNotify: () -> Void = {}
    ) -> Bool {
        // A window that applies a set re-publishes what it now shows, which is the same set.
        guard isAvailable, !isPublishing else { return false }
        if next == pins && (expected == nil || expected == next) {
            beforeNotify()
            return true
        }
        do {
            try database.writer.write { db in
                if let expected, try ProfilePin.readTree(db) != expected {
                    throw CocoaError(.fileWriteUnknown)
                }
                try ProfilePin.deleteAll(db)
                for pin in next {
                    try pin.insert(db)
                }
            }
        } catch {
            Pipeline.log.error("pins: write failed")
            return false
        }
        pins = next
        beforeNotify()
        if let source {
            source.sharedSpaceService?.pinsChanged(in: source.context.profile, store: self)
        }
        isPublishing = true
        defer { isPublishing = false }
        for model in subscribers.allObjects where model !== source && model.attachedPinStore === self {
            model.applyProfilePins(next)
            model.scheduleSave()
        }
        return true
    }
}
