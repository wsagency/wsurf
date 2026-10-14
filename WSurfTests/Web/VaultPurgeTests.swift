// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import Testing

@testable import WSurf

// Task 8 (§11.4): purge is explicit, needs a fresh assertion, and replaces Trash entries with tombstones in one transaction.

nonisolated enum PurgeCap: CaseIterable, Sendable {
    case liveAccountCap, sixteenVaults, largeHistory
}

/// `purge`'s own write transaction on a test-owned pool whose connections carry `wsurf_full()`, which fails with a real
/// `SQLITE_FULL`. The store's pool is opened inside the store, so (like `MoveCancelSeam`) this runs the store's own `purging` body
/// (the identical code `purge` hands to `run`) inside the same `BEGIN IMMEDIATE`, through the real `mapIntegrity`.
nonisolated enum FullDiskSeam {
    static func pool(at file: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("wsurf_full", argumentCount: 0, pure: false) { _ in
                throw DatabaseError(resultCode: .SQLITE_FULL, message: "injected")
            })
        }
        return try DatabasePool(path: file.path, configuration: configuration)
    }

    static func purge(on pool: DatabasePool, supportDirectory: URL, _ request: CommitRequest, requested: [UUID]?) throws -> Int {
        try mapIntegrity(request.grant.ordinal) {
            try VerificationScratch.attached(on: pool, supportDirectory: supportDirectory, cleanupFailed: { _ in }) { db in
                var removed = 0
                try db.inTransaction(.immediate) {
                    let result = try ProfileVaultStore.purging(db, request, requested: requested)
                    removed = result.removed
                    return result.outcome.entry == nil ? .rollback : .commit
                }
                return removed
            }
        }
    }
}

struct VaultPurgeTests {
    // MARK: Authorization

    @Test func purgeNeedsAFreshAssertionFromAnEnrolledCredential() async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 2) { f in
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id).row.recordID
                let image = try f.headWriteImage()
                let revisions = try f.moveHeadRevisions()

                let unenrolled = FreshAuthorization(credentialID: Data(repeating: 0xEE, count: 32), prf: f.proof.prf)
                await #expect(throws: CredentialVaultError.authenticationFailed) {
                    _ = try await store.purge(vaultID: f.vaultID, entryIDs: [entry], emptyAll: false, authorization: unenrolled, using: access)
                }
                let wrongPRF = FreshAuthorization(credentialID: f.proof.credentialID, prf: SymmetricKey(size: .bits256))
                await #expect(throws: CredentialVaultError.authenticationFailed) {
                    _ = try await store.purge(vaultID: f.vaultID, entryIDs: [entry], emptyAll: true, authorization: wrongPRF, using: access)
                }
                // A correct assertion on someone else's access (no lease of its own) is refused too: the lease alone proves nothing.
                let stranger = f.beginAccess()
                await #expect(throws: CredentialVaultError.unauthorized) {
                    _ = try await store.purge(
                        vaultID: f.vaultID, entryIDs: [entry], emptyAll: false, authorization: f.freshAuthorization, using: stranger
                    )
                }
                #expect(try f.headWriteImage() == image)
                #expect(try f.moveHeadRevisions() == revisions)

                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [entry], emptyAll: false, authorization: f.freshAuthorization, using: access
                )
                #expect(receipt.removedEntries == 1)
            }
        }
    }

    // MARK: Tombstones

    @Test func purgeReplacesEntriesWithTombstonesAndJournals() async throws {
        let victim = try MoveFixtures.fullAccount()
        let bystander = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [victim, bystander], historyRows: 3) { f in
            // A normal migrated store (stub + store) allows an owned `.pre-v2` backup; it is created only now, after the fixture is initialized,
            // because before the first-run bootstrap it would fail the store closed (§6.2 row 10).
            let backupName = "Credentials.vault.pre-v2"
            let backup = Data("opaque pre-migration backup \(UUID())".utf8)
            try backup.write(to: f.directory.appendingPathComponent(backupName), options: .withoutOverwriting)
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id)
                let trashRevisions = try f.moveRevisions(in: f.trashID, owner: victim.id)
                #expect(trashRevisions.count == 3)
                let wrappers = try f.storedWrappersBytes(of: f.vaultID)
                let directory = try f.directoryImage()
                let journalBefore = try f.journalRows(of: f.trashID).count
                let revisions = try f.moveHeadRevisions()
                let bystanderRow = try f.storedRecord(f.vaultID, bystander.id)

                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [entry.row.recordID], emptyAll: false, authorization: f.freshAuthorization, using: access
                )

                #expect(receipt == PurgeReceipt(removedEntries: 1, revision: revisions.source + 1))
                #expect(try f.moveHeadRevisions() == revisions.advanced())
                #expect(try f.moveTrashEntries().isEmpty)
                #expect(try f.moveRevisions(in: f.trashID, owner: victim.id).isEmpty)
                let tombstones = try f.moveHistoryRows(of: f.trashID).filter { $0.kind == .tombstone }
                #expect(tombstones.count == 3, "the account and one per passkey")
                let bodies = try tombstones.map { try JSONDecoder().decode(TombstoneBody.self, from: try f.movePlaintext(of: $0)) }
                for body in bodies {
                    #expect(body.entryID == entry.row.recordID && body.ownerID == victim.id && body.scope == .account)
                    #expect(body.purgedAt == MoveFixtures.wall)
                }
                #expect(Set(bodies.compactMap(\.passkeyCredentialID)) == Set(victim.passkeys.map(\.credentialID)))
                #expect(bodies.filter { $0.passkeyCredentialID == nil }.count == 1)
                for row in tombstones {
                    let plaintext = try f.movePlaintext(of: row)
                    for secret in [victim.password ?? "", "hunter2"] {
                        #expect(MoveFixtures.occurrences(of: secret, in: plaintext) == 0)
                    }
                    #expect(MoveFixtures.occurrences(of: "totp", in: plaintext) == 0)
                    #expect(!plaintext.includes(victim.passkeys[0].privateKeyPKCS8) && !plaintext.includes(victim.totp?.secret ?? Data([0])))
                }

                let groups = try f.journalRows(of: f.trashID)
                #expect(groups.count == journalBefore + 1)
                let purge = try #require(groups.last)
                #expect(purge.transfer == nil)
                let removes = purge.ops.filter { $0.op == .remove }
                let adds = purge.ops.filter { $0.op == .add }
                #expect(Set(removes.map(\.recordID)) == Set(trashRevisions.map(\.recordID) + [entry.row.recordID]))
                #expect(Set(adds.map(\.recordID)) == Set(tombstones.map(\.recordID)) && adds.allSatisfy { $0.kind == .tombstone })

                let heads = try f.moveStoredHeads()
                #expect(heads.trash.historyCounts == HistoryCounts(revision: 0, trashEntry: 0, tombstone: 3))
                #expect(try f.storedWrappersBytes(of: f.vaultID) == wrappers)
                #expect(try f.storedRecord(f.vaultID, bystander.id) == bystanderRow)
                try f.expectMoveRegistryMatchesHeads()

                // Nothing beside the store file is created or changed: the stub, the owned pre-migration backup (opaque bytes, kept as
                // is) and every other file keep their bytes, and no `cutover-v1*` appears.
                let after = try f.directoryImage()
                let database = ["Credentials.store", "Credentials.store-wal", "Credentials.store-shm"]
                for (name, bytes) in directory where !database.contains(name) {
                    #expect(after[name] == bytes, "\(name) changed")
                }
                #expect(after[backupName] == backup)
                #expect(after.keys.allSatisfy { directory[$0] != nil || database.contains($0) }, "\(Set(after.keys).subtracting(directory.keys))")
                #expect(after.keys.allSatisfy { !$0.contains("cutover-v1") })
            }
            try f.verify()
        }
    }

    @Test func purgeOfASingleCredentialLeavesOneTombstoneAndKeepsTheRest() async throws {
        let owner = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(
            accounts: [owner], historyRows: 2, extraHistory: [FixtureHistoryRun(subject: .totp, count: 2)]
        ) { f in
            try await f.withWallStore { store, access in
                try await f.deleteCredential(store, access, owner: owner.id, subject: .passkey, passkeyID: owner.passkeys[0].id)
                try await f.deleteCredential(store, access, owner: owner.id, subject: .totp)
                let totpEntry = try f.trashEntry(of: owner.id, subject: .totp)
                let passkeyEntry = try f.trashEntry(of: owner.id, subject: .passkey)
                #expect(try f.moveRevisions(in: f.trashID, owner: owner.id, subject: .totp).count == 2)

                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [totpEntry.row.recordID], emptyAll: false, authorization: f.freshAuthorization,
                    using: access
                )

                #expect(receipt.removedEntries == 1)
                #expect(try f.moveTrashEntries().map(\.row.recordID) == [passkeyEntry.row.recordID])
                #expect(try f.moveRevisions(in: f.trashID, owner: owner.id, subject: .totp).isEmpty)
                let tombstone = try #require(try f.moveHistoryRows(of: f.trashID).first { $0.kind == .tombstone })
                let body = try JSONDecoder().decode(TombstoneBody.self, from: try f.movePlaintext(of: tombstone))
                #expect(body.scope == .credential && body.subject == .totp && body.entryID == totpEntry.row.recordID)
                #expect(try f.moveRevisions(in: f.vaultID, owner: owner.id).count == 2)
            }
            try f.verify()
        }
    }

    @Test func emptyAllPurgesEveryEntry() async throws {
        let accounts = MoveFixtures.tinyAccounts(4)
        try await VaultStoreFixture.with(accounts: accounts + [VaultFixtures.account(username: "keeper", origin: "https://keep.example")], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                for account in accounts {
                    try await f.deleteAccount(store, access, account.id)
                }
                let entries = Set(try f.trashEntryIDs())
                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [UUID()], emptyAll: true, authorization: f.freshAuthorization, using: access
                )
                #expect(receipt.removedEntries == 4)
                #expect(try f.trashEntryIDs().isEmpty)
                let identifiers = try await store.removedIdentifiers(vaultID: f.vaultID, using: access)
                #expect(Set(identifiers.items.map(\.entryID)) == entries && identifiers.items.allSatisfy { $0.isTombstone })
                #expect(try await store.trashPage(vaultID: f.vaultID, after: nil, using: access).items.isEmpty)
            }
            try f.verify()
        }
    }

    @Test func anUnknownEntryPurgesNothingAndNothingToPurgeWritesNothing() async throws {
        let victim = VaultFixtures.account(username: "ada")
        try await VaultStoreFixture.with(accounts: [victim, VaultFixtures.account(username: "grace", origin: "https://b.example")]) { f in
            try await f.withWallStore { store, access in
                // Empty Trash: no write.
                var image = try f.headWriteImage()
                let empty = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [], emptyAll: true, authorization: f.freshAuthorization, using: access
                )
                #expect(empty.removedEntries == 0)
                #expect(try f.headWriteImage() == image)

                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id).row.recordID
                image = try f.headWriteImage()
                await #expect(throws: CredentialVaultError.invalidData) {
                    _ = try await store.purge(
                        vaultID: f.vaultID, entryIDs: [entry, UUID()], emptyAll: false, authorization: f.freshAuthorization, using: access
                    )
                }
                #expect(try f.headWriteImage() == image)

                // A repeated id counts once.
                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [entry, entry], emptyAll: false, authorization: f.freshAuthorization, using: access
                )
                #expect(receipt.removedEntries == 1)
            }
            try f.verify()
        }
    }

    // MARK: Capacity and failure

    @Test(arguments: PurgeCap.allCases)
    func purgeIsNotBlockedByLogicalCapacity(_ cap: PurgeCap) async throws {
        let victim = VaultFixtures.account(username: "ada")
        let others = cap == .liveAccountCap
            ? MoveFixtures.tinyAccounts(CredentialVaultLimits.accounts - 1)
            : [VaultFixtures.account(username: "grace", origin: "https://b.example")]
        try await VaultStoreFixture.with(
            accounts: [victim] + others, historyRows: cap == .largeHistory ? 1_500 : 3, secondVault: cap == .sixteenVaults,
            extraVaults: cap == .sixteenVaults ? 14 : 0
        ) { f in
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let revisions = try f.moveHeadRevisions()
                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [], emptyAll: true, authorization: f.freshAuthorization, using: access
                )
                #expect(receipt == PurgeReceipt(removedEntries: 1, revision: revisions.source + 1))
                #expect(try f.moveHeadRevisions() == revisions.advanced())
            }
            #expect(try f.moveHistoryRows(of: f.trashID).map(\.kind) == [.tombstone])
            try f.expectMoveRegistryMatchesHeads()
            try f.verify()
        }
    }

    @Test(arguments: [true, false])
    func purgeOnAFullFilesystemFailsAtomicallyWithTheHonestError(_ emptyAll: Bool) async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 3) { f in
            try await f.withWallStore { store, access in
                try await f.deleteAccount(store, access, victim.id)
                let entry = try f.trashEntry(of: victim.id).row.recordID
                try f.mutate { db in
                    try db.execute(sql: "CREATE TRIGGER full BEFORE INSERT ON record WHEN NEW.kind = 'tombstone' BEGIN SELECT wsurf_full(); END")
                }
                let image = try f.headWriteImage()
                let revisions = try f.moveHeadRevisions()
                let grant = try await store.authorizedGrant(f.vaultID, access)
                let (clock, wallClock) = await (store.now, store.wall)
                let request = CommitRequest(
                    grant: grant,
                    intent: CommitIntent(vaultID: f.vaultID, access: access, expectedRevision: nil, cause: nil, isCommit: false),
                    now: clock, wall: wallClock()
                )
                let pool = try FullDiskSeam.pool(at: f.storeURL)

                #expect(throws: CredentialStoreError.diskFull) {
                    _ = try FullDiskSeam.purge(on: pool, supportDirectory: f.directory, request, requested: emptyAll ? nil : [entry])
                }

                #expect(try f.headWriteImage() == image)
                #expect(try f.moveHeadRevisions() == revisions)
                #expect(try f.trashEntryIDs() == [entry])
                try f.mutate { try $0.execute(sql: "DROP TRIGGER full") }
                try f.verify()
                // Nothing is wedged: the same purge now goes through.
                let receipt = try await store.purge(
                    vaultID: f.vaultID, entryIDs: [entry], emptyAll: false, authorization: f.freshAuthorization, using: access
                )
                #expect(receipt.removedEntries == 1)
            }
            try f.verify()
        }
    }
}
