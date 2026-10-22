// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

@MainActor
struct ProfilePinStoreTests {
    private func folder(_ name: String, key: String) -> ProfilePin {
        ProfilePin(
            id: UUID(), parentID: nil, orderKey: key, kind: .folder,
            title: name, color: .blue, isExpanded: false, isPinned: true
        )
    }

    private func tab(_ link: String, key: String, in parent: UUID? = nil, favorite: Bool = false) -> ProfilePin {
        ProfilePin(
            id: UUID(), parentID: parent, orderKey: key, kind: .tab,
            url: link, title: "Title of \(link)", customTitle: "Mine", pinnedURL: URL(string: link),
            pinnedTitle: "Saved", isFavorite: favorite
        )
    }

    private func stored(in database: AppDatabase) throws -> [ProfilePin] {
        try database.writer.read { try ProfilePin.fetchAll($0) }
    }

    @Test func publishingWritesTheWholeSetInOrder() throws {
        let database = AppDatabase.temporary()
        let store = ProfilePinStore.store(for: database)
        let work = folder("Work", key: "V")
        let child = tab("https://work.example/", key: "V", in: work.id)
        let favorite = tab("https://fav.example/", key: "W", favorite: true)
        let set = ProfilePin.depthFirst([favorite, child, work])
        #expect(set.map(\.id) == [work.id, child.id, favorite.id])

        store.publish(set)
        #expect(store.pins == set)
        #expect(ProfilePin.depthFirst(try stored(in: database)) == set)

        // The next set replaces the stored one, so a removed folder takes its children with it.
        let next = ProfilePin.depthFirst([favorite, tab("https://new.example/", key: "X")])
        store.publish(next)
        #expect(ProfilePin.depthFirst(try stored(in: database)) == next)
    }

    @Test func aStoreForTheSameDatabaseIsShared() throws {
        let database = AppDatabase.temporary()
        let first = ProfilePinStore.store(for: database)
        #expect(ProfilePinStore.store(for: database) === first)
        #expect(ProfilePinStore.store(for: .temporary()) !== first)

        let set = [tab("https://one.example/", key: "V")]
        var writer: ProfilePinStore? = ProfilePinStore.store(for: database)
        writer?.publish(set)
        writer = nil
        // Once nothing holds the store, the next one reads what was written.
        #expect(ProfilePinStore.store(for: database).pins == set)
    }

    @Test func anUnchangedSetWritesNothing() throws {
        let database = AppDatabase.temporary()
        let store = ProfilePinStore.store(for: database)
        let set = [folder("Work", key: "V"), tab("https://one.example/", key: "W")]
        store.publish(set)

        // A memory database has one connection, so its change counter sees every write.
        func changes() throws -> Int {
            try database.writer.read { try Int.fetchOne($0, sql: "SELECT total_changes()") ?? 0 }
        }
        let before = try changes()
        store.publish(set)
        #expect(try changes() == before)
        store.publish(set + [tab("https://two.example/", key: "X")])
        #expect(try changes() > before)
    }

    @Test func assigningKeysKeepsEveryKeyWhileTheOrderIsUnchanged() {
        var set = ProfilePin.depthFirst([
            tab("https://a.example/", key: "V"), tab("https://b.example/", key: "W"), tab("https://c.example/", key: "X"),
        ])
        let before = set
        ProfilePin.assignOrderKeys(&set, previous: before)
        #expect(set == before)

        // Moving an item later rewrites only that item's key.
        var moved = [before[1], before[2], before[0]]
        ProfilePin.assignOrderKeys(&moved, previous: before)
        #expect(moved.map(\.id) == [before[1].id, before[2].id, before[0].id])
        #expect(moved.map(\.orderKey) == ["W", "X", "Y"])

        // Moving an item to the front rewrites the keys that follow it, and the order still sorts.
        var lifted = [before[2], before[0], before[1]]
        ProfilePin.assignOrderKeys(&lifted, previous: before)
        #expect(lifted.map(\.orderKey) == lifted.map(\.orderKey).sorted())
    }

    @Test func aNewItemBetweenTwoGetsAKeyBetweenThem() {
        let first = tab("https://a.example/", key: "V")
        let last = tab("https://c.example/", key: "W")
        var set = [first, tab("https://b.example/", key: ""), last]
        ProfilePin.assignOrderKeys(&set, previous: [first, last])
        #expect(set[0].orderKey == "V" && set[2].orderKey == "W")
        #expect("V" < set[1].orderKey && set[1].orderKey < "W")
    }
}
