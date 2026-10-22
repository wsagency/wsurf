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
}
