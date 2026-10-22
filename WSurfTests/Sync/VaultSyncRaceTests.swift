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
        try await lockout.a.engine.sendNow()
        await lockout.a.sync.settle()

        #expect(rig.item(lockout.entry)?.payload == lockout.theirs.payload)
        try await expectBothVersionsToChoose(rig, lockout)
    }
}
