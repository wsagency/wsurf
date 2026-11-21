// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfCore
import WSurfVault

extension VaultAssetDeviceTransferTests {
    enum ChunkRepairRetry: CaseIterable {
        case heartbeat, restart, accountSwitch
    }

    @Test(arguments: ChunkRepairRetry.allCases)
    func aFreshMacRecoversAChunkLostDuringTheItemSave(retry: ChunkRepairRetry) async throws {
        try await withDevicePair { pair in
            try await pair.enableA()
            let bytes = Data("original attachment bytes".utf8)
            let source = pair.envA.directory.appending(path: "original.bin")
            try bytes.write(to: source)
            var entry = pair.account("attached", password: "original password")
            entry.attachments = [try await pair.managerA.addAttachment(from: source)]
            let peer = pair.account("unrelated")
            try await pair.save([entry, peer], in: pair.managerA)
            await pair.wrote(pair.syncA, pair.clockA)

            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let id = SyncRecordID(zone: zone, name: entry.id.uuidString)
            let db = try #require(pair.syncA.database(pair.profile.id))
            let row = try #require(try db.read { try $0.outbox(pair.vaultID, entry.id) })
            let (_, manifest) = try VaultSyncCodec.assetReference(row.envelope, accountID: entry.id, key: try await pair.managerA.syncKey())
            let chunk = try #require(pair.cloud.encryptedVaultAssets.keys.first { $0.zone == zone && $0.name != manifest.name })
            let originalChunk = try #require(pair.cloud.encryptedVaultAssets[chunk])
            let fullReads = pair.engineA.fetchAllCount
            pair.engineA.beforeRecordSave = { record in
                guard record.id == id else { return }
                pair.engineA.beforeRecordSave = nil
                #expect(record.assetManifestName == manifest.name)
                pair.cloud.encryptedVaultAssets[chunk] = nil
            }
            var repairAttempts = 0
            pair.engineA.beforeVaultUpload = { name in
                if name == chunk.name {
                    repairAttempts += 1
                    throw URLError(.networkConnectionLost)
                }
            }
            try await pair.engineA.sendNow()
            await pair.syncA.settle()
            let saved = try #require(pair.cloud.record(id))
            #expect(saved.payload == row.envelope && pair.cloud.encryptedVaultAssets[chunk] == nil)
            #expect(try db.read { try $0.outbox(pair.vaultID, entry.id) } == nil)
            #expect(repairAttempts > 0, "The normal Item acknowledgement starts chunk recovery")
            let folder = pair.envA.directory.appending(path: "VaultSyncAssets/\(pair.vaultID.uuidString.lowercased())/out/\(entry.id.uuidString.lowercased())")
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: chunk.name).path))

            try await pair.addToB()
            try await pair.unlockB()
            let receiver = try #require(pair.managerB)
            let initial = try await pair.accounts(receiver)
            #expect(initial[entry.id] == nil && initial[peer.id]?.username == peer.username)

            let beforeEdit = repairAttempts
            let peerSource = pair.envA.directory.appending(path: "peer.bin")
            try Data("unrelated attachment".utf8).write(to: peerSource)
            let peerFile = try await pair.managerA.addAttachment(from: peerSource)
            try await pair.edit(pair.managerA, peer.id) {
                $0.password = "updated independently"
                $0.attachments = [peerFile]
            }
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.pump()
            try await pair.engineB.fetchNow()
            await pair.syncB.settle()
            #expect(try await pair.accounts(receiver)[peer.id]?.password == "updated independently")
            #expect(repairAttempts == beforeEdit, "Acknowledging another attachment must only check its own chunks")
            #expect(pair.engineA.fetchAllCount == fullReads)

            switch retry {
            case .restart:
                // A missing stage file can still be recovered from the sender's unlocked, verified attachment.
                try FileManager.default.removeItem(at: folder.appending(path: chunk.name))
                await pair.relaunch(onA: true)
            case .heartbeat:
                pair.engineA.beforeVaultUpload = nil
            case .accountSwitch:
                pair.engineA.beforeVaultUpload = { name in
                    guard name == chunk.name else { return }
                    pair.cloud.switchUser("different-synthetic-account")
                    pair.cloud.createZone(zone)
                }
                pair.syncA.beat()
                await pair.syncA.settle()
                #expect(pair.cloud.user == "different-synthetic-account" && pair.cloud.encryptedVaultAssets.isEmpty)
                let original = try #require(try await pair.accounts(pair.managerA)[entry.id]?.attachments?.first)
                let copy = pair.envA.directory.appending(path: "sender.bin")
                try await pair.managerA.readAttachment(original, to: copy)
                #expect(try Data(contentsOf: copy) == bytes)
                return
            }
            pair.syncA.beat()
            await pair.syncA.settle()
            pair.syncB.beat()
            try await pair.converge()
            #expect(pair.cloud.encryptedVaultAssets[chunk] == originalChunk)
            #expect(pair.cloud.record(id)?.systemFields == saved.systemFields, "Repair must preserve the saved Item revision")
            if retry == .heartbeat {
                #expect(pair.engineA.fetchAllCount == fullReads)
            }
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            let received = try #require(try await pair.accounts(receiver)[entry.id])
            #expect(received.password == "original password")
            let file = try #require(received.attachments?.first)
            let copy = pair.envA.directory.appending(path: "received.bin")
            try await receiver.readAttachment(file, to: copy)
            #expect(try Data(contentsOf: copy) == bytes)
        }
    }
}
