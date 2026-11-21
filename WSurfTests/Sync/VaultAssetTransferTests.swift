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
        var fetches: [(CKRecord.ID, [String]?)] = []
        var tag: String?
        var switchAtDispatch = false
        var fetchError: CKError?
        var beforeSave: (() throws -> Void)?
        var beforeRepair: (() throws -> Void)?
        var returnedID: CKRecord.ID?
        var returnedType = "VaultAsset"
        var checkedVersion: (record: CKRecord, tag: String)?
        var repairFile: URL?

        init() throws {
            try bytes.write(to: file)
            try bytes.write(to: serverFile)
        }

        deinit {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: serverFile)
        }

        var requests: VaultAssetRequests {
            VaultAssetRequests(currentUser: { self.user }, fetch: { ids, keys in
                var result: VaultAssetRequests.Results = [:]
                for id in ids {
                    self.fetches.append((id, keys))
                    try self.checkDispatch(id)
                    if let error = self.fetchError {
                        throw error
                    }
                    guard let tag = self.tag else {
                        result[id] = .failure(CKError(.unknownItem))
                        continue
                    }
                    let record = CKRecord(recordType: self.returnedType, recordID: self.returnedID ?? id)
                    if keys?.isEmpty != true {
                        if FileManager.default.fileExists(atPath: self.serverFile.path) {
                            record["ciphertext"] = CKAsset(fileURL: self.serverFile)
                        }
                        record["kept"] = "existing field"
                        self.checkedVersion = (record, tag)
                    }
                    result[id] = .success((record, tag))
                }
                return result
            }, save: { record in
                self.saves.append(record.recordID)
                try self.beforeSave?()
                let isRepair = self.checkedVersion?.record === record
                if isRepair {
                    try self.beforeRepair?()
                }
                try self.checkDispatch(record.recordID)
                let file = try #require((record["ciphertext"] as? CKAsset)?.fileURL)
                if isRepair {
                    guard self.tag == self.checkedVersion?.tag else { throw CKError(.serverRecordChanged) }
                    #expect(record["kept"] as? String == "existing field")
                    self.repairFile = file
                } else if self.tag != nil {
                    throw CKError(.serverRecordChanged)
                }
                try Data(contentsOf: file).write(to: self.serverFile)
                let next = isRepair ? "repaired" : "version-1"
                self.tag = next
                return next
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
        #expect(tag == db.tag && db.fetches.map(\.1) == [nil])
        db.tag = "verified-new-version"
        let updated = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: tag)
        #expect(updated == db.tag)
        #expect(db.fetches.map(\.1) == [nil, [], nil])
        #expect(db.fetches.allSatisfy { $0.0.zoneID.ownerName == db.owner })
        #expect(db.saves.count == 1)
    }

    @Test(arguments: [true, false])
    func aDamagedAssetIsRestoredFromVerifiedLocalBytes(hadReceipt: Bool) async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        let original = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: nil)
        try Data(repeating: 0x21, count: db.bytes.count).write(to: db.serverFile)
        db.tag = "damaged-version"
        db.beforeRepair = { try Data("replaced staging".utf8).write(to: db.file) }
        let repaired = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: hadReceipt ? original : nil)
        #expect(repaired != "damaged-version" && repaired == db.tag)
        #expect(try db.bytes == Data(contentsOf: db.serverFile))
        let copy = try #require(db.repairFile)
        #expect(copy != db.file && !FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func aFetchedAssetWithoutAReadableFileSizeDoesNotStartARepair() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        db.tag = "current"
        try FileManager.default.removeItem(at: db.serverFile)
        try FileManager.default.createDirectory(at: db.serverFile, withIntermediateDirectories: false)
        #expect(try db.serverFile.resourceValues(forKeys: [.fileSizeKey]).fileSize == nil)

        await #expect(throws: (any Error).self) {
            _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "earlier")
        }
        #expect(db.saves.isEmpty)
        #expect(db.tag == "current")
    }

    @Test(arguments: [true, false])
    func repairsAnAssetWhoseCiphertextFieldIsMissing(hadReceipt: Bool) async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        db.tag = "missing-field"
        try FileManager.default.removeItem(at: db.serverFile)
        await #expect(throws: VaultSyncError.malformed) {
            _ = try await db.requests.download(ref, zone: db.zone, user: db.owner)
        }
        let tag = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: hadReceipt ? "earlier" : nil)
        #expect(tag == "repaired")
        #expect(try await db.requests.download(ref, zone: db.zone, user: db.owner).data == db.bytes)
    }

    @Test(arguments: [true, false])
    func aRepairCannotOverwriteANewerVersionOrFollowAnAccountSwitch(switchAccount: Bool) async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        db.tag = "damaged"
        try Data("short".utf8).write(to: db.serverFile)
        let winner = Data("a concurrent writer".utf8)
        db.beforeRepair = {
            db.tag = "winner"
            try winner.write(to: db.serverFile)
            if switchAccount {
                db.user = "fixture-account-B"
            }
        }
        await #expect(throws: CKError.self) {
            _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "previous")
        }
        #expect(db.tag == "winner" && db.saves.count == 1 && db.saves.first?.zoneID.ownerName == db.owner)
        #expect(try Data(contentsOf: db.serverFile) == winner)
        db.beforeRepair = nil
        db.user = db.owner
        _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "previous")
        #expect(try Data(contentsOf: db.serverFile) == db.bytes)
    }

    @Test func unrelatedRecordsAndBadLocalBytesCannotAuthorizeARepair() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        db.tag = "damaged"
        let damaged = Data("wrong".utf8)
        try damaged.write(to: db.serverFile)
        let zone = CKRecordZone.ID(zoneName: db.zone, ownerName: db.owner)
        let otherZone = CKRecordZone.ID(zoneName: SyncZone.vault(profileID: UUID(), vaultID: UUID()), ownerName: db.owner)
        let otherOwner = CKRecordZone.ID(zoneName: db.zone, ownerName: "fixture-account-B")
        let unrelated = [
            CKRecord.ID(recordName: "unrelated", zoneID: zone), CKRecord.ID(recordName: ref.name, zoneID: otherZone),
            CKRecord.ID(recordName: ref.name, zoneID: otherOwner),
        ]
        for id in unrelated {
            db.returnedID = id
            await #expect(throws: VaultSyncError.malformed) {
                _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "previous")
            }
        }
        db.returnedID = nil
        db.returnedType = "Item"
        await #expect(throws: VaultSyncError.malformed) {
            _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "previous")
        }
        db.returnedType = "VaultAsset"
        try Data("bad local copy".utf8).write(to: db.file)
        await #expect(throws: VaultSyncError.authenticationFailed) {
            _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "previous")
        }
        #expect(db.saves.isEmpty && db.tag == "damaged")
        #expect(try Data(contentsOf: db.serverFile) == damaged)
    }

    @Test func recreatingAMissingRecordUsesTheSameBytesThatWereVerified() async throws {
        let db = try Database()
        let ref = try VaultAssetRef(db.bytes)
        db.beforeSave = { try Data("changed staging".utf8).write(to: db.file) }
        _ = try await db.requests.upload(ref, from: db.file, zone: db.zone, user: db.owner, acknowledged: "lost-with-zone")
        #expect(try Data(contentsOf: db.serverFile) == db.bytes)
    }

    @Test func publicationRequiresEachAccountBoundVersionWithoutFetchingCiphertext() async throws {
        let db = try Database()
        let refs = try [VaultAssetRef(db.bytes), VaultAssetRef(Data("manifest".utf8))]
        let tags = Dictionary(uniqueKeysWithValues: refs.map { ($0, "verified") })
        db.tag = "verified"
        #expect(try await db.requests.versionsMatch(tags, zone: db.zone, user: db.owner))
        #expect(Set(db.fetches.map { $0.0.recordName }) == Set(refs.map(\.name)))
        #expect(db.fetches.allSatisfy { $0.0.zoneID.ownerName == db.owner && $0.1 == [] })
        var changed = tags
        changed[refs[1]] = "another-version"
        #expect(try await !db.requests.versionsMatch(changed, zone: db.zone, user: db.owner))
        db.tag = nil
        #expect(try await !db.requests.versionsMatch(tags, zone: db.zone, user: db.owner))
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

    @Test(arguments: [true, false])
    func unpublishedPointerRepairsItsManifestAndChunksBeforeANewMacOpensIt(relaunch: Bool) async throws {
        try await withDevicePair { pair in
            try await pair.enableA()
            let entry = try await entryWithFile(in: pair)
            await pair.wrote(pair.syncA, pair.clockA)
            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let id = SyncRecordID(zone: zone, name: entry.id.uuidString)
            let db = try #require(try VaultSyncDatabase.open(directory: pair.envA.directory, create: false))
            let queued = try #require(try db.read { try $0.outbox(pair.vaultID, entry.id) })
            let key = try await pair.managerA.syncKey()
            let (_, manifest) = try VaultSyncCodec.assetReference(queued.envelope, accountID: entry.id, key: key)
            let allAssets = pair.cloud.encryptedVaultAssets
            #expect(allAssets.count == 2 && allAssets[SyncRecordID(zone: zone, name: manifest.name)] != nil && pair.cloud.record(id) == nil)

            var header = try #require(pair.cloud.record(SyncRecordID(zone: zone, name: VaultSync.vaultRecordName)))
            pair.cloud.removeZoneSilently(zone)
            pair.cloud.createZone(zone)
            header.systemFields = nil
            guard case .saved = pair.cloud.save(header) else {
                Issue.record("Could not recreate the fixture vault header")
                return
            }
            let interrupt: (FakeSyncEngine) -> Void = { engine in
                engine.beforeVaultUpload = { name in
                    if name == manifest.name {
                        throw URLError(.networkConnectionLost)
                    }
                }
            }
            if relaunch {
                await pair.relaunch(onA: true, configure: interrupt)
            } else {
                interrupt(pair.engineA)
            }
            try await pair.pump()
            #expect(pair.cloud.record(id) == nil, "An engine retry must not send a dangling pointer")
            let late = SyncRecord(id: id, type: .item, schema: 1, payload: queued.envelope)
            await pair.syncA.handle(.sent(saved: [late], deleted: [], failed: []))
            #expect(try db.read { try $0.outbox(pair.vaultID, entry.id) }?.envelope == queued.envelope)

            pair.engineA.beforeVaultUpload = nil
            pair.syncA.beat()
            try await pair.pump()
            #expect(pair.cloud.record(id)?.payload == queued.envelope)
            #expect(pair.cloud.encryptedVaultAssets == allAssets)
            try await pair.addToB()
            try await pair.unlockB()
            let manager = try #require(pair.managerB)
            let received = try #require(try await pair.accounts(manager)[entry.id]?.attachments?.first)
            let copy = pair.envA.directory.appending(path: "restored-attachment.bin")
            try await manager.readAttachment(received, to: copy)
            #expect(try Data(contentsOf: copy) == Data("synthetic file bytes".utf8))
        }
    }

    @Test func aPresentManifestCannotHideADamagedChunkOnResume() async throws {
        try await withDevicePair { pair in
            try await pair.enableA()
            let entry = try await entryWithFile(in: pair)
            await pair.wrote(pair.syncA, pair.clockA)
            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let id = SyncRecordID(zone: zone, name: entry.id.uuidString)
            let db = try #require(try VaultSyncDatabase.open(directory: pair.envA.directory, create: false))
            let row = try #require(try db.read { try $0.outbox(pair.vaultID, entry.id) })
            let (_, manifest) = try VaultSyncCodec.assetReference(row.envelope, accountID: entry.id, key: try await pair.managerA.syncKey())
            let chunk = try #require(pair.cloud.encryptedVaultAssets.keys.first { $0.zone == zone && $0.name != manifest.name })
            let original = try #require(pair.cloud.encryptedVaultAssets[chunk])
            pair.cloud.encryptedVaultAssets[chunk] = Data(repeating: 0x5a, count: original.count)
            await pair.relaunch(onA: true) { engine in
                engine.beforeVaultUpload = { _ in throw URLError(.networkConnectionLost) }
            }
            try await pair.pump()
            #expect(pair.cloud.record(id) == nil)
            var uploads: [String] = []
            pair.engineA.beforeVaultUpload = { uploads.append($0) }
            pair.syncA.beat()
            try await pair.pump()
            #expect(pair.cloud.record(id)?.payload == row.envelope && pair.cloud.encryptedVaultAssets[chunk] == original)
            #expect(uploads == [chunk.name])
        }
    }

    @Test func aMissingLegacyStagingFolderIsRebuiltFromTheUnlockedStore() async throws {
        try await withDevicePair { pair in
            try await pair.enableA()
            let entry = try await entryWithFile(in: pair)
            await pair.wrote(pair.syncA, pair.clockA)
            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let id = SyncRecordID(zone: zone, name: entry.id.uuidString)
            let db = try #require(try VaultSyncDatabase.open(directory: pair.envA.directory, create: false))
            var legacy = try #require(try db.read { try $0.outbox(pair.vaultID, entry.id) })
            legacy.publication = nil
            try db.write { try $0.save(legacy, vault: pair.vaultID) }
            let folder = pair.envA.directory.appending(path: "VaultSyncAssets/\(pair.vaultID.uuidString.lowercased())/out/\(entry.id.uuidString.lowercased())")
            try FileManager.default.removeItem(at: folder)
            pair.cloud.encryptedVaultAssets = [:]
            await pair.relaunch(onA: true)
            try await pair.pump()
            let rebuilt = try #require(pair.cloud.record(id))
            #expect(rebuilt.payload != legacy.envelope && pair.cloud.encryptedVaultAssets.count == 2)
            try await pair.addToB()
            try await pair.unlockB()
            let manager = try #require(pair.managerB)
            #expect(try await pair.accounts(manager)[entry.id]?.attachments?.first?.id == entry.attachments?.first?.id)
        }
    }

    @Test func aLockedSenderChecksItsSealedPointerAndReleasesStagingOnlyOnReceipt() async throws {
        try await withDevicePair { pair in
            try await pair.enableA()
            let entry = try await entryWithFile(in: pair)
            await pair.wrote(pair.syncA, pair.clockA)
            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let id = SyncRecordID(zone: zone, name: entry.id.uuidString)
            let folder = pair.envA.directory.appending(path: "VaultSyncAssets/\(pair.vaultID.uuidString.lowercased())/out/\(entry.id.uuidString.lowercased())")
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 2)
            pair.managerA.lock(reason: .manual)
            pair.syncA.vaultLocked(profileID: pair.profile.id, vaultID: pair.vaultID)
            try await pair.engineA.sendNow()
            await pair.syncA.settle()
            #expect(pair.cloud.record(id) != nil && !pair.managerA.isUnlocked)
            #expect(!FileManager.default.fileExists(atPath: folder.path))
        }
    }

    @Test func withdrawingEnrollmentDuringTheVersionCheckWithholdsThePointer() async throws {
        try await withDevicePair { pair in
            try await pair.enableA()
            let entry = try await entryWithFile(in: pair)
            await pair.wrote(pair.syncA, pair.clockA)
            let id = SyncRecordID(zone: SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID), name: entry.id.uuidString)
            let router = SyncRouter(state: SyncRouterState(), persist: { _ in }, tabs: nil, vaults: pair.syncA)
            pair.engineA.duringAccountLookup = {
                pair.engineA.duringAccountLookup = nil
                try pair.syncA.disable(profileID: pair.profile.id, vaultID: pair.vaultID)
            }
            #expect(await router.recordForUpload(id) == nil)
            #expect(pair.cloud.record(id) == nil && pair.statusA == .off)
        }
    }

    @Test func losingTheManifestBetweenPreflightAndServerSaveCannotPublishADanglingPointer() async throws {
        try await withDevicePair { pair in
            try await pair.enableA()
            let entry = try await entryWithFile(in: pair)
            await pair.wrote(pair.syncA, pair.clockA)
            let id = SyncRecordID(zone: SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID), name: entry.id.uuidString)
            let db = try #require(try VaultSyncDatabase.open(directory: pair.envA.directory, create: false))
            let row = try #require(try db.read { try $0.outbox(pair.vaultID, entry.id) })
            let (_, manifest) = try VaultSyncCodec.assetReference(row.envelope, accountID: entry.id, key: try await pair.managerA.syncKey())
            let manifestID = SyncRecordID(zone: id.zone, name: manifest.name)
            pair.engineA.beforeRecordSave = { record in
                guard record.id == id else { return }
                let native = CloudKitMapping.ckRecord(record)
                #expect(native.parent?.recordID == CKRecord.ID(recordName: manifest.name, zoneID: native.recordID.zoneID))
                pair.cloud.encryptedVaultAssets[manifestID] = nil
            }
            try await pair.pump()
            #expect(pair.cloud.record(id) == nil)
            pair.engineA.beforeRecordSave = nil
            pair.syncA.beat()
            try await pair.pump()
            #expect(pair.cloud.record(id)?.payload == row.envelope && pair.cloud.encryptedVaultAssets[manifestID] != nil)
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
