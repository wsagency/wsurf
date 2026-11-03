// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// The edges of what a Mac reads, keeps and shows: a full read with a record that cannot be read, entries with files, rows of a vault
// that is gone, rows that wait for the owner, and a removal from iCloud that did not happen. Nothing here touches CloudKit, the
// Keychain or a real vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncEdgeTests {
    // MARK: A full read

    @Test func oneRecordThatCannotBeReadDoesNotBlockTheOthersOrThisMacsUploads() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(3)
        _ = try await rig.syncedMac(holding: held)
        let (b, vb) = try rig.mac(unlocked: false)
        b.engine.unreadable = [held[2].id.uuidString]

        await b.sync.adopted(profileID: rig.profile, vaultID: rig.vaultID)
        await b.unlock(vb)
        try await b.pump()

        #expect(Set(vb.accounts.keys) == [held[0].id, held[1].id], "the entries that could be read arrived")
        #expect(b.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).unreadable == 1, "the one that could not is counted")
        #expect(rig.status(b) == .synced, "the read finished")
        let own = SyncVaultFixtures.account(username: "made on B")
        vb.add(own)
        await b.wrote(vb)
        try await b.pump()
        #expect(rig.item(own) != nil, "this Mac’s own changes are not held back by it")
    }

    // MARK: Files

    private static func scan() -> CredentialAttachment {
        CredentialAttachment(
            id: UUID(), name: "scan.pdf", contentType: "com.adobe.pdf", size: 10, sha256: Data(repeating: 7, count: 32),
            wrappedKey: Data(repeating: 9, count: CredentialAttachment.wrappedKeyBytes), addedAt: nil
        )
    }

    @Test func aRemoteDeleteNeverMovesAnEntryWithFilesToTrashWithoutAsking() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        // The files of an entry are never synced, so B’s copy of the entry is the only place they are.
        var withFile = entry
        withFile.attachments = [Self.scan()]
        vb.edit(withFile)
        await b.wrote(vb)
        va.remove(entry.id)
        await a.wrote(va)
        try await converge([a, b])

        #expect(vb.account(entry.id)?.attachments?.count == 1 && vb.trash.isEmpty, "the entry and its files stay where they are")
        #expect(rig.status(b) == .needsReview(1))
        let waiting = try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.map(\.kind) == [.deletedThereChangedHere])

        // Moving it to Trash is the owner’s choice, and then it goes with its files.
        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [entry.id], keepLocal: false)
        #expect(vb.account(entry.id) == nil && vb.trash[entry.id]?.attachments?.count == 1)
    }

    // MARK: Rows of a vault that is gone

    @Test func rowsOfAVaultTheProfileNoLongerListsAreDroppedAtLaunchAndNothingIsSent() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(2)
        let (a, va) = try await rig.syncedMac(holding: held)
        va.edit(syncChanging(held[0], password: "sealed before"))
        await a.wrote(va)
        // The vault was deleted while sync did not run, so no hook ran and its rows stayed. The profile still has another vault.
        a.host.removeVault(profile: rig.profile, vault: rig.vaultID)
        _ = try a.host.addVault(profile: rig.profile, name: "Other")
        let writes = rig.cloud.writeCount

        a.sync.attach(a.engine)
        try await a.pump()

        #expect(rig.cloud.writeCount == writes, "a vault that is gone is not sent")
        #expect(rig.status(a) == .off)
        #expect(a.sync.record(for: SyncRecordID(zone: rig.zone, name: held[0].id.uuidString)) == nil)
        #expect(!a.sync.isSyncing(profileID: rig.profile, vaultID: rig.vaultID))
    }

    @Test func rowsOfAVaultThatIsGoneAreDroppedAtTheNextUnlockToo() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, _) = try await rig.syncedMac(holding: syncAccounts(1))
        let otherID = UUID()
        let other = try a.host.addVault(profile: rig.profile, vault: otherID, name: "Other")
        other.add(syncAccounts(1)[0])
        try await a.sync.enable(profileID: rig.profile, vaultID: otherID)
        try await a.pump()
        a.host.removeVault(profile: rig.profile, vault: rig.vaultID)

        a.sync.vaultUnlocked(profileID: rig.profile, vaultID: otherID)
        await a.sync.settle()

        #expect(rig.status(a) == .off)
        #expect(a.sync.status(profileID: rig.profile, vaultID: otherID) == .synced, "the vault that is still there is untouched")
    }

    @Test(arguments: [false, true])
    private func aListingThatIsEmptyOrMissingDropsNothing(missing: Bool) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, _) = try await rig.syncedMac(holding: syncAccounts(1))
        if missing {
            // The profile still has its vaults; the host cannot list them now.
            _ = try a.host.addVault(profile: rig.profile, name: "Other")
            a.host.removeVault(profile: rig.profile, vault: rig.vaultID)
            a.host.listingUnavailable = true
        } else {
            a.host.removeVault(profile: rig.profile, vault: rig.vaultID)
        }

        a.sync.attach(a.engine)
        await a.sync.settle()

        #expect(rig.status(a) == .synced, "a listing that is empty or missing is not trusted as “every vault is gone”")
    }

    // MARK: Rows that wait for the owner

    @Test func informationRowsCountAsWaitingAndAreDismissedFromTheSheet() async throws {
        let rig = Rig()
        defer { rig.finish() }
        _ = try await rig.syncedMac(holding: syncAccounts(2))
        let (b, vb) = try await rig.addedMac(unlock: false)
        vb.unlock()
        vb.commitFailure = CredentialVaultError.invalidData
        await b.unlock(vb)
        try await b.pump()

        let waiting = try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.map(\.kind) == [.refused, .refused])
        #expect(rig.status(b) == .needsReview(2), "rows that stop an entry from syncing are not “up to date”")

        vb.commitFailure = nil
        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: waiting.map(\.id), keepLocal: true)
        #expect(try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).isEmpty)
        #expect(rig.status(b) == .synced)
        #expect(vb.accounts.isEmpty && vb.trash.isEmpty, "dismissing writes nothing here and deletes nothing anywhere")
    }

    @Test(arguments: [true, false])
    func aReviewRowWhoseEntryWasDeletedMeanwhileCanStillBeAnswered(keepLocal: Bool) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        va.edit(syncChanging(entry, password: "from A"))
        await a.wrote(va)
        try await a.pump()
        vb.edit(syncChanging(entry, password: "from B"))
        await b.wrote(vb)
        try await b.pump()
        #expect(rig.status(b) == .needsReview(1))
        // The owner deletes the entry on B before answering.
        vb.remove(entry.id)
        await b.wrote(vb)

        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [entry.id], keepLocal: keepLocal)
        try await converge([a, b])

        #expect(rig.status(b) == .synced && rig.status(a) == .synced)
        #expect(try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).isEmpty)
        if keepLocal {
            #expect(vb.account(entry.id) == nil && va.account(entry.id) == nil, "kept deleted, on both")
        } else {
            #expect(vb.account(entry.id)?.password == "from A", "iCloud’s version came back")
        }
    }

    // MARK: A removal from iCloud that did not happen

    @Test func aRemovalFromICloudThatFailedStaysVisibleUntilItWorks() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, _) = try await rig.syncedMac(holding: syncAccounts(2))
        a.engine.failsZoneDeletes = true

        a.sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()

        #expect(rig.cloud.zones[rig.zone] != nil, "the zone is still in iCloud")
        #expect(rig.status(a) == .removalFailed, "and the vault says so, instead of “removed”")

        a.engine.failsZoneDeletes = false
        a.sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()

        #expect(rig.cloud.zones[rig.zone] == nil)
        #expect(rig.status(a) == .removed(.deleted))
    }

    @Test func dismissingARowThatHasABaseKeepsTheVersionSoTheNextEditLandsOnTheRightTag() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        // A changes the password; B’s vault refuses to take it, so it waits as information, and the owner dismisses it.
        va.edit(syncChanging(entry, password: "from A"))
        await a.wrote(va)
        try await a.pump()
        vb.commitFailure = CredentialVaultError.invalidData
        try await b.engine.fetchNow()
        await b.sync.settle()
        #expect(try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).map(\.kind) == [.refused])
        vb.commitFailure = nil
        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [entry.id], keepLocal: true)

        // B then edits the entry. The record that goes up must be the version after A’s, on A’s change tag; at the version A already
        // holds it would overwrite A’s record and be dropped by A as a replay.
        vb.edit(syncChanging(entry, note: "from B"))
        await b.wrote(vb)
        try await b.pump()
        let sent = try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: va.syncKey)
        #expect(sent.version == 3 && sent.account?.notes?.first?.text == "from B")
        try await converge([a, b])

        #expect(va.account(entry.id) == vb.account(entry.id), "both Macs ended with one version of the entry")
        #expect(va.account(entry.id)?.notes?.first?.text == "from B")
        #expect(va.history[entry.id]?.contains { $0.account.password == "from A" } == true, "A’s own version is in its History")
        #expect(rig.status(a) == .synced && rig.status(b) == .synced)
    }

    @Test func aFailedReadOfTheVaultDoesNotMarkItLocked() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        va.edit(syncChanging(entry, password: "typed"))

        // One read fails while the vault is unlocked: that pass seals nothing, and the next one does.
        a.host.failSnapshots = 1
        await a.wrote(va)
        #expect(a.engine.pending.isEmpty)
        await a.wrote(va)

        #expect(a.engine.pending == [.saveRecord(SyncRecordID(zone: rig.zone, name: entry.id.uuidString))])
    }

    @Test func aSkippedRecordIsReadAgainAtTheNextHeartbeatOnceAndNeverHoldsProduce() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(3)
        _ = try await rig.syncedMac(holding: held)
        let (b, vb) = try rig.mac(unlocked: false)
        b.engine.unreadable = [held[2].id.uuidString]
        await b.sync.adopted(profileID: rig.profile, vaultID: rig.vaultID)
        await b.unlock(vb)
        try await b.pump()
        #expect(Set(vb.accounts.keys) == [held[0].id, held[1].id])
        let reads = b.engine.fetchAllCount

        // The server can return it now: the heartbeat reads the zone once more, and the entry arrives.
        b.engine.unreadable = []
        b.sync.beat()
        await b.sync.settle()
        try await b.pump()

        #expect(b.engine.fetchAllCount == reads + 1)
        #expect(Set(vb.accounts.keys) == Set(held.map(\.id)))
        // Once it is read, it is not read again.
        b.sync.beat()
        await b.sync.settle()
        #expect(b.engine.fetchAllCount == reads + 1)
    }

    @Test func aRecordThatStaysUnreadableIsReadAgainOncePerRunNotAtEveryHeartbeat() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(2)
        _ = try await rig.syncedMac(holding: held)
        let (b, vb) = try rig.mac(unlocked: false)
        b.engine.unreadable = [held[1].id.uuidString]
        await b.sync.adopted(profileID: rig.profile, vaultID: rig.vaultID)
        await b.unlock(vb)
        let reads = b.engine.fetchAllCount

        for _ in 0..<3 {
            b.sync.beat()
            await b.sync.settle()
        }

        #expect(b.engine.fetchAllCount == reads + 1, "one more read in this run, not one per heartbeat")
        #expect(Set(vb.accounts.keys) == [held[0].id])
    }

    @Test func aRemovalThatFailedClearsWhenTheEngineGetsItDoneLaterWithoutTryAgain() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, _) = try await rig.syncedMac(holding: syncAccounts(1))
        a.engine.failsZoneDeletes = true
        a.sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()
        #expect(rig.status(a) == .removalFailed)

        a.engine.failsZoneDeletes = false
        try await a.engine.sendNow()
        await a.sync.settle()

        #expect(rig.cloud.zones[rig.zone] == nil)
        #expect(rig.status(a) == .removed(.deleted), "it did get done")
    }

    @Test func aZoneThatIsAlreadyGoneCountsAsRemoved() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, _) = try await rig.syncedMac(holding: syncAccounts(1))
        a.engine.failsZoneDeletes = true
        a.sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()
        #expect(rig.status(a) == .removalFailed)

        // Another Mac removes the zone meanwhile, so the engine’s delete finds nothing to delete.
        rig.cloud.deleteZone(rig.zone, reason: .deleted)
        try await a.engine.sendNow()
        await a.sync.settle()

        #expect(rig.status(a) == .removed(.deleted))
    }
}
