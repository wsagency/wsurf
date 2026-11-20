// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurfCore
@testable import WSurfVault

@MainActor
struct VaultSyncApplyRecoveryTests {
    @Test func replacingTheBytesAtTheSameVersionPreservesTheReplacement() throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let db = try #require(try VaultSyncDatabase.open(directory: rig.root, create: true))
        let first = InboxRow(accountID: UUID(), version: 2, envelope: Data([1]))
        var second = first
        second.envelope = Data([2])
        try db.write { tx in
            try tx.save(first, vault: rig.vaultID)
            try tx.save(second, vault: rig.vaultID)
            #expect(try !tx.consume(first, vault: rig.vaultID))
            #expect(try tx.inbox(rig.vaultID, limit: 1) == [second])
            #expect(try tx.consume(second, vault: rig.vaultID))
        }
    }

    @Test(arguments: [false, true])
    func aReplacementInANewerFormatKeepsItsTagAndBlocksLocalSaves(removal: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (mac, vault) = try await rig.syncedMac(holding: [entry])
        let id = SyncRecordID(zone: rig.zone, name: entry.id.uuidString)
        var replacement = try #require(rig.cloud.record(id)).payload
        replacement[replacement.startIndex] = VaultSyncCodec.assetFormat + 1
        #expect(throws: VaultSyncError.unsupportedFormat) { try VaultSyncCodec.version(of: replacement) }
        func replaceOnServer() async {
            rig.cloud.overwrite(id, payload: replacement)
            if let record = rig.cloud.record(id) {
                await mac.sync.handle(.fetched(modified: [record], deleted: []))
            }
        }
        if removal {
            let item = SyncItem(accountID: entry.id, version: 2, account: nil)
            rig.cloud.overwrite(id, payload: try VaultSyncCodec.sealItem(item, key: rig.key))
            mac.host.beforeCommit = { _ in
                mac.host.beforeCommit = nil
                await replaceOnServer()
            }
        } else {
            let portable = try VaultAssetAccount(account: syncChanging(entry, note: "remote edit"), chunks: [:])
            let pointer = try VaultSyncCodec.sealAssetAccount(portable, version: 2, key: rig.key)
            let (_, ref) = try VaultSyncCodec.assetReference(pointer.envelope, accountID: entry.id, key: rig.key)
            rig.cloud.encryptedVaultAssets[SyncRecordID(zone: rig.zone, name: ref.name)] = pointer.body
            rig.cloud.overwrite(id, payload: pointer.envelope)
            mac.engine.beforeVaultDownload = { _ in
                mac.engine.beforeVaultDownload = nil
                await replaceOnServer()
            }
        }
        try await mac.engine.fetchNow()
        await mac.sync.settle()

        let db = try #require(mac.sync.database(rig.profile))
        #expect(try db.read { try $0.inboxVersion(rig.vaultID, entry.id) } == 0)
        #expect(try db.read { try $0.systemFields(rig.vaultID, id.name) } == FakeSyncCloud.fields(for: 3))
        #expect(mac.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).newer == 1)
        if removal {
            vault.restore(entry.id)
        }
        vault.edit(syncChanging(entry, password: "local edit"))
        await mac.wrote(vault)
        #expect(mac.sync.record(for: id) == nil)
        try await mac.pump()
        #expect(rig.cloud.record(id)?.payload == replacement && rig.cloud.tag(of: id) == 3)
    }
}
