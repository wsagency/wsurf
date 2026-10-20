// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB
import Testing

@testable import WSurf

// Delete Vault: one transaction removes a vault and its linked Trash, needs a fresh assertion of that vault's own passkey, and never
// touches the other vaults or anything outside the store file.

/// What a vault can hold besides live credentials that keeps it from being deleted without an assertion.
nonisolated enum VaultNotEmpty: CaseIterable, Sendable {
    case liveCredential, trashEntry, tombstoneOnly, blockedWebsite
}

@MainActor
struct VaultDeleteTests {
    // MARK: Readback

    /// Every row of the vault ids in `vaults`, serialised (blobs by content): equal images mean no byte of them changed.
    private nonisolated func vaultImage(_ f: VaultStoreFixture, of vaults: [UUID]) throws -> [String: [String]] {
        try f.read { db in
            var image: [String: [String]] = [:]
            for vault in vaults {
                for (table, order) in [("vault", "vaultID"), ("head", "vaultID"), ("record", "recordID"), ("journal", "seq")] {
                    let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table) WHERE vaultID = ? ORDER BY \(order)", arguments: [vault.lowerText])
                    image["\(table)/\(vault.lowerText)"] = rows.map(Self.text)
                }
            }
            return image
        }
    }

    /// The whole store file: every vault, head, record and journal row, the registry and `store_meta`.
    private nonisolated func storeImage(_ f: VaultStoreFixture) throws -> [String: [String]] {
        try f.read { db in
            var image: [String: [String]] = [:]
            let tables = [
                ("vault", "vaultID"), ("head", "vaultID"), ("record", "vaultID, recordID"), ("journal", "vaultID, seq"),
                ("registry", "id"), ("store_meta", "id"),
            ]
            for (table, order) in tables {
                image[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(order)").map(Self.text)
            }
            return image
        }
    }

    private nonisolated static func text(_ row: Row) -> String {
        row.columnNames.map { name -> String in
            let value: DatabaseValue = row[name]
            if case .blob(let data) = value.storage {
                return "\(name)=\(data.base64EncodedString())"
            }
            return "\(name)=\(value)"
        }.joined(separator: "|")
    }

    private nonisolated func rowCounts(_ f: VaultStoreFixture, of vault: UUID) throws -> [String: Int] {
        try f.read { db in
            var counts: [String: Int] = [:]
            for table in ["vault", "head", "record", "journal"] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE vaultID = ?", arguments: [vault.lowerText]) ?? -1
            }
            return counts
        }
    }

    private func unlock(
        _ store: ProfileVaultStore, _ f: VaultStoreFixture, vault: UUID, access: VaultAccess
    ) async throws {
        let proof = f.proof(for: vault)
        try await store.unlockInitialized(
            vaultID: vault, credentialID: proof.credentialID, prf: proof.prf, access: access, verifying: nil, scratchWarning: nil
        )
    }

    // MARK: Store

    @Test func deletingAVaultRemovesEveryRowOfItAndItsTrashAndBothRegistryEntries() async throws {
        let victim = try MoveFixtures.fullAccount()
        let keeper = VaultFixtures.account(username: "grace", origin: "https://b.example")
        let bystander = VaultFixtures.account(username: "heidi", origin: "https://c.example")
        try await VaultStoreFixture.with(accounts: [victim, keeper], historyRows: 3, secondVault: true, secondAccounts: [bystander]) { f in
            let secondID = try #require(f.secondVaultID)
            let secondTrashID = try #require(f.secondTrashID)
            try await f.withWallStore { store, access in
                // A Trash entry with its history, so the pair holds every kind of row: live, revision, trashEntry, journal, heads.
                try await f.deleteAccount(store, access, victim.id)
                for id in [f.vaultID, f.trashID] {
                    let counts = try rowCounts(f, of: id)
                    #expect(counts.values.allSatisfy { $0 > 0 }, "\(counts)")
                }
                let bystanders = try vaultImage(f, of: [secondID, secondTrashID])
                let registryRevision = try f.storedRegistry().revision

                try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)

                for id in [f.vaultID, f.trashID] {
                    #expect(try rowCounts(f, of: id) == ["vault": 0, "head": 0, "record": 0, "journal": 0])
                }
                #expect(try vaultImage(f, of: [secondID, secondTrashID]) == bystanders)
                #expect(try f.read { try StoreTables.vaultRows($0) }.count == 2)

                let stored = try #require(try f.read { try StoreTables.registry($0) })
                #expect(stored.revision == registryRevision + 1)
                #expect(StoreSeal.verifyRegistryMAC(rk: f.registryKey, catalog: stored.catalog, mac: stored.mac))
                let catalog = try RegistryCatalog.decode(stored.catalog)
                #expect(catalog.revision == stored.revision)
                #expect(Set(catalog.vaults.map(\.vaultID)) == [secondID, secondTrashID])
                #expect(catalog.encode() == (try f.rebuiltRegistry()).encode(), "the registry describes exactly the rows that remain")

                // The grant went with the vault.
                await #expect(throws: CredentialVaultError.unauthorized) { _ = try await store.snapshot(vaultID: f.vaultID, using: access) }
                #expect(try await store.listing().map(\.vaultID) == [secondID])
                await #expect(throws: CredentialStoreError.noSuchVault) { _ = try await store.discovery(vaultID: f.vaultID) }
            }
        }
    }

    @Test func theOtherVaultsStillUnlockAndVerifyAfterwards() async throws {
        let bystander = VaultFixtures.account(username: "heidi", origin: "https://c.example")
        try await VaultStoreFixture.with(
            accounts: [VaultFixtures.account()], historyRows: 2, secondVault: true, secondAccounts: [bystander]
        ) { f in
            let secondID = try #require(f.secondVaultID)
            // B is already open in the same store when A is deleted.
            let store = f.makeStore()
            let accessA = f.beginAccess()
            let accessB = f.beginAccess()
            try await unlock(store, f, vault: f.vaultID, access: accessA)
            try await unlock(store, f, vault: secondID, access: accessB)

            try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: accessA)

            // Its session still reads and writes: its registry entries are the ones it verified.
            let open = try await store.snapshot(vaultID: secondID, using: accessB)
            #expect(open.accounts.map(\.id) == [bystander.id])
            let added = VaultFixtures.account(username: "ivan", origin: "https://d.example")
            _ = try await store.commit(vaultID: secondID, open.accounts + [added], expectedRevision: open.revision, cause: nil, using: accessB)

            // A fresh unlock from the file runs the whole §6.8 check against the smaller registry and finds what was written.
            let (fresh, freshAccess) = try await f.unlocked(vaultID: secondID)
            let reread = try await fresh.snapshot(vaultID: secondID, using: freshAccess)
            #expect(Set(reread.accounts.map(\.id)) == [bystander.id, added.id])
            #expect(try await fresh.listing().map(\.vaultID) == [secondID])
        }
    }

    @Test func aSharedUnlockPasskeyStillOpensTheOtherVault() async throws {
        let bystander = VaultFixtures.account(username: "heidi", origin: "https://c.example")
        try await VaultStoreFixture.with(
            accounts: [VaultFixtures.account()], secondVault: true, sharedProof: true, secondAccounts: [bystander]
        ) { f in
            let secondID = try #require(f.secondVaultID)
            #expect(f.secondProof == nil, "both vaults enrol the one passkey")
            let wrappers = try f.storedWrappersBytes(of: secondID)

            try await f.withWallStore { store, access in
                try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
            }

            // The wrapper list is per vault: the passkey that opened the deleted vault opens this one, from the file.
            #expect(try f.storedWrappersBytes(of: secondID) == wrappers)
            let (store, access) = try await f.unlocked(vaultID: secondID)
            #expect(try await store.snapshot(vaultID: secondID, using: access).accounts.map(\.id) == [bystander.id])
        }
    }

    @Test func theLastVaultCannotBeDeleted() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 1) { f in
            try await f.withWallStore { store, access in
                let image = try storeImage(f)
                await #expect(throws: CredentialStoreError.lastVault) {
                    try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
                }
                #expect(try storeImage(f) == image)
                _ = try await store.snapshot(vaultID: f.vaultID, using: access)  // the grant is still good
            }
        }
        // Nor does the vault that is left once another was deleted.
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], secondVault: true) { f in
            let secondID = try #require(f.secondVaultID)
            let other = try #require(f.secondProof)
            try await f.withWallStore { store, access in
                try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
            }
            let (store, access) = try await f.unlocked(vaultID: secondID)
            let image = try storeImage(f)
            await #expect(throws: CredentialStoreError.lastVault) {
                try await store.deleteVault(
                    vaultID: secondID, authorization: FreshAuthorization(credentialID: other.credentialID, prf: other.prf), using: access
                )
            }
            #expect(try storeImage(f) == image)
        }
    }

    @Test func deletionNeedsAFreshAssertionOfThisVaultsPasskey() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], historyRows: 1, secondVault: true) { f in
            let other = try #require(f.secondProof)
            try await f.withWallStore { store, access in
                let image = try storeImage(f)

                let unenrolled = FreshAuthorization(credentialID: Data(repeating: 0xEE, count: 32), prf: f.proof.prf)
                await #expect(throws: CredentialVaultError.authenticationFailed) {
                    try await store.deleteVault(vaultID: f.vaultID, authorization: unenrolled, using: access)
                }
                let wrongPRF = FreshAuthorization(credentialID: f.proof.credentialID, prf: SymmetricKey(size: .bits256))
                await #expect(throws: CredentialVaultError.authenticationFailed) {
                    try await store.deleteVault(vaultID: f.vaultID, authorization: wrongPRF, using: access)
                }
                // Another vault's passkey, asserted correctly, is not enrolled here.
                let foreign = FreshAuthorization(credentialID: other.credentialID, prf: other.prf)
                await #expect(throws: CredentialVaultError.authenticationFailed) {
                    try await store.deleteVault(vaultID: f.vaultID, authorization: foreign, using: access)
                }
                // A correct assertion on an access that holds no lease on this vault proves nothing either.
                let stranger = f.beginAccess()
                await #expect(throws: CredentialVaultError.unauthorized) {
                    try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: stranger)
                }
                #expect(try storeImage(f) == image)

                try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
                #expect(try rowCounts(f, of: f.vaultID) == ["vault": 0, "head": 0, "record": 0, "journal": 0])
            }
        }
    }

    @Test func aCancellationBeforeTheCommitChangesNothing() async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 2, secondVault: true) { f in
            let secondID = try #require(f.secondVaultID)
            let (store, access) = try await f.unlocked()
            try await f.deleteAccount(store, access, victim.id)
            let grant = try await store.authorizedGrant(f.vaultID, access)
            let clock = await store.now
            let before = try storeImage(f)
            let pool = try DatabasePool(path: f.storeURL.path)

            // Every row is deleted and the registry rewritten inside the transaction; the cancel lands at its last poll.
            let running = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try pool.writeWithoutTransaction { (db: Database) throws in
                    try db.inTransaction(.immediate) {
                        try ProfileVaultStore.deleting(db, grant: grant, vaultID: f.vaultID, access: access, now: clock)
                        return .commit
                    }
                }
            }
            await #expect(throws: CancellationError.self) { try await running.value }
            try pool.close()

            #expect(try storeImage(f) == before)
            // Both vaults still unlock and verify, and the deleted one can still be deleted.
            _ = try await f.unlocked(vaultID: secondID)
            try f.verify()
            try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
            #expect(try rowCounts(f, of: f.trashID) == ["vault": 0, "head": 0, "record": 0, "journal": 0])
        }
    }

    @Test func aDiskFullAfterTheRowsWereDeletedChangesNothing() async throws {
        let victim = try MoveFixtures.fullAccount()
        try await VaultStoreFixture.with(accounts: [victim], historyRows: 2, secondVault: true) { f in
            let (store, access) = try await f.unlocked()
            try await f.deleteAccount(store, access, victim.id)
            let grant = try await store.authorizedGrant(f.vaultID, access)
            let clock = await store.now
            // The vault row is the last row deleted: its records, journal and head are already gone when this fires.
            try f.mutate { db in
                try db.execute(sql: "CREATE TRIGGER fullatvault BEFORE DELETE ON vault BEGIN SELECT wsurf_full(); END")
            }
            let before = try storeImage(f)
            let pool = try FullDiskSeam.pool(at: f.storeURL)

            #expect(throws: CredentialStoreError.diskFull) {
                try mapIntegrity(grant.ordinal) {
                    try pool.writeWithoutTransaction { (db: Database) throws in
                        try db.inTransaction(.immediate) {
                            try ProfileVaultStore.deleting(db, grant: grant, vaultID: f.vaultID, access: access, now: clock)
                            return .commit
                        }
                    }
                }
            }
            try? pool.close()

            #expect(try storeImage(f) == before)
            try f.mutate { try $0.execute(sql: "DROP TRIGGER fullatvault") }
            try f.verify()
            try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
        }
    }

    @Test func nothingOutsideTheStoreIsTouched() async throws {
        try await VaultStoreFixture.with(accounts: [try MoveFixtures.fullAccount()], historyRows: 2, secondVault: true) { f in
            // A normal migrated store (stub + store) allows an owned `.pre-v2` backup. WSurf never deletes it.
            let backupName = "Credentials.vault.pre-v2"
            let backup = Data("opaque pre-migration backup \(UUID())".utf8)
            try backup.write(to: f.directory.appendingPathComponent(backupName), options: .withoutOverwriting)
            try await f.withWallStore { store, access in
                let directory = try f.directoryImage()
                let defaults = f.defaultsImage()
                let state = f.evaluate()

                try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)

                let after = try f.directoryImage()
                let database = ["Credentials.store", "Credentials.store-wal", "Credentials.store-shm"]
                for (name, bytes) in directory where !database.contains(name) {
                    #expect(after[name] == bytes, "\(name) changed")
                }
                #expect(after[backupName] == backup)
                #expect(after["Credentials.vault"] == directory["Credentials.vault"], "the stub")
                #expect(after.keys.allSatisfy { directory[$0] != nil || database.contains($0) }, "\(Set(after.keys).subtracting(directory.keys))")
                #expect(after.keys.allSatisfy { !$0.contains("cutover-v1") })
                #expect(f.defaultsImage() == defaults, "the A3 witness and every other preference")
                #expect(f.evaluate() == state)
            }
        }
    }

    // MARK: A vault that holds nothing

    @Test func anEmptyVaultIsDeletedWithNoAssertion() async throws {
        let keeper = VaultFixtures.account(username: "grace", origin: "https://b.example")
        try await VaultStoreFixture.with(accounts: [keeper], historyRows: 1, secondVault: true) { f in
            let secondID = try #require(f.secondVaultID)
            let secondTrashID = try #require(f.secondTrashID)
            let (store, access) = try await f.unlocked(vaultID: secondID)
            let others = try vaultImage(f, of: [f.vaultID, f.trashID])
            let registryRevision = try f.storedRegistry().revision

            try await store.deleteEmptyVault(vaultID: secondID, using: access)

            for id in [secondID, secondTrashID] {
                #expect(try rowCounts(f, of: id) == ["vault": 0, "head": 0, "record": 0, "journal": 0])
            }
            #expect(try vaultImage(f, of: [f.vaultID, f.trashID]) == others)
            let stored = try #require(try f.read { try StoreTables.registry($0) })
            #expect(stored.revision == registryRevision + 1)
            #expect(StoreSeal.verifyRegistryMAC(rk: f.registryKey, catalog: stored.catalog, mac: stored.mac))
            let catalog = try RegistryCatalog.decode(stored.catalog)
            #expect(Set(catalog.vaults.map(\.vaultID)) == [f.vaultID, f.trashID])
            #expect(catalog.encode() == (try f.rebuiltRegistry()).encode())
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await store.snapshot(vaultID: secondID, using: access) }
            // The vault that is left still unlocks and verifies.
            let (remaining, remainingAccess) = try await f.unlocked()
            #expect(try await remaining.snapshot(vaultID: f.vaultID, using: remainingAccess).accounts.map(\.id) == [keeper.id])
        }
    }

    @Test func anEmptyVaultStillNeedsTheUnlock() async throws {
        try await VaultStoreFixture.with(accounts: [VaultFixtures.account()], secondVault: true) { f in
            let secondID = try #require(f.secondVaultID)
            let (store, _) = try await f.unlocked(vaultID: secondID)
            let image = try storeImage(f)

            // An access that holds no lease on the vault deletes nothing, empty or not.
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await store.deleteEmptyVault(vaultID: secondID, using: f.beginAccess())
            }

            #expect(try storeImage(f) == image)
        }
    }

    @Test(arguments: VaultNotEmpty.allCases)
    func aVaultWithAnythingInItIsNotDeletedWithoutAnAssertion(_ kind: VaultNotEmpty) async throws {
        let victim = try MoveFixtures.fullAccount()
        let blocked = kind == .blockedWebsite
        try await VaultStoreFixture.with(
            accounts: blocked ? [] : [victim], blockedOrigins: blocked ? ["https://blocked.example"] : [], historyRows: blocked ? 0 : 1,
            secondVault: true
        ) { f in
            try await f.withWallStore { store, access in
                switch kind {
                case .liveCredential, .blockedWebsite:
                    break
                case .trashEntry:
                    try await f.deleteAccount(store, access, victim.id)
                case .tombstoneOnly:
                    // Purged: no live credential, no Trash entry and no earlier version is left, only the tombstones.
                    try await f.deleteAccount(store, access, victim.id)
                    let entry = try f.trashEntry(of: victim.id).row.recordID
                    _ = try await store.purge(
                        vaultID: f.vaultID, entryIDs: [entry], emptyAll: false, authorization: f.freshAuthorization, using: access
                    )
                    #expect(try f.trashEntryIDs().isEmpty)
                }
                let image = try storeImage(f)

                await #expect(throws: CredentialStoreError.vaultNotEmpty) {
                    try await store.deleteEmptyVault(vaultID: f.vaultID, using: access)
                }

                #expect(try storeImage(f) == image, "\(kind)")
                _ = try await store.snapshot(vaultID: f.vaultID, using: access)  // the grant is still good
                // The two confirmations still delete it.
                try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
                #expect(try rowCounts(f, of: f.vaultID) == ["vault": 0, "head": 0, "record": 0, "journal": 0])
            }
        }
    }

    @Test func theLastVaultIsNotDeletedEvenWhenItIsEmpty() async throws {
        try await VaultStoreFixture.with { f in
            try await f.withWallStore { store, access in
                let image = try storeImage(f)

                await #expect(throws: CredentialStoreError.lastVault) {
                    try await store.deleteEmptyVault(vaultID: f.vaultID, using: access)
                }

                #expect(try storeImage(f) == image)
            }
        }
    }

    /// The deleting transaction is what an owner waits for: a big vault is one bounded transaction, not a long spin.
    @Test func deletingABigVaultIsOneBoundedTransaction() async throws {
        try await VaultStoreFixture.with(accounts: MoveFixtures.tinyAccounts(1_500), historyRows: 1_500, secondVault: true) { f in
            try await f.withWallStore { store, access in
                let rows = try rowCounts(f, of: f.vaultID)["record"] ?? 0
                #expect(rows >= 3_000)
                let clock = ContinuousClock()

                let elapsed = try await clock.measure {
                    try await store.deleteVault(vaultID: f.vaultID, authorization: f.freshAuthorization, using: access)
                }

                print("DELETE-VAULT rows=\(rows) seconds=\(elapsed)")
                #expect(elapsed < .seconds(20), "\(elapsed)")
                #expect(try rowCounts(f, of: f.vaultID) == ["vault": 0, "head": 0, "record": 0, "journal": 0])
            }
        }
    }

    // MARK: Manager

    private func withTwoVaults(
        _ body: (_ profile: Profile, _ passkeys: VaultPasskeys, _ keeper: FixtureVault, _ doomed: FixtureVault) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, passkeys, vaults in
            try await body(profile, passkeys, vaults[0], vaults[1])
        }
    }

    @Test func theDeletedVaultsManagerIsLockedAndCannotWrite() async throws {
        try await withTwoVaults { profile, passkeys, keeper, doomed in
            let store = try CredentialManager.store(for: profile)
            try await VaultManagerFixture.save([VaultFixtures.account()], in: doomed)
            let epoch = try #require(doomed.manager.authorizationEpoch)

            try await doomed.manager.deleteVault(authorizedEpoch: epoch, in: VaultManagerFixture.anchor())

            #expect(passkeys.assertions == [doomed.proof.credentialID], "one fresh assertion, of its own passkey")
            #expect(try VaultManagerFixture.rows(of: doomed.vaultID, in: profile).isEmpty)
            #expect(!doomed.manager.isUnlocked)
            #expect(doomed.manager.authorizationEpoch == nil)
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await doomed.manager.snapshot() }
            await #expect(throws: CredentialVaultError.unauthorized) { try await doomed.manager.renameVault("Gone", authorizedEpoch: epoch) }
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await doomed.manager.commit([], expectedRevision: 1, authorizedEpoch: epoch)
            }
            // It cannot be unlocked again, and the registry no longer hands it out: a lookup makes a new manager that finds no vault.
            await #expect(throws: CredentialVaultError.unauthorized) { try await doomed.manager.unlock(in: VaultManagerFixture.anchor()) }
            let replacement = try CredentialManager.forVault(profile, vaultID: doomed.vaultID)
            #expect(replacement !== doomed.manager)
            await #expect(throws: CredentialStoreError.noSuchVault) { try await replacement.discoverUnlocks() }

            // The other vault is untouched and still writable.
            #expect(CredentialManager.unlockedManagers(for: profile).map(\.vaultID) == [keeper.vaultID])
            #expect(try await store.listing().map(\.vaultID) == [keeper.vaultID])
            try await VaultManagerFixture.save([VaultFixtures.account(username: "grace")], in: keeper)
            #expect(try await keeper.manager.snapshot().accounts.map(\.username) == ["grace"])
        }
    }

    @Test func aLockBetweenTheConfirmationsDeletesNothing() async throws {
        try await withTwoVaults { profile, passkeys, keeper, doomed in
            let store = try CredentialManager.store(for: profile)
            let rows = try VaultManagerFixture.rows(of: doomed.vaultID, in: profile)
            let others = try VaultManagerFixture.rows(of: keeper.vaultID, in: profile)
            let epoch = try #require(doomed.manager.authorizationEpoch)

            // The lock lands while the passkey prompt is open.
            passkeys.beforeAssert = { doomed.manager.lock(reason: .manual) }
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await doomed.manager.deleteVault(authorizedEpoch: epoch, in: VaultManagerFixture.anchor())
            }
            passkeys.beforeAssert = nil
            #expect(passkeys.assertions.count == 1)

            // A re-unlock does not carry the earlier confirmation, and it asks for no prompt at all.
            try await VaultManagerFixture.unlock(doomed)
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await doomed.manager.deleteVault(authorizedEpoch: epoch, in: VaultManagerFixture.anchor())
            }
            #expect(passkeys.assertions.count == 1)

            #expect(try VaultManagerFixture.rows(of: doomed.vaultID, in: profile) == rows)
            #expect(try VaultManagerFixture.rows(of: keeper.vaultID, in: profile) == others)
            #expect(try await store.listing().count == 2)
        }
    }

    @Test func aDeclinedOrForeignAssertionDeletesNothing() async throws {
        try await withTwoVaults { profile, passkeys, keeper, doomed in
            let store = try CredentialManager.store(for: profile)
            let rows = try VaultManagerFixture.rows(of: doomed.vaultID, in: profile)
            let epoch = try #require(doomed.manager.authorizationEpoch)

            passkeys.beforeAssert = { throw PasskeyUnlockError.appCancelled }
            await #expect(throws: PasskeyUnlockError.self) {
                try await doomed.manager.deleteVault(authorizedEpoch: epoch, in: VaultManagerFixture.anchor())
            }
            passkeys.beforeAssert = nil

            // The prompt answers with the other vault's passkey: it is not enrolled in the vault being deleted.
            passkeys.answer = keeper.proof
            await #expect(throws: CredentialVaultError.authenticationFailed) {
                try await doomed.manager.deleteVault(authorizedEpoch: epoch, in: VaultManagerFixture.anchor())
            }
            passkeys.answer = nil

            #expect(doomed.manager.authorizationEpoch == epoch, "a refused deletion leaves the vault unlocked")
            #expect(try VaultManagerFixture.rows(of: doomed.vaultID, in: profile) == rows)
            #expect(try await store.listing().count == 2)
        }
    }

    @Test func theDefaultPointerFallsBackAndTheLockTimeIsRemoved() async throws {
        try await withTwoVaults { profile, _, keeper, doomed in
            let store = try CredentialManager.store(for: profile)
            let defaults = ProfileSettingsStore.defaults(for: profile)
            await store.setDefaultVault(doomed.vaultID)
            try doomed.manager.setAutoLock(.oneHour)
            try keeper.manager.setAutoLock(.fifteenMinutes)
            #expect(defaults.object(forKey: CredentialAutoLock.key(for: doomed.vaultID)) != nil)

            try await doomed.manager.deleteVault(
                authorizedEpoch: try #require(doomed.manager.authorizationEpoch), in: VaultManagerFixture.anchor()
            )

            #expect(await store.defaultVaultID() == nil, "the pointer named the deleted vault")
            #expect(defaults.object(forKey: CredentialAutoLock.key(for: doomed.vaultID)) == nil)
            #expect(CredentialAutoLock.stored(for: keeper.vaultID, in: defaults) == .fifteenMinutes)
        }
    }

    @Test func aDefaultPointerToAnotherVaultIsLeftAlone() async throws {
        try await withTwoVaults { profile, _, keeper, doomed in
            let store = try CredentialManager.store(for: profile)
            await store.setDefaultVault(keeper.vaultID)

            try await doomed.manager.deleteVault(
                authorizedEpoch: try #require(doomed.manager.authorizationEpoch), in: VaultManagerFixture.anchor()
            )

            #expect(await store.defaultVaultID() == keeper.vaultID)
        }
    }

    @Test func aNewVaultAfterDeletingTheHighestReusesItsNumber() async throws {
        try await withTwoVaults { profile, passkeys, keeper, doomed in
            let store = try CredentialManager.store(for: profile)
            #expect(try await store.listing().map(\.ordinal) == [1, 2])

            try await doomed.manager.deleteVault(
                authorizedEpoch: try #require(doomed.manager.authorizationEpoch), in: VaultManagerFixture.anchor()
            )
            #expect(try await store.listing().map(\.ordinal) == [1])

            let created = try await CredentialManager.createVault(
                profile: profile, name: "Again", choice: .newPasskey(authorizedBy: keeper.manager), in: VaultManagerFixture.anchor(),
                native: passkeys.native
            )

            let listing = try await store.listing()
            #expect(listing.map(\.ordinal) == [1, 2])
            #expect(listing.last?.vaultID == created)
            #expect(created != doomed.vaultID, "only the label comes back; the vault is a new one")
        }
    }

    @Test func anEmptyVaultIsDeletedByItsManagerWithNoPrompt() async throws {
        try await withTwoVaults { profile, passkeys, keeper, doomed in
            let store = try CredentialManager.store(for: profile)
            let epoch = try #require(doomed.manager.authorizationEpoch)

            try await doomed.manager.deleteEmptyVault(authorizedEpoch: epoch)

            #expect(passkeys.assertions.isEmpty, "no passkey prompt")
            #expect(try VaultManagerFixture.rows(of: doomed.vaultID, in: profile).isEmpty)
            #expect(!doomed.manager.isUnlocked)
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await doomed.manager.snapshot() }
            #expect(CredentialManager.unlockedManagers(for: profile).map(\.vaultID) == [keeper.vaultID])
            #expect(try await store.listing().map(\.vaultID) == [keeper.vaultID])
            // Registered nowhere, and the last vault is not offered the same.
            let replacement = try CredentialManager.forVault(profile, vaultID: doomed.vaultID)
            #expect(replacement !== doomed.manager)
            let keeperEpoch = try #require(keeper.manager.authorizationEpoch)
            await #expect(throws: CredentialStoreError.lastVault) { try await keeper.manager.deleteEmptyVault(authorizedEpoch: keeperEpoch) }
        }
    }

    @Test func aVaultWithACredentialRefusesTheShortcutAndAStaleLeaseDeletesNothing() async throws {
        try await withTwoVaults { profile, passkeys, _, doomed in
            let epoch = try #require(doomed.manager.authorizationEpoch)

            // A lock, and a re-unlock after it, do not carry the earlier decision.
            doomed.manager.lock(reason: .manual)
            await #expect(throws: CredentialVaultError.unauthorized) { try await doomed.manager.deleteEmptyVault(authorizedEpoch: epoch) }
            try await VaultManagerFixture.unlock(doomed)
            await #expect(throws: CredentialVaultError.unauthorized) { try await doomed.manager.deleteEmptyVault(authorizedEpoch: epoch) }

            // One credential is something to lose.
            try await VaultManagerFixture.save([VaultFixtures.account()], in: doomed)
            let rows = try VaultManagerFixture.rows(of: doomed.vaultID, in: profile)
            let current = try #require(doomed.manager.authorizationEpoch)
            await #expect(throws: CredentialStoreError.vaultNotEmpty) { try await doomed.manager.deleteEmptyVault(authorizedEpoch: current) }

            #expect(doomed.manager.isUnlocked, "a refused deletion leaves the vault open")
            #expect(try VaultManagerFixture.rows(of: doomed.vaultID, in: profile) == rows)
            #expect(passkeys.assertions.isEmpty)
        }
    }
}
