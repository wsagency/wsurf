// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import GRDB
import Testing

@testable import WSurf

/// The palette's and omnibox's memory of where the user has been. The
/// contract: revisits float rather than pile up, blank and internal pages
/// never enter, and the retention promise made on the Privacy page holds.
@MainActor
struct HistoryStoreTests {
    /// Each test gets its own database, so nothing here touches the real one
    /// in Application Support.
    private func makeStore() -> (HistoryStore, AppDatabase) {
        let database = AppDatabase.temporary()
        return (HistoryStore(database: database), database)
    }

    @Test func aRevisitFloatsInsteadOfPilingUp() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "First visit")
        store.record(url: "https://example.com/b", title: "Elsewhere")
        store.record(url: "https://example.com/a", title: "Second visit")

        #expect(store.entries.count == 2)
        #expect(store.entries.first?.url == "https://example.com/a")
        #expect(store.entries.first?.title == "Second visit")
    }

    @Test func blankAndInternalPagesNeverEnter() {
        let (store, _) = makeStore()

        store.record(url: "", title: "Nothing")
        store.record(url: "about:blank", title: "Blank")
        store.record(url: "https://wsurf.local/start", title: "Start page")
        // An extension that replaces the new tab page: a real navigation, to
        // a page that is part of the browser rather than part of the web.
        store.record(
            url: "safari-web-extension://84CF36BF-D3D9-4DF5-AF49-A6FFA34F46DC/newtab.html",
            title: "New Tab"
        )
        store.record(url: "file:///Users/someone/notes.html", title: "Notes")
        store.record(url: "data:text/html,<h1>hi</h1>", title: "Inline")

        #expect(store.entries.isEmpty)
    }

    /// The scheme rule guards the import too, not only live navigation.
    @Test func junkArrivingFromAnImportIsDropped() {
        let (store, _) = makeStore()

        store.merge([
            HistoryStore.Entry(
                url: "safari-web-extension://84CF36BF-D3D9-4DF5-AF49-A6FFA34F46DC/newtab.html",
                title: "New Tab",
                date: .now
            ),
            HistoryStore.Entry(url: "https://example.com", title: "A real page", date: .now),
        ])

        #expect(store.entries.map(\.url) == ["https://example.com"])
    }

    @Test func anUntitledPageIsNamedByItsAddress() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/bare", title: "")
        #expect(store.entries.first?.title == "https://example.com/bare")
    }

    @Test func removingOnePageLeavesTheRestAlone() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "Keep")
        store.record(url: "https://example.com/b", title: "Drop")
        guard let doomed = store.entries.first(where: { $0.url == "https://example.com/b" }) else {
            Issue.record("the entry that was just recorded is missing")
            return
        }

        store.remove(doomed)

        #expect(store.entries.map(\.url) == ["https://example.com/a"])
    }

    @Test func searchMatchesTitleAndURLRegardlessOfCase() {
        let (store, _) = makeStore()

        store.record(url: "https://swift.org/docs", title: "Language Guide")
        store.record(url: "https://example.com", title: "Unrelated")

        #expect(store.search("LANGUAGE").count == 1)
        #expect(store.search("swift.org").count == 1)
        #expect(store.search("nowhere").isEmpty)
    }

    @Test func anEmptyQueryReturnsTheNewestFirstAndHonoursTheLimit() {
        let (store, _) = makeStore()

        for i in 1...8 {
            store.record(url: "https://example.com/\(i)", title: "Page \(i)")
        }

        let results = store.search("", limit: 3)
        #expect(results.count == 3)
        #expect(results.first?.url == "https://example.com/8")
    }

    /// The "last hour" of a clear: everything visited after the cutoff goes,
    /// everything before it stays.
    @Test func clearingSinceADateKeepsWhatCameBefore() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/old", title: "Old")
        let cutoff = Date()
        store.record(url: "https://example.com/new", title: "New")

        store.removeEntries(since: cutoff)
        #expect(store.entries.map(\.url) == ["https://example.com/old"])
    }

    /// Retention is enforced against what is *loaded*, not only what is
    /// recorded: entries persisted last month must not outlive a "keep a
    /// day" promise just because the app was closed in between.
    @Test func pruneDropsEntriesOlderThanTheRetentionChoice() {
        let (store, _) = makeStore()

        store.merge([
            HistoryStore.Entry(
                url: "https://example.com/last-week",
                title: "A week ago",
                date: Date(timeIntervalSinceNow: -3 * 86_400)
            ),
            HistoryStore.Entry(url: "https://example.com/today", title: "Today", date: .now),
        ])
        #expect(store.entries.count == 2)

        store.prune(retention: .day)
        #expect(store.entries.map(\.url) == ["https://example.com/today"])
    }

    @Test func foreverMeansForever() {
        let (store, _) = makeStore()

        store.merge([
            HistoryStore.Entry(
                url: "https://example.com/2020",
                title: "Years back",
                date: Date(timeIntervalSinceNow: -6 * 365 * 86_400)
            ),
        ])
        store.prune(retention: .forever)
        #expect(store.entries.count == 1)
    }

    @Test func historySurvivesARelaunch() {
        let (store, database) = makeStore()

        store.record(url: "https://example.com/kept", title: "Kept")

        let reloaded = HistoryStore(database: database)
        #expect(reloaded.entries.map(\.url) == ["https://example.com/kept"])
    }

    @Test func clearEmptiesEverything() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com", title: "Something")
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(store.search("").isEmpty)
    }

    // MARK: - The table behind the window

    /// The window is what the lists draw; the table is everything. Search
    /// goes to the table, which is the whole point of it being one.
    @Test func searchFindsAPageThatFellOutOfTheWindow() {
        let store = HistoryStore(database: .temporary(), windowSize: 2)

        store.record(url: "https://example.com/needle", title: "Needle")
        store.record(url: "https://example.com/b", title: "Filler B")
        store.record(url: "https://example.com/c", title: "Filler C")

        #expect(store.entries.count == 2)
        #expect(!store.entries.contains { $0.url.hasSuffix("/needle") })
        #expect(store.search("needle").map(\.url) == ["https://example.com/needle"])
    }

    @Test func countIsTheWholeTableNotJustTheWindow() {
        let store = HistoryStore(database: .temporary(), windowSize: 2)

        for i in 1...5 {
            store.record(url: "https://example.com/\(i)", title: "Page \(i)")
        }

        #expect(store.entries.count == 2)
        #expect(store.count == 5)
    }

    @Test func countFollowsRemovalAndRevisits() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "A")
        store.record(url: "https://example.com/b", title: "B")
        // A revisit is the same page, so the count must not move.
        store.record(url: "https://example.com/a", title: "A again")
        #expect(store.count == 2)

        guard let doomed = store.entries.first(where: { $0.url.hasSuffix("/b") }) else {
            Issue.record("the entry that was just recorded is missing")
            return
        }
        store.remove(doomed)
        #expect(store.count == 1)
        #expect(store.count == store.entries.count)
    }

    @Test func revisitsAreCountedRatherThanOverwritten() throws {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "First")
        store.record(url: "https://example.com/a", title: "Second")
        store.record(url: "https://example.com/a", title: "Third")

        let entry = try #require(store.entries.first)
        #expect(entry.visitCount == 3)
        #expect(entry.title == "Third")
    }

    /// A page opened every day should beat one opened once, even when the
    /// once was more recent - that is what the visit count is kept for.
    @Test func searchPutsTheOftenVisitedPageFirst() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/rare", title: "Swift rare")
        for _ in 1...4 {
            store.record(url: "https://example.com/daily", title: "Swift daily")
        }
        store.record(url: "https://example.com/rare", title: "Swift rare")

        #expect(store.search("swift").map(\.url).first == "https://example.com/daily")
    }

    @Test func searchMatchesAPrefixRatherThanOnlyAWholeWord() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "Documentation")

        #expect(store.search("docum").count == 1)
        #expect(store.search("documentation").count == 1)
        #expect(store.search("cumenta").isEmpty)
    }

    @Test func searchBoundsToTheDaysAPhraseNames() {
        let (store, _) = makeStore()
        let calendar = Calendar.current
        let now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let lastMonth = calendar.date(byAdding: .day, value: -40, to: now)!

        store.merge([
            HistoryStore.Entry(url: "https://example.com/fresh", title: "Pricing fresh", date: yesterday),
            HistoryStore.Entry(url: "https://example.com/stale", title: "Pricing stale", date: lastMonth),
        ])

        let bounded = HistoryQuery.parse("pricing yesterday", now: now, calendar: calendar)
        #expect(store.search(matching: bounded, limit: 10).map(\.url) == ["https://example.com/fresh"])

        let dateOnly = HistoryQuery.parse("yesterday", now: now, calendar: calendar)
        #expect(store.search(matching: dateOnly, limit: 10).map(\.url) == ["https://example.com/fresh"])

        let unbounded = HistoryQuery.parse("pricing", now: now, calendar: calendar)
        #expect(store.search(matching: unbounded, limit: 10).count == 2)
    }

    @Test func mergeAddsUpVisitsAndTakesTheNewerTitle() throws {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "Live")
        store.merge([
            HistoryStore.Entry(url: "https://example.com/a", title: "Stale", date: .distantPast),
        ])

        let entry = try #require(store.entries.first)
        #expect(entry.visitCount == 2)
        // The older visit must not rename the page.
        #expect(entry.title == "Live")
    }

    // MARK: - Visits

    /// The reason the visit log exists. Clearing "the last hour" used to
    /// delete whole page rows by their *last* visit, so a page opened this
    /// morning and again months ago lost both.
    @Test func clearingSinceADateSpareTheOlderVisitToTheSamePage() throws {
        let (store, _) = makeStore()
        let longAgo = Date(timeIntervalSinceNow: -90 * 24 * 3600)

        store.merge([
            HistoryStore.Entry(url: "https://example.com/a", title: "Ages ago", date: longAgo),
        ])
        let cutoff = Date()
        store.record(url: "https://example.com/a", title: "Just now")

        store.removeEntries(since: cutoff)

        // The page survives, because it was not only visited in the window.
        let entry = try #require(store.entries.first { $0.url == "https://example.com/a" })
        #expect(entry.visitCount == 1)
        #expect(store.visits.count == 1)
        // And what is left is the visit from before the cutoff.
        #expect(store.visits.first?.visitedAt ?? .now < cutoff)
    }

    /// The other half: a page whose every visit falls in the window goes.
    @Test func clearingSinceADateDropsAPageVisitedOnlyInside() {
        let (store, _) = makeStore()
        let cutoff = Date()

        store.record(url: "https://example.com/only", title: "Only inside")
        store.removeEntries(since: cutoff)

        #expect(store.entries.isEmpty)
        #expect(store.visits.isEmpty)
        #expect(store.count == 0)
    }

    @Test func aRevisitIsTwoVisitsAndOneEntry() {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "First")
        store.record(url: "https://example.com/a", title: "Second")

        #expect(store.entries.count == 1)
        #expect(store.visits.count == 2)
        #expect(store.visits.allSatisfy { $0.url == "https://example.com/a" })
    }

    @Test func removingOneVisitLeavesTheOtherAndKeepsThePage() throws {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "First")
        let second = try #require(store.record(url: "https://example.com/a", title: "Second"))

        store.removeVisit(second)

        #expect(store.visits.count == 1)
        let entry = try #require(store.entries.first)
        #expect(entry.visitCount == 1)
    }

    /// One collapsed history row can stand for several visits; removing it
    /// removes all of them in one write.
    @Test func removingSeveralVisitsAtOnceTakesThePageWithThem() throws {
        let (store, _) = makeStore()

        let first = try #require(store.record(url: "https://example.com/a", title: "First"))
        let second = try #require(store.record(url: "https://example.com/a", title: "Second"))
        store.record(url: "https://example.com/b", title: "Elsewhere")

        store.removeVisits([first, second])

        #expect(store.entries.map(\.url) == ["https://example.com/b"])
        #expect(store.visits.count == 1)
    }

    /// Every way a visit can disappear while a tab still remembers it as the page it came from.
    enum Forgetting: CaseIterable, CustomTestStringConvertible {
        case clear, sinceADate, onlyThatVisit, thePage

        var testDescription: String {
            "\(self)"
        }

        @MainActor
        func perform(on store: HistoryStore, forgetting visit: Int64) {
            switch self {
            case .clear:
                store.clear()
            case .sinceADate:
                store.removeEntries(since: .distantPast)
            case .onlyThatVisit:
                store.removeVisit(visit)
            case .thePage:
                if let entry = store.entries.first {
                    store.remove(entry)
                }
            }
        }
    }

    /// A tab keeps the id of its last visit, so a link clicked after Clear History names a visit that is gone.
    /// The foreign key on `fromVisit` must not turn that into a visit nobody recorded.
    @Test(arguments: Forgetting.allCases)
    func aVisitFromAForgottenVisitIsStillRecorded(forgetting: Forgetting) throws {
        let (store, _) = makeStore()
        let earlier = try #require(store.record(url: "https://example.com/a", title: "A"))
        forgetting.perform(on: store, forgetting: earlier)

        let visit = store.record(
            url: "https://example.com/b",
            title: "B",
            transition: .link,
            fromVisit: earlier
        )

        #expect(visit != nil)
        #expect(store.visits.map(\.url) == ["https://example.com/b"])
        #expect(store.referrerChain(to: try #require(visit)).map(\.url) == ["https://example.com/b"])
    }

    /// The tab hands over a trail as well as a visit. One that no stored visit carries any more is the trail of
    /// something Clear History removed, and it ends there.
    @Test func aTrailThatNoStoredVisitCarriesStartsOver() throws {
        let (store, _) = makeStore()
        let first = try #require(store.record(url: "https://example.com/a", title: "A"))
        store.record(url: "https://example.com/b", title: "B", transition: .link, fromVisit: first, trail: first)
        store.clear()

        let visit = try #require(store.record(
            url: "https://example.com/c",
            title: "C",
            transition: .link,
            fromVisit: first,
            trail: first
        ))

        #expect(store.visits.map(\.trail) == [visit], "the trail starts again with this visit")
    }

    @Test func aTrailSurvivesRemovingItsFirstVisit() throws {
        let (store, _) = makeStore()
        let first = try #require(store.record(url: "https://example.com/a", title: "A"))
        let second = try #require(store.record(url: "https://example.com/b", title: "B", trail: first))
        store.removeVisit(first)

        let third = try #require(store.record(url: "https://example.com/c", title: "C", trail: first))

        #expect(store.visits.map(\.id) == [third, second])
        #expect(Set(store.visits.map(\.trail)) == [first], "the trail is still carried by the visits that remain")
    }

    @Test func clearingHistoryRemovesEveryTrail() throws {
        let (store, database) = makeStore()
        let first = try #require(store.record(url: "https://example.com/a", title: "A"))
        store.record(url: "https://example.com/b", title: "B", transition: .link, fromVisit: first, trail: first)

        store.clear()

        #expect(store.visits.isEmpty)
        try database.writer.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyVisit") == 0)
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyVisit WHERE trail IS NOT NULL") == 0)
        }
    }

    @Test func clearingARangeRemovesTheTrailsInsideItAndKeepsTheOthers() throws {
        let (store, database) = makeStore()
        let kept = try #require(store.record(url: "https://example.com/a", title: "A"))
        let cutoff = Date()
        let inside = try #require(store.record(url: "https://example.com/b", title: "B"))
        store.record(url: "https://example.com/c", title: "C", transition: .link, fromVisit: inside, trail: inside)

        store.removeEntries(since: cutoff)

        #expect(store.visits.map(\.id) == [kept])
        #expect(store.visits.map(\.trail) == [kept])
        try database.writer.read { db throws in
            #expect(try Int64.fetchAll(db, sql: "SELECT DISTINCT trail FROM historyVisit") == [kept])
        }
        let next = try #require(store.record(url: "https://example.com/d", title: "D", trail: inside))
        #expect(store.visits.first?.trail == next, "the cleared trail does not come back")
    }

    /// Pruning by age takes visits, and so trails, the same way a range clear does.
    @Test func pruningTakesTheTrailsOfOldVisitsToo() throws {
        let (store, database) = makeStore()
        store.merge([HistoryStore.Entry(url: "https://example.com/old", title: "Old", date: Date(timeIntervalSinceNow: -90 * 24 * 3600))])
        let fresh = try #require(store.record(url: "https://example.com/new", title: "New"))

        store.prune(retention: .month)

        #expect(store.visits.map(\.id) == [fresh])
        try database.writer.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyVisit") == 1)
        }
    }

    @Test func removingNoVisitsChangesNothing() {
        let (store, _) = makeStore()
        store.record(url: "https://example.com/a", title: "Only")

        store.removeVisits([])
        store.removeVisits([9999])

        #expect(store.entries.count == 1)
        #expect(store.visits.count == 1)
    }

    /// Removing the last visit takes the page with it - a page with no
    /// visits is a row nothing can reach.
    @Test func removingTheLastVisitRemovesThePage() throws {
        let (store, _) = makeStore()

        let only = try #require(store.record(url: "https://example.com/a", title: "Only"))
        store.removeVisit(only)

        #expect(store.entries.isEmpty)
        #expect(store.visits.isEmpty)
    }

    @Test func aVisitRemembersHowThePageWasReached() throws {
        let (store, _) = makeStore()

        store.record(url: "https://example.com/a", title: "Typed", transition: .typed)
        store.record(url: "https://example.com/b", title: "Clicked", transition: .link)

        #expect(store.visits.first?.transition == .link)
        #expect(store.visits.last?.transition == .typed)
    }

    /// What a per-URL history cannot answer: which page led to this one.
    @Test func theReferrerChainWalksBackToWhereItStarted() throws {
        let (store, _) = makeStore()

        let search = try #require(
            store.record(url: "https://example.com/search", title: "Search", transition: .typed)
        )
        let result = try #require(
            store.record(
                url: "https://example.com/result",
                title: "Result",
                transition: .link,
                fromVisit: search
            )
        )
        let deeper = try #require(
            store.record(
                url: "https://example.com/deeper",
                title: "Deeper",
                transition: .link,
                fromVisit: result
            )
        )

        let chain = store.referrerChain(to: deeper)
        #expect(chain.map(\.url) == [
            "https://example.com/search",
            "https://example.com/result",
            "https://example.com/deeper",
        ])
    }

    /// A typed address is where a chain starts, whatever the caller passes:
    /// nobody arrived at it from anywhere.
    @Test func aTypedAddressCarriesNoReferrer() throws {
        let (store, _) = makeStore()

        let first = try #require(store.record(url: "https://example.com/a", title: "A"))
        let second = try #require(
            store.record(
                url: "https://example.com/b",
                title: "B",
                transition: .typed,
                fromVisit: first
            )
        )

        #expect(store.referrerChain(to: second).map(\.url) == ["https://example.com/b"])
    }

    /// Pages that predate the visit log keep their count, and get the one
    /// visit that can be proven from what was stored.
    @Test func aPageFromBeforeTheVisitLogGetsOneVisit() throws {
        let (store, _) = makeStore()

        store.merge([
            HistoryStore.Entry(
                url: "https://example.com/a",
                title: "Old",
                visitCount: 12,
                lastVisit: Date(timeIntervalSinceNow: -3600)
            ),
        ])

        #expect(store.entries.first?.visitCount == 12)
        #expect(store.visits.count == 1)
        #expect(store.visits.first?.transition == .imported)
    }

    /// `merge` is what the stage session and any future importer write
    /// through: an older copy of a page must not overwrite the fresh one,
    /// and only genuinely new addresses are counted.
    @Test func mergeKeepsTheNewerVisitAndReportsOnlyNewURLs() {
        let (store, _) = makeStore()
        store.record(url: "https://known.example/", title: "Known")

        let added = store.merge([
            .init(url: "https://known.example/", title: "Stale", date: .distantPast),
            .init(url: "https://new.example/", title: "New", date: Date(timeIntervalSinceNow: -60)),
            .init(url: "file:///etc/hosts", title: "No", date: .now),
        ])

        #expect(added == 1)
        #expect(store.entries.first?.title == "Known")
        #expect(store.entries.map(\.url).contains("https://new.example/"))
        #expect(!store.entries.map(\.url).contains("file:///etc/hosts"))
    }

    @Test func aTitleThatArrivesAfterLoadReplacesThePlaceholder() throws {
        let (store, database) = makeStore()
        let url = "https://jira.example/browse/ENEY-6039"
        let visit = try #require(store.record(url: url, title: "Jira"))

        store.retitle(visit: visit, url: url, title: "[ENEY-6039] Tour cards stay on top - Jira")

        #expect(store.entries.first?.title == "[ENEY-6039] Tour cards stay on top - Jira")
        #expect(store.visits.first?.title == "[ENEY-6039] Tour cards stay on top - Jira")
        #expect(store.search("tour cards").map(\.url) == [url])
        #expect(HistoryStore(database: database).visits.first?.title == "[ENEY-6039] Tour cards stay on top - Jira")
    }

    @Test func aTitleForAnotherAddressLeavesTheVisitAlone() throws {
        let (store, _) = makeStore()
        let visit = try #require(store.record(url: "https://example.com/a", title: "A"))

        store.retitle(visit: visit, url: "https://example.com/b", title: "B")
        store.retitle(visit: visit, url: "https://example.com/a", title: "")

        #expect(store.entries.map(\.title) == ["A"])
        #expect(store.visits.map(\.title) == ["A"])
    }

    /// A page the person cleared must not come back because its title arrived late.
    @Test(arguments: Forgetting.allCases)
    func aLateTitleNeverBringsBackAForgottenPage(forgetting: Forgetting) throws {
        let (store, database) = makeStore()
        let url = "https://example.com/a"
        let visit = try #require(store.record(url: url, title: "A"))
        forgetting.perform(on: store, forgetting: visit)

        store.retitle(visit: visit, url: url, title: "A, finally titled")

        #expect(store.entries.isEmpty)
        #expect(store.visits.isEmpty)
        try database.writer.read { db throws in
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyPage") == 0)
        }
    }

    @Test func aVisitStartsItsOwnTrailUnlessItContinuesOne() throws {
        let (store, database) = makeStore()
        let first = try #require(store.record(url: "https://example.com/a", title: "A"))
        let second = try #require(store.record(url: "https://example.com/b", title: "B", trail: first))
        let third = try #require(store.record(url: "https://example.com/c", title: "C"))

        let trails = HistoryStore(database: database).visits.map(\.trail)
        #expect(trails == [third, first, first])
        #expect(store.visits.map(\.trail) == [third, first, first])
        #expect(second != first)
    }

    @Test func anInPageVisitRemembersWhereItCameFrom() throws {
        let (store, _) = makeStore()
        let board = try #require(store.record(url: "https://jira.example/board", title: "Board"))
        let ticket = try #require(store.record(
            url: "https://jira.example/browse/1",
            title: "Ticket",
            transition: .inPage,
            fromVisit: board,
            trail: board
        ))

        #expect(store.referrerChain(to: ticket).map(\.url) == ["https://jira.example/board", "https://jira.example/browse/1"])
        #expect(store.visits.first?.transition == .inPage)
    }

    @Test func olderVisitsLoadInPagesPastTheWindow() {
        let database = AppDatabase.temporary()
        let store = HistoryStore(database: database, windowSize: 3)
        for index in 0..<7 {
            store.record(url: "https://example.com/\(index)", title: "Page \(index)")
        }
        #expect(store.visits.map(\.url).last == "https://example.com/4")
        #expect(store.hasOlderVisits)

        store.loadOlderVisits(limit: 3)
        #expect(store.visits.map(\.url) == (1...6).reversed().map { "https://example.com/\($0)" })
        #expect(store.hasOlderVisits)

        store.loadOlderVisits(limit: 3)
        #expect(store.visits.count == 7)
        #expect(store.visits.last?.url == "https://example.com/0")
        #expect(!store.hasOlderVisits)
    }

    @Test func aNewVisitKeepsThePagedVisits() {
        let store = HistoryStore(database: .temporary(), windowSize: 3)
        for index in 0..<7 {
            store.record(url: "https://example.com/\(index)", title: "Page \(index)")
        }
        store.loadOlderVisits(limit: 3)

        store.record(url: "https://example.com/new", title: "New")
        #expect(store.visits.count == 7)
        #expect(store.visits.last?.url == "https://example.com/1")

        store.removeVisits([store.visits[0].id])
        #expect(store.visits.count == 7)
        #expect(store.visits.last?.url == "https://example.com/0")
        #expect(!store.hasOlderVisits)
    }

    @Test func clearingHistoryEndsPaging() {
        let store = HistoryStore(database: .temporary(), windowSize: 3)
        for index in 0..<7 {
            store.record(url: "https://example.com/\(index)", title: "Page \(index)")
        }
        store.loadOlderVisits(limit: 3)

        store.clear()

        #expect(store.visits.isEmpty)
        #expect(!store.hasOlderVisits)
    }

    // MARK: - A database saved before trails

    /// History written by an earlier build has no trail column. Opening it adds the column, keeps every visit, and
    /// lets the next visit start a trail.
    @Test func aDatabaseFromBeforeTrailsGainsTheColumnAndKeepsItsVisits() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryBeforeTrails-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let old = try DatabaseQueue(path: url.path)
        try old.write { db in
            try db.execute(sql: """
                CREATE TABLE historyPage (
                    url TEXT PRIMARY KEY, title TEXT NOT NULL, visitCount INTEGER NOT NULL DEFAULT 1,
                    lastVisit DOUBLE NOT NULL);
                CREATE TABLE historyVisit (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    url TEXT NOT NULL REFERENCES historyPage(url) ON DELETE CASCADE,
                    visitedAt DOUBLE NOT NULL, transition TEXT NOT NULL,
                    fromVisit INTEGER REFERENCES historyVisit(id) ON DELETE SET NULL);
                INSERT INTO historyPage VALUES ('https://example.com/a', 'A', 1, 1000);
                INSERT INTO historyVisit (url, visitedAt, transition) VALUES ('https://example.com/a', 1000, 'typed');
                """)
        }
        try old.close()

        let database = AppDatabase(at: url)
        #expect(!database.isEphemeral)
        let store = HistoryStore(database: database)
        #expect(store.visits.map(\.url) == ["https://example.com/a"])
        #expect(store.visits.first?.trail == nil)

        let earlier = try #require(store.visits.first?.id)
        let visit = try #require(store.record(
            url: "https://example.com/b", title: "B", transition: .link, fromVisit: earlier
        ))
        #expect(store.visits.map(\.trail) == [visit, nil])
        try database.writer.read { db throws in
            #expect(try db.columns(in: "historyVisit").contains { $0.name == "trail" })
            #expect(try db.columns(in: "sessionTab").contains { $0.name == "lastVisit" })
            #expect(try db.columns(in: "sessionTab").contains { $0.name == "visitTrail" })
        }
    }
}
