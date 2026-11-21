// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfCore
import WSurfVault

extension VaultAssetDeviceTransferTests {
    enum ManifestRepair: CaseIterable {
        case acknowledgement, restart, missingStaging, concurrentWriter, accountSwitch
    }

    @Test(arguments: ManifestRepair.allCases)
    func aFreshMacRecoversAManifestReplacedDuringTheItemSave(_ retry: ManifestRepair) async throws {
        try await withDevicePair { pair in
            try await pair.enableA()
            let bytes = Data("original attachment".utf8)
            let file = pair.envA.directory.appending(path: "attachment.bin")
            try bytes.write(to: file)
            var entry = pair.account("attached", password: "original password")
            entry.attachments = [try await pair.managerA.addAttachment(from: file)]
            let peer = pair.account("unrelated")
            try await pair.save([entry, peer], in: pair.managerA)
            await pair.wrote(pair.syncA, pair.clockA)

            let key = VaultKey(profileID: pair.profile.id, vaultID: pair.vaultID)
            let user = pair.cloud.user
            let id = key.itemRecord(entry.id)
            let db = try #require(pair.syncA.database(pair.profile.id))
            let row = try #require(try db.read { try $0.outbox(pair.vaultID, entry.id) })
            let (_, manifest) = try VaultSyncCodec.assetReference(row.envelope, accountID: entry.id, key: try await pair.managerA.syncKey())
            let manifestID = SyncRecordID(zone: key.zone, name: manifest.name)
            let assets = pair.cloud.encryptedVaultAssets
            let original = try #require(assets[manifestID])
            let assetWrites = pair.cloud.vaultAssetWrites
            var repairedWrites = assetWrites
            repairedWrites[manifestID, default: 0] += 1
            #expect(assets.count == 2)
            pair.engineA.beforeRecordSave = { record in
                guard record.id == id else { return }
                pair.engineA.beforeRecordSave = nil
                #expect(record.assetManifestName == manifest.name)
                pair.cloud.encryptedVaultAssets[manifestID] = Data([0])
            }
            if retry != .acknowledgement {
                pair.engineA.beforeVaultUpload = { _ in throw URLError(.networkConnectionLost) }
            }
            try await pair.engineA.sendNow()
            await pair.syncA.settle()
            let saved = try #require(pair.cloud.record(id))
            let itemWrites = pair.cloud.writeCount
            #expect(saved.payload == row.envelope)
            #expect(try db.read { try $0.outbox(pair.vaultID, entry.id) } == nil)
            let folder = try #require(pair.syncA.assetDirectory(key)).appending(path: "out/\(entry.id.uuidString.lowercased())")
            let staged = folder.appending(path: manifest.name)
            if retry != .acknowledgement {
                #expect(pair.cloud.encryptedVaultAssets[manifestID] == Data([0]))
                #expect(try db.read { try $0.pendingAssetCheck(pair.vaultID, entry.id) } != nil)
                #expect((try? Data(contentsOf: staged)) == original)
            }

            try await pair.addToB()
            try await pair.unlockB()
            let receiver = try #require(pair.managerB)
            let waiting = try await pair.accounts(receiver)
            #expect((waiting[entry.id] != nil) == (retry == .acknowledgement))
            #expect(waiting[peer.id]?.username == peer.username)

            switch retry {
            case .acknowledgement:
                break
            case .restart:
                await pair.relaunch(onA: true)
            case .missingStaging:
                try FileManager.default.removeItem(at: staged)
                await pair.relaunch(onA: true)
                pair.syncA.beat()
                await pair.syncA.settle()
                #expect(try db.read { try $0.pendingAssetCheck(pair.vaultID, entry.id) } != nil)
                #expect(pair.cloud.encryptedVaultAssets[manifestID] == Data([0]) && pair.cloud.vaultAssetWrites == assetWrites)
                #expect(pair.cloud.writeCount == itemWrites && pair.cloud.record(id)?.systemFields == saved.systemFields)
                return
            case .concurrentWriter:
                let writer = FakeSyncEngine(cloud: pair.cloud)
                let copy = pair.envA.directory.appending(path: "other-mac.manifest")
                try original.write(to: copy)
                let previous = try #require(row.publication?.tags[manifest])
                pair.engineA.beforeVaultUpload = { name in
                    #expect(name == manifest.name)
                    _ = try await writer.uploadVaultAsset(manifest, from: copy, zone: key.zone, user: user, acknowledged: previous)
                }
                pair.syncA.beat()
                await pair.syncA.settle()
                #expect(pair.cloud.encryptedVaultAssets[manifestID] == original && pair.cloud.vaultAssetWrites == repairedWrites)
                #expect(try db.read { try $0.pendingAssetCheck(pair.vaultID, entry.id) } != nil)
                pair.engineA.beforeVaultUpload = nil
            case .accountSwitch:
                pair.engineA.beforeVaultUpload = { _ in
                    pair.cloud.switchUser("other-synthetic-account")
                    pair.cloud.createZone(key.zone)
                }
                pair.syncA.beat()
                await pair.syncA.settle()
                #expect(pair.cloud.user != user && pair.cloud.encryptedVaultAssets.isEmpty)
                #expect(try db.read { try $0.pendingAssetCheck(pair.vaultID, entry.id) } != nil)
                return
            }

            pair.syncA.beat()
            await pair.syncA.settle()
            pair.syncB.beat()
            try await pair.converge()
            #expect(pair.cloud.encryptedVaultAssets == assets && pair.cloud.vaultAssetWrites == repairedWrites)
            #expect(pair.cloud.writeCount == itemWrites && pair.cloud.record(id)?.systemFields == saved.systemFields)
            #expect(try db.read { try $0.pendingAssetCheck(pair.vaultID, entry.id) } == nil)
            #expect(try db.read { try $0.assetTag(manifest, key: key, user: user) } == nil)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            let received = try #require(try await pair.accounts(receiver)[entry.id])
            #expect(received.password == entry.password)
            let attachment = try #require(received.attachments?.first)
            let copy = pair.envA.directory.appending(path: "received.bin")
            try await receiver.readAttachment(attachment, to: copy)
            #expect(try Data(contentsOf: copy) == bytes)
        }
    }
}
