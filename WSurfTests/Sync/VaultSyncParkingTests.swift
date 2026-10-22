// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// A record in a format only a newer WSurf reads: it parks that one entry, in the inbox, with its bytes. The vault goes on, nothing
// is sent over the parked record, and the build that can read it takes it in. Nothing here touches CloudKit, the Keychain or a real
// vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncParkingTests {
    /// `payload` with its format byte set to one this build does not know.
    private static func inANewerFormat(_ payload: Data) -> Data {
        var unknown = payload
        unknown[unknown.startIndex] = 2
        return unknown
    }

    @Test func theFormatByteIsPartOfWhatAnItemOpensAs() {
        let key = VaultSyncKey.derive(dek: SymmetricKey(size: .bits256), profileID: UUID(), vaultID: UUID())
        let account = UUID()
        let known = VaultSyncCodec.itemAAD(key: key, accountID: account, format: VaultSyncCodec.itemFormat, state: 1, version: 1)
        let newer = VaultSyncCodec.itemAAD(key: key, accountID: account, format: VaultSyncCodec.itemFormat + 1, state: 1, version: 1)
        #expect(known != newer, "a value sealed for one format never opens as another")
    }

    @Test func anItemSealedForAnotherFormatNeverOpensAsThisOne() throws {
        let key = VaultSyncKey.derive(dek: SymmetricKey(size: .bits256), profileID: UUID(), vaultID: UUID())
        let account = UUID()
        func envelope(sealedFor format: UInt8) throws -> Data {
            var header = StoreWriter()
            header.u8(VaultSyncCodec.itemFormat)
            header.u8(VaultSyncCodec.removedState)
            header.u64(1)
            let aad = VaultSyncCodec.itemAAD(key: key, accountID: account, format: format, state: VaultSyncCodec.removedState, version: 1)
            return header.data + (try #require(try AES.GCM.seal(Data(), using: key.key, authenticating: aad).combined))
        }

        #expect(try VaultSyncCodec.openItem(envelope(sealedFor: VaultSyncCodec.itemFormat), accountID: account, key: key).account == nil)
        // The header says this format and the seal was made for another: it does not open.
        #expect(throws: VaultSyncError.authenticationFailed) {
            _ = try VaultSyncCodec.openItem(envelope(sealedFor: VaultSyncCodec.itemFormat + 1), accountID: account, key: key)
        }
    }

    @Test func aRecordInANewerFormatParksOnlyThatEntry() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let held = syncAccounts(3)
        let (a, va) = try await rig.syncedMac(holding: held)
        let (b, vb) = try await rig.addedMac()
        try await converge([a, b])
        // A newer WSurf rewrites the second entry in a format this build cannot read.
        let id = SyncRecordID(zone: rig.zone, name: held[1].id.uuidString)
        let unknown = Self.inANewerFormat(try #require(rig.cloud.record(id)).payload)
        rig.cloud.overwrite(id, payload: unknown)

        try await b.engine.fetchNow()
        await b.sync.settle()
        #expect(rig.status(b) == .synced, "one entry does not stop the vault")
        #expect(b.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).newer == 1)

        // B changes the parked entry and another one: only the other goes up.
        vb.edit(syncChanging(held[1], password: "typed on B"))
        vb.edit(syncChanging(held[0], password: "also typed on B"))
        await b.wrote(vb)
        try await b.pump()
        #expect(rig.cloud.record(id)?.payload == unknown, "nothing is written over the parked record")
        let other = try VaultSyncCodec.openItem(#require(rig.item(held[0])).payload, accountID: held[0].id, key: rig.key)
        #expect(other.version == 2 && other.account?.password == "also typed on B")

        // The newer WSurf writes the entry in a format B reads: B merges it with what it typed, and A gets the result.
        let update = syncChanging(held[1], note: "from the update")
        let readable = try VaultSyncCodec.sealItem(SyncItem(accountID: held[1].id, version: 3, account: update), key: rig.key)
        rig.cloud.overwrite(id, payload: readable)
        try await converge([a, b])
        #expect(b.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).newer == 0)
        for vault in [va, vb] {
            #expect(vault.account(held[1].id)?.password == "typed on B")
            #expect(vault.account(held[1].id)?.notes?.first?.text == "from the update")
        }
        #expect(rig.status(a) == .synced && rig.status(b) == .synced)
    }

    @Test func aSaveAnsweredWithARecordInANewerFormatIsParkedNotSentOver() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (a, va) = try await rig.syncedMac(holding: [entry])
        va.edit(syncChanging(entry, password: "sealed here"))
        await a.wrote(va)
        // Before A sends, a newer WSurf rewrites the record, so the server answers A’s save with it.
        let id = SyncRecordID(zone: rig.zone, name: entry.id.uuidString)
        let unknown = Self.inANewerFormat(try #require(rig.cloud.record(id)).payload)
        rig.cloud.overwrite(id, payload: unknown)

        try await a.pump()

        #expect(rig.cloud.record(id)?.payload == unknown, "the save is not tried again over a record this build cannot read")
        #expect(a.engine.pending.isEmpty)
        #expect(a.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).newer == 1)
        #expect(va.account(entry.id)?.password == "sealed here")
    }
}
