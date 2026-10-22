// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// What a Mac may tell the others to delete: a store that is behind what the Mac last synced is checked before anything is read, and
// a large deletion waits for the person. Nothing here touches CloudKit, the Keychain or a real vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncRemovalGuardTests {
    // MARK: A restored store

    @Test func aStoreRestoredBeforeTheUnlockIsCheckedBeforeAnythingIsRead() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(30)
        let (a, va) = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        a.lock(va)
        // The person restores an older copy of the vault while it is locked: most entries are missing, and the revision is behind.
        for account in held.prefix(25) {
            va.remove(account.id)
        }
        va.revision = 1
        // Meanwhile another Mac changes an entry.
        vb.edit(syncChanging(held[29], password: "from B"))
        await b.wrote(vb)
        try await b.pump()
        let writes = rig.cloud.writeCount
        let reads = a.engine.fetchCount

        await a.unlock(va)
        try await a.pump()

        #expect(rig.status(a) == .rolledBack)
        #expect(a.engine.fetchCount == reads, "a store that is behind reads nothing from iCloud")
        #expect(rig.cloud.writeCount == writes, "and sends nothing, not even a deletion")
        #expect(va.account(held[29].id)?.password == "secret")
        try await converge([a, b])
        #expect(vb.accounts.count == 30)
    }

    // MARK: Large deletions

    private struct Deleted {
        let a: SimulatedMac
        let va: FakeVault
        let b: SimulatedMac
        let vb: FakeVault
        let held: [CredentialAccount]
    }

    /// The entries of a vault, synced on A and B, with the first `removing` of them deleted on A and produced.
    private func deleting(_ removing: Int, of total: Int, _ rig: Rig) async throws -> Deleted {
        let held = syncAccounts(total)
        let (a, va) = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        for account in held.prefix(removing) {
            va.remove(account.id)
        }
        await a.wrote(va)
        try await converge([a, b])
        return Deleted(a: a, va: va, b: b, vb: vb, held: held)
    }

    @Test func aLargeDeletionWaitsForTheOwnerAndGoesOutOnce() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let deleted = try await deleting(30, of: 60, rig)
        let (a, va, b, vb, held) = (deleted.a, deleted.va, deleted.b, deleted.vb, deleted.held)

        #expect(rig.status(a) == .holdingRemovals(30))
        #expect(vb.accounts.count == 60, "nothing was deleted elsewhere")
        for account in held {
            #expect(try VaultSyncCodec.version(of: #require(rig.item(account)).payload) == 1, "no removed state was sent")
        }
        // Other changes go on meanwhile.
        va.edit(syncChanging(held[59], password: "typed meanwhile"))
        await a.wrote(va)
        try await converge([a, b])
        #expect(vb.account(held[59].id)?.password == "typed meanwhile")
        #expect(rig.status(a) == .holdingRemovals(30))

        a.sync.releaseRemovals(profileID: rig.profile, vaultID: rig.vaultID)
        try await converge([a, b])
        #expect(vb.accounts.count == 30 && vb.trash.count == 30, "the deletions reached the other Mac, and are in its Trash")
        #expect(rig.status(a) == .synced)

        // The answer was for that pass only: the next large deletion waits again.
        for account in held.dropFirst(30).prefix(25) {
            va.remove(account.id)
        }
        await a.wrote(va)
        try await converge([a, b])
        #expect(rig.status(a) == .holdingRemovals(25))
        #expect(vb.accounts.count == 30)
    }

    @Test(arguments: [(total: 60, removing: 20, held: false), (60, 21, true), (200, 50, false), (200, 51, true)])
    func aDeletionIsHeldOnlyAboveTheLargerOfTwentyAndAQuarter(total: Int, removing: Int, held: Bool) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let deleted = try await deleting(removing, of: total, rig)

        if held {
            #expect(rig.status(deleted.a) == .holdingRemovals(removing))
            #expect(deleted.vb.accounts.count == total)
        } else {
            #expect(rig.status(deleted.a) == .synced)
            #expect(deleted.vb.accounts.count == total - removing && deleted.vb.trash.count == removing)
        }
    }

    @Test func restoringTheEntriesEndsTheHold() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let deleted = try await deleting(30, of: 60, rig)
        #expect(rig.status(deleted.a) == .holdingRemovals(30))
        let writes = rig.cloud.writeCount

        for account in deleted.held.prefix(30) {
            deleted.va.add(account)
        }
        await deleted.a.wrote(deleted.va)
        try await converge([deleted.a, deleted.b])

        #expect(rig.status(deleted.a) == .synced)
        #expect(rig.cloud.writeCount == writes && deleted.vb.accounts.count == 60, "the entries never left the other Mac")
    }
}
