// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// What a merge or a delete on one Mac does on another, and that nothing that was merged away or deleted comes back unasked: the removed
// state and the survivor's update arrive together, a Mac that disagrees is asked, a purge changes nothing elsewhere, and only a
// deliberate restore brings an entry back. A merge is what `CredentialMerge` makes of two entries: the survivor is replaced by one that
// carries a `mergedFrom` link to the other, and the other goes to the Trash. Nothing here touches CloudKit, the Keychain or a real vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncResurrectionTests {
    /// What a merge changes in the survivor besides the link to the entry it absorbed.
    private enum Change: CaseIterable, CustomTestStringConvertible {
        /// Nothing: two identical entries merge, and only the link is new.
        case linkOnly
        case notes
        /// The name of the other entry is picked, which is part of the metadata that the link travels with.
        case name

        var testDescription: String {
            "\(self)"
        }
    }

    /// Both Macs hold both entries at version 1; A merges them while B is unlocked or not, and sends.
    private func merged(_ rig: Rig, _ change: Change, bUnlockedDuringTheMerge: Bool = true) async throws -> MergedEntries {
        let entries = try await MergedEntries.synced(rig)
        if !bUnlockedDuringTheMerge {
            entries.b.lock(entries.vb)
        }
        let gone = entries.gone
        try await entries.merge(send: true) { survivor in
            switch change {
            case .linkOnly:
                break
            case .notes:
                survivor.notes = gone.notes
            case .name:
                survivor.displayName = "Example (old)"
            }
        }
        return entries
    }

    /// What every Mac must end with, and its staying put through more rounds in both directions.
    private func expectMergedEverywhere(_ rig: Rig, _ entries: MergedEntries) async throws {
        let survivor = entries.va.account(entries.keep.id) ?? entries.keep
        for _ in 0..<3 {
            try await entries.rounds(1)
            #expect(entries.vb.account(entries.gone.id) == nil, "the entry merged away does not come back on B")
            #expect(entries.vb.trash[entries.gone.id]?.password == "older", "it is in B’s Trash, with its content")
            #expect(entries.va.account(entries.gone.id) == nil && entries.va.trash[entries.gone.id] != nil)
            let theirs = entries.vb.account(entries.keep.id)
            #expect(theirs?.mergedFrom == survivor.mergedFrom && theirs?.mergedFrom != nil, "B’s survivor carries the link")
            #expect(theirs?.notes == survivor.notes && theirs?.displayName == survivor.displayName)
            #expect(rig.status(entries.a) == .synced && rig.status(entries.b) == .synced)
        }
        let removed = try VaultSyncCodec.openItem(
            #require(rig.cloud.record(entries.goneRecord)).payload, accountID: entries.gone.id, key: entries.va.syncKey
        )
        #expect(removed.account == nil, "iCloud holds the removed state, not the entry")
    }

    // MARK: (a) and (b): a merge reaches a Mac that holds older copies

    @Test(arguments: Change.allCases)
    private func aMergeArrivesAsARemovedStatePlusASurvivorUpdateAndNothingComesBack(change: Change) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = try await merged(rig, change)

        try await expectMergedEverywhere(rig, entries)
    }

    @Test(arguments: Change.allCases)
    private func aMacThatWasLockedDuringTheMergeEndsTheSameAtItsNextUnlock(change: Change) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = try await merged(rig, change, bUnlockedDuringTheMerge: false)
        try await entries.b.engine.fetchNow()
        await entries.b.sync.settle()
        #expect(entries.vb.account(entries.gone.id) != nil, "nothing is applied while B is locked")

        await entries.b.unlock(entries.vb)

        try await expectMergedEverywhere(rig, entries)
    }

    @Test func aMergeWhoseTwoRecordsArriveInSeparateFetchesEndsTheSame() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = try await merged(rig, .name)
        let survivorRecord = try #require(rig.item(entries.keep))
        let goneRecord = try #require(rig.cloud.record(entries.goneRecord))

        // The survivor, which holds the identity of the entry merged away, comes first; the removed state of that entry a fetch later.
        await entries.b.sync.handle(.fetched(modified: [survivorRecord], deleted: []))
        await entries.b.sync.settle()
        await entries.b.sync.handle(.fetched(modified: [goneRecord], deleted: []))
        await entries.b.sync.settle()

        try await expectMergedEverywhere(rig, entries)
    }

    // MARK: (c) B edits the entry that A merged away, before B has fetched

    /// The rows of one Mac, by kind.
    private func kinds(_ mac: SimulatedMac, _ rig: Rig) async throws -> [SyncConflictKind] {
        try await mac.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).map(\.kind).sorted { $0.rawValue < $1.rawValue }
    }

    @Test(arguments: [true, false])
    private func bsEditLandingFirstAsksAAndLosesNothing(keepDeleted: Bool) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = try await MergedEntries.synced(rig)
        let (a, va, b, vb, gone) = (entries.a, entries.va, entries.b, entries.vb, entries.gone)
        try await entries.merge(send: false)
        vb.edit(syncChanging(gone, password: "B edit"))
        await b.wrote(vb)
        try await b.pump()

        // A sends: the survivor goes up, and the removed state is turned down because B’s edit is already there.
        try await a.pump()
        try await entries.rounds()

        #expect(try await kinds(a, rig) == [.changedThereDeletedHere], "A is asked: changed there, deleted here")
        let waiting = try await a.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.first?.incoming?.password == "B edit" && waiting.first?.local == nil)
        #expect(va.account(gone.id) == nil && va.trash[gone.id]?.password == "older", "nothing came back on A, and A’s copy is in its Trash")
        #expect(vb.account(gone.id)?.password == "B edit", "nothing was lost on B")
        // The survivor says it holds the item of the entry B still has, so B waits to take it until that entry is settled.
        #expect(try await kinds(b, rig) == [.ambiguous])

        try await a.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [gone.id], keepLocal: keepDeleted)
        try await entries.rounds()

        if keepDeleted {
            #expect(vb.account(gone.id) == nil && vb.trash[gone.id]?.password == "B edit", "B’s edit is in B’s Trash")
            #expect(vb.account(entries.keep.id)?.mergedFrom != nil && rig.status(a) == .synced && rig.status(b) == .synced)
        } else {
            // Putting the entry back beside a survivor that holds its item would make two holders: the row says so, and nothing moves.
            #expect(try await kinds(a, rig) == [.ambiguous])
            #expect(va.account(gone.id) == nil && va.trash[gone.id]?.password == "older" && vb.account(gone.id)?.password == "B edit")
        }
    }

    @Test(arguments: [true, false])
    private func asRemovalLandingFirstAsksBAndLosesNothing(keepMine: Bool) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = try await MergedEntries.synced(rig)
        let (a, va, b, vb, gone) = (entries.a, entries.va, entries.b, entries.vb, entries.gone)
        try await entries.merge(send: true)

        // B edits before it has fetched: its save is turned down with A’s removed state.
        vb.edit(syncChanging(gone, password: "B edit"))
        await b.wrote(vb)
        try await b.pump()
        try await entries.rounds()

        let waiting = try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.contains { $0.id == gone.id && $0.kind == .deletedThereChangedHere && $0.incoming == nil })
        #expect(waiting.first { $0.id == gone.id }?.local?.password == "B edit")
        #expect(vb.account(gone.id)?.password == "B edit", "nothing was lost on B")
        #expect(va.account(gone.id) == nil && va.trash[gone.id]?.password == "older", "nothing came back on A")

        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [gone.id], keepLocal: keepMine)
        try await entries.rounds()

        if keepMine {
            // B keeps its edit. A’s survivor holds the item of that entry, so A does not take it back as a second holder: it asks.
            #expect(vb.account(gone.id)?.password == "B edit")
            #expect(va.account(gone.id) == nil && va.trash[gone.id] != nil, "nothing is silently put back on A")
            #expect(try await kinds(a, rig) == [.ambiguous])
        } else {
            #expect(vb.account(gone.id) == nil && vb.trash[gone.id]?.password == "B edit", "B’s edit is in B’s Trash")
            #expect(va.account(gone.id) == nil)
            #expect(rig.status(a) == .synced)
            #expect(rig.status(b) == .synced)
        }
    }
}
