// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// Orders of events that decide whether a Mac's sealed row may go up: what it fetched before it sent, what the engine handed out
// before the server answered, and where a resend comes from. Each test keeps a record from another Mac in iCloud. Nothing here
// touches CloudKit, the Keychain or a real vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncRaceTests {
    /// Two Macs hold one entry in sync. A changes it and seals the change, and is locked before the engine sends; then B's change
    /// of the same entry reaches iCloud.
    private struct Lockout {
        let a: SimulatedMac
        let va: FakeVault
        let b: SimulatedMac
        let vb: FakeVault
        let entry: CredentialAccount
        /// The record B put in iCloud.
        let theirs: SyncRecord

        var id: SyncRecordID {
            SyncRecordID(zone: SyncZone.vault(profileID: va.profileID, vaultID: va.vaultID), name: entry.id.uuidString)
        }
    }

    private func lockedWithAPendingChange(_ rig: Rig) async throws -> Lockout {
        let entry = syncAccounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        va.edit(syncChanging(entry, password: "from A"))
        await a.wrote(va)
        a.lock(va)
        vb.edit(syncChanging(entry, password: "from B"))
        await b.wrote(vb)
        try await b.pump()
        let theirs = try #require(rig.item(entry))
        #expect(try VaultSyncCodec.version(of: theirs.payload) == 2)
        return Lockout(a: a, va: va, b: b, vb: vb, entry: entry, theirs: theirs)
    }

    /// A unlocks. Both versions are there to choose from, and B's is still what iCloud holds.
    private func expectBothVersionsToChoose(_ rig: Rig, _ lockout: Lockout) async throws {
        await lockout.a.unlock(lockout.va)
        try await lockout.a.pump()
        #expect(rig.status(lockout.a) == .needsReview(1))
        #expect(lockout.va.account(lockout.entry.id)?.password == "from A")
        let waiting = try await lockout.a.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID)
        #expect(waiting.count == 1 && waiting.first?.kind == .bothChanged)
        #expect(waiting.first?.local?.password == "from A" && waiting.first?.incoming?.password == "from B")
        #expect(rig.item(lockout.entry)?.payload == lockout.theirs.payload, "iCloud still holds B’s version")
    }

    // MARK: A fetch before a send

    @Test func aFetchBeforeASendNeverOverwritesTheNewerRecord() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let lockout = try await lockedWithAPendingChange(rig)
        let tag = rig.cloud.tag(of: lockout.id)

        // A fetches B’s version while it is locked, so nothing is merged; then the engine sends what A sealed before.
        try await lockout.a.engine.fetchNow()
        await lockout.a.sync.settle()
        try await lockout.a.engine.sendNow()
        await lockout.a.sync.settle()

        #expect(rig.item(lockout.entry)?.payload == lockout.theirs.payload, "A’s row is not sent over a record it has not merged")
        #expect(rig.cloud.tag(of: lockout.id) == tag)
        try await expectBothVersionsToChoose(rig, lockout)
        try await converge([lockout.a, lockout.b])
        #expect(lockout.vb.account(lockout.entry.id)?.password == "from B")
        #expect(rig.item(lockout.entry)?.payload == lockout.theirs.payload)

        // A keeps its version: it goes up as the next version, on the change tag of B’s record, and B takes it.
        try await lockout.a.sync.resolve(profileID: rig.profile, vaultID: rig.vaultID, accountIDs: [lockout.entry.id], keepLocal: true)
        try await converge([lockout.a, lockout.b])
        let latest = try VaultSyncCodec.openItem(#require(rig.item(lockout.entry)).payload, accountID: lockout.entry.id, key: rig.key)
        #expect(latest.version == 3 && latest.account?.password == "from A")
        #expect(lockout.vb.account(lockout.entry.id)?.password == "from A")
        #expect(lockout.vb.history[lockout.entry.id]?.contains { $0.account.password == "from B" } == true, "B’s own version is in its History")
        #expect(rig.status(lockout.a) == .synced && rig.status(lockout.b) == .synced)
    }

    @Test func aSaveTheServerTurnsDownIsNotSentAgainOverTheRecordThatWaitsToBeMerged() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let lockout = try await lockedWithAPendingChange(rig)

        // The engine asked for A’s row and has it in flight. B’s version is fetched meanwhile, and the server then turns the save down.
        _ = try #require(lockout.a.engine.handOut(lockout.id))
        try await lockout.a.engine.fetchNow()
        await lockout.a.sync.settle()
        let failure = SyncFailedSave(id: lockout.id, failure: .serverRecordChanged(lockout.theirs))
        await lockout.a.sync.handle(.sent(saved: [], deleted: [], failed: [failure]))
        await lockout.a.sync.settle()

        #expect(!lockout.a.engine.pending.contains(.saveRecord(lockout.id)), "no second try over a record that waits to be merged")
        try await lockout.a.engine.sendNow()
        await lockout.a.sync.settle()
        #expect(rig.item(lockout.entry)?.payload == lockout.theirs.payload)
        try await expectBothVersionsToChoose(rig, lockout)
    }

    private enum Resend: CaseIterable, CustomTestStringConvertible {
        case heartbeat, signIn

        var testDescription: String {
            "\(self)"
        }
    }

    @Test(arguments: Resend.allCases)
    private func aResendNeverOverwritesTheNewerRecord(trigger: Resend) async throws {
        let rig = Rig()
        defer { rig.finish() }
        let lockout = try await lockedWithAPendingChange(rig)
        try await lockout.a.engine.fetchNow()
        await lockout.a.sync.settle()

        // The heartbeat and a sign-in both ask the engine for everything that still waits to go up.
        switch trigger {
        case .heartbeat:
            lockout.a.sync.beat()
        case .signIn:
            await lockout.a.engine.simulateAccount(.signOut)
            await lockout.a.engine.simulateAccount(.signIn(user: "user-1"))
        }
        await lockout.a.sync.settle()
        #expect(lockout.a.sync.record(for: lockout.id) == nil, "the hold, not the order of events, keeps the row back")
        try await lockout.a.engine.sendNow()
        await lockout.a.sync.settle()

        #expect(rig.item(lockout.entry)?.payload == lockout.theirs.payload)
        try await expectBothVersionsToChoose(rig, lockout)
    }

    // MARK: A lock while a pass runs

    @Test func produceStopsWhenTheVaultIsLockedWhileItRuns() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        va.edit(syncChanging(entry, password: "typed"))
        let pause = HostPause()
        a.host.pauseAfterSnapshot = pause

        // The quiet moment passes and produce reads the vault; the vault is locked before it goes on.
        a.sync.noteWrite(profileID: rig.profile, vaultID: rig.vaultID)
        _ = await waitUntil { a.clock.pendingCount > 0 }
        a.clock.advance(by: .seconds(2))
        _ = await waitUntil { pause.isWaiting }
        a.lock(va)
        pause.release()
        await a.sync.settle()

        #expect(a.engine.pending.isEmpty, "nothing is sealed with a key the vault no longer holds")
        #expect(rig.status(a) == .synced)
        await a.unlock(va)
        try await a.pump()
        let sent = try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: va.syncKey)
        #expect(sent.version == 2 && sent.account?.password == "typed", "the change is sealed at the next unlock")
    }

    // MARK: Sign-out, sign-in and other accounts

    @Test func aZoneAnotherMacRemovedIsNotCreatedAgainAfterASignIn() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, va) = try await rig.syncedMac(holding: syncAccounts(1))
        // A new name for the vault waits to go up; then this Mac signs out, and another Mac removes the vault from iCloud.
        va.name = "Renamed"
        await a.wrote(va)
        await a.engine.simulateAccount(.signOut)
        rig.cloud.deleteZone(rig.zone, reason: .deleted)

        await a.engine.simulateAccount(.signIn(user: "user-1"))
        try await a.pump()

        #expect(rig.cloud.zones[rig.zone] == nil, "only turning sync on creates a zone")
        #expect(rig.status(a) == .removed(.deleted))
        #expect(va.name == "Renamed")
    }

    @Test func anAccountSeenForTheFirstTimeWithSyncOnIsADifferentAccount() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(2)
        // The app’s file was lost, so this Mac does not know which Apple Account it has been syncing with.
        let (a, va) = try rig.mac(holding: held, knownAccount: false)
        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()
        #expect(a.sync.state.accountUser == nil)
        va.edit(syncChanging(held[0], password: "typed"))
        await a.wrote(va)

        // The engine starts fresh and names the account: another one, where a zone of that name exists.
        rig.cloud.switchUser("user-2")
        rig.cloud.createZone(rig.zone)
        await a.engine.simulateAccount(.signIn(user: "user-2"))
        try await a.pump()

        #expect(rig.status(a) == .accountChanged)
        #expect(rig.cloud.recordCount == 0, "nothing went up to the other account")
        #expect(va.account(held[0].id)?.password == "typed" && a.sync.state.accountUser == "user-2")
    }

    @Test func aFirstSignInWithNothingSyncedJustRemembersTheAccount() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, va) = try rig.mac(holding: syncAccounts(1), knownAccount: false)

        await a.engine.simulateAccount(.signIn(user: "user-1"))
        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()

        #expect(a.sync.state.accountUser == "user-1" && rig.status(a) == .synced)
        #expect(rig.cloud.names(in: rig.zone).count == 2 && va.accounts.count == 1)
    }

    @Test func aZoneWhoseCreationWasLostIsCreatedAgainOnlyForAVaultThatNeverUploaded() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let (a, _) = try rig.mac(holding: syncAccounts(1))
        // Sync was turned on and the engine’s queue was lost (a sign-out) before the zone was ever created.
        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        await a.engine.simulateAccount(.signOut)

        await a.engine.simulateAccount(.signIn(user: "user-1"))
        try await a.pump()

        #expect(rig.cloud.zones[rig.zone] != nil && rig.cloud.names(in: rig.zone).count == 2)
        #expect(rig.status(a) == .synced)
    }

    @Test func nothingIsHandedToTheEngineBeforeTheCheckOfTheVaultsAtLaunchHasRun() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        va.edit(syncChanging(entry, password: "sealed before the quit"))
        await a.wrote(va)
        let id = SyncRecordID(zone: rig.zone, name: entry.id.uuidString)
        #expect(a.sync.record(for: id) != nil)

        // The next launch: a vault deleted while sync was off may still have rows, so none is sent until they are checked.
        a.sync.attach(a.engine)
        #expect(a.sync.record(for: id) == nil)
        await a.sync.settle()
        try await a.pump()

        let sent = try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: va.syncKey)
        #expect(sent.account?.password == "sealed before the quit", "and it is sent once they are")
    }
}
