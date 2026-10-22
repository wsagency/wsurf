// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// Vault sync through the one engine (spec amendment 2026-10-22), over fake Macs on one fake cloud: sealing, the first upload, adding a
// vault on a second Mac, merge and review, locked vaults, zone removal, account changes, quota and rollback. The keys are per-test
// random; nothing here touches CloudKit, the Keychain or a real vault.

private typealias Rig = VaultSyncRig

private func accounts(_ count: Int) -> [CredentialAccount] {
    syncAccounts(count)
}

private func changing(_ account: CredentialAccount, password: String? = nil, note: String? = nil) -> CredentialAccount {
    syncChanging(account, password: password, note: note)
}

@MainActor
struct VaultSyncTests {
    // MARK: First upload and a second Mac

    @Test func enablingCreatesTheZoneAndUploadsEveryEntrySealed() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(3)

        let (mac, vault) = try await rig.syncedMac(holding: held)

        #expect(rig.cloud.names(in: rig.zone) == (held.map(\.id.uuidString) + ["vault"]).sorted())
        for account in held {
            let record = try #require(rig.item(account))
            #expect(record.type == .item)
            let opened = try VaultSyncCodec.openItem(record.payload, accountID: account.id, key: vault.syncKey)
            #expect(opened.version == 1 && opened.account == account)
        }
        let list = try VaultWrapperList.encode(vault.wrappers)
        let payload = try JSONDecoder().decode(VaultRecordPayload.self, from: #require(rig.record("vault")).payload)
        #expect(rig.record("vault")?.type == .vault)
        #expect(payload.keyGeneration == 1 && payload.wrappers == list)
        #expect(try VaultSyncCodec.openVault(payload.sealed, wrappers: list, key: vault.syncKey) == vault.name)
        #expect(payload.profile.name == "Personal")
        #expect(rig.status(mac) == .synced)
        #expect(vault.commitCount == 0)
    }

    @Test func secondMacAddsAndConverges() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(3)
        let (a, va) = try await rig.syncedMac(holding: held)

        let (b, vb) = try await rig.addedMac(unlock: false)
        #expect(rig.status(b) == .waitingForUnlock(3))
        #expect(vb.commitCount == 0 && vb.accounts.isEmpty)
        await b.unlock(vb)
        try await b.pump()

        #expect(vb.accounts == va.accounts)
        #expect(rig.status(b) == .synced && rig.status(a) == .synced)
        #expect(va.commitCount == 0)
        let writes = rig.cloud.writeCount
        try await converge([a, b])
        #expect(rig.cloud.writeCount == writes, "nothing echoes")

        // B changes the password; A has it after A's next sync, and its History has the old one as a change from another device.
        let target = held[0]
        vb.edit(changing(target, password: "second"))
        await b.wrote(vb)
        try await converge([a, b])
        #expect(va.account(target.id)?.password == "second")
        #expect(va.history[target.id]?.last?.account.password == "secret")
        #expect(va.history[target.id]?.last?.cause == "sync")

        // A moves it to Trash; B has it in its Trash with the account.
        va.remove(target.id)
        await a.wrote(va)
        try await converge([a, b])
        #expect(vb.account(target.id) == nil)
        #expect(vb.trash[target.id]?.password == "second")
        #expect(vb.history[target.id]?.last?.cause == "sync")
        #expect(vb.accounts.count == 2 && va.accounts.count == 2)
    }

    @Test func wrongKeySkipsEntriesAndWritesNothing() async throws {
        let rig = Rig()
        defer { rig.finish() }
        _ = try await rig.syncedMac(holding: accounts(3))
        let writes = rig.cloud.writeCount

        let (b, vb) = try await rig.addedMac(dek: SymmetricKey(size: .bits256))

        #expect(b.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).unreadable == 3)
        #expect(vb.commitCount == 0 && vb.accounts.isEmpty && vb.trash.isEmpty)
        #expect(rig.cloud.writeCount == writes)
        #expect(rig.status(b) == .synced)
    }

    @Test func lockedVaultQueuesUntilUnlock() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(3)
        let (a, va) = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac(unlock: false)

        // Another change arrives while B is locked: it replaces the waiting row of that entry.
        va.edit(changing(held[0], password: "newer"))
        await a.wrote(va)
        try await a.pump()
        try await b.engine.fetchNow()
        await b.sync.settle()
        #expect(rig.status(b) == .waitingForUnlock(3))
        #expect(vb.commitCount == 0 && vb.attempts.isEmpty)

        await b.unlock(vb)
        try await b.pump()

        #expect(vb.accounts.count == 3 && vb.account(held[0].id)?.password == "newer")
        #expect(vb.commitCount == 1, "one batch")
        #expect(rig.status(b) == .synced)
    }

    @Test func lockedVaultStillSendsWhatItSealedBefore() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(1)
        let (a, va) = try await rig.syncedMac(holding: held)
        va.edit(changing(held[0], password: "sealed before the lock"))
        await a.wrote(va)
        a.lock(va)

        try await a.pump()

        let sent = try VaultSyncCodec.openItem(#require(rig.item(held[0])).payload, accountID: held[0].id, key: va.syncKey)
        #expect(sent.version == 2 && sent.account?.password == "sealed before the lock")
    }

    // MARK: Versions

    @Test func nextVersionWaitsForTheSentEvent() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = accounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [first])
        let id = SyncRecordID(zone: rig.zone, name: first.id.uuidString)
        va.edit(changing(first, password: "second"))
        await a.wrote(va)
        let handedOut = try #require(a.sync.record(for: id))
        #expect(try VaultSyncCodec.version(of: handedOut.payload) == 2)

        va.edit(changing(first, password: "third"))
        await a.wrote(va)
        let again = try #require(a.sync.record(for: id))
        #expect(again.payload == handedOut.payload, "a row the engine asked for is never rewritten")

        guard case .saved(let stored) = rig.cloud.save(handedOut) else {
            Issue.record("the fake cloud refused the save")
            return
        }
        await a.sync.handle(.sent(saved: [stored], deleted: [], failed: []))
        await a.sync.settle()
        let next = try #require(a.sync.record(for: id))
        let opened = try VaultSyncCodec.openItem(next.payload, accountID: first.id, key: va.syncKey)
        #expect(opened.version == 3 && opened.account?.password == "third")
    }

    @Test func aSavedRecordThatIsNotTheRowHandedOutIsReadAsIncoming() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = accounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [first])
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        va.edit(changing(first, password: "from A"))
        await a.wrote(va)
        let ours = try #require(a.sync.record(for: SyncRecordID(zone: rig.zone, name: first.id.uuidString)))
        vb.edit(changing(first, password: "from B"))
        await b.wrote(vb)
        try await b.pump()
        let theirs = try #require(rig.item(first))
        #expect(try VaultSyncCodec.version(of: theirs.payload) == 2 && theirs.payload != ours.payload)

        // The engine reports a save at A's version, but the bytes are not the ones A handed out.
        await a.sync.handle(.sent(saved: [theirs], deleted: [], failed: []))
        await a.sync.settle()

        #expect(rig.status(a) == .needsReview(1), "never taken for A's own row")
        #expect(va.account(first.id)?.password == "from A")
    }

    @Test func ownUnconfirmedWriteIsNotAConflict() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let first = accounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [first])
        va.edit(changing(first, password: "second"))
        await a.wrote(va)
        let handedOut = try #require(a.sync.record(for: SyncRecordID(zone: rig.zone, name: first.id.uuidString)))
        // The server took it, and the answer never arrived. Meanwhile the person typed again.
        guard case .saved = rig.cloud.save(handedOut) else {
            Issue.record("the fake cloud refused the save")
            return
        }
        va.edit(changing(first, password: "third"))
        await a.wrote(va)

        try await a.engine.fetchNow()
        try await a.pump()

        #expect(rig.status(a) == .synced, "no review row for a version this Mac wrote itself")
        #expect(va.commitCount == 0)
        #expect(try await a.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).isEmpty)
        #expect(va.account(first.id)?.password == "third")
        let latest = try VaultSyncCodec.openItem(#require(rig.item(first)).payload, accountID: first.id, key: va.syncKey)
        #expect(latest.version == 3 && latest.account?.password == "third")
    }

    // MARK: Concurrent edits

    private struct Divergence {
        let a: SimulatedMac
        let va: FakeVault
        let b: SimulatedMac
        let vb: FakeVault
        let entry: CredentialAccount
    }

    /// Both Macs hold one entry in sync; then each changes it before the other hears.
    private func divergent(
        _ rig: Rig, a changeA: (CredentialAccount) -> CredentialAccount, b changeB: (CredentialAccount) -> CredentialAccount
    ) async throws -> Divergence {
        let entry = accounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        va.edit(changeA(entry))
        await a.wrote(va)
        try await a.pump()
        vb.edit(changeB(entry))
        await b.wrote(vb)
        try await b.pump()
        return Divergence(a: a, va: va, b: b, vb: vb, entry: entry)
    }

    @Test func concurrentEditsBecomeOneReviewNotALoss() async throws {
        let rig = Rig()
        defer { rig.finish() }

        let split = try await divergent(rig, a: { changing($0, password: "from A") }, b: { changing($0, password: "from B") })
        let (va, b, vb, entry) = (split.va, split.b, split.vb, split.entry)

        #expect(rig.status(b) == .needsReview(1))
        #expect(vb.account(entry.id)?.password == "from B", "nothing was applied")
        #expect(va.account(entry.id)?.password == "from A")
        let waiting = try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.count == 1)
        #expect(waiting.first?.kind == .bothChanged && waiting.first?.parts == [.password])
        #expect(waiting.first?.local?.password == "from B" && waiting.first?.incoming?.password == "from A")
        #expect(try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: rig.key).account?.password == "from A")
    }

    @Test func keepingThisMacsVersionUploadsItAndTheOtherStaysInHistory() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let split = try await divergent(rig, a: { changing($0, password: "from A") }, b: { changing($0, password: "from B") })
        let (a, va, b, vb, entry) = (split.a, split.va, split.b, split.vb, split.entry)

        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [entry.id], keepLocal: true)
        try await converge([a, b])

        #expect(vb.account(entry.id)?.password == "from B" && va.account(entry.id)?.password == "from B")
        #expect(va.history[entry.id]?.contains { $0.account.password == "from A" && $0.cause == "sync" } == true)
        #expect(rig.status(a) == .synced && rig.status(b) == .synced)
    }

    @Test func takingICloudsVersionKeepsThisMacsInHistory() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let split = try await divergent(rig, a: { changing($0, password: "from A") }, b: { changing($0, password: "from B") })
        let (a, va, b, vb, entry) = (split.a, split.va, split.b, split.vb, split.entry)
        let writes = rig.cloud.writeCount

        try await b.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [entry.id], keepLocal: false)
        try await converge([a, b])

        #expect(vb.account(entry.id)?.password == "from A" && va.account(entry.id)?.password == "from A")
        #expect(vb.history[entry.id]?.contains { $0.account.password == "from B" && $0.cause == "sync" } == true)
        #expect(rig.cloud.writeCount == writes, "iCloud already held the winner")
        #expect(rig.status(b) == .synced)
    }

    @Test func staleChangeTagIsMergedAndResent() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let split = try await divergent(rig, a: { changing($0, password: "from A") }, b: { changing($0, note: "from B") })
        let (a, va, b, vb, entry) = (split.a, split.va, split.b, split.vb, split.entry)

        try await converge([a, b])

        for vault in [va, vb] {
            #expect(vault.account(entry.id)?.password == "from A")
            #expect(vault.account(entry.id)?.notes?.first?.text == "from B")
        }
        #expect(rig.status(a) == .synced && rig.status(b) == .synced)
        let latest = try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: rig.key)
        #expect(latest.version == 3)
    }

    // MARK: Zone removal, account changes, leaving

    @Test(arguments: SyncZoneDeletionReason.allCases)
    func zoneRemovalStopsSyncAndKeepsLocal(reason: SyncZoneDeletionReason) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(2)
        let (a, va) = try await rig.syncedMac(holding: held)
        let before = va.accounts

        rig.cloud.deleteZone(rig.zone, reason: reason)
        try await a.engine.fetchNow()
        await a.sync.settle()

        #expect(rig.status(a) == .removed(reason))
        #expect(va.accounts == before && va.commitCount == 0)
        #expect(a.sync.record(for: SyncRecordID(zone: rig.zone, name: held[0].id.uuidString)) == nil)
        let writes = rig.cloud.writeCount
        va.edit(changing(held[0], password: "after the removal"))
        await a.wrote(va, timer: false)
        try await a.pump()
        #expect(rig.cloud.writeCount == writes && rig.cloud.zones[rig.zone] == nil && a.engine.pending.isEmpty)
    }

    @Test func nothingUploadsAgainUntilTurnedOn() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(2)
        let (a, va) = try await rig.syncedMac(holding: held)
        rig.cloud.deleteZone(rig.zone, reason: .deleted)
        try await a.engine.fetchNow()
        await a.sync.settle()
        va.edit(changing(held[0], password: "later"))
        await a.wrote(va, timer: false)
        try await a.pump()
        #expect(rig.cloud.zones[rig.zone] == nil)

        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()

        #expect(rig.cloud.names(in: rig.zone).count == 3)
        #expect(try VaultSyncCodec.openItem(#require(rig.item(held[0])).payload, accountID: held[0].id, key: va.syncKey).account?.password == "later")
        #expect(rig.status(a) == .synced)
    }

    @Test func rejoiningReviewsOnlyDifferences() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(3)
        _ = try await rig.syncedMac(holding: held)
        // B holds the same entries without having synced them: one equal, one changed here, one deleted here.
        let (b, vb) = try rig.mac(holding: [held[0], changing(held[1], password: "different")])
        vb.add(held[2])
        vb.remove(held[2].id)
        let tags = held.map { rig.cloud.tag(of: SyncRecordID(zone: rig.zone, name: $0.id.uuidString)) }

        try await b.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await b.pump()

        #expect(rig.status(b) == .needsReview(2))
        let waiting = try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.map(\.kind).sorted { $0.rawValue < $1.rawValue } == [.noCommonBase, .previouslyRemoved])
        #expect(vb.commitCount == 0 && vb.account(held[1].id)?.password == "different" && vb.account(held[2].id) == nil)
        #expect(held.map { rig.cloud.tag(of: SyncRecordID(zone: rig.zone, name: $0.id.uuidString)) } == tags, "nothing was overwritten")
    }

    @Test func accountSwitchClearsSyncStateAndUploadsNothing() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(2)
        let (a, va) = try await rig.syncedMac(holding: held)
        await a.engine.simulateAccount(.signIn(user: "user-1"))

        rig.cloud.switchUser("user-2")
        await a.engine.simulateAccount(.switchAccounts(user: "user-2"))
        await a.sync.settle()

        #expect(rig.status(a) == .accountChanged)
        #expect(a.sync.state.remote.isEmpty && a.sync.state.accountUser == "user-2")
        va.edit(changing(held[0], password: "other account"))
        await a.wrote(va, timer: false)
        try await a.pump()
        #expect(rig.cloud.recordCount == 0 && va.accounts.count == 2)
    }

    @Test func signOutKeepsPendingChangesForTheSameAccount() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(1)
        let (a, va) = try await rig.syncedMac(holding: held)
        await a.engine.simulateAccount(.signIn(user: "user-1"))
        va.edit(changing(held[0], password: "while signed out"))
        await a.wrote(va)

        await a.engine.simulateAccount(.signOut)
        #expect(rig.status(a) == .signedOut)
        await a.engine.simulateAccount(.signIn(user: "user-1"))
        try await a.pump()

        let sent = try VaultSyncCodec.openItem(#require(rig.item(held[0])).payload, accountID: held[0].id, key: va.syncKey)
        #expect(sent.version == 2 && sent.account?.password == "while signed out")
        #expect(rig.status(a) == .synced)
    }

    @Test func removeFromICloudDeletesOnlyTheZone() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(2)
        let (a, va) = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac()
        let otherVault = UUID()
        let otherZone = SyncZone.vault(profileID: rig.profile, vaultID: otherVault)
        let other = try a.host.addVault(profile: rig.profile, vault: otherVault, name: "Other")
        other.add(accounts(1)[0])
        try await a.sync.enable(profileID: rig.profile, vaultID: otherVault)
        try await a.pump()

        a.sync.removeFromICloud(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()
        try await b.engine.fetchNow()
        await b.sync.settle()

        #expect(rig.cloud.zones[rig.zone] == nil && rig.cloud.zones[otherZone] != nil)
        #expect(rig.status(a) == .removed(.deleted) && rig.status(b) == .removed(.deleted))
        #expect(a.sync.status(profileID: rig.profile, vaultID: otherVault) == .synced)
        #expect(va.accounts.count == 2 && vb.accounts.count == 2)
    }

    @Test func deletingTheVaultOrProfileDeletesItsZoneOnlyIfSyncedHere() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, _) = try await rig.syncedMac(holding: accounts(1))
        // A holds a second vault that it never synced, though iCloud has its zone from another Mac.
        let foreign = UUID()
        let foreignZone = SyncZone.vault(profileID: rig.profile, vaultID: foreign)
        rig.cloud.createZone(foreignZone)
        _ = try a.host.addVault(profile: rig.profile, vault: foreign, name: "Never synced here")

        a.sync.vaultDeleted(profileID: rig.profile, vaultID: foreign)
        try await a.pump()
        #expect(rig.cloud.zones[foreignZone] != nil)

        a.sync.vaultDeleted(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()
        #expect(rig.cloud.zones[rig.zone] == nil)
        #expect(rig.status(a) == .off)

        let erased = Rig()
        defer { erased.finish() }
        let (c, _) = try await erased.syncedMac(holding: accounts(1))
        c.sync.profileErased(erased.profile)
        try await c.pump()
        #expect(erased.cloud.zones[erased.zone] == nil)
    }

    @Test func disablingLeavesICloudAndTheOtherMacsAlone() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(2)
        let (a, va) = try await rig.syncedMac(holding: held)
        let writes = rig.cloud.writeCount

        a.sync.disable(profileID: rig.profile, vaultID: rig.vaultID)
        va.edit(changing(held[0], password: "private again"))
        await a.wrote(va, timer: false)
        try await a.pump()

        #expect(rig.status(a) == .off)
        #expect(rig.cloud.writeCount == writes && rig.cloud.names(in: rig.zone).count == 3)
        #expect(a.sync.record(for: SyncRecordID(zone: rig.zone, name: held[0].id.uuidString)) == nil)
    }

    @Test func privateProfileZoneIsNeverFormedOrRead() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let hidden = UUID()
        let (a, va) = try rig.mac(holding: accounts(1), excluded: [hidden])
        let key = VaultSyncKey.derive(dek: rig.dek, profileID: hidden, vaultID: UUID())
        let list = try VaultWrapperList.encode(va.wrappers)
        let payload = VaultRecordPayload(
            keyGeneration: 1, profile: VaultProfileCard(name: "Hidden", symbol: "person", color: "gray"), wrappers: list,
            sealed: try VaultSyncCodec.sealVault(name: "Hidden", wrappers: list, key: key)
        )
        let data = try JSONEncoder().encode(payload)
        func vaultRecord(profile: UUID) -> SyncRecord {
            SyncRecord(id: SyncRecordID(zone: SyncZone.vault(profileID: profile, vaultID: UUID()), name: "vault"), type: .vault, schema: 1, payload: data)
        }
        let hiddenRecord = vaultRecord(profile: hidden)
        let visibleRecord = vaultRecord(profile: UUID())

        await a.sync.handle(.fetched(modified: [hiddenRecord, visibleRecord], deleted: []))

        let visible = try #require(SyncZone.vaultIDs(visibleRecord.id.zone)).profileID
        #expect(a.sync.state.remote.keys.sorted() == [visibleRecord.id.zone])
        #expect(a.sync.remoteVaults(profileID: hidden).isEmpty && a.sync.remoteProfiles().map(\.id) == [visible])
        #expect(a.sync.record(for: hiddenRecord.id) == nil)
        await #expect(throws: VaultSyncFailure.unavailable) { try await a.sync.enable(profileID: hidden, vaultID: UUID()) }
    }

    // MARK: Newer versions, quota, rollback

    @Test func unknownKeyGenerationIsLeftAlone() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(1)
        let (a, va) = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac()
        var payload = try JSONDecoder().decode(VaultRecordPayload.self, from: #require(rig.record("vault")).payload)
        payload.keyGeneration = 2
        rig.cloud.overwrite(SyncRecordID(zone: rig.zone, name: "vault"), payload: try JSONEncoder().encode(payload))

        try await a.engine.fetchNow()
        try await b.engine.fetchNow()
        await b.sync.settle()
        let writes = rig.cloud.writeCount
        vb.edit(changing(held[0], password: "ignored"))
        await b.wrote(vb)
        try await b.pump()

        #expect(rig.status(b) == .needsUpdate && rig.status(a) == .needsUpdate)
        #expect(rig.cloud.writeCount == writes && va.commitCount == 0)
    }

    @Test func aRowFromANewerWSurfIsReadAgainAfterTheUpdate() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(2)
        _ = try await rig.syncedMac(holding: held)
        // The second entry's record is in a format this build does not know.
        let newer = SyncRecordID(zone: rig.zone, name: held[1].id.uuidString)
        let original = try #require(rig.cloud.record(newer)).payload
        var unknown = original
        unknown[unknown.startIndex] = 2
        rig.cloud.overwrite(newer, payload: unknown)

        let (b, vb) = try await rig.addedMac()

        #expect(rig.status(b) == .synced, "the vault goes on without that one entry")
        #expect(Set(vb.accounts.keys) == [held[0].id] && vb.trash.isEmpty, "the entry this build can read arrived")
        #expect(b.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).newer == 1)
        // A launch of the same build tries again and meets the same row.
        b.sync.attach(b.engine)
        await b.sync.settle()
        #expect(Set(vb.accounts.keys) == [held[0].id] && b.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).newer == 1)
        let writes = rig.cloud.writeCount
        vb.add(SyncVaultFixtures.account(username: "made here"))
        await b.wrote(vb)
        try await b.pump()
        #expect(rig.cloud.writeCount == writes + 1, "other entries keep syncing meanwhile")
        #expect(rig.cloud.record(newer)?.payload == unknown, "the record this build cannot read is left as it is")

        // The build that can read it reads the zone again: nothing was lost to the engine having moved on.
        rig.cloud.overwrite(newer, payload: original)
        b.sync.attach(b.engine)
        try await b.pump()
        #expect(Set(vb.accounts.keys).isSuperset(of: held.map(\.id)))
        #expect(rig.status(b) == .synced && b.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).newer == 0)
    }

    @Test func quotaExceededKeepsChangesQueued() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(1)
        let (a, va) = try await rig.syncedMac(holding: held)
        rig.cloud.quotaFull = true
        va.edit(changing(held[0], password: "no room"))
        await a.wrote(va)

        try await a.pump()
        #expect(rig.status(a) == .iCloudFull)
        #expect(a.sync.record(for: SyncRecordID(zone: rig.zone, name: held[0].id.uuidString)) != nil)

        rig.cloud.quotaFull = false
        a.sync.beat()
        try await a.pump()

        #expect(rig.status(a) == .synced)
        #expect(try VaultSyncCodec.openItem(#require(rig.item(held[0])).payload, accountID: held[0].id, key: va.syncKey).account?.password == "no room")
    }

    @Test func restoredOlderStoreStopsSync() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(1)
        let (a, va) = try await rig.syncedMac(holding: held)
        va.edit(changing(held[0], password: "second"))
        await a.wrote(va)
        try await a.pump()
        let writes = rig.cloud.writeCount

        va.revision = 1
        va.edit(changing(held[0], password: "from a restored backup"))
        va.revision = 1
        await a.wrote(va)
        try await a.pump()

        #expect(rig.status(a) == .rolledBack)
        #expect(rig.cloud.writeCount == writes && a.engine.pending.isEmpty)
        #expect(a.sync.record(for: SyncRecordID(zone: rig.zone, name: held[0].id.uuidString)) == nil)
    }

    // MARK: The vault record

    @Test func unlockChangesUpdateTheVaultRecordForLaterMacsOnly() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, va) = try await rig.syncedMac(holding: accounts(1))
        let (b, vb) = try await rig.addedMac()
        let before = vb.wrappers.count

        va.wrappers = try SyncVaultFixtures.wrappers(rig.dek, profile: rig.profile, vault: rig.vaultID, passkeys: [1, 2])
        va.name = "Renamed"
        await a.wrote(va)
        try await a.pump()
        try await b.engine.fetchNow()
        await b.sync.settle()

        let payload = try JSONDecoder().decode(VaultRecordPayload.self, from: #require(rig.record("vault")).payload)
        #expect(try VaultWrapperList.decode(payload.wrappers).count == 2)
        #expect(try VaultSyncCodec.openVault(payload.sealed, wrappers: payload.wrappers, key: va.syncKey) == "Renamed")
        #expect(vb.wrappers.count == before && vb.name == "Personal", "a Mac that added the vault keeps its own list")
        #expect(b.sync.remoteVaults(profileID: rig.profile).first?.payload == payload, "a later Mac would see the new list")
        #expect(rig.status(a) == .synced)
    }

    @Test func remoteVaultsAndProfilesAreListed() async throws {
        let rig = Rig()
        defer { rig.finish() }
        _ = try await rig.syncedMac(holding: accounts(1))
        let other = SimulatedMac(cloud: rig.cloud, root: rig.root.appending(path: "other", directoryHint: .isDirectory))
        other.start()
        let elsewhere = UUID()
        other.host.addProfile(elsewhere, name: "Elsewhere")

        try await other.engine.fetchNow()
        await other.sync.settle()

        #expect(other.sync.remoteVaults(profileID: rig.profile).map(\.vaultID) == [rig.vaultID])
        #expect(other.sync.remoteProfiles().map(\.id) == [rig.profile], "the profile this Mac does not hold")
        #expect(other.sync.remoteProfiles().first?.card.name == "Personal")
        #expect(other.persisted?.remote[rig.zone]?.profileID == rig.profile, "the cache is handed to the app to keep")
    }

    @Test func aLongProfileNameIsCutWhenRead() throws {
        let long = String(repeating: "n", count: 500)
        let json = Data(#"{"name":"\#(long)","symbol":"person","color":"gray"}"#.utf8)

        let card = try JSONDecoder().decode(VaultProfileCard.self, from: json)

        #expect(card.name.count == VaultProfileCard.maxCharacters)
    }

    // MARK: Debounce, offline add, refusals, entries that stay

    @Test func writesAreProducedAfterTheQuietMoment() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(1)
        let (a, va) = try await rig.syncedMac(holding: held)
        va.edit(changing(held[0], password: "typed"))

        a.sync.noteWrite(profileID: rig.profile, vaultID: rig.vaultID)
        _ = await waitUntil { a.clock.pendingCount > 0 }
        a.clock.advance(by: .seconds(1))
        for _ in 0..<20 {
            await Task.yield()
        }
        await a.sync.settle()
        #expect(a.engine.pending.isEmpty, "the quiet moment is not over")

        a.sync.noteWrite(profileID: rig.profile, vaultID: rig.vaultID)
        _ = await waitUntil { a.clock.pendingCount > 0 }
        a.clock.advance(by: .seconds(2))
        for _ in 0..<20 {
            await Task.yield()
        }
        await a.sync.settle()

        #expect(a.engine.pending.contains(.saveRecord(SyncRecordID(zone: rig.zone, name: held[0].id.uuidString))))
    }

    @Test func addingWhileOfflineReadsTheZoneLater() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(2)
        _ = try await rig.syncedMac(holding: held)
        let (b, vb) = try rig.mac(unlocked: false)
        b.engine.offline = true

        await b.sync.adopted(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(rig.status(b) == .sending(1), "the read of the zone is still to do")

        b.engine.offline = false
        b.sync.beat()
        await b.sync.settle()
        await b.unlock(vb)
        try await b.pump()

        #expect(vb.accounts.count == 2 && rig.status(b) == .synced)
    }

    @Test func enablingNeedsAnUnlockedVaultAndAnEngineThatCanRead() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, va) = try rig.mac(holding: accounts(1), unlocked: false)

        await #expect(throws: VaultSyncFailure.locked) { try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID) }
        va.unlock()
        a.engine.offline = true
        await #expect(throws: URLError.self) { try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID) }

        #expect(rig.status(a) == .off && rig.cloud.zones.isEmpty, "a failed start changes nothing")
    }

    @Test func anEntryTheVaultRefusesWaitsAsInformation() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = accounts(2)
        _ = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac(unlock: false)
        vb.unlock()
        vb.commitFailure = CredentialVaultError.invalidData
        await b.unlock(vb)
        try await b.pump()

        #expect(vb.accounts.isEmpty && vb.commitCount == 0)
        let waiting = try await b.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.map(\.kind) == [.refused, .refused])
        #expect(rig.status(b) == .synced, "information rows are not a reason to review")
    }

    @Test func aFailedCommitThatIsNotAboutOneEntryLeavesTheRowsWaiting() async throws {
        let rig = Rig()
        defer { rig.finish() }
        _ = try await rig.syncedMac(holding: accounts(2))
        let (b, vb) = try await rig.addedMac(unlock: false)
        vb.commitFailure = CredentialStoreError.diskFull
        await b.unlock(vb)
        try await b.pump()
        #expect(vb.accounts.isEmpty && vb.commitCount == 0)
        #expect(rig.status(b) == .sending(2), "the rows wait for the next pass")

        vb.commitFailure = nil
        b.sync.beat()
        try await b.pump()

        #expect(vb.accounts.count == 2)
    }

    @Test func entriesThatDoNotFitStayOnThisMacAndAreNeverRemovedElsewhere() async throws {
        let rig = Rig()
        defer { rig.finish() }
        var huge = SyncVaultFixtures.account(username: "huge")
        huge.notes = [CredentialNote(text: String(repeating: "x", count: 800_000))]
        let normal = accounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [huge, normal])

        #expect(rig.item(huge) == nil && rig.item(normal) != nil)
        #expect(a.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).notSyncable == 1)
        va.remove(huge.id)
        await a.wrote(va)
        try await a.pump()

        #expect(rig.item(huge) == nil, "an entry that was never synced is not reported removed")
    }

    // MARK: Nothing secret leaves

    private static func needles(_ marker: Data) -> [Data] {
        var found = [marker]
        for shift in 0..<3 {
            let encoded = (Data(repeating: 0x2E, count: shift) + marker + Data(repeating: 0x2E, count: 3)).base64EncodedString()
            let middle = String(encoded.dropFirst(4).dropLast(8))
            found.append(Data(middle.utf8))
            found.append(Data(middle.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").utf8))
        }
        return found
    }

    private func markedAccount(_ markers: inout [Data]) throws -> CredentialAccount {
        func marker(_ field: String) -> String {
            let text = "\(field)-\(UUID().uuidString)"
            markers.append(Data(text.utf8))
            return text
        }
        let host = UUID().uuidString.lowercased() + ".test"
        markers.append(Data(host.utf8))
        let passkeyKey = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        markers.append(passkeyKey)
        let totp = try TOTP.parse("JBSWY3DPEHPK3PXPJBSWY3DPEHPK3PXP")
        markers.append(totp.secret)
        let passkey = WebsitePasskey(
            id: UUID(), credentialID: Data((0..<32).map { _ in UInt8.random(in: 0...255) }), rpID: host, userHandle: Data([1]),
            userName: marker("passkey-user"), userDisplayName: "Ada", algorithm: -7, privateKeyPKCS8: passkeyKey, backupEligible: true,
            backupState: false
        )
        var account = CredentialAccount(
            id: UUID(), username: marker("username"), displayName: marker("display"), origins: ["https://" + host],
            loginURLs: [URL(string: "https://" + host + "/" + marker("login-path"))!], password: marker("password"), passkeys: [passkey],
            totp: totp, exchangeAccountID: nil, exchangeItemID: nil
        )
        account.notes = [CredentialNote(text: marker("note"))]
        account.secureItems = [
            SecureItem(kind: .customFields, id: Data([0xC0, 0x01]), label: "Locker", fields: [
                SecureItemField(
                    name: "", value: marker("secure-value"),
                    field: CredentialEditableFieldMetadata(id: nil, label: "Code", fieldType: .concealedString)
                ),
            ]),
        ]
        return account
    }

    @Test func nothingSecretLeavesOutsideSealedBytes() async throws {
        let rig = Rig()
        defer { rig.finish() }
        var markers: [Data] = []
        let account = try markedAccount(&markers)
        let vaultName = "vault-name-\(UUID().uuidString)"
        markers.append(Data(vaultName.utf8))
        let (mac, vault) = try rig.mac(holding: [account])
        vault.name = vaultName
        try await mac.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await mac.pump()

        let records = try #require(rig.cloud.records(in: rig.zone))
        #expect(records.count == 2)
        for record in records {
            for marker in markers {
                for needle in Self.needles(marker) {
                    #expect(record.payload.range(of: needle) == nil, "a marker is readable in the \(record.type.rawValue) record")
                }
            }
            #expect(record.id.name == "vault" || UUID(uuidString: record.id.name)?.uuidString == record.id.name)
        }
        #expect(rig.zone.range(of: "^v-[0-9A-F-]{36}-[0-9A-F-]{36}$", options: .regularExpression) != nil)
        // The record round-trips: the markers are in the sealed bytes, not lost.
        let opened = try VaultSyncCodec.openItem(#require(rig.item(account)).payload, accountID: account.id, key: vault.syncKey)
        #expect(opened.account == account)
    }

    @Test func syncStateAtRestHoldsNoPlaintext() async throws {
        let rig = Rig()
        defer { rig.finish() }
        var markers: [Data] = []
        let account = try markedAccount(&markers)
        let (a, vault) = try rig.mac(holding: [account])
        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()
        // A sealed change waits in A's outbox, and the sealed entries wait in B's inbox, when the files are read.
        vault.edit(changing(account, password: "pending-\(UUID().uuidString)"))
        await a.wrote(vault)
        let (b, _) = try await rig.addedMac(unlock: false)
        #expect(rig.status(b) == .waitingForUnlock(1))

        let directories = [a, b].compactMap { $0.host.syncDirectory(profileID: rig.profile) }
        #expect(directories.count == 2)
        for directory in directories {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("Credentials.sync") }
            #expect(files.contains { $0.lastPathComponent == "Credentials.sync" })
            for file in files {
                let bytes = try Data(contentsOf: file)
                for marker in markers {
                    for needle in Self.needles(marker) {
                        #expect(bytes.range(of: needle) == nil, "a marker is readable in \(file.lastPathComponent)")
                    }
                }
            }
        }
    }
}
