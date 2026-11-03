// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import GRDB
import Testing

@testable import WSurf

/// When History reaches the database and what it leaves in memory: a title is written once its page has stopped changing it,
/// nothing waiting is written over what the person cleared, and the window of history is read when someone first asks for it.
/// Every store here has a database of its own, and a delay too long to elapse unless a test lets it.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct HistoryWriteTests {
    private static let never = Duration.seconds(3_600)

    private func makeStore(titleDelay: Duration = never, windowSize: Int = 3000) -> (HistoryStore, AppDatabase) {
        let database = AppDatabase.temporary()
        return (HistoryStore(database: database, windowSize: windowSize, titleDelay: titleDelay), database)
    }

    private func storedTitle(of url: String, in database: AppDatabase) throws -> String? {
        try database.writer.read { db throws in
            try String.fetchOne(db, sql: "SELECT title FROM historyPage WHERE url = ?", arguments: [url])
        }
    }

    private func count(_ table: String, in database: AppDatabase) throws -> Int {
        try database.writer.read { db throws in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
        }
    }

    // MARK: - Titles

    /// A page that sets its title again and again is shown at once and written once.
    @Test func aTitleIsShownAtOnceAndWrittenOnceWhenItStopsChanging() throws {
        let (store, database) = makeStore()
        let url = "https://app.example/inbox"
        let visit = try #require(store.record(url: url, title: "Inbox"))

        for unread in 1...20 {
            store.retitle(visit: visit, url: url, title: "(\(unread)) Inbox")
        }

        #expect(store.entries.first?.title == "(20) Inbox")
        #expect(store.visits.first?.title == "(20) Inbox")
        #expect(try storedTitle(of: url, in: database) == "Inbox", "nothing was written yet")
        #expect(store.hasPendingTitles)

        store.flushPendingTitles()

        #expect(try storedTitle(of: url, in: database) == "(20) Inbox")
        #expect(!store.hasPendingTitles)
    }

    @Test func theTitlesOfManyTabsAreWrittenTogetherInTheOrderTheyArrived() throws {
        let (store, database) = makeStore()
        let url = "https://shared.example/page"
        let first = try #require(store.record(url: url, title: "Page"))
        let second = try #require(store.record(url: url, title: "Page"))

        store.retitle(visit: first, url: url, title: "Earlier tab")
        store.retitle(visit: second, url: url, title: "Later tab")
        store.flushPendingTitles()

        #expect(try storedTitle(of: url, in: database) == "Later tab")
        #expect(store.entries.first?.title == "Later tab")
    }

    @Test func aTitleIsWrittenWhenItsDelayHasPassed() async throws {
        let (store, database) = makeStore(titleDelay: .milliseconds(20))
        let url = "https://slow.example/"
        let visit = try #require(store.record(url: url, title: "Slow"))

        store.retitle(visit: visit, url: url, title: "Slow, titled")

        let written = await waitUntil(timeout: .seconds(10)) { (try? storedTitle(of: url, in: database)) == "Slow, titled" }
        #expect(written)
        #expect(!store.hasPendingTitles)
    }

    /// A page that never stops retitling is still written: the delay runs from the first title that waits, not the last.
    @Test func aPageThatNeverStopsRetitlingIsStillWritten() async throws {
        let (store, database) = makeStore(titleDelay: .milliseconds(60))
        let url = "https://ticker.example/"
        let visit = try #require(store.record(url: url, title: "Ticker"))

        var tick = 0
        let written = await waitUntil(timeout: .seconds(10), tick: .milliseconds(10)) {
            tick += 1
            store.retitle(visit: visit, url: url, title: "Ticker \(tick)")
            guard let stored = try? storedTitle(of: url, in: database) else { return false }
            return stored != "Ticker"
        }

        #expect(written)
    }

    @Test func aSearchFindsATitleThatWaitsAndAnotherStoreSeesItAfterward() throws {
        let (store, database) = makeStore()
        let url = "https://docs.example/guide"
        let visit = try #require(store.record(url: url, title: "Docs"))
        store.retitle(visit: visit, url: url, title: "Quarterly planning guide")

        #expect(store.search("quarterly").map(\.url) == [url])
        #expect(try storedTitle(of: url, in: database) == "Quarterly planning guide")
        #expect(HistoryStore(database: database).search("planning").map(\.url) == [url])
    }

    /// The visit that records a page names its title, and an older title that still waits must not be written over it.
    @Test func aNewVisitIsNotOverwrittenByAnOlderWaitingTitle() throws {
        let (store, database) = makeStore()
        let url = "https://news.example/story"
        let first = try #require(store.record(url: url, title: "Story"))
        store.retitle(visit: first, url: url, title: "Story, as the first visit titled it")

        store.record(url: url, title: "Story, as the second visit titled it")
        store.flushPendingTitles()

        #expect(try storedTitle(of: url, in: database) == "Story, as the second visit titled it")
        #expect(store.entries.first?.title == "Story, as the second visit titled it")
    }

    /// A part of history goes, and the titles that wait for the rest are written first, so they are not lost with it.
    @Test func removingSomeVisitsKeepsTheTitleOfThePagesThatStay() throws {
        let (store, database) = makeStore()
        let kept = try #require(store.record(url: "https://kept.example/", title: "Kept"))
        let removed = try #require(store.record(url: "https://removed.example/", title: "Removed"))
        store.retitle(visit: kept, url: "https://kept.example/", title: "Kept, titled")
        store.retitle(visit: removed, url: "https://removed.example/", title: "Removed, titled")

        store.removeVisit(removed)

        #expect(try storedTitle(of: "https://kept.example/", in: database) == "Kept, titled")
        #expect(try storedTitle(of: "https://removed.example/", in: database) == nil)
        #expect(!store.hasPendingTitles)
    }

    // MARK: - Clear History

    /// Clear History after a title was shown and before it was written leaves nothing behind: not the page, its visits, its
    /// place in the search index, or a write that comes later.
    @Test func clearHistoryAfterAPendingTitleLeavesNothingBehind() throws {
        let (store, database) = makeStore()
        let url = "https://private.example/appointment"
        let visit = try #require(store.record(url: url, title: "Appointment", transition: .typed))
        try #require(store.record(url: "https://private.example/next", title: "Next", transition: .link, fromVisit: visit) != nil)
        store.retitle(visit: visit, url: url, title: "Appointment with the clinic on Friday")
        #expect(store.hasPendingTitles)

        store.clear()

        #expect(!store.hasPendingTitles, "what waited was dropped, not kept for later")
        store.flushPendingTitles()
        #expect(store.entries.isEmpty)
        #expect(store.visits.isEmpty)
        #expect(store.count == 0)
        for table in ["historyPage", "historyVisit", "historyPage_ft_docsize"] {
            #expect(try count(table, in: database) == 0, "\(table)")
        }
        try database.writer.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyPage_ft WHERE historyPage_ft MATCH 'clinic'") == 0)
        }
        #expect(HistoryStore(database: database).entries.isEmpty)
    }

    /// The same, when the title is written by another store on the same database after the clear, the way a second window
    /// of the profile or a profile's maintenance reaches it.
    @Test func aTitleAnotherStoreWritesAfterClearHistoryBringsNothingBack() throws {
        let database = AppDatabase.temporary()
        let window = HistoryStore(database: database, titleDelay: Self.never)
        let other = HistoryStore(database: database, titleDelay: Self.never)
        let url = "https://private.example/appointment"
        let visit = try #require(window.record(url: url, title: "Appointment"))
        window.retitle(visit: visit, url: url, title: "Appointment with the clinic")
        _ = other.entries
        other.retitle(visit: visit, url: url, title: "Appointment with the clinic, again")

        window.clear()
        other.flushPendingTitles()
        window.flushPendingTitles()

        #expect(try count("historyPage", in: database) == 0)
        #expect(try count("historyVisit", in: database) == 0)
        #expect(try count("historyPage_ft_docsize", in: database) == 0)
    }

    /// The timer of a title that waited does not outlive Clear History: the page is cleared, and 15 times the delay later
    /// it is still gone.
    @Test func aTimerThatWasRunningWhenHistoryWasClearedWritesNothing() async throws {
        let (store, database) = makeStore(titleDelay: .milliseconds(20))
        let visit = try #require(store.record(url: "https://private.example/timer", title: "Timer"))
        store.retitle(visit: visit, url: "https://private.example/timer", title: "Timer, titled")

        store.clear()
        _ = await waitUntil(timeout: .milliseconds(300), tick: .milliseconds(10)) { false }

        #expect(try count("historyPage", in: database) == 0)
        #expect(try count("historyPage_ft_docsize", in: database) == 0)
        #expect(!store.hasPendingTitles)
    }

    /// A page the person removed from History is not renamed either.
    @Test func aPageThatWasRemovedIsNotRenamedByATitleThatWaited() throws {
        let (store, database) = makeStore()
        let url = "https://removed.example/"
        let visit = try #require(store.record(url: url, title: "Removed"))
        store.retitle(visit: visit, url: url, title: "Removed, titled")

        store.remove(try #require(store.entries.first))
        store.flushPendingTitles()

        #expect(try count("historyPage", in: database) == 0)
        #expect(!store.hasPendingTitles)
    }

    // MARK: - Tab close and quit

    @Test func closingATabWritesTheTitleItGaveItsLastVisit() throws {
        let database = AppDatabase.temporary()
        let model = BrowserModel(database: database)
        let tab = model.newTab()
        let url = "https://example.com/report"
        tab.noteNavigationStarted()
        tab.urlString = url
        tab.pageTitle = "Report"
        tab.onNavigationFinished?(false)
        tab.pageTitle = "Report, final"
        tab.onTitleChanged?()
        #expect(try storedTitle(of: url, in: database) == "Report", "waiting")

        model.close(tab)

        #expect(try storedTitle(of: url, in: database) == "Report, final")
        #expect(!model.history.hasPendingTitles)
    }

    /// The app writes what waits when it quits. The observer that does it is the one the store installs for the default
    /// center, here on a center of the test's own so that nothing else in the host hears the notification.
    @Test func quittingWritesTheTitlesThatWait() throws {
        let center = NotificationCenter()
        let observer = HistoryStore.flushWhenPosted(to: center)
        defer { center.removeObserver(observer) }
        let (store, database) = makeStore()
        let other = HistoryStore(database: database, titleDelay: Self.never)
        let url = "https://example.com/quit"
        let visit = try #require(store.record(url: url, title: "Quit"))
        store.retitle(visit: visit, url: url, title: "Quit, titled")
        #expect(try storedTitle(of: url, in: database) == "Quit")

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        #expect(try storedTitle(of: url, in: database) == "Quit, titled")
        #expect(!store.hasPendingTitles)
        #expect(!other.hasPendingTitles)
    }

    // MARK: - The window of history is read when someone asks

    @Test func theWindowIsReadByTheFirstReaderAndNotByInit() throws {
        let database = AppDatabase.temporary()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO historyPage (url, title, visitCount, lastVisit) VALUES ('https://a.example/', 'A', 1, 1)")
        }
        let store = HistoryStore(database: database)
        // Written behind the store's back after it was made: a store that read at init would not show it.
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO historyPage (url, title, visitCount, lastVisit) VALUES ('https://b.example/', 'B', 1, 2)")
            try db.execute(sql: "INSERT INTO historyVisit (url, visitedAt, transition) VALUES ('https://b.example/', 2, 'typed')")
        }

        #expect(store.entries.map(\.url) == ["https://b.example/", "https://a.example/"])
        #expect(store.count == 2)
        #expect(store.visits.map(\.url) == ["https://b.example/"])
    }

    @Test func aWindowThatIsLoadedIsNotReadAgainUntilTheDatabaseChangesUnderIt() throws {
        let (store, database) = makeStore()
        store.record(url: "https://a.example/", title: "A")
        #expect(store.entries.count == 1)
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO historyPage (url, title, visitCount, lastVisit) VALUES ('https://b.example/', 'B', 1, 2)")
        }
        #expect(store.entries.count == 1, "it is the store's own writes that it follows")

        store.merge([.init(url: "https://c.example/", title: "C", date: .now)])

        #expect(Set(store.entries.map(\.url)) == ["https://a.example/", "https://b.example/", "https://c.example/"])
        #expect(store.count == 3)
    }

    @Test func clearingReadsTheEmptyDatabaseForTheNextReaderOnly() {
        let (store, _) = makeStore()
        store.record(url: "https://a.example/", title: "A")
        store.clear()

        #expect(store.entries.isEmpty)
        #expect(store.count == 0)

        store.record(url: "https://b.example/", title: "B")
        #expect(store.entries.map(\.url) == ["https://b.example/"])
    }

    // MARK: - One and two letters

    /// A short query is a prefix of most words. It is answered from the pages in memory and never reads the database:
    /// the rows are taken out from under the store, and the answer does not change; a longer query reads them and finds none.
    @Test func aShortQueryIsAnsweredFromMemoryAndALongerOneFromTheDatabase() throws {
        let (store, database) = makeStore()
        store.record(url: "https://github.com/wsagency/wsurf", title: "WSurf on GitHub")
        store.record(url: "https://golang.org/doc", title: "Go documentation")
        #expect(store.entries.count == 2)
        try database.writer.write { try $0.execute(sql: "DELETE FROM historyPage") }

        #expect(Set(store.search("g").map(\.url)) == ["https://github.com/wsagency/wsurf", "https://golang.org/doc"])
        #expect(store.search("go").map(\.url) == ["https://golang.org/doc"])
        #expect(store.search("gi").map(\.url) == ["https://github.com/wsagency/wsurf"])
        #expect(store.search("zz").isEmpty)
        #expect(store.search("gol").isEmpty, "three letters read the database, which is empty")
    }

    /// The words in memory follow what the store records, renames and removes.
    @Test func aShortQueryFollowsWhatIsRecordedRenamedAndRemoved() throws {
        let (store, _) = makeStore()
        #expect(store.search("zz").isEmpty)

        let visit = try #require(store.record(url: "https://example.com/a", title: "Plain"))
        #expect(store.search("pl").map(\.url) == ["https://example.com/a"])
        #expect(store.search("zz").isEmpty)

        store.retitle(visit: visit, url: "https://example.com/a", title: "Zzyzx road")
        #expect(store.search("zz").map(\.url) == ["https://example.com/a"])
        #expect(store.search("pl").isEmpty)

        store.remove(try #require(store.entries.first))
        #expect(store.search("zz").isEmpty)
    }

    @Test func aShortQueryRanksByVisitsThenByRecency() {
        let (store, _) = makeStore()
        store.record(url: "https://news.example/a", title: "Daily news")
        store.record(url: "https://news.example/b", title: "Weekly news")
        store.record(url: "https://news.example/a", title: "Daily news")
        store.record(url: "https://newsletter.example/", title: "Newsletter")

        #expect(store.search("ne").map(\.url) == ["https://news.example/a", "https://newsletter.example/", "https://news.example/b"])
        #expect(store.search("ne", limit: 2).count == 2)
    }

    /// The pages in memory are answered by the rule the full-text index uses, so a short query finds what the same query
    /// typed with a third letter would have narrowed: every page it should, upper and lower case, accents, digits and
    /// the parts of an address.
    @Test func aShortQueryMatchesWhatTheFullTextIndexMatches() throws {
        let (store, _) = makeStore()
        let pages: [(String, String)] = [
            ("https://www.example.com/a_b-c?x=1", "Plain title"),
            ("https://skola.example.hr/", "Škola i Čaj"),
            ("https://cafe.example/", "Café Münster"),
            ("https://example.org/2024/report", "Quarterly 2024 Report"),
            ("https://example.net/", "ünder the ÉCLAIR"),
            ("https://xn--bcher-kva.example/", "Zebra crossing"),
            ("https://example.dev/some-path", "9 lives"),
        ]
        for (url, title) in pages {
            store.record(url: url, title: title)
        }
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789".map { String($0) }
        let queries = letters + letters.flatMap { first in letters.map { first + $0 } }
        for query in queries {
            let fromMemory = Set(store.search(query, limit: 50).map(\.url))
            let fromTheIndex = Set(store.search(matching: HistoryQuery(terms: query, dateRange: nil), limit: 50).map(\.url))
            #expect(fromMemory == fromTheIndex, "query \(query)")
        }
    }

    @Test(arguments: [
        ("https://www.example.com/path", "ex", true),
        ("https://www.example.com/path", "pa", true),
        ("https://www.example.com/path", "xa", false),
        ("https://www.example.com/a_b-c", "c", true),
        ("https://www.example.com/a_b-c", "b", true),
        ("Škola i Čaj", "sk", true),
        ("Škola i Čaj", "ca", true),
        ("Škola i Čaj", "ko", false),
        ("Quarterly 2024 Report", "20", true),
        ("Quarterly 2024 Report", "re", true),
        ("Quarterly 2024 Report", "ly", false),
        ("", "a", false),
    ])
    func aWordOfTheTextStartsWithThePrefix(text: String, prefix: String, expected: Bool) {
        #expect(WordPrefixes(text).matches(Array(prefix.utf8)) == expected)
    }
}
