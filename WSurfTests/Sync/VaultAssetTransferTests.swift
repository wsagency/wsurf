// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfCore
import WSurfVault

@MainActor
struct VaultAssetTransferTests {
    private final class Database {
        let owner = "fixture-account-A"
        let zone = SyncZone.vault(profileID: UUID(), vaultID: UUID())
        let bytes = Data("encrypted fixture".utf8)
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let serverFile = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        var user = "fixture-account-A"
        var saves: [CKRecord.ID] = []
        var fetches: [(CKRecord.ID, [String])] = []
        var tag: String?
        var switchAtDispatch = false
        var fetchError: CKError?

        init() throws {
            try bytes.write(to: file)
            try bytes.write(to: serverFile)
        }

        deinit {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: serverFile)
        }

        var requests: VaultAssetRequests {
            VaultAssetRequests(currentUser: { self.user }, fetch: { id, keys in
                self.fetches.append((id, keys))
                try self.checkDispatch(id)
                if let error = self.fetchError {
                    throw error
                }
                guard let tag = self.tag else { throw CKError(.unknownItem) }
                return (tag, keys.isEmpty ? nil : self.serverFile)
            }, save: { record in
                self.saves.append(record.recordID)
                try self.checkDispatch(record.recordID)
                #expect(record.recordType == "VaultAsset")
                #expect((record["ciphertext"] as? CKAsset)?.fileURL == self.file)
                if self.tag != nil {
                    throw CKError(.serverRecordChanged)
                }
                self.tag = "version-1"
                return "version-1"
            })
        }

        private func checkDispatch(_ id: CKRecord.ID) throws {
            if switchAtDispatch {
                user = "fixture-account-B"
            }
            if id.zoneID.ownerName != CKCurrentUserDefaultName && id.zoneID.ownerName != user {
                throw CKError(.permissionFailure)
            }
        }
    }

    @Test func readsAndWritesAddressTheApprovedPrivateZone() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        let id = CKRecord.ID(recordName: ref.name, zoneID: .init(zoneName: db.zone, ownerName: db.owner))
        _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: nil)
        #expect(try await db.requests.download(ref, zone: db.zone, user: db.owner).data == db.bytes)
        #expect(db.saves == [id] && db.fetches.map(\.0) == [id])
    }

    @Test func accountSwitchAtDispatchCannotSaveToTheNewOwner() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        db.switchAtDispatch = true
        await #expect(throws: (any Error).self) {
            _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: nil)
        }
        #expect(db.tag == nil)
    }

    @Test func acknowledgedVersionUsesOnlySystemFieldsAndAMissingRecordIsRestored() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        let first = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: nil)
        let next = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: first)
        #expect(next == first && db.saves.count == 1)
        #expect(db.fetches.map(\.1) == [[]])
        db.tag = nil
        _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: first)
        #expect(db.tag != nil && db.saves.count == 2)
        #expect(db.fetches.map(\.1) == [[], []])
    }

    @Test func changedOrUnknownServerBytesMustBeVerified() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        db.tag = "different-server-version"
        let tag = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: nil)
        #expect(tag == db.tag && db.fetches.map(\.1) == [["ciphertext"]])
        db.tag = "verified-new-version"
        let updated = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: tag)
        #expect(updated == db.tag)
        try Data(repeating: 0x21, count: db.bytes.count).write(to: db.serverFile)
        await #expect(throws: VaultSyncError.authenticationFailed) {
            _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "old-tag")
        }
        #expect(db.fetches.map(\.1) == [["ciphertext"], [], ["ciphertext"], [], ["ciphertext"]])
        #expect(db.fetches.allSatisfy { $0.0.zoneID.ownerName == db.owner })
        #expect(db.saves.count == 1)
    }

    @Test func unavailableMetadataKeepsTheUploadPending() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        for code in [CKError.Code.zoneNotFound, .networkUnavailable] {
            db.fetchError = CKError(code)
            await #expect(throws: CKError.self) {
                _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "old-tag")
            }
        }
        #expect(db.saves.isEmpty && db.fetches.map(\.1) == [[], []])
    }

    @Test func fetchSwitchAndDefaultAliasCannotDiscloseAnAsset() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        db.tag = "available"
        db.switchAtDispatch = true
        await #expect(throws: CKError.self) {
            _ = try await db.requests.download(ref, zone: db.zone, user: db.owner)
        }
        db.user = CKCurrentUserDefaultName
        await #expect(throws: VaultSyncFailure.unavailable) {
            _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.user, acknowledged: nil)
        }
        #expect(db.fetches.count == 1 && db.fetches.first?.0.zoneID.ownerName == db.owner && db.saves.isEmpty)
    }

    @Test func chunkReceiptsSurviveReopenAndAreScopedToTheAccountAndZone() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = VaultKey(profileID: UUID(), vaultID: UUID())
        let otherProfile = VaultKey(profileID: UUID(), vaultID: key.vaultID)
        let otherVault = VaultKey(profileID: key.profileID, vaultID: UUID())
        let ref = try VaultAssetRef(Data("immutable".utf8))
        let otherRef = try VaultAssetRef(Data("another".utf8))
        do {
            let store = try #require(try VaultSyncDatabase.open(directory: root, create: true))
            try store.write { tx in
                try tx.saveAssetTag("confirmed", for: ref, key: key, user: "A")
                try tx.saveAssetTag("other", for: ref, key: otherVault, user: "A")
            }
        }
        let store = try #require(try VaultSyncDatabase.open(directory: root, create: false))
        try store.read { tx throws in
            #expect(try tx.assetTag(ref, key: key, user: "A") == "confirmed")
            #expect(try tx.assetTag(ref, key: key, user: "B") == nil)
            #expect(try tx.assetTag(ref, key: otherProfile, user: "A") == nil)
            #expect(try tx.assetTag(otherRef, key: key, user: "A") == nil)
            #expect(try tx.assetTag(ref, key: otherVault, user: "A") == "other")
        }
        try store.write { try $0.remove(key.vaultID) }
        try store.read { tx throws in
            #expect(try tx.assetTag(ref, key: key, user: "A") == nil)
            #expect(try tx.assetTag(ref, key: otherVault, user: "A") == "other")
        }
    }
}

// MARK: - Transfers between Macs

@MainActor
@Suite(.serialized)
struct VaultAssetDeviceTransferTests {
    private func entryWithFile(in pair: DevicePair) async throws -> CredentialAccount {
        let source = pair.envA.directory.appending(path: "attachment.bin")
        try Data("synthetic file bytes".utf8).write(to: source)
        var entry = pair.account("attached")
        entry.attachments = [try await pair.managerA.addAttachment(from: source)]
        try await pair.save([entry], in: pair.managerA)
        return entry
    }

    @Test func passwordEditsOnEitherMacTransferOnlyTheNewManifestAfterRelaunch() async throws {
        try await withDevicePair { pair in
            let entry = try await entryWithFile(in: pair)
            try await pair.enableA()
            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let id = SyncRecordID(zone: zone, name: entry.id.uuidString)
            let key = try await pair.managerA.syncKey()
            let original = try #require(pair.cloud.record(id))
            let (version, manifest) = try VaultSyncCodec.assetReference(original.payload, accountID: entry.id, key: key)
            let bytes = try #require(pair.cloud.encryptedVaultAssets[SyncRecordID(zone: zone, name: manifest.name)])
            let item = try VaultSyncCodec.openAssetAccount(bytes, accountID: entry.id, version: version, key: key)
            let chunk = try #require(item.chunks.values.first?.first)
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)

            for onA in [true, false] {
                var uploads: [String] = []
                var downloads: [String] = []
                await pair.relaunch(onA: onA) { engine in
                    engine.beforeVaultUpload = { uploads.append($0) }
                    engine.beforeVaultDownload = { downloads.append($0) }
                }
                let password = onA ? "changed-on-A" : "changed-on-B"
                try await pair.edit(onA ? pair.managerA : managerB, entry.id) { $0.password = password }
                await pair.wrote(onA ? pair.syncA : pair.syncB, onA ? pair.clockA : pair.clockB)
                try await pair.converge()
                let record = try #require(pair.cloud.record(id))
                let (_, updated) = try VaultSyncCodec.assetReference(record.payload, accountID: entry.id, key: key)
                #expect(uploads == [updated.name])
                #expect(!downloads.contains(chunk.name))
                #expect(try await pair.accounts(onA ? managerB : pair.managerA)[entry.id]?.password == password)
            }
        }
    }

    @Test func aRecreatedZoneMustRegainCheckpointedChunksBeforeThePointerCanBeSent() async throws {
        try await withDevicePair { pair in
            let entry = try await entryWithFile(in: pair)
            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let id = SyncRecordID(zone: zone, name: entry.id.uuidString)
            var first: String?
            pair.engineA.beforeVaultUpload = { name in
                guard first == nil else { throw URLError(.networkConnectionLost) }
                first = name
            }
            try await pair.enableA()
            let chunk = try #require(first)
            let chunkID = SyncRecordID(zone: zone, name: chunk)
            let original = try #require(pair.cloud.encryptedVaultAssets[chunkID])
            let database = try #require(try VaultSyncDatabase.open(directory: pair.envA.directory, create: false))
            let pending = try #require(try database.read { try $0.outbox(pair.vaultID, entry.id) })
            #expect(pending.remainingAssets.count == 1 && pair.cloud.record(id) == nil)

            var header = try #require(pair.cloud.record(SyncRecordID(zone: zone, name: VaultSync.vaultRecordName)))
            pair.cloud.removeZoneSilently(zone)
            pair.cloud.createZone(zone)
            header.systemFields = nil
            guard case .saved = pair.cloud.save(header) else {
                Issue.record("Could not create the fixture's replacement vault header")
                return
            }
            await pair.relaunch(onA: true) { engine in
                engine.beforeVaultUpload = { name in
                    if name == chunk {
                        throw URLError(.networkConnectionLost)
                    }
                }
            }
            try await pair.pump()
            #expect(pair.cloud.record(id) == nil && pair.syncA.record(for: id) == nil)
            #expect(pair.cloud.encryptedVaultAssets[chunkID] == nil)

            pair.engineA.beforeVaultUpload = nil
            pair.syncA.beat()
            try await pair.pump()
            #expect(pair.cloud.record(id)?.payload == pending.envelope)
            #expect(pair.cloud.encryptedVaultAssets[chunkID] == original)
            let staging = pair.envA.directory.appending(path: "VaultSyncAssets/\(pair.vaultID.uuidString.lowercased())/out/\(entry.id.uuidString.lowercased())")
            #expect(!FileManager.default.fileExists(atPath: staging.path))
        }
    }
}
