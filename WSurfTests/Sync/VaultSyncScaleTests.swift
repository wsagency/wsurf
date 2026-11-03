// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// What a sync costs as a vault grows, counted instead of timed: how many times the vault is read in full, and how many entries a change
// touches. A full read of a vault is O(entries), and so is a pass; neither may repeat once per batch of 200. Nothing here touches
// CloudKit, the Keychain or a real vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncScaleTests {
    /// Enough entries for three drain batches and two produce chunks.
    private static let entries = 600

    @Test func joiningAVaultReadsItOnceNotOncePerBatch() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(Self.entries)
        _ = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac(unlock: false)
        let before = b.host.snapshotCount

        await b.unlock(vb)
        try await b.pump()

        #expect(vb.accounts.count == Self.entries && rig.status(b) == .synced)
        // The check of the store, one read for the whole drain and one for produce: not one per batch of 200.
        #expect(b.host.snapshotCount - before <= 4, "\(b.host.snapshotCount - before) full reads of the vault")
        #expect(vb.commitCount >= Self.entries / 200, "the entries still go in batches of 200")
    }

    @Test func aChangeToOneEntrySealsOneItemAndNothingElse() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(Self.entries)
        let (a, va) = try await rig.syncedMac(holding: held)
        let writes = rig.cloud.writeCount
        let before = a.host.snapshotCount

        va.edit(syncChanging(held[300], password: "typed"))
        await a.wrote(va)

        let id = SyncRecordID(zone: rig.zone, name: held[300].id.uuidString)
        #expect(a.engine.pending == [.saveRecord(id)], "exactly the one entry that changed is queued")
        #expect(a.host.snapshotCount - before == 1, "one pass reads the vault once")
        try await a.pump()
        #expect(rig.cloud.writeCount == writes + 1)

        // Nothing changed since: a pass seals and sends nothing.
        let quiet = a.host.snapshotCount
        await a.wrote(va)
        try await a.pump()
        #expect(a.engine.pending.isEmpty && rig.cloud.writeCount == writes + 1)
        #expect(a.host.snapshotCount - quiet == 1)
    }

    @Test func aReadFromScratchOfUnchangedRecordsTakesNothingIn() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(Self.entries)
        let (a, _) = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        let commits = vb.commitCount
        let writes = rig.cloud.writeCount
        let reads = b.host.snapshotCount

        // The change token expired: the engine fetches every record again, and the model gets all of them as modified.
        b.engine.expireChangeToken()
        try await b.engine.fetchNow()
        await b.sync.settle()
        try await b.pump()

        #expect(rig.status(b) == .synced)
        #expect(vb.commitCount == commits && rig.cloud.writeCount == writes, "replays change nothing here and nothing in iCloud")
        #expect(b.host.snapshotCount == reads, "and need no read of the vault: they never reach the inbox")
    }

    /// The drain reads the vault once and follows its own commits. A change the person makes meanwhile, and a vault that is locked and
    /// opened again while a batch waits for the host, must not leave it with a stale view: nothing is lost, nothing is sent twice, and
    /// no row waits.
    @Test func aLocalEditBetweenBatchesAndAnUnlockInTheMiddleOfADrainLeaveNothingWrong() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(Self.entries)
        let (a, va) = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac(unlock: false)
        let pause = HostPause()
        let taken = vb.commitCount
        b.host.beforeCommit = { count in
            if count == taken + 1 {
                await pause.wait()
            }
        }

        // The first batch is in; the second waits for the host.
        vb.unlock()
        b.sync.vaultUnlocked(profileID: rig.profile, vaultID: rig.vaultID)
        _ = await waitUntil { pause.isWaiting }
        let edited = try #require(vb.accounts.values.sorted { $0.id.uuidString < $1.id.uuidString }.first)
        #expect(vb.accounts.count == 200, "one batch is in")

        // The person edits an entry that batch brought in, and the vault is locked and opened again while the second batch waits.
        vb.edit(syncChanging(edited, password: "typed meanwhile"))
        b.lock(vb)
        vb.unlock()
        b.sync.vaultUnlocked(profileID: rig.profile, vaultID: rig.vaultID)
        b.host.beforeCommit = nil
        pause.release()
        await b.sync.settle()
        await b.wrote(vb)
        try await converge([a, b])

        #expect(vb.accounts.count == Self.entries && va.accounts.count == Self.entries, "every entry is on both Macs")
        #expect(vb.account(edited.id)?.password == "typed meanwhile" && va.account(edited.id)?.password == "typed meanwhile")
        #expect(Set(vb.accounts.values.map(\.id)) == Set(held.map(\.id)) && vb.trash.isEmpty && va.trash.isEmpty)
        #expect(try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).isEmpty)
        #expect(rig.status(a) == .synced && rig.status(b) == .synced)
        let sent = try VaultSyncCodec.openItem(#require(rig.item(edited)).payload, accountID: edited.id, key: va.syncKey)
        #expect(sent.version == 2, "the edit went up once, as the version after the one B took in")
    }
}
