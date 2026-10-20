// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// Secure items are their own history subject, like notes: they move to the Trash with their earlier versions, restore, and are erased by
/// a purge. The planted Wi-Fi passphrases are synthetic and distinctive so a search of every stored row can find them.
struct VaultSecureItemHistoryTests {
    private nonisolated static let first = [SecureItemFixtures.card(), SecureItemFixtures.wifi(passphrase: "wifi-pass-one-6c2d")]
    private nonisolated static let second = [SecureItemFixtures.wifi(ssid: "Other-Net", passphrase: "wifi-pass-two-6c2d")]

    private static func owner() throws -> CredentialAccount {
        var owner = try MoveFixtures.fullAccount()
        owner.secureItems = first
        return owner
    }

    /// Occurrences of `text` in every reachable row of `vault`. A revision keeps its value as base64 inside the row, so that value is
    /// decoded before it is searched.
    private func textCount(_ text: String, in vault: UUID, _ f: VaultStoreFixture) throws -> Int {
        var total = 0
        for row in try f.moveLiveRows(of: vault) + f.moveHistoryRows(of: vault) {
            var bytes = try f.moveSearchableBytes(of: row)
            if row.kind == .revision {
                bytes.append(try JSONDecoder().decode(RevisionBody.self, from: f.movePlaintext(of: row)).value)
            }
            total += MoveFixtures.occurrences(of: text, in: bytes)
        }
        return total
    }

    private func setItems(
        _ f: VaultStoreFixture, _ store: ProfileVaultStore, _ access: VaultAccess, _ items: [SecureItem]?
    ) async throws {
        try await f.edit(store, access) { accounts in
            accounts.map { account in
                var live = account
                live.secureItems = items
                return live
            }
        }
    }

    @Test func anItemEditKeepsTheEarlierItemsAsAnEarlierVersion() async throws {
        let owner = try Self.owner()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                try await setItems(f, store, access, Self.second)

                let revisions = try f.sourceRevisions(of: owner.id).filter { $0.subject == .secureItem }
                #expect(revisions.count == 1)
                let live = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(live.secureItems == Self.second)
                let page = try await store.revisionPage(vaultID: f.vaultID, accountID: owner.id, after: nil, using: access)
                #expect(page.items.contains { $0.subject == .secureItem && $0.id == revisions[0].recordID })
            }
            try f.verify()
        }
    }

    @Test func clearedItemsStayInHistoryAndLeaveTrashEmpty() async throws {
        let owner = try Self.owner()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                try await setItems(f, store, access, Self.second)
                try await setItems(f, store, access, nil)
                let left = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(left.secureItems == nil && left.password == owner.password)

                // Clearing the items by an edit supersedes the list like any other items edit: both lists stay earlier versions.
                let versions = try f.sourceRevisions(of: owner.id).filter { $0.subject == .secureItem }
                #expect(versions.count == 2)
                let page = try await store.revisionPage(vaultID: f.vaultID, accountID: owner.id, after: nil, using: access)
                #expect(page.items.filter { $0.subject == .secureItem }.count == 2)
                #expect(try await store.trashPage(vaultID: f.vaultID, after: nil, using: access).items.isEmpty)
                #expect(try f.trashEntryIDs().isEmpty)
                #expect(try f.moveRevisions(in: f.trashID, owner: owner.id, subject: .secureItem).isEmpty)

                // Both lists are there to restore, and the one that was cleared comes back without a Trash entry.
                var clearedVersion: StoredRevision?
                var previews: [[SecureItem]?] = []
                for version in versions {
                    let items = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: version.recordID, using: access).secureItems
                    previews.append(items)
                    if items == Self.second {
                        clearedVersion = version
                    }
                }
                #expect(previews.contains { $0 == Self.first } && previews.contains { $0 == Self.second })
                let cleared = try #require(clearedVersion)
                let revision = try await f.nextRevision(store, access)
                _ = try await store.restoreRevision(
                    vaultID: f.vaultID, revisionID: cleared.recordID, expectedRevision: revision, using: access
                )
                let restored = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(restored.secureItems == Self.second)
                #expect(try f.sourceRevisions(of: owner.id).filter { $0.subject == .secureItem }.count == 2)
            }
            #expect(try f.moveHistoryRows(of: f.trashID).isEmpty)
            try f.verify()
        }
    }

    @Test func removingTheItemsLeavesTheRestOfTheCredential() async throws {
        let owner = try Self.owner()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                try await f.deleteCredential(store, access, owner: owner.id, subject: .secureItem)
                let left = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(left.secureItems == nil)
                #expect(left.password == owner.password && left.totp == owner.totp && left.passkeys.map(\.id) == owner.passkeys.map(\.id))
                #expect(try f.trashEntry(of: owner.id, subject: .secureItem).body.subject == .secureItem)
            }
            try f.verify()
        }
    }

    @Test func restoringItemsOverNewerItemsIsBlocked() async throws {
        let owner = try Self.owner()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                try await f.deleteCredential(store, access, owner: owner.id, subject: .secureItem)
                let entry = try f.trashEntry(of: owner.id, subject: .secureItem)
                try await setItems(f, store, access, Self.second)
                let image = try f.headWriteImage()

                let preview = try await store.previewUndelete(vaultID: f.vaultID, entryID: entry.row.recordID, using: access)
                #expect(preview.block == .slotOccupied(.secureItem))
                await #expect(throws: CredentialStoreError.undeleteBlocked(.slotOccupied(.secureItem))) {
                    try await f.undelete(store, access, entry.row.recordID)
                }
                #expect(try f.headWriteImage() == image)
            }
        }
    }

    @Test func anEarlierVersionOfTheItemsRestoresAndKeepsTheCurrentOnesAsAVersion() async throws {
        let owner = try Self.owner()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                try await setItems(f, store, access, Self.second)
                let chosen = try #require(try f.sourceRevisions(of: owner.id).first { $0.subject == .secureItem })
                let chosenRow = try f.storedRecord(f.vaultID, chosen.recordID)

                let preview = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: chosen.recordID, using: access)
                #expect(preview.secureItems == Self.first)
                #expect(RecordSubject.secureItem.restoresFromEarlierVersions)
                let revision = try await f.nextRevision(store, access)
                _ = try await store.restoreRevision(
                    vaultID: f.vaultID, revisionID: chosen.recordID, expectedRevision: revision, using: access
                )

                let live = try #require(try await store.snapshot(vaultID: f.vaultID, using: access).accounts.first)
                #expect(live.secureItems == Self.first && live.password == owner.password)
                #expect(try f.storedRecord(f.vaultID, chosen.recordID) == chosenRow)
                #expect(try f.sourceRevisions(of: owner.id).filter { $0.subject == .secureItem }.count == 2)
            }
            try f.verify()
        }
    }

    @Test func aSecureItemRevisionOfTheWrongTypeIsRefused() async throws {
        let owner = try Self.owner()
        let wrong = try TrashFixtures.revisionBody(owner)
        try await VaultStoreFixture.with(
            accounts: [owner], extraHistory: [FixtureHistoryRun(subject: .secureItem, count: 1, plaintext: wrong)]
        ) { f in
            try await f.withWallStore { store, access in
                let revision = try #require(try f.sourceRevisions(of: owner.id).first)
                let image = try f.headWriteImage()
                await #expect(throws: CredentialVaultError.invalidData) {
                    _ = try await store.previewRestoreRevision(vaultID: f.vaultID, revisionID: revision.recordID, using: access)
                }
                #expect(try f.headWriteImage() == image)
            }
        }
    }

    @Test func purgeErasesSecureItemHistory() async throws {
        let owner = try Self.owner()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                try await setItems(f, store, access, Self.second)
                try await f.deleteCredential(store, access, owner: owner.id, subject: .secureItem)
                let entry = try f.trashEntry(of: owner.id, subject: .secureItem)
                let planted = ["wifi-pass-one-6c2d", "wifi-pass-two-6c2d"]
                for text in planted {
                    #expect(try textCount(text, in: f.trashID, f) >= 1, "\(text) is kept in the Trash until purged")
                }

                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [entry.row.recordID], emptyAll: false, authorization: f.freshAuthorization, using: access
                )

                receipt.expectRemoved(1)
                #expect(try f.moveRevisions(in: f.trashID, owner: owner.id, subject: .secureItem).isEmpty)
                for text in planted {
                    #expect(try textCount(text, in: f.trashID, f) == 0, "\(text) is gone from the Trash")
                    #expect(try textCount(text, in: f.vaultID, f) == 0, "\(text) is not in the vault")
                }
                let tombstone = try #require(try f.moveHistoryRows(of: f.trashID).first { $0.kind == .tombstone })
                let body = try JSONDecoder().decode(TombstoneBody.self, from: try f.movePlaintext(of: tombstone))
                #expect(body.scope == .credential && body.subject == .secureItem && body.entryID == entry.row.recordID)
            }
            try f.verify()
        }
    }

    @Test func purgeErasesTheItemsOfAWholeRemovedAccount() async throws {
        let owner = try Self.owner()
        try await VaultStoreFixture.with(accounts: [owner]) { f in
            try await f.withWallStore { store, access in
                try await setItems(f, store, access, Self.second)
                try await f.deleteAccount(store, access, owner.id)
                #expect(try textCount("wifi-pass-two-6c2d", in: f.trashID, f) >= 1)
                #expect(try textCount("wifi-pass-one-6c2d", in: f.trashID, f) >= 1)
                #expect(try textCount(SecureItemFixtures.cardNumber, in: f.trashID, f) >= 1)

                try await store.purge(vaultID: f.vaultID, entryIDs: [], emptyAll: true, authorization: f.freshAuthorization, using: access)
                    .expectRemoved(1)

                for text in ["wifi-pass-one-6c2d", "wifi-pass-two-6c2d", SecureItemFixtures.cardNumber] {
                    #expect(try textCount(text, in: f.trashID, f) == 0)
                    #expect(try textCount(text, in: f.vaultID, f) == 0)
                }
            }
            try f.verify()
        }
    }

    @Test func aCardOnlyAccountRoundTripsThroughASecondStore() async throws {
        let items = [SecureItemFixtures.card(), SecureItemFixtures.wifi()]
        let account = SecureItemFixtures.account(items)
        try await VaultStoreFixture.with { f in
            try await f.withWallStore { store, access in
                let before = try await store.snapshot(vaultID: f.vaultID, using: access)
                _ = try await store.commit(vaultID: f.vaultID, [account], expectedRevision: before.revision, cause: nil, using: access)
            }
            // A second store reads the vault from disk.
            try await f.withWallStore { store, access in
                let stored = try await store.snapshot(vaultID: f.vaultID, using: access)
                let read = try #require(stored.accounts.first)
                #expect(stored.accounts.count == 1 && read.id == account.id)
                #expect(read.secureItems == items)
                #expect(read.password == nil && read.username.isEmpty && read.passkeys.isEmpty && read.totp == nil && read.notes == nil)
            }
            try f.verify()
        }
    }
}
