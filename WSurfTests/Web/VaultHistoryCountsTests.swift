// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Testing

@testable import WSurf

/// `historyCounts` is what Settings shows as "how many" (Trash entries, earlier versions) without paging: the head-authenticated counts,
/// each checked against the stored rows. Every expectation here is against the real store and the sealed heads read back by the fixture.
struct VaultHistoryCountsTests {
    @Test func countsFollowDeleteUndeleteAndPurge() async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(
            accounts: [victim, bystander], historyRows: 3, extraHistory: [FixtureHistoryRun(subject: .totp, count: 2)]
        ) { f in
            try await f.withWallStore { store, access in
                var counts = try await store.historyCounts(vaultID: f.vaultID, using: access)
                #expect(counts.live.revision == 5 && counts.trash == HistoryCounts())

                try await f.deleteAccount(store, access, victim.id)
                counts = try await store.historyCounts(vaultID: f.vaultID, using: access)
                #expect(counts.trash.trashEntry == 1)
                #expect(counts.live.revision == 0 && counts.trash.revision == 5)
                let stored = try f.moveStoredHeads()
                #expect(counts.live == stored.source.historyCounts && counts.trash == stored.trash.historyCounts)

                try await f.undelete(store, access, try f.trashEntry(of: victim.id).row.recordID)
                counts = try await store.historyCounts(vaultID: f.vaultID, using: access)
                #expect(counts.live.revision == 5 && counts.trash == HistoryCounts())

                try await f.deleteAccount(store, access, victim.id)
                let purged = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [], emptyAll: true, authorization: f.freshAuthorization, using: access
                )
                #expect(purged.removedEntries == 1)
                counts = try await store.historyCounts(vaultID: f.vaultID, using: access)
                #expect(counts.trash.trashEntry == 0 && counts.trash.revision == 0)
                #expect(counts.live.tombstone + counts.trash.tombstone > 0)
                let after = try f.moveStoredHeads()
                #expect(counts.live == after.source.historyCounts && counts.trash == after.trash.historyCounts)
            }
            try f.verify()
        }
    }

    @Test func aTrashLargerThanOnePageIsCountedNotPaged() async throws {
        let keeper = VaultFixtures.account(username: "keeper", origin: "https://keeper.example")
        let removed = MoveFixtures.tinyAccounts(120)
        try await VaultStoreFixture.with(accounts: [keeper] + removed) { f in
            try await f.withWallStore { store, access in
                try await f.edit(store, access) { $0.filter { $0.id == keeper.id } }
                let page = try await store.trashPage(vaultID: f.vaultID, after: nil, using: access)
                let counts = try await store.historyCounts(vaultID: f.vaultID, using: access)
                #expect(page.items.count == StoreFormat.historyPage && page.next != nil)
                #expect(counts.trash.trashEntry == 120)
            }
        }
    }

    @Test func aMissingRowIsAnIntegrityFailureNotANumber() async throws {
        let victim = VaultFixtures.account(username: "victim", origin: "https://v.example")
        try await VaultStoreFixture.with(accounts: [victim, VaultFixtures.account(username: "keeper", origin: "https://k.example")]) { f in
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id).row.recordID
                _ = try await store.historyCounts(vaultID: f.vaultID, using: access)
                try f.mutate { db in
                    try db.execute(
                        sql: "DELETE FROM record WHERE vaultID = ? AND recordID = ?", arguments: [f.trashID.lowerText, entry.lowerText]
                    )
                }
                await #expect {
                    _ = try await store.historyCounts(vaultID: f.vaultID, using: access)
                } throws: { error in
                    if case CredentialStoreError.integrityFailure = error {
                        true
                    } else {
                        false
                    }
                }
            }
        }
    }

    @Test func aRevokedOrForeignAccessReadsNothing() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 2) { f in
            try await f.withWallStore { store, access in
                let stranger = f.beginAccess()
                await #expect(throws: CredentialVaultError.unauthorized) {
                    _ = try await store.historyCounts(vaultID: f.vaultID, using: stranger)
                }
                access.revoke()
                await #expect(throws: (any Error).self) {
                    _ = try await store.historyCounts(vaultID: f.vaultID, using: access)
                }
            }
        }
    }
}
