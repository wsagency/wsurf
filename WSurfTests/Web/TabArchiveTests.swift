// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import GRDB
import Testing

@testable import WSurf

/// Tabs left unused close into an archive that history clearing empties and that the assistant never reads.
@MainActor
struct TabArchiveTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400

    private func makeModel() -> BrowserModel {
        BrowserModel(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("TabArchivePermissions-\(UUID().uuidString).json")
            )
        )
    }

    /// A model with a blank tab in front, which loads nothing and is never a candidate.
    private func makeModelInFront() -> BrowserModel {
        let model = makeModel()
        model.newTab()
        return model
    }

    /// An unloaded tab last used `age` seconds before `now`.
    @discardableResult
    private func stalePage(
        in model: BrowserModel, _ address: String, unusedFor age: TimeInterval = 30 * 86_400
    ) -> BrowserTab {
        let tab = model.addPage(address)
        tab.lastActiveAt = now.addingTimeInterval(-age)
        return tab
    }

    // MARK: - Sweeping

    @Test func aTabUnusedPastTheDelayMovesToTheArchive() {
        let model = makeModelInFront()
        let stale = stalePage(in: model, "https://example.test/old", unusedFor: 2 * day)
        stale.title = "Old page"

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 1)

        #expect(!model.tabs.contains { $0 === stale })
        #expect(model.tabArchive.entries.map(\.url) == ["https://example.test/old"])
        #expect(model.tabArchive.entries.first?.title == "Old page")
        #expect(model.tabArchive.entries.first?.archivedAt == now)
        #expect(!model.canReopenClosedTab)
    }

    @Test func aRecentlyUsedTabStays() {
        let model = makeModelInFront()
        let recent = stalePage(in: model, "https://example.test/recent", unusedFor: 3600)

        #expect(model.archiveTabs(unusedFor: .twelveHours, now: now) == 0)
        #expect(model.tabs.contains { $0 === recent })
        #expect(model.tabArchive.entries.isEmpty)
    }

    @Test func neverArchivesNothing() {
        let model = makeModelInFront()
        let stale = stalePage(in: model, "https://example.test/old", unusedFor: 365 * day)

        #expect(model.archiveTabs(unusedFor: .never, now: now) == 0)
        #expect(model.tabs.contains { $0 === stale })
    }

    @Test func theActiveTabStaysHoweverOld() {
        let model = makeModel()
        let active = model.newTab()
        active.lastActiveAt = now.addingTimeInterval(-30 * day)

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 0)
        #expect(model.tabs.contains { $0 === active })
    }

    @Test func aPinnedTabStays() {
        let model = makeModelInFront()
        let pinned = model.pinned("https://example.test/pinned")
        pinned.lastActiveAt = now.addingTimeInterval(-30 * day)

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 0)
        #expect(model.tabs.contains { $0 === pinned })
    }

    @Test func aPageOfAProfilePinStays() {
        let model = makeModelInFront()
        let page = stalePage(in: model, "https://example.test/pin")
        page.pinID = UUID()

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 0)
        #expect(model.tabs.contains { $0 === page })
    }

    @Test func aFavoriteStays() {
        let model = makeModelInFront()
        let favorite = stalePage(in: model, "https://example.test/favorite")
        favorite.isFavorite = true

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 0)
        #expect(model.tabs.contains { $0 === favorite })
    }

    @Test func aTabInAFolderStays() {
        let model = makeModelInFront()
        let filed = stalePage(in: model, "https://example.test/filed")
        let other = stalePage(in: model, "https://example.test/other")
        _ = model.createFolder(named: "Kept", containing: [filed])

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 1)
        #expect(model.tabs.contains { $0 === filed })
        #expect(!model.tabs.contains { $0 === other })
    }

    @Test func tabsInASplitStay() {
        let model = makeModelInFront()
        let left = stalePage(in: model, "https://example.test/left")
        let right = stalePage(in: model, "https://example.test/right")
        let alone = stalePage(in: model, "https://example.test/alone")
        model.split(left, with: right, axis: .sideBySide)

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 1)
        #expect(model.tabs.contains { $0 === left })
        #expect(model.tabs.contains { $0 === right })
        #expect(!model.tabs.contains { $0 === alone })
    }

    @Test func aTabInUseStays() {
        let model = makeModelInFront()
        let assistant = stalePage(in: model, "https://assistant.example.test/")
        assistant.setAgentWorking(true)
        let client = stalePage(in: model, "https://client.example.test/")
        client.setExternalAutomationWorking(true)
        let kept = stalePage(in: model, "https://kept.example.test/")
        model.setKeepsActive(true, for: kept)
        let download = stalePage(in: model, "https://download.example.test/")
        let downloadID = model.downloads.beginItem(
            source: URL(string: "https://download.example.test/file.zip"),
            sourceTabID: download.id
        )
        defer { model.downloads.noteFailure(downloadID, reason: "Stopped", resumeData: nil) }
        stalePage(in: model, "https://idle.example.test/")

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 1)

        #expect(model.tabArchive.entries.map(\.url) == ["https://idle.example.test/"])
        for tab in [assistant, client, kept, download] {
            #expect(model.tabs.contains { $0 === tab })
        }
    }

    @Test(.boundedWebViews) func aStartPageTabClosesWithoutAnArchiveEntry() {
        let model = makeModelInFront()
        let blank = model.newTab(activate: false)
        blank.lastActiveAt = now.addingTimeInterval(-30 * day)

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 1)
        #expect(!model.tabs.contains { $0 === blank })
        #expect(model.tabArchive.entries.isEmpty)
    }

    @Test func aPrivateWindowNeverArchives() {
        let model = makeModel()
        model.adopt(
            database: .temporary(),
            sitePermissions: SitePermissions(
                storageURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("TabArchivePrivate-\(UUID().uuidString).json")
            ),
            privately: true
        )
        model.newTab()
        let stale = stalePage(in: model, "https://example.test/old")

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 0)
        #expect(model.tabs.contains { $0 === stale })
        #expect(model.tabArchive.entries.isEmpty)
    }

    @Test func tabsPastTheCapacityCloseAndTheLeastRecentlyUsedAreDropped() {
        let model = makeModelInFront()
        // The higher the number, the more recently the tab was used.
        for index in 0..<40 {
            stalePage(in: model, "https://example.test/\(index)", unusedFor: 2 * day + Double(40 - index) * 60)
        }

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 40)

        #expect(model.tabs.count == 1)
        #expect(model.tabArchive.entries.count == TabArchive.capacity)
        #expect(model.tabArchive.entries.first?.url == "https://example.test/39")
        #expect(model.tabArchive.entries.last?.url == "https://example.test/10")
    }

    @Test func twoTabsOnOnePageLeaveOneEntry() {
        let model = makeModelInFront()
        stalePage(in: model, "https://example.test/same")
        stalePage(in: model, "https://example.test/same")

        #expect(model.archiveTabs(unusedFor: .day, now: now) == 2)
        #expect(model.tabArchive.entries.map(\.url) == ["https://example.test/same"])
    }

    @Test func aWindowWithoutADelayStartsNoTimerAndArchivesNothing() {
        let model = makeModelInFront()
        stalePage(in: model, "https://example.test/old")

        #expect(model.context.settings.archiveTabsAfter == .never)
        model.applyArchiveSweeper()
        #expect(!model.archiveSweeper.isRunning)
        #expect(model.archiveStaleTabs(now: now) == 0)
        #expect(model.tabs.count == 2)
    }

    @Test func theDelaysAreTwelveHoursADayAWeekOrNever() {
        #expect(TabArchiveDelay.allCases.map(\.interval) == [43_200, 86_400, 604_800, nil])
    }

    @Test func theDelaysAreNamedForTheSettingsMenu() {
        #expect(TabArchiveDelay.allCases.map { String(localized: $0.label) }
            == ["After 12 hours", "After a day", "After a week", "Never"])
    }

    // MARK: - The setting

    @Test func archivingIsOffUntilTheDelayIsChosenAndTheChoiceIsKept() throws {
        let suite = "TabArchiveTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        var changes = 0
        settings.onSleepPolicyChanged = { changes += 1 }
        #expect(settings.archiveTabsAfter == .never)

        settings.archiveTabsAfter = .week
        settings.archiveTabsAfter = .week
        #expect(changes == 1)
        #expect(BrowserSettings(defaults: defaults).archiveTabsAfter == .week)

        settings.resetToDefaults()
        #expect(settings.archiveTabsAfter == .never)
        defaults.set("a fortnight", forKey: "tabs.archive")
        #expect(BrowserSettings(defaults: defaults).archiveTabsAfter == .never)
    }

    // MARK: - The timer

    @Test func aNewDelaySweepsAtOnceAndThenEveryTenMinutes() async {
        let clock = TestClock()
        let sweeper = TabArchiveSweeper(clock: clock)
        var sweeps = 0

        sweeper.apply(.day) { sweeps += 1 }
        #expect(sweeps == 1)
        #expect(sweeper.isRunning)

        for expected in 2...3 {
            #expect(await waitUntil { clock.pendingCount == 1 })
            clock.advance(by: .seconds(599))
            #expect(sweeps == expected - 1)
            clock.advance(by: .seconds(1))
            #expect(await waitUntil { sweeps == expected })
        }
        sweeper.stop()
    }

    @Test func theSameDelayChangesNothingAndNeverStopsTheTimer() async {
        let clock = TestClock()
        let sweeper = TabArchiveSweeper(clock: clock)
        var sweeps = 0
        sweeper.apply(.day) { sweeps += 1 }

        sweeper.apply(.day) { sweeps += 100 }
        #expect(sweeps == 1)
        #expect(sweeper.isRunning)

        sweeper.apply(.never) { sweeps += 100 }
        #expect(!sweeper.isRunning)
        #expect(await waitUntil { clock.pendingCount == 0 })
        clock.advance(by: .seconds(3600))
        #expect(sweeps == 1)

        sweeper.apply(.week) { sweeps += 10 }
        #expect(sweeps == 11)
        #expect(sweeper.isRunning)
        sweeper.stop()
        #expect(!sweeper.isRunning)
    }

    // MARK: - Use

    @Test func leavingATabMarksItUsed() {
        let model = makeModel()
        let first = model.newTab()
        let second = model.newTab(activate: false)
        first.lastActiveAt = .distantPast
        second.lastActiveAt = .distantPast

        model.activate(second)

        #expect(first.lastActiveAt > Date(timeIntervalSinceNow: -60))
        #expect(second.lastActiveAt > Date(timeIntervalSinceNow: -60))
    }

    @Test func usingATabMarksTheOtherPanesOfItsSplit() {
        let model = makeModel()
        let elsewhere = model.newTab()
        let left = model.newTab(activate: false)
        let right = model.newTab(activate: false)
        model.split(left, with: right, axis: .sideBySide)
        left.lastActiveAt = .distantPast
        right.lastActiveAt = .distantPast

        model.activate(left)

        #expect(right.lastActiveAt > Date(timeIntervalSinceNow: -60))
        #expect(elsewhere.lastActiveAt > Date(timeIntervalSinceNow: -60))
    }

    @Test func lastUseSurvivesARestore() throws {
        let database = AppDatabase.temporary()
        let first = BrowserModel(database: database)
        defer { first.closeAllTabs(saving: false) }
        first.newTab()
        let usedAt = Date(timeIntervalSinceNow: -3600)
        first.addPage("https://example.test/old").lastActiveAt = usedAt
        first.saveBlocking()

        let reopened = BrowserModel(database: database)
        defer { reopened.closeAllTabs(saving: false) }
        reopened.restoreSession()

        let restored = try #require(reopened.page(at: "https://example.test/old"))
        #expect(abs(restored.lastActiveAt.timeIntervalSince(usedAt)) < 5)
    }

    @Test func timeWhileTheWindowWasClosedDoesNotCount() throws {
        let database = AppDatabase.temporary()
        let first = BrowserModel(database: database)
        defer { first.closeAllTabs(saving: false) }
        first.newTab()
        let usedAt = Date(timeIntervalSinceNow: -2 * day)
        first.addPage("https://example.test/old").lastActiveAt = usedAt
        first.saveBlocking()
        let closedAt = Date(timeIntervalSinceNow: -day)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE sessionWindow SET lastActiveAt = ?", arguments: [closedAt])
        }

        let reopened = BrowserModel(database: database)
        defer { reopened.closeAllTabs(saving: false) }
        reopened.restoreSession()

        let restored = try #require(reopened.page(at: "https://example.test/old"))
        #expect(abs(restored.lastActiveAt.timeIntervalSince(usedAt) - day) < 5)
        #expect(reopened.staleTabs(unusedFor: 1.5 * day).isEmpty)
    }

    @Test func anUpgradeKeepsSavedTabsAndArchivesNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabArchiveUpgrade-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let frontID = UUID()
        let savedID = UUID()
        let before = AppDatabase(at: url)
        try before.writer.write { db in
            // The schema a build without the archive left behind.
            try db.execute(sql: "ALTER TABLE sessionTab DROP COLUMN lastActiveAt")
            try db.execute(sql: "DROP TABLE archivedTab")
            for (position, row) in [(frontID, "", true), (savedID, "https://example.test/saved", false)].enumerated() {
                try db.execute(
                    sql: "INSERT INTO sessionTab (id, title, url, isActive) VALUES (?, ?, ?, ?)",
                    arguments: [row.0, "Saved", row.1, row.2]
                )
                try db.execute(sql: "INSERT INTO sessionItem (position, tabID) VALUES (?, ?)", arguments: [position, row.0])
            }
        }

        let upgraded = AppDatabase(at: url)
        try upgraded.writer.read { db throws in
            #expect(try db.columns(in: "sessionTab").contains { $0.name == "lastActiveAt" })
            #expect(try db.tableExists("archivedTab"))
        }
        let model = BrowserModel(database: upgraded)
        defer { model.closeAllTabs(saving: false) }
        model.restoreSession()

        let restored = try #require(model.tab(id: savedID))
        #expect(abs(restored.lastActiveAt.timeIntervalSinceNow) < 60)
        #expect(model.archiveTabs(unusedFor: .twelveHours) == 0)
        #expect(model.tabs.count == 2)
    }

    // MARK: - Restoring

    @Test(.boundedWebViews) func restoringOpensTheTabAfterTheActiveOneAndForgetsTheEntry() throws {
        let model = makeModel()
        let front = model.newTab()
        model.tabArchive.add([(title: "Old page", url: "https://example.test/old")], at: now)
        let entry = try #require(model.tabArchive.entries.first)

        let tab = try #require(model.restore(entry))

        let frontIndex = try #require(model.tabs.firstIndex { $0 === front })
        #expect(tab.urlString == "https://example.test/old")
        #expect(tab.title == "Old page")
        #expect(model.activeTabID == tab.id)
        #expect(model.tabs.firstIndex { $0 === tab } == frontIndex + 1)
        #expect(model.tabArchive.entries.isEmpty)
    }

    // MARK: - Store

    @Test func archivingAPageAgainKeepsOneEntry() {
        let archive = TabArchive(database: .temporary())
        archive.add([(title: "Old", url: "https://example.test")], at: now)
        archive.add([(title: "New", url: "https://example.test")], at: now.addingTimeInterval(60))

        #expect(archive.entries.map(\.title) == ["New"])
    }

    @Test func theArchiveKeepsTheNewestEntriesUpToItsCapacity() {
        let archive = TabArchive(database: .temporary())
        let pages = (0...TabArchive.capacity).map { (title: "Page \($0)", url: "https://example.test/\($0)") }
        archive.add(Array(pages.prefix(1)), at: now.addingTimeInterval(-60))
        archive.add(Array(pages.dropFirst()), at: now)

        #expect(archive.entries.count == TabArchive.capacity)
        #expect(!archive.entries.contains { $0.url == "https://example.test/0" })
    }

    @Test func pagesArchivedTogetherKeepTheLaterOnesWhenTheArchiveIsFull() {
        let archive = TabArchive(database: .temporary())

        archive.add((0..<50).map { (title: "Page \($0)", url: "https://example.test/\($0)") }, at: now)

        #expect(archive.entries.map(\.title) == (20..<50).reversed().map { "Page \($0)" })
    }

    @Test func anOversizedArchiveIsTrimmedWhenItLoads() throws {
        let database = AppDatabase.temporary()
        let start = now
        try database.writer.write { db in
            for index in 0...TabArchive.capacity {
                try TabArchive.Entry(
                    id: UUID(),
                    title: "Page \(index)",
                    url: "https://example.test/\(index)",
                    archivedAt: start.addingTimeInterval(Double(index))
                ).insert(db)
            }
        }

        let archive = TabArchive(database: database)

        #expect(archive.entries.count == TabArchive.capacity)
        #expect(!archive.entries.contains { $0.url == "https://example.test/0" })
    }

    @Test func theArchiveSkipsPagesHistoryWouldNotRecord() {
        let archive = TabArchive(database: .temporary())
        archive.add([
            (title: "Local", url: "file:///tmp/page.html"),
            (title: "Blank", url: "about:blank"),
            (title: "", url: ""),
        ], at: now)

        #expect(archive.entries.isEmpty)
    }

    @Test func removingAnEntryKeepsTheOthers() throws {
        let database = AppDatabase.temporary()
        let archive = TabArchive(database: database)
        archive.add([
            (title: "First", url: "https://example.test/first"),
            (title: "Second", url: "https://example.test/second"),
        ], at: now)

        archive.remove(try #require(archive.entries.first { $0.title == "First" }))

        #expect(archive.entries.map(\.title) == ["Second"])
        #expect(TabArchive(database: database).entries.map(\.title) == ["Second"])
    }

    // MARK: - Clearing

    @Test func recentEntriesGoWithTheRecentHistoryAndAllOfThemWithAllHistory() throws {
        let archive = TabArchive(database: .temporary())
        archive.add([(title: "Old", url: "https://example.test/old")], at: now.addingTimeInterval(-7200))
        archive.add([(title: "New", url: "https://example.test/new")], at: now)

        archive.removeEntries(since: now.addingTimeInterval(-3600))
        #expect(archive.entries.map(\.title) == ["Old"])

        archive.clear()
        #expect(archive.entries.isEmpty)
    }

    @Test func historyRetentionPrunesTheArchive() {
        let archive = TabArchive(database: .temporary())
        archive.add([(title: "Old", url: "https://example.test/old")], at: now.addingTimeInterval(-2 * day))
        archive.add([(title: "New", url: "https://example.test/new")], at: now)

        archive.prune(retention: .forever, now: now)
        #expect(archive.entries.count == 2)
        archive.prune(retention: .day, now: now)
        #expect(archive.entries.map(\.title) == ["New"])
    }

    @Test func clearHistoryEmptiesTheArchiveOverTheChosenRange() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        context.tabArchive.add([(title: "Old", url: "https://example.test/old")], at: Date(timeIntervalSinceNow: -7200))
        context.tabArchive.add([(title: "New", url: "https://example.test/new")], at: Date())

        try await BrowsingData.clear([.history], range: .hour, history: context.history, context: context)
        #expect(context.tabArchive.entries.map(\.title) == ["Old"])

        try await BrowsingData.clear([.history], range: .everything, history: context.history, context: context)
        #expect(context.tabArchive.entries.isEmpty)
    }

    @Test func erasingAProfilesHistoryEmptiesItsArchive() throws {
        let profile = Profile(id: UUID(), name: "Archive", symbol: "tray", color: .gray)
        let url = try #require(profile.databaseURL)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        TabArchive(database: AppDatabase(at: url)).add([(title: "Old", url: "https://example.test/old")], at: now)
        #expect(TabArchive(database: AppDatabase(at: url)).entries.count == 1)

        ProfileMaintenance.clearHistory(of: profile)

        #expect(TabArchive(database: AppDatabase(at: url)).entries.isEmpty)
    }

    @Test func aWindowPrunesTheArchiveByHistoryRetentionWhenItAdoptsAProfile() {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        context.settings.historyRetention = .day
        context.tabArchive.add([(title: "Old", url: "https://example.test/old")], at: Date(timeIntervalSinceNow: -2 * day))
        context.tabArchive.add([(title: "New", url: "https://example.test/new")], at: Date())
        let model = BrowserModel(context: context)

        model.adopt(database: context.database, sitePermissions: context.sitePermissions, privately: true)

        #expect(model.tabArchive.entries.map(\.title) == ["New"])
    }

    // MARK: - Command palette

    @Test func theArchiveListShowsEveryArchivedTabNewestFirst() throws {
        let archive = TabArchive(database: .temporary())
        archive.add([(title: "Older", url: "https://example.test/older")], at: now.addingTimeInterval(-60))
        archive.add([(title: "Newer", url: "https://example.test/newer")], at: now)

        let section = try #require(Omnibox.archivedSection(query: " ", entries: archive.entries) { _ in })

        #expect(section.title == String(localized: "Archived Tabs"))
        #expect(section.items.map(\.title) == ["Newer", "Older"])
    }

    @Test func theArchiveListFiltersAndRestores() throws {
        let archive = TabArchive(database: .temporary())
        archive.add([
            (title: "Quarterly report", url: "https://example.test/report"),
            (title: "Recipes", url: "https://example.test/recipes"),
        ], at: now)
        var restored: TabArchive.Entry?

        let section = try #require(Omnibox.archivedSection(
            query: "quarterly",
            entries: archive.entries
        ) { restored = $0 })
        section.items.first?.run()

        #expect(section.items.map(\.kind) == [.archived])
        #expect(section.items.first?.symbol == "archivebox")
        #expect(restored?.url == "https://example.test/report")
    }

    @Test func aTypedQueryRanksTheBestMatchAboveANewerOne() throws {
        let archive = TabArchive(database: .temporary())
        archive.add([(title: "Recipes", url: "https://example.test/b")], at: now.addingTimeInterval(-60))
        archive.add([(title: "Notes", url: "https://example.test/recipes")], at: now)

        let all = try #require(Omnibox.archivedSection(query: "", entries: archive.entries) { _ in })
        let typed = try #require(Omnibox.archivedSection(query: "recipes", entries: archive.entries) { _ in })

        #expect(all.items.map(\.title) == ["Notes", "Recipes"])
        #expect(typed.items.map(\.title) == ["Recipes", "Notes"])
    }

    @Test func anArchivedRowNamesTheSiteAndWhenItWasArchived() throws {
        let archive = TabArchive(database: .temporary())
        archive.add([(title: "Report", url: "https://example.test/report")], at: Date(timeIntervalSinceNow: -2 * day))
        let entry = try #require(archive.entries.first)

        let section = try #require(Omnibox.archivedSection(query: "", entries: archive.entries) { _ in })

        let archived = entry.archivedAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
        #expect(section.items.first?.detail == "example.test · \(archived)")
        #expect(section.items.first?.iconHost == "example.test")
    }

    @Test func removingFromTheArchiveListDeletesTheEntry() throws {
        let archive = TabArchive(database: .temporary())
        archive.add([(title: "Report", url: "https://example.test/report")], at: now)

        let section = try #require(Omnibox.archivedSection(
            query: "",
            entries: archive.entries,
            restore: { _ in },
            remove: { archive.remove($0) }
        ))
        section.items.first?.remove?()

        #expect(archive.entries.isEmpty)
    }

    @Test func theArchiveListSkipsPagesThatAreOpen() {
        let archive = TabArchive(database: .temporary())
        archive.add([(title: "Report", url: "https://example.test/report")], at: now)

        #expect(Omnibox.archivedSection(
            query: "",
            entries: archive.entries,
            excluding: ["https://example.test/report"]
        ) { _ in } == nil)
    }

    @Test func typingTheArchiveNameOffersTabIntoTheArchive() {
        #expect(CommandPaletteProjection.opensArchive("arc"))
        #expect(CommandPaletteProjection.opensArchive("Archived Tabs"))
        #expect(CommandPaletteProjection.opensArchive("show archived tabs"))
        #expect(CommandPaletteProjection.opensArchive("show arc"))
        #expect(!CommandPaletteProjection.opensArchive("ar"))
        #expect(!CommandPaletteProjection.opensArchive("show"))
        #expect(!CommandPaletteProjection.opensArchive("archive.org"))
    }

    // MARK: - What may read it

    @Test func theAssistantAndMCPNeverNameTheArchive() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["WSurf/Agent", "WSurf/MCP", "WSurf/Web/Assistant"] {
            let files = try #require(FileManager.default.enumerator(at: root.appending(path: folder), includingPropertiesForKeys: nil))
            var scanned = 0
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                scanned += 1
                for name in ["TabArchive", "tabArchive", "archivedTab"] {
                    #expect(!source.contains(name), "\(file.lastPathComponent) names \(name)")
                }
            }
            #expect(scanned > 0, "\(folder) has no sources to scan")
        }
    }
}
