// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurfCore
@testable import WSurfVault

@MainActor
struct VaultSyncApplyRecoveryTests {
    private func record(_ account: CredentialAccount, version: UInt64, rig: VaultSyncRig) throws -> SyncRecord {
        let item = SyncItem(accountID: account.id, version: version, account: account)
        return SyncRecord(id: SyncRecordID(zone: rig.zone, name: account.id.uuidString), type: .item, schema: 1, payload: try VaultSyncCodec.sealItem(item, key: rig.key))
    }

    @Test(arguments: [false, true], [false, true])
    func recreatedZoneReplacesAnItemDuringItsDownload(oldAssetSurvives: Bool, distinctServerDates: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let entries = syncAccounts(2)
        let entry = entries[0], peer = entries[1]
        let (mac, vault) = try await rig.syncedMac(holding: [entry])
        let id = SyncRecordID(zone: rig.zone, name: entry.id.uuidString)
        let db = try #require(mac.sync.database(rig.profile))
        let old = try VaultAssetAccount(account: syncChanging(entry, password: "displaced"), chunks: [:])
        let pointer = try VaultSyncCodec.sealAssetAccount(old, version: 2, key: rig.key)
        let (_, ref) = try VaultSyncCodec.assetReference(pointer.envelope, accountID: entry.id, key: rig.key)
        let asset = SyncRecordID(zone: rig.zone, name: ref.name)
        rig.cloud.encryptedVaultAssets[asset] = pointer.body
        rig.cloud.overwrite(id, payload: pointer.envelope)
        let displaced = try #require(rig.cloud.record(id))
        let header = try #require(rig.record(VaultSync.vaultRecordName))
        mac.engine.beforeVaultDownload = { _ in
            mac.engine.beforeVaultDownload = nil
            rig.cloud.removeZoneSilently(rig.zone)
            rig.cloud.createZone(rig.zone)
            if distinctServerDates {
                let later = try #require(displaced.modifiedAt).addingTimeInterval(1)
                rig.cloud.now = { later }
            }
            var newHeader = header
            newHeader.systemFields = nil
            guard case .saved = rig.cloud.save(newHeader),
                  case .saved(let current) = rig.cloud.save(try record(syncChanging(entry, password: "current"), version: 2, rig: rig)),
                  case .saved(let independent) = rig.cloud.save(try record(peer, version: 1, rig: rig)) else {
                Issue.record("The recreated synthetic zone must contain both items")
                return
            }
            #expect(current.systemFields != displaced.systemFields)
            #expect((current.modifiedAt != displaced.modifiedAt) == distinctServerDates)
            if oldAssetSurvives {
                rig.cloud.encryptedVaultAssets[asset] = pointer.body
            }
            await mac.sync.handle(.fetched(modified: [current, independent], deleted: []))
            let stored = try db.read { tx in
                try (tx.inbox(rig.vaultID, limit: 2).first { $0.accountID == entry.id }?.envelope, tx.systemFields(rig.vaultID, id.name))
            }
            #expect(stored.1 != current.systemFields || stored.0 == current.payload, "the replacement tag cannot accompany the old envelope")
            await mac.sync.handle(.fetched(modified: [displaced], deleted: []))
            if distinctServerDates {
                let retained = try db.read { tx in
                    try (tx.inbox(rig.vaultID, limit: 2).first { $0.accountID == entry.id }?.envelope, tx.systemFields(rig.vaultID, id.name))
                }
                #expect(retained.0 == current.payload && retained.1 == current.systemFields)
            }
        }
        try await mac.engine.fetchNow()
        await mac.sync.settle()

        let current = try #require(rig.cloud.record(id))
        #expect(vault.account(entry.id)?.password == "current")
        #expect(vault.account(peer.id)?.username == peer.username)
        #expect(vault.history[entry.id]?.contains { $0.account.password == "displaced" } != true)
        #expect(try db.read { try $0.inboxVersion(rig.vaultID, entry.id) } == nil)
        #expect(try db.read { try $0.systemFields(rig.vaultID, id.name) } == current.systemFields)

        await mac.sync.handle(.fetched(modified: [displaced], deleted: []))
        await mac.sync.settle()
        vault.edit(syncChanging(try #require(vault.account(entry.id)), note: "local note"))
        await mac.wrote(vault)
        let edit = try #require(mac.sync.record(for: id))
        #expect(edit.systemFields == current.systemFields)
        let outgoing = try #require(try db.read { try $0.outbox(rig.vaultID, entry.id) })
        let parts = try VaultSyncCodec.openParts(outgoing.parts, accountID: entry.id, version: outgoing.version, key: rig.key)
        #expect(try parts.password == SyncParts.of(syncChanging(entry, password: "current")).password)
    }

    @Test func delayedSaveConflictHoldsOnlyItsItemUntilTheServerCanReturnIt() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let entries = syncAccounts(2)
        let entry = entries[0], peer = entries[1]
        let (mac, vault) = try await rig.syncedMac(holding: entries)
        vault.edit(syncChanging(entry, note: "local note"))
        await mac.wrote(vault)
        let attempted = try #require(mac.engine.handOut(SyncRecordID(zone: rig.zone, name: entry.id.uuidString)))
        mac.lock(vault)

        func update(_ account: CredentialAccount, password: String) throws -> SyncRecord {
            let updated = try record(syncChanging(account, password: password), version: 2, rig: rig)
            rig.cloud.overwrite(updated.id, payload: updated.payload)
            return try #require(rig.cloud.record(updated.id))
        }
        let stale = try update(entry, password: "displaced")
        let current = try update(entry, password: "current")
        let independent = try update(peer, password: "independent")
        mac.engine.unreadable = [current.id.name]
        await mac.sync.handle(.fetched(modified: [current, independent], deleted: []))
        let late = SyncFailedSave(id: stale.id, failure: .serverRecordChanged(stale), attempted: attempted)
        await mac.sync.handle(.sent(saved: [], deleted: [], failed: [late]))
        await mac.unlock(vault)
        let db = try #require(mac.sync.database(rig.profile))
        #expect(try db.read { try $0.systemFields(rig.vaultID, current.id.name) } == current.systemFields)
        #expect(mac.sync.record(for: current.id) == nil)
        #expect(vault.account(peer.id)?.password == "independent")

        mac.engine.unreadable = []
        mac.sync.beat()
        await mac.sync.settle()
        try await mac.pump()
        let merged = try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: rig.key)
        #expect(merged.account?.password == "current" && merged.account?.notes?.first?.text == "local note")
    }

    @Test func replacementArrivingInsideTheHostCommitMergesAgainstWhatWasWritten() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (mac, vault) = try await rig.syncedMac(holding: [entry])
        let old = try record(syncChanging(entry, password: "displaced"), version: 2, rig: rig)
        let current = try record(syncChanging(entry, password: "current"), version: 2, rig: rig)
        rig.cloud.overwrite(old.id, payload: old.payload)
        mac.host.beforeCommit = { _ in
            mac.host.beforeCommit = nil
            rig.cloud.overwrite(current.id, payload: current.payload)
            if let replacement = rig.cloud.record(current.id) {
                await mac.sync.handle(.fetched(modified: [replacement], deleted: []))
            }
        }
        try await mac.engine.fetchNow()
        await mac.sync.settle()
        #expect(vault.account(entry.id)?.password == "current")
        #expect(rig.status(mac) == .synced)
        #expect(try await mac.sync.conflicts(profileID: rig.profile, vaultID: rig.vaultID).isEmpty)
    }

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
    func lateSaveRepliesPreserveTheParkedServerRecord(unknownItem: Bool) async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let entry = syncAccounts(1)[0]
        let (mac, vault) = try await rig.syncedMac(holding: [entry])
        let id = SyncRecordID(zone: rig.zone, name: entry.id.uuidString)
        vault.edit(syncChanging(entry, password: "local edit"))
        await mac.wrote(vault)
        let attempted = try #require(mac.engine.handOut(id))
        let delayed: SyncEvent
        if unknownItem {
            rig.cloud.deleteRecord(id)
            guard case .failed(.unknownItem) = rig.cloud.save(attempted) else {
                Issue.record("The missing record must reject the in-flight save")
                return
            }
            delayed = .sent(saved: [], deleted: [], failed: [SyncFailedSave(id: id, failure: .unknownItem, attempted: attempted)])
            var recreated = attempted
            recreated.systemFields = nil
            guard case .saved = rig.cloud.save(recreated) else {
                Issue.record("The synthetic writer must recreate the record")
                return
            }
        } else {
            guard case .saved(let saved) = rig.cloud.save(attempted) else {
                Issue.record("The synthetic cloud must accept the original save")
                return
            }
            delayed = .sent(saved: [saved], deleted: [], failed: [])
        }
        var newer = attempted.payload
        newer[newer.startIndex] = VaultSyncCodec.assetFormat + 1
        rig.cloud.overwrite(id, payload: newer)
        let current = try #require(rig.cloud.record(id))
        await mac.sync.handle(.fetched(modified: [current], deleted: []))
        await mac.sync.settle()
        await mac.sync.handle(delayed)
        await mac.sync.settle()
        let db = try #require(mac.sync.database(rig.profile))
        #expect(try db.read { try $0.systemFields(rig.vaultID, id.name) } == current.systemFields)
        #expect(mac.sync.tally(profileID: rig.profile, vaultID: rig.vaultID).newer == 1)
        #expect(mac.sync.record(for: id) == nil)
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
            let displaced = rig.cloud.record(id)
            rig.cloud.overwrite(id, payload: replacement)
            if let record = rig.cloud.record(id) {
                await mac.sync.handle(.fetched(modified: [record], deleted: []))
            }
            if let displaced {
                await mac.sync.handle(.fetched(modified: [displaced], deleted: []))
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
