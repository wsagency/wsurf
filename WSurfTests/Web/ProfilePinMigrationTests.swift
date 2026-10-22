// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

/// The shape of a real profile: one recent window with 161 items, pins, folders and Favorites, then older
/// windows, some closed, that repeat some of its pins and add others.
@MainActor
@Suite(.serialized)
struct ProfilePinMigrationTests {
    private struct Windows {
        var main = UUID()
        var second = UUID()
        var third = UUID()
        var fourth = UUID()
        var fifth = UUID()
        var empty = UUID()
    }

    private func link(_ name: String) -> String {
        "https://\(name).example/"
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PinMigration-\(UUID().uuidString).sqlite")
    }

    /// Saves each window with unattached models, as every build before profile pins did.
    private func build(_ windows: Windows, in database: AppDatabase, ageOrder: [UUID]) throws {
        func save(_ id: UUID, closed: Bool = false, _ fill: (BrowserModel) -> Void) {
            let model = BrowserModel(windowID: id, database: database)
            fill(model)
            model.saveBlocking()
            if closed {
                model.markSessionClosed()
            }
            model.closeAllTabs(saving: false)
        }
        func loose(_ model: BrowserModel, _ count: Int, prefix: String) {
            for index in 0..<count {
                model.addPage(link("\(prefix)\(index)"))
            }
        }

        save(windows.main) { model in
            model.pinned(link("a")).isFavorite = true
            model.pinned(link("b")).isFavorite = true
            model.pinned(link("c"))
            let work = model.createFolder(named: "Work")
            model.pin(work)
            model.move([.tab(model.pinned(link("d")).id)], into: work, settlingPins: false)
            model.move([.tab(model.addPage(link("e")).id)], into: work, settlingPins: false)
            let nested = model.createFolder(named: "Nested")
            model.move([.folder(nested.id)], into: work, settlingPins: false)
            model.move([.tab(model.addPage(link("f")).id)], into: nested, settlingPins: false)
            let misc = model.createFolder(named: "Misc")
            for index in 0..<12 {
                model.move([.tab(model.addPage(link("misc\(index)")).id)], into: misc)
            }
            loose(model, 140, prefix: "loose")
            #expect(model.tabs.count + model.folders.count == 161)
        }
        save(windows.second, closed: true) { model in
            // Its page for this pin has moved on; the pin is still the same link.
            model.pinned(link("c")).urlString = link("c") + "elsewhere"
            model.pinned(link("g"))
            let work = model.createFolder(named: "Work")
            model.pin(work)
            model.move([.tab(model.pinned(link("d")).id)], into: work, settlingPins: false)
            model.move([.tab(model.addPage(link("h")).id)], into: work, settlingPins: false)
            model.pinned(link("i"))
            model.pinned(link("j")).isFavorite = true
            loose(model, 5, prefix: "second")
        }
        save(windows.third) { model in
            let reading = model.createFolder(named: "Reading")
            model.pin(reading)
            model.move([.tab(model.addPage(link("k")).id)], into: reading, settlingPins: false)
            loose(model, 3, prefix: "third")
        }
        save(windows.fourth, closed: true) { model in
            model.pinned(link("a"))
            loose(model, 2, prefix: "fourth")
        }
        save(windows.fifth, closed: true) { model in
            loose(model, 4, prefix: "fifth")
        }
        save(windows.empty) { _ in }

        // Index 0 is the most recently active window.
        let now = Date()
        try database.writer.write { db in
            for (index, id) in ageOrder.enumerated() {
                try db.execute(
                    sql: "UPDATE sessionWindow SET lastActiveAt = ? WHERE id = ?",
                    arguments: [now.addingTimeInterval(-3_600 * Double(index)), id]
                )
            }
        }
    }

    /// Runs the migration again over the saved windows, as an upgrade of this database would.
    private func migrate(_ database: AppDatabase, at file: URL) throws -> AppDatabase {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v3-profile-pins"])
        }
        return AppDatabase(at: file)
    }

    private func stored(_ database: AppDatabase) throws -> [ProfilePin] {
        ProfilePin.depthFirst(try database.writer.read { try ProfilePin.fetchAll($0) })
    }

    /// A star marks a Favorite and `Name{...}` a folder; a link shows as its host's first label.
    private func outline(_ pins: [ProfilePin], under parent: UUID? = nil) -> String {
        pins.filter { $0.parentID == parent }.sorted { $0.orderKey < $1.orderKey }.map { pin -> String in
            switch pin.kind {
            case .tab:
                let name = pin.url.replacingOccurrences(of: "https://", with: "")
                    .replacingOccurrences(of: ".example/", with: "")
                return (pin.isFavorite ? "★" : "") + name
            case .folder:
                return "\(pin.title){\(outline(pins, under: pin.id))}"
            }
        }.joined(separator: " ")
    }

    private func migrated(
        _ order: (Windows) -> [UUID]
    ) throws -> (windows: Windows, file: URL, database: AppDatabase) {
        let windows = Windows()
        let file = temporaryFile()
        let original = AppDatabase(at: file)
        try build(windows, in: original, ageOrder: order(windows))
        return (windows, file, try migrate(original, at: file))
    }

    @Test func migrationMergesEveryWindowsPinsWithoutDuplicates() throws {
        let run = try migrated { [$0.empty, $0.main, $0.second, $0.third, $0.fourth, $0.fifth] }
        defer { try? FileManager.default.removeItem(at: run.file) }
        let pins = try stored(run.database)

        #expect(outline(pins) == "★a ★b c Work{d e Nested{f} h} g i ★j Reading{k}")
        let links = pins.filter { $0.kind == .tab }.map(\.url)
        #expect(links.count == 11 && Set(links).count == 11)
        #expect(pins.filter { $0.kind == .folder }.map(\.title).sorted() == ["Nested", "Reading", "Work"])
    }

    @Test func migrationKeepsTheMostRecentlyActiveWindowsOrder() throws {
        // The empty window is the newest of all and has no pins, so it decides nothing.
        let run = try migrated { [$0.empty, $0.second, $0.main, $0.third, $0.fourth, $0.fifth] }
        defer { try? FileManager.default.removeItem(at: run.file) }

        #expect(outline(try stored(run.database)) == "c g Work{d h e Nested{f}} i ★j ★a ★b Reading{k}")
    }

    @Test func migrationNeverDeletesWindowRows() throws {
        let windows = Windows()
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let original = AppDatabase(at: file)
        try build(windows, in: original, ageOrder: [windows.main, windows.second, windows.third, windows.fourth, windows.fifth, windows.empty])

        let queries = [
            "SELECT windowID, id, title, customTitle, url, state, pinnedURL, pinnedTitle, internalPage, isActive, isFavorite FROM sessionTab ORDER BY id",
            "SELECT windowID, id, position, name, color, isExpanded, isPinned FROM sessionFolder ORDER BY id",
            "SELECT windowID, position, tabID, folderID, parentID FROM sessionItem ORDER BY windowID, position",
            "SELECT id, lastActiveAt, closedAt, revision FROM sessionWindow ORDER BY id",
        ]
        func rows(_ database: AppDatabase) throws -> [[Row]] {
            try database.writer.read { db in try queries.map { try Row.fetchAll(db, sql: $0) } }
        }
        let before = try rows(original)
        // 158 tabs in the main window and 22 in the others, 5 folders, 6 windows.
        #expect(before[0].count == 180 && before[1].count == 5 && before[3].count == 6)

        let upgraded = try migrate(original, at: file)
        #expect(try rows(upgraded) == before)

        // Only the link to the profile's pins was added.
        let linkedTabs = try upgraded.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessionTab WHERE pinID IS NOT NULL") }
        let linkedFolders = try upgraded.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sessionFolder WHERE pinID IS NOT NULL") }
        // main: a b c d e f, second: c g d h i j, third: k, fourth: a.
        #expect(linkedTabs == 14)
        // main: Work Nested, second: Work, third: Reading.
        #expect(linkedFolders == 4)
    }

    @Test func migrationRunsOnceAndIsIdempotent() throws {
        let run = try migrated { [$0.empty, $0.main, $0.second, $0.third, $0.fourth, $0.fifth] }
        defer { try? FileManager.default.removeItem(at: run.file) }
        func links(_ database: AppDatabase) throws -> [String] {
            try database.writer.read { db in
                try String.fetchAll(db, sql: """
                    SELECT 'tab ' || hex(id) || ' ' || IFNULL(hex(pinID), '-') FROM sessionTab
                    UNION ALL SELECT 'folder ' || hex(id) || ' ' || IFNULL(hex(pinID), '-') FROM sessionFolder
                    ORDER BY 1
                    """)
            }
        }
        let pins = try stored(run.database)
        let linked = try links(run.database)

        let reopened = AppDatabase(at: run.file)
        #expect(try stored(reopened) == pins)
        #expect(try links(reopened) == linked)

        try reopened.writer.write { try ProfilePinMigration.run(in: $0) }
        #expect(try stored(reopened) == pins)
        #expect(try links(reopened) == linked)
    }

    @Test func migratedWindowsRestoreEachPinOnceWithTheirOwnPages() throws {
        let run = try migrated { [$0.empty, $0.main, $0.second, $0.third, $0.fourth, $0.fifth] }
        defer { try? FileManager.default.removeItem(at: run.file) }
        let pins = try stored(run.database)
        let tabPins = Set(pins.filter { $0.kind == .tab }.map(\.id))

        let main = BrowserModel(windowID: run.windows.main, database: run.database)
        let second = BrowserModel(windowID: run.windows.second, database: run.database)
        main.restoreSession()
        second.restoreSession()
        defer {
            main.closeAllTabs(saving: false)
            second.closeAllTabs(saving: false)
        }

        for window in [main, second] {
            let linked = window.tabs.compactMap(\.pinID)
            #expect(linked.count == 11 && Set(linked) == tabPins)
            let placed = window.sidebarTree.walk().compactMap { item -> UUID? in
                switch item {
                case .tab(let id):
                    window.tab(id: id)?.pinID
                case .folder(let id):
                    window.profileFolderIDs.contains(id) ? id : nil
                }
            }
            #expect(placed == pins.map(\.id))
        }
        // Loose tabs stay where they were, and only their own window has them.
        #expect(main.tabs.count == 152 + 11)
        #expect(second.tabs.count == 5 + 11)
        #expect(main.folders.contains { $0.name == "Misc" })

        // The second window kept its own page for a pin that the main window opens at the pin's link.
        let moved = second.tabs.first { $0.urlString == link("c") + "elsewhere" }
        #expect(moved?.pinID == main.tabs.first { $0.urlString == link("c") }?.pinID)
        #expect(second.page(at: link("c")) == nil)
    }
}
