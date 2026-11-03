// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import GRDB
import Observation
import os

@MainActor
@Observable
final class HistoryStore {
    nonisolated enum Transition: String, Codable, Sendable, CaseIterable {
        case link
        case typed
        case reload
        case formSubmit
        case backForward
        case agent
        /// A move the page made itself (`pushState`, `replaceState`) without loading a document.
        case inPage
        case imported
        case unknown

        var carriesReferrer: Bool {
            self == .link || self == .formSubmit || self == .inPage
        }
    }

    nonisolated struct Visit: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
        static let databaseTableName = "historyVisit"

        var id: Int64?
        var url: String
        var visitedAt: Date
        var transition: Transition
        var fromVisit: Int64?

        static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
            .timeIntervalSinceReferenceDate
        }

        static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
            .timeIntervalSinceReferenceDate
        }
    }

    nonisolated struct VisitedPage: Codable, FetchableRecord, Identifiable, Hashable, Sendable {
        var id: Int64
        var url: String
        var title: String
        var visitedAt: Date
        var transition: Transition
        /// The first visit of the run of visits this one belongs to. Nil for a visit saved before trails.
        var trail: Int64?

        static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
            .timeIntervalSinceReferenceDate
        }

        var entry: Entry {
            Entry(url: url, title: title, date: visitedAt)
        }
    }

    nonisolated struct Entry: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable, Sendable {
        static let databaseTableName = "historyPage"

        var id: String {
            url
        }
        var url: String
        var title: String
        var visitCount: Int
        var lastVisit: Date

        var date: Date {
            lastVisit
        }

        static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
            .timeIntervalSinceReferenceDate
        }

        static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
            .timeIntervalSinceReferenceDate
        }

        init(url: String, title: String, visitCount: Int = 1, lastVisit: Date) {
            self.url = url
            self.title = title
            self.visitCount = visitCount
            self.lastVisit = lastVisit
        }

        init(url: String, title: String, date: Date) {
            self.init(url: url, title: title, lastVisit: date)
        }
    }

    // The window of history that views read. It is read from the database by the first reader, not by `init`: a profile
    // that nobody opens History, the Start page or the omnibox in pays nothing for it at launch. Each property is observed by
    // hand (`access` and `withMutation`), since the macro cannot see through a load on first use. The load itself never
    // notifies: nothing has read a property that is not loaded, and a read happens inside a view's body.
    @ObservationIgnored private var storedEntries: [Entry] = [] {
        didSet { shortIndex = nil }
    }
    /// What a query of one or two letters reads, made by the first such query after the entries change.
    @ObservationIgnored private var shortIndex: ShortIndex?

    /// The words of each of `storedEntries`, in the same order, and the entries' indexes from the most visited down, so that a
    /// query that most pages match stops after the few it asks for.
    private struct ShortIndex {
        let words: [WordPrefixes]
        let byRank: [Int]

        init(_ entries: [Entry]) {
            words = entries.map { WordPrefixes($0.url, $0.title) }
            byRank = entries.indices.sorted { HistoryStore.outranks(entries[$0], entries[$1]) }
        }
    }
    @ObservationIgnored private var storedVisits: [VisitedPage] = []
    @ObservationIgnored private var storedCount = 0
    @ObservationIgnored private var storedHasOlderVisits = false
    @ObservationIgnored private var isLoaded = false

    var entries: [Entry] {
        access(keyPath: \.entries)
        loadIfNeeded()
        return storedEntries
    }

    var visits: [VisitedPage] {
        access(keyPath: \.visits)
        loadIfNeeded()
        return storedVisits
    }

    var count: Int {
        access(keyPath: \.count)
        loadIfNeeded()
        return storedCount
    }

    var hasOlderVisits: Bool {
        access(keyPath: \.hasOlderVisits)
        loadIfNeeded()
        return storedHasOlderVisits
    }

    /// How many visits `visits` may hold: the window, grown by every page of older visits that was read.
    @ObservationIgnored private var visitLimit: Int

    private let database: AppDatabase
    private let windowSize: Int

    /// Titles that arrived after a load and are not written yet, oldest first, one per visit. See `retitle`.
    @ObservationIgnored private var pendingTitles: [PendingTitle] = []
    @ObservationIgnored private var titleFlush: Task<Void, Never>?
    private let titleDelay: Duration

    private struct PendingTitle {
        let visit: Int64
        let url: String
        let title: String
    }

    init(database: AppDatabase = .shared, windowSize: Int = 3000, titleDelay: Duration = .seconds(2)) {
        self.database = database
        self.windowSize = windowSize
        self.titleDelay = titleDelay
        visitLimit = windowSize
        _ = Self.terminationObserver
    }

    func loadOlderVisits(limit: Int = 1_000) {
        guard hasOlderVisits, let oldest = storedVisits.last else { return }
        let older = read { db in
            try Self.fetchVisits(db, before: oldest, limit: limit + 1)
        }
        guard let older else { return }
        withMutation(keyPath: \.hasOlderVisits) { storedHasOlderVisits = older.count > limit }
        withMutation(keyPath: \.visits) { storedVisits.append(contentsOf: older.prefix(limit)) }
        visitLimit = max(visitLimit, storedVisits.count)
    }

    private nonisolated static func fetchVisits(
        _ db: Database,
        before oldest: VisitedPage? = nil,
        limit: Int
    ) throws -> [VisitedPage] {
        let older = oldest == nil ? "" : """
            WHERE historyVisit.visitedAt < ?
                OR (historyVisit.visitedAt = ? AND historyVisit.id < ?)
            """
        var arguments: StatementArguments = []
        if let oldest {
            let date = oldest.visitedAt.timeIntervalSinceReferenceDate
            arguments += [date, date, oldest.id]
        }
        arguments += [limit]
        return try VisitedPage.fetchAll(
            db,
            sql: """
                SELECT historyVisit.id, historyVisit.url, historyPage.title,
                       historyVisit.visitedAt, historyVisit.transition, historyVisit.trail
                FROM historyVisit
                JOIN historyPage ON historyPage.url = historyVisit.url
                \(older)
                ORDER BY historyVisit.visitedAt DESC, historyVisit.id DESC
                LIMIT ?
                """,
            arguments: arguments
        )
    }

    nonisolated static func isRecordable(_ url: String) -> Bool {
        guard let scheme = URL(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return !url.hasPrefix("https://wsurf.local")
    }

    private struct SavedVisit {
        let entry: Entry
        let isNew: Bool
        let visitID: Int64
        let trail: Int64
    }

    /// `fromVisit` and `trail` name what a tab remembers, and the tab may remember a visit that Clear History, a range or
    /// a single removal has since deleted. Neither is trusted: an id that names no stored visit is stored as none (the
    /// foreign key on `fromVisit` would otherwise reject the whole insert and lose the visit), and a trail that no stored
    /// visit carries starts over with this visit.
    @discardableResult
    func record(
        url: String,
        title: String,
        transition: Transition = .typed,
        fromVisit: Int64? = nil,
        trail: Int64? = nil
    ) -> Int64? {
        guard Self.isRecordable(url) else { return nil }
        loadIfNeeded()
        let title = title.isEmpty ? url : title
        let saved = write { db -> SavedVisit? in
            let known = try Entry.fetchOne(db, key: url)
            let now = Date().timeIntervalSinceReferenceDate
            try db.execute(
                sql: """
                    INSERT INTO historyPage (url, title, visitCount, lastVisit)
                    VALUES (?, ?, 1, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        title = excluded.title,
                        visitCount = visitCount + 1,
                        lastVisit = excluded.lastVisit
                    """,
                arguments: [url, title, now]
            )
            let continued = try trail.flatMap {
                try Int64.fetchOne(db, sql: "SELECT trail FROM historyVisit WHERE trail = ? LIMIT 1", arguments: [$0])
            }
            try db.execute(
                sql: """
                    INSERT INTO historyVisit (url, visitedAt, transition, fromVisit, trail)
                    VALUES (?, ?, ?, (SELECT id FROM historyVisit WHERE id = ?), ?)
                    """,
                arguments: [url, now, transition.rawValue, transition.carriesReferrer ? fromVisit : nil, continued]
            )
            let visitID = db.lastInsertedRowID
            if continued == nil {
                try db.execute(sql: "UPDATE historyVisit SET trail = id WHERE id = ?", arguments: [visitID])
            }
            guard let entry = try Entry.fetchOne(db, key: url) else { return nil }
            return SavedVisit(entry: entry, isNew: known == nil, visitID: visitID, trail: continued ?? visitID)
        }
        guard let saved = saved.flatMap({ $0 }) else { return nil }
        // This visit names the page's title now, so a title still waiting from an earlier visit of it would write the old one over it.
        pendingTitles.removeAll { $0.url == url }

        withMutation(keyPath: \.entries) {
            storedEntries.removeAll { $0.url == url }
            storedEntries.insert(saved.entry, at: 0)
            if storedEntries.count > windowSize {
                storedEntries.removeLast(storedEntries.count - windowSize)
            }
        }
        var hasOlder = storedHasOlderVisits
        withMutation(keyPath: \.visits) {
            storedVisits.insert(
                VisitedPage(
                    id: saved.visitID,
                    url: url,
                    title: title,
                    visitedAt: saved.entry.lastVisit,
                    transition: transition,
                    trail: saved.trail
                ),
                at: 0
            )
            if storedVisits.count > visitLimit {
                if visitLimit > windowSize {
                    visitLimit = storedVisits.count
                } else {
                    storedVisits.removeLast(storedVisits.count - visitLimit)
                    hasOlder = true
                }
            }
        }
        if hasOlder != storedHasOlderVisits {
            withMutation(keyPath: \.hasOlderVisits) { storedHasOlderVisits = hasOlder }
        }
        if saved.isNew {
            withMutation(keyPath: \.count) { storedCount += 1 }
        }
        return saved.visitID
    }

    /// Names the page of `visit` once its document has a title. Only the page that visit recorded can be renamed: a title
    /// for another address, or for a visit that is gone, changes nothing, so a cleared page is never written back.
    ///
    /// The title is shown at once, and the write waits (`titleDelay`) for the page's other titles: a page that sets its title
    /// again and again, or a background tab that does, costs one write for all of them. Memory changes at once because the
    /// model compares a tab's title with `visits` (a held in-page move waits for a different one). The write happens on the
    /// timer, on `flushPendingTitles()` (a tab closing, a search, the app quitting, every change to what is stored) and never
    /// brings back a page that was cleared in the meantime: it is an `UPDATE` that needs the visit to exist, and Clear History
    /// drops what is waiting.
    func retitle(visit: Int64, url: String, title: String) {
        guard !title.isEmpty else { return }
        loadIfNeeded()
        if storedVisits.contains(where: { $0.id == visit && $0.url == url }) {
            applyTitle(title, to: url)
        }
        pendingTitles.removeAll { $0.visit == visit }
        pendingTitles.append(PendingTitle(visit: visit, url: url, title: title))
        if !Self.storesWithPendingTitles.contains(where: { $0.store === self }) {
            Self.storesWithPendingTitles.append(WeakStore(store: self))
        }
        // The timer starts with the first waiting title and is not restarted by later ones, so a page that never stops
        // retitling is still written once per `titleDelay`. Not `[weak self]`: a store that is let go with titles waiting still
        // writes them.
        guard titleFlush == nil else { return }
        titleFlush = Task { @MainActor [self] in
            try? await Task.sleep(for: titleDelay)
            guard !Task.isCancelled else { return }
            flushPendingTitles()
        }
    }

    var hasPendingTitles: Bool {
        !pendingTitles.isEmpty
    }

    /// Writes the titles that wait, in the order they arrived, in one transaction.
    func flushPendingTitles() {
        titleFlush?.cancel()
        titleFlush = nil
        Self.storesWithPendingTitles.removeAll { $0.store == nil || $0.store === self }
        guard !pendingTitles.isEmpty else { return }
        let batch = pendingTitles
        pendingTitles = []
        let changed = write { db -> [PendingTitle] in
            try batch.filter { pending in
                try db.execute(
                    sql: """
                        UPDATE historyPage SET title = ?
                        WHERE url = ? AND title != ?
                            AND EXISTS (SELECT 1 FROM historyVisit WHERE id = ? AND url = ?)
                        """,
                    arguments: [pending.title, pending.url, pending.title, pending.visit, pending.url]
                )
                return db.changesCount > 0
            }
        }
        for pending in changed ?? [] {
            applyTitle(pending.title, to: pending.url)
        }
    }

    /// Forgets the titles that wait, for a page that is about to be erased: not even its title is written.
    private func discardPendingTitles(forURL url: String? = nil) {
        pendingTitles.removeAll { url == nil || $0.url == url }
        guard pendingTitles.isEmpty else { return }
        titleFlush?.cancel()
        titleFlush = nil
    }

    private func applyTitle(_ title: String, to url: String) {
        if storedEntries.contains(where: { $0.url == url && $0.title != title }) {
            withMutation(keyPath: \.entries) {
                for index in storedEntries.indices where storedEntries[index].url == url {
                    storedEntries[index].title = title
                }
            }
        }
        if storedVisits.contains(where: { $0.url == url && $0.title != title }) {
            withMutation(keyPath: \.visits) {
                for index in storedVisits.indices where storedVisits[index].url == url {
                    storedVisits[index].title = title
                }
            }
        }
    }

    // MARK: - Writing titles at the end of the app

    private struct WeakStore {
        weak var store: HistoryStore?
    }

    /// The stores that were given a title since they last wrote. Weak, and pruned when one writes.
    private static var storesWithPendingTitles: [WeakStore] = []

    /// The app writes the waiting titles before it quits. AppKit posts this on the main thread and the observer runs before
    /// the post returns, as for the settings' deferred writes.
    private static let terminationObserver = flushWhenPosted(to: .default)

    static func flushWhenPosted(to center: NotificationCenter) -> NSObjectProtocol {
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { HistoryStore.flushAllPendingTitles() }
        }
    }

    static func flushAllPendingTitles() {
        let stores = storesWithPendingTitles.compactMap(\.store)
        storesWithPendingTitles = []
        for store in stores {
            store.flushPendingTitles()
        }
    }

    func removeVisit(_ id: Int64) {
        removeVisits([id])
    }

    func removeVisits(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        flushPendingTitles()
        let marks = databaseQuestionMarks(count: ids.count)
        let removed = write { db -> Bool in
            let urls = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT url FROM historyVisit WHERE id IN (\(marks))",
                arguments: StatementArguments(ids)
            )
            guard !urls.isEmpty else { return false }
            try db.execute(
                sql: "DELETE FROM historyVisit WHERE id IN (\(marks))",
                arguments: StatementArguments(ids)
            )
            try db.execute(
                sql: """
                    UPDATE historyPage SET
                        visitCount = (
                            SELECT COUNT(*) FROM historyVisit
                            WHERE historyVisit.url = historyPage.url
                        ),
                        lastVisit = COALESCE(
                            (
                                SELECT MAX(visitedAt) FROM historyVisit
                                WHERE historyVisit.url = historyPage.url
                            ),
                            lastVisit
                        )
                    WHERE url IN (\(databaseQuestionMarks(count: urls.count)))
                    """,
                arguments: StatementArguments(urls)
            )
            try db.execute(sql: "DELETE FROM historyPage WHERE visitCount = 0")
            return true
        }
        guard removed == true else { return }
        invalidate()
    }

    func referrerChain(to visitID: Int64, limit: Int = 12) -> [VisitedPage] {
        let chain = read { db -> [VisitedPage] in
            var found: [VisitedPage] = []
            var next: Int64? = visitID
            var seen: Set<Int64> = []
            while let id = next, found.count < limit, seen.insert(id).inserted {
                let row = try VisitedPage.fetchOne(
                    db,
                    sql: """
                        SELECT historyVisit.id, historyVisit.url, historyPage.title,
                               historyVisit.visitedAt, historyVisit.transition, historyVisit.trail
                        FROM historyVisit
                        JOIN historyPage ON historyPage.url = historyVisit.url
                        WHERE historyVisit.id = ?
                        """,
                    arguments: [id]
                )
                guard let row else { break }
                found.append(row)
                next = try Int64.fetchOne(
                    db,
                    sql: "SELECT fromVisit FROM historyVisit WHERE id = ?",
                    arguments: [id]
                )
            }
            return found
        } ?? []
        return chain.reversed()
    }

    @discardableResult
    func merge(_ imported: [Entry]) -> Int {
        let arriving = imported.filter { Self.isRecordable($0.url) }
        guard !arriving.isEmpty else { return 0 }
        flushPendingTitles()

        let added = write { db -> Int in
            var added = 0
            for entry in arriving {
                if try Entry.fetchOne(db, key: entry.url) == nil {
                    added += 1
                }
                try db.execute(
                    sql: """
                        INSERT INTO historyPage (url, title, visitCount, lastVisit)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(url) DO UPDATE SET
                            title = CASE WHEN excluded.lastVisit > lastVisit
                                THEN excluded.title ELSE title END,
                            visitCount = visitCount + excluded.visitCount,
                            lastVisit = max(lastVisit, excluded.lastVisit)
                        """,
                    arguments: [
                        entry.url, entry.title, entry.visitCount,
                        entry.lastVisit.timeIntervalSinceReferenceDate,
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO historyVisit (url, visitedAt, transition, fromVisit)
                        VALUES (?, ?, ?, NULL)
                        """,
                    arguments: [
                        entry.url,
                        entry.lastVisit.timeIntervalSinceReferenceDate,
                        Transition.imported.rawValue,
                    ]
                )
            }
            return added
        }
        invalidate()
        return added ?? 0
    }

    /// Pages whose address or title has a word that starts with `query`, the ones visited most first.
    ///
    /// A query of one or two letters is answered from `entries`, the pages visited last, and never reads the database: such a
    /// query is a prefix of most words, so it matched most of the table, and the omnibox asks for it again with every key and
    /// every redraw. The cost of that was a read of nearly the whole full-text index and a sort of everything it found.
    /// Longer queries still search all of history.
    func search(_ query: String, limit: Int = 6) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }
        if let prefix = Self.shortPrefix(of: needle) {
            return mostVisited(withAWordStarting: prefix, limit: limit)
        }
        return searchEverything(needle, limit: limit)
    }

    /// The most visited of the pages in memory that have a word starting with `prefix`, by visits and then by recency, as the
    /// full-text query orders them.
    private func mostVisited(withAWordStarting prefix: [UInt8], limit: Int) -> [Entry] {
        let entries = self.entries
        let index = shortIndex ?? ShortIndex(entries)
        shortIndex = index
        var found: [Entry] = []
        for position in index.byRank {
            if found.count == limit {
                break
            }
            if index.words[position].matches(prefix) {
                found.append(entries[position])
            }
        }
        return found
    }

    private nonisolated static func outranks(_ entry: Entry, _ other: Entry) -> Bool {
        entry.visitCount != other.visitCount ? entry.visitCount > other.visitCount : entry.lastVisit > other.lastVisit
    }

    private func searchEverything(_ query: String, limit: Int) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: needle) else { return [] }
        flushPendingTitles()
        return read { db in
            try Entry.fetchAll(
                db,
                sql: """
                    SELECT historyPage.* FROM historyPage
                    JOIN historyPage_ft ON historyPage_ft.rowid = historyPage.rowid
                        AND historyPage_ft MATCH ?
                    ORDER BY historyPage.visitCount DESC, historyPage.lastVisit DESC
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            )
        } ?? []
    }

    func search(matching query: HistoryQuery, limit: Int = 6) -> [Entry] {
        // The History page's search reads all of history, whatever the length of the query.
        guard let range = query.dateRange else { return searchEverything(query.terms, limit: limit) }
        flushPendingTitles()
        let lower = range.lowerBound.timeIntervalSinceReferenceDate
        let upper = range.upperBound.timeIntervalSinceReferenceDate
        let needle = query.terms.trimmingCharacters(in: .whitespacesAndNewlines)

        if needle.isEmpty {
            return read { db in
                try Entry.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT historyPage.* FROM historyPage
                        JOIN historyVisit ON historyVisit.url = historyPage.url
                            AND historyVisit.visitedAt >= ? AND historyVisit.visitedAt < ?
                        ORDER BY historyPage.lastVisit DESC
                        LIMIT ?
                        """,
                    arguments: [lower, upper, limit]
                )
            } ?? []
        }

        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: needle) else { return [] }
        return read { db in
            try Entry.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT historyPage.* FROM historyPage
                    JOIN historyPage_ft ON historyPage_ft.rowid = historyPage.rowid
                        AND historyPage_ft MATCH ?
                    JOIN historyVisit ON historyVisit.url = historyPage.url
                        AND historyVisit.visitedAt >= ? AND historyVisit.visitedAt < ?
                    ORDER BY historyPage.visitCount DESC, historyPage.lastVisit DESC
                    LIMIT ?
                    """,
                arguments: [pattern, lower, upper, limit]
            )
        } ?? []
    }

    func remove(_ entry: Entry) {
        loadIfNeeded()
        let deleted = write { db in
            try Entry.deleteOne(db, key: entry.url)
        }
        guard deleted == true else { return }
        discardPendingTitles(forURL: entry.url)
        withMutation(keyPath: \.entries) { storedEntries.removeAll { $0.url == entry.url } }
        withMutation(keyPath: \.visits) { storedVisits.removeAll { $0.url == entry.url } }
        withMutation(keyPath: \.count) { storedCount -= 1 }
    }

    /// Erases all of history. Titles that wait are dropped, not written: the pages they name are gone, and a title that came
    /// in later cannot bring one back, since a write of it needs the visit it names.
    func clear() {
        discardPendingTitles()
        write { db in
            _ = try Entry.deleteAll(db)
        }
        invalidate()
    }

    func removeEntries(since date: Date) {
        deleteVisits(matching: "visitedAt >= ?", date)
    }

    func prune(retention: HistoryRetention) {
        guard let maximumAge = retention.maximumAge else { return }
        deleteVisits(matching: "visitedAt < ?", Date(timeIntervalSinceNow: -maximumAge))
    }

    private func deleteVisits(matching condition: String, _ date: Date) {
        flushPendingTitles()
        let deleted = write { db -> Bool in
            let cutoff = date.timeIntervalSinceReferenceDate
            let touched = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT url FROM historyVisit WHERE \(condition)",
                arguments: [cutoff]
            )
            guard !touched.isEmpty else { return false }
            try db.execute(
                sql: "DELETE FROM historyVisit WHERE \(condition)",
                arguments: [cutoff]
            )
            try db.execute(
                sql: """
                    UPDATE historyPage SET
                        visitCount = (
                            SELECT COUNT(*) FROM historyVisit
                            WHERE historyVisit.url = historyPage.url
                        ),
                        lastVisit = COALESCE(
                            (
                                SELECT MAX(visitedAt) FROM historyVisit
                                WHERE historyVisit.url = historyPage.url
                            ),
                            lastVisit
                        )
                    WHERE url IN (\(databaseQuestionMarks(count: touched.count)))
                    """,
                arguments: StatementArguments(touched)
            )
            try db.execute(sql: "DELETE FROM historyPage WHERE visitCount = 0")
            return true
        }
        if deleted == true {
            invalidate()
        }
    }

    // MARK: - Storage

    /// Reads the window on first use. A read that fails leaves the window empty and is not retried by every reader.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        let visitLimit = visitLimit
        // The "history.reload" interval for Instruments, next to "launch": the one place the window is really read.
        let loaded = Pipeline.signposter.withIntervalSignpost("history.reload") {
            read { db -> ([Entry], [VisitedPage], Int) in
                let entries = try Entry
                    .order(sql: "lastVisit DESC")
                    .limit(windowSize)
                    .fetchAll(db)
                let visits = try Self.fetchVisits(db, limit: visitLimit + 1)
                return (entries, visits, try Entry.fetchCount(db))
            }
        }
        guard let loaded else { return }
        storedEntries = loaded.0
        storedHasOlderVisits = loaded.1.count > visitLimit
        storedVisits = Array(loaded.1.prefix(visitLimit))
        storedCount = loaded.2
    }

    /// The database changed behind the window: the next reader reads it again, and the views that read it are told now.
    /// Waiting titles are written first, so the read finds them and none is left for a window that is not loaded.
    private func invalidate() {
        flushPendingTitles()
        isLoaded = false
        withMutation(keyPath: \.entries) {
            withMutation(keyPath: \.visits) {
                withMutation(keyPath: \.count) {
                    withMutation(keyPath: \.hasOlderVisits) {}
                }
            }
        }
    }

    @discardableResult
    private func write<T>(_ updates: (Database) throws -> T) -> T? {
        do {
            return try database.writer.write(updates)
        } catch {
            Pipeline.log.error("history: write failed")
            return nil
        }
    }

    private func read<T>(_ value: (Database) throws -> T) -> T? {
        do {
            return try database.writer.read(value)
        } catch {
            Pipeline.log.error("history: read failed")
            return nil
        }
    }

    /// A query of one or two letters or digits, lowercase; nil for any other.
    private nonisolated static func shortPrefix(of needle: String) -> [UInt8]? {
        let bytes = Array(needle.utf8)
        guard bytes.count <= 2, bytes.allSatisfy(WordPrefixes.isLetterOrDigit) else { return nil }
        return bytes.map(WordPrefixes.lowercased)
    }
}

/// The first one and two letters of the words of an address and a title, which is all that a query of one or two letters asks.
/// Words are read as the full-text index reads them: runs of letters and digits, upper and lower case and accents are one, and
/// anything else ends a word. A byte above 0x7F is taken for part of a word, which is what a letter of another script is; it
/// starts no word that an ASCII query can match.
nonisolated struct WordPrefixes {
    /// One bit for each of the ten digits and the 26 letters: some word starts with it.
    private var initials: UInt64 = 0
    /// The first two letters of each word of two letters or more.
    private var pairs: Set<UInt16> = []

    init(_ texts: String...) {
        for text in texts {
            add(text)
        }
    }

    /// Whether some word starts with `prefix`, one or two lowercase ASCII letters or digits.
    func matches(_ prefix: [UInt8]) -> Bool {
        switch prefix.count {
        case 1:
            guard let bit = Self.bit(of: prefix[0]) else { return false }
            return initials & (1 << bit) != 0
        case 2:
            return pairs.contains(UInt16(prefix[0]) << 8 | UInt16(prefix[1]))
        default:
            return false
        }
    }

    private mutating func add(_ text: String) {
        var text = text
        if !text.utf8.allSatisfy({ $0 < 0x80 }) {
            text = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        var seen = 0  // letters of the word being read, 0 between words
        var first: UInt8 = 0
        text.withUTF8 { bytes in
            for byte in bytes {
                guard Self.isLetterOrDigit(byte) || byte >= 0x80 else {
                    seen = 0
                    continue
                }
                seen += 1
                if seen == 1 {
                    first = byte
                    if let bit = Self.bit(of: byte) {
                        initials |= 1 << bit
                    }
                } else if seen == 2, Self.isLetterOrDigit(first), Self.isLetterOrDigit(byte) {
                    pairs.insert(UInt16(Self.lowercased(first)) << 8 | UInt16(Self.lowercased(byte)))
                }
            }
        }
    }

    static func isLetterOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    private static func bit(of byte: UInt8) -> UInt64? {
        let byte = lowercased(byte)
        switch byte {
        case 0x30...0x39:
            return UInt64(byte - 0x30)
        case 0x61...0x7A:
            return UInt64(byte - 0x61) + 10
        default:
            return nil
        }
    }
}
