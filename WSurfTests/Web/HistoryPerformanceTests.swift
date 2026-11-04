// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import GRDB
import XCTest

@testable import WSurf

// XCTest owns and runs one instance serially. Sendable lets its synchronous
// measurement callback enter the app target's main-actor boundary.
nonisolated final class HistoryPerformanceTests: XCTestCase, @unchecked Sendable {
    /// Clearing is measured over 6,000 pages and about 9,400 visits, a history of a year or two. The cost of it was quadratic in
    /// the visits (50,000 pages took 7 minutes in the same statement from the command line), so a case that fits the six
    /// passes of a gate run is small beside a real history.
    private static let clearedPages = 6_000
    private static let searchedPages = 50_000

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryPerformance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Hands the allocator's free pages back, so the footprint holds what is live (as `VaultScalePerformanceTests` does).
    private static func returnFreePages() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    /// Erasing all of a profile's history, Clear History's work: the pages, their visits, the referrers that pointed from one
    /// visit to the next, and the full-text index. The database is made before each pass, outside the measurement.
    func testClearingALargeHistory() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let options = XCTMeasureOptions.budgeted
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        var passes = 0

        MainActor.assumeIsolated {
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
                passes += 1
                autoreleasepool {
                    let database = AppDatabase(at: directory.appendingPathComponent("History-\(passes).sqlite"))
                    XCTAssertFalse(database.isEphemeral)
                    do {
                        try HistoryPerformanceFixture.populate(database, pages: Self.clearedPages)
                    } catch {
                        XCTFail("The history was not made: \(error)")
                    }
                    let store = HistoryStore(database: database)
                    XCTAssertEqual(store.count, Self.clearedPages)
                    Self.returnFreePages()
                    startMeasuring()
                    store.clear()
                    XCTAssertEqual(store.count, 0)
                    XCTAssertTrue(store.entries.isEmpty)
                    Self.returnFreePages()
                    stopMeasuring()
                    try? database.writer.close()
                }
            }
        }
    }

    /// The queries of the two cases below: the first letter or two of a query, each the start of a word in a large part of the
    /// table ("ht" and "ww" in nearly every address).
    private static let firstLetters = ["c", "co", "ht", "ww", "ne", "a", "go", "sh", "ma", "vi"]

    /// A store over a history of 50,000 pages, its window read and the words of the window looked at once, which is not what
    /// the cases measure.
    @MainActor
    private func makeSearchedStore(in directory: URL) -> (HistoryStore, AppDatabase) {
        let database = AppDatabase(at: directory.appendingPathComponent("History.sqlite"))
        do {
            try HistoryPerformanceFixture.populate(database, pages: Self.searchedPages)
        } catch {
            XCTFail("The history was not made: \(error)")
        }
        let store = HistoryStore(database: database)
        XCTAssertEqual(store.entries.count, 3_000)
        XCTAssertEqual(store.count, Self.searchedPages)
        _ = store.search("c")
        return (store, database)
    }

    /// The search alone: the ten queries, each asking for the 50 pages that the omnibox ranks its rows from.
    func testSearchingForTheFirstLettersOfAQueryOverFiftyThousandPages() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        MainActor.assumeIsolated {
            let (store, database) = makeSearchedStore(in: directory)
            var found: [[HistoryStore.Entry]] = []
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                found = Self.firstLetters.map { store.search($0, limit: 50) }
            }

            XCTAssertEqual(found.map(\.count), [Int](repeating: 50, count: Self.firstLetters.count))
            try? database.writer.close()
        }
    }

    /// What the omnibox asks for while someone types, through the path the Ask surface and the command palette take, ranking and
    /// rows included.
    func testTypingTheFirstLettersOfAQueryOverFiftyThousandPages() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        MainActor.assumeIsolated {
            let (store, database) = makeSearchedStore(in: directory)
            var sections: [OmniboxSection?] = []
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                sections = Self.firstLetters.map { Omnibox.historySection(query: $0, store: store, limit: 5, open: { _ in }) }
            }

            XCTAssertEqual(sections.map { $0?.items.count ?? 0 }, [Int](repeating: 5, count: Self.firstLetters.count))
            try? database.writer.close()
        }
    }

    /// Someone typing one word into the Start page's address field, over 50,000 pages: the queries of three to ten letters, which
    /// search the full-text index. The surface's body reads the rows three times for each of them, as it does when the text changes
    /// and again when a title or the assistant's status changes the page. The rows come from `AskSurfaceModel`, ranking included, and
    /// a query needs one search however often they are read.
    func testTypingAWordIntoTheAddressFieldOverFiftyThousandPages() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        MainActor.assumeIsolated {
            let (store, database) = makeSearchedStore(in: directory)
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary(), history: store))
            defer { coordinator.browser.cancelPendingSave() }
            let model = AskSurfaceModel(placement: .startPage, browser: coordinator.browser, coordinator: coordinator)
            model.fieldFocusDidChange(true)
            let word = Array("githubwiki")
            var rows = 0
            var passes = 0
            Omnibox.$agentOnlyForTesting.withValue(true) {
                measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                    passes += 1
                    for length in 3...word.count {
                        model.interaction.text = String(word.prefix(length))
                        for _ in 0..<3 {
                            rows = model.sections.flattened.count
                        }
                    }
                }
            }

            XCTAssertEqual(rows, 3, "the question and the two pages found")
            XCTAssertEqual(model.sectionComputations, passes * (word.count - 2), "one computation for each query")
            try? database.writer.close()
        }
    }

    /// The same typing as above with the app's store, which reads the full-text index off the main thread. What a keystroke costs the
    /// main thread is the lookup in the cache and the start of a read, not the read: it was 2 ms a query. The rows of a query arrive
    /// after the keystroke, so this case counts the main thread's time and the reads started, one for each query however often the
    /// rows are read.
    func testTypingAWordWithTheSearchInTheBackgroundOverFiftyThousandPages() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        MainActor.assumeIsolated {
            let (sync, database) = makeSearchedStore(in: directory)
            _ = sync
            let store = HistoryStore(database: database, searchesInBackground: true)
            _ = store.entries
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary(), history: store))
            defer { coordinator.browser.cancelPendingSave() }
            let model = AskSurfaceModel(placement: .startPage, browser: coordinator.browser, coordinator: coordinator)
            model.fieldFocusDidChange(true)
            let word = Array("githubwiki")
            Omnibox.$agentOnlyForTesting.withValue(true) {
                measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                    for length in 3...word.count {
                        model.interaction.text = String(word.prefix(length))
                        for _ in 0..<3 {
                            _ = model.sections.flattened.count
                        }
                    }
                }
            }

            XCTAssertLessThanOrEqual(store.backgroundSearchCount, word.count - 2, "one read for each query")
            try? database.writer.close()
        }
    }

    /// Opening a profile's database that already holds 50,000 pages, once for each profile at launch. Every open used to
    /// define the schema again, and defining the full-text index rebuilds it from the pages.
    func testOpeningAProfileDatabaseOfFiftyThousandPages() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite")

        MainActor.assumeIsolated {
            let database = AppDatabase(at: url)
            do {
                try HistoryPerformanceFixture.populate(database, pages: Self.searchedPages)
            } catch {
                XCTFail("The history was not made: \(error)")
            }
            try? database.writer.close()

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                let reopened = AppDatabase(at: url)
                XCTAssertFalse(reopened.isEphemeral)
                try? reopened.writer.close()
            }

            let last = AppDatabase(at: url)
            XCTAssertFalse(last.isEphemeral)
            XCTAssertEqual(HistoryStore(database: last).count, Self.searchedPages)
            try? last.writer.close()
        }
    }
}

/// A history like a long-used profile's, the same every time: addresses and titles of many sites, pages visited once or a few
/// times, and most visits made by following a link from the one before.
private enum HistoryPerformanceFixture {
    private static let names = [
        "news", "shop", "mail", "docs", "github", "wiki", "video", "music", "maps", "travel", "store", "bank", "blog", "forum",
        "photo", "cloud", "sports", "weather", "recipe", "jobs", "learn", "course", "stack", "reddit", "amazon", "apple",
        "google", "example", "support", "account", "review", "guide",
    ]
    private static let domains = ["com", "org", "net", "io", "co.uk", "hr", "de", "dev"]

    static func populate(_ database: AppDatabase, pages: Int) throws {
        let now = Date().timeIntervalSinceReferenceDate
        try database.writer.write { db in
            let page = try db.makeStatement(
                sql: "INSERT INTO historyPage (url, title, visitCount, lastVisit) VALUES (?, ?, ?, ?)"
            )
            let visit = try db.makeStatement(
                sql: "INSERT INTO historyVisit (url, visitedAt, transition, fromVisit) VALUES (?, ?, ?, ?)"
            )
            var previous: Int64?
            for index in 0..<pages {
                let mix = (index &* 2_654_435_761) % 1_000
                let site = names[mix % names.count] + names[(mix / 7) % names.count] + String(mix)
                let section = names[(mix / 3) % names.count]
                let url = "https://www.\(site).\(domains[mix % domains.count])/\(section)/\(names[(index / 5) % names.count])-\(index)"
                let title = names[(index / 3) % names.count].capitalized + " " + names[(index / 11) % names.count] + " - " + site
                let visits = 1 + (index % 7 == 0 ? 2 : (index % 3 == 0 ? 1 : 0))
                let last = now - Double(index % 90) * 86_400 - Double(index)
                try page.execute(arguments: [url, title, visits, last])
                for step in 0..<visits {
                    let followed = step > 0 || mix % 10 < 6
                    try visit.execute(arguments: [url, last - Double(step) * 3_600, followed ? "link" : "typed", followed ? previous : nil])
                    previous = db.lastInsertedRowID
                }
            }
        }
    }
}
