// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// What a purge, a restore and an old removal do to entries that were merged away or deleted on another Mac: a purge changes nothing
// elsewhere, only a deliberate restore brings an entry back, and an entry that arrives live with no base after its ID was removed here
// is asked about. Nothing here touches CloudKit, the Keychain or a real vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncDeleteRaceTests {
    // MARK: (d) A empties its Trash

    @Test func purgingTheMergedAwayEntryOnAChangesNothingOnBAndNothingComesBack() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = try await MergedEntries.synced(rig)
        try await entries.merge(send: true)
        try await entries.rounds()
        let (a, va, vb, gone) = (entries.a, entries.va, entries.vb, entries.gone)
        let tag = rig.cloud.tag(of: entries.goneRecord)
        let writes = rig.cloud.writeCount

        va.purge(gone.id)
        await a.wrote(va)
        try await entries.rounds()

        #expect(rig.cloud.tag(of: entries.goneRecord) == tag && rig.cloud.writeCount == writes, "a purge sends nothing")
        #expect(vb.trash[gone.id]?.password == "older" && vb.account(gone.id) == nil, "B keeps its own Trash entry")
        #expect(va.account(gone.id) == nil && va.trash[gone.id] == nil && va.tombstones.contains(gone.id))
        #expect(rig.status(a) == .synced && rig.status(entries.b) == .synced)
    }

    // MARK: (e) B restores an entry A deleted

    @Test func restoringADeletedEntryOnBIsADeliberateChangeAndSyncsAsOne() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = try await MergedEntries.synced(rig)
        let (a, va, b, vb, gone) = (entries.a, entries.va, entries.b, entries.vb, entries.gone)
        va.remove(gone.id)
        await a.wrote(va)
        try await entries.rounds()
        #expect(vb.trash[gone.id] != nil && vb.account(gone.id) == nil)

        vb.restore(gone.id)
        await b.wrote(vb)
        try await entries.rounds()

        #expect(va.account(gone.id)?.password == "older" && vb.account(gone.id)?.password == "older", "it is back on both")
        #expect(rig.status(a) == .synced && rig.status(b) == .synced)
        let latest = try VaultSyncCodec.openItem(#require(rig.record(gone.id.uuidString)).payload, accountID: gone.id, key: va.syncKey)
        #expect(latest.version == 3 && latest.account != nil, "a new version after the removed state, not a replay of the first")
    }

    // MARK: (f) An entry with no base whose ID this Mac removed before

    @Test(arguments: [false, true])
    private func anEntryThatArrivesLiveWithNoBaseAfterItsIDWasRemovedHereIsAskedAbout(purged: Bool) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = SyncVaultFixtures.account(username: "ada", password: "from A", origin: "https://example.test")
        let (a, va) = try await rig.syncedMac(holding: [entry])
        // B held the entry, deleted it (and maybe emptied its Trash) before it ever synced, and turns sync on now.
        let (b, vb) = try rig.mac(holding: [entry])
        vb.remove(entry.id)
        if purged {
            vb.purge(entry.id)
        }
        let writes = rig.cloud.writeCount

        try await b.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await b.pump()
        try await converge([a, b])

        #expect(vb.account(entry.id) == nil, "never a silent add")
        #expect(rig.status(b) == .needsReview(1))
        let waiting = try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.map(\.kind) == [.previouslyRemoved] && waiting.first?.incoming?.password == "from A")
        #expect(rig.cloud.writeCount == writes && va.account(entry.id) != nil, "and nothing is deleted on A")
    }

    // MARK: Entries removed before sync was on

    @Test func dismissingARowForAnEntryRemovedBeforeSyncNeverSendsItsRemovalOverTheNewerRecord() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = SyncVaultFixtures.account(username: "ada", password: "v1", origin: "https://example.test")
        let (a, va) = try await rig.syncedMac(holding: [entry])
        for password in ["v2", "v3", "v4"] {
            va.edit(syncChanging(entry, password: password))
            await a.wrote(va)
            try await a.pump()
        }
        // B held the entry and deleted it before sync was on. It turns sync on now: the entry arrives, live, at version 4.
        let (b, vb) = try rig.mac(holding: [entry])
        vb.remove(entry.id)
        try await b.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await b.pump()
        #expect(try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).map(\.kind) == [.previouslyRemoved])

        // The owner chooses Restore, B’s vault refuses it, and the owner dismisses the refusal.
        vb.commitFailure = CredentialVaultError.invalidData
        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [entry.id], keepLocal: false)
        vb.commitFailure = nil
        #expect(try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).map(\.kind) == [.refused])
        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [entry.id], keepLocal: true)
        try await converge([a, b])

        // Its removal as it was before sync is not sent over a record this Mac has seen: iCloud keeps version 4.
        let held = try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: va.syncKey)
        #expect(held.version == 4 && held.account?.password == "v4")
        #expect(va.account(entry.id)?.password == "v4" && rig.status(a) == .synced)
    }

    @Test func manyEntriesDeletedBeforeSyncAreToldOnceAndAreNotAHeldDeletion() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = syncAccounts(35)
        let (a, va) = try rig.mac(holding: entries)
        for entry in entries.prefix(30) {
            va.remove(entry.id)
        }

        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()

        #expect(rig.status(a) == .synced, "they remove nothing anywhere, so they are not a large deletion")
        for entry in entries.prefix(30) {
            let told = try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: va.syncKey)
            #expect(told.version == 1 && told.account == nil)
        }
        // A Mac that adds the vault later keeps what they stood for, and holds none of them.
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        #expect(vb.accounts.count == 5 && vb.trash.isEmpty && vb.tombstones.count == 30)
        #expect(rig.status(a) == .synced && rig.status(b) == .synced)
    }
}
