// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import GRDB
import Testing

@testable import WSurf
@testable import WSurfCore
@testable import WSurfVault

@MainActor
@Suite(.serialized)
struct VaultSyncAssetTests {
    private func attach(_ bytes: Data, to manager: CredentialManager, in pair: DevicePair) async throws -> CredentialAttachment {
        let source = pair.envA.directory.appending(path: "synthetic-\(UUID().uuidString).bin")
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        return try await manager.addAttachment(from: source)
    }

    private func id(_ account: CredentialAccount, in pair: DevicePair) -> SyncRecordID {
        SyncRecordID(zone: SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID), name: account.id.uuidString)
    }

    @Test func upgradingAnExistingOutboxAndParkedPointerPreservesBoth() throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        let account = SyncVaultFixtures.account(username: "synthetic")
        let portable = try VaultAssetAccount(account: account, chunks: [:])
        let pointer = try VaultSyncCodec.sealAssetAccount(portable, version: 4, key: rig.key)
        let old = OutboxRow(accountID: UUID(), version: 1, envelope: Data([1]), parts: Data([2]))
        do {
            let db = try #require(try VaultSyncDatabase.open(directory: rig.root, create: true))
            try db.write { tx in
                try tx.save(old, vault: rig.vaultID)
                try tx.save(InboxRow(accountID: account.id, version: 0, envelope: pointer.envelope), vault: rig.vaultID)
                try tx.db.execute(sql: "ALTER TABLE outbox DROP COLUMN remainingAssets")
                try tx.db.execute(sql: "ALTER TABLE vault DROP COLUMN approvedUser")
                try tx.db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3'")
            }
        }
        let db = try #require(try VaultSyncDatabase.open(directory: rig.root, create: false))
        let outgoing = try db.read { try $0.outbox(rig.vaultID, old.accountID) }
        let incoming = try db.read { try $0.inbox(rig.vaultID, limit: 1) }
        #expect(outgoing == old && incoming == [InboxRow(accountID: account.id, version: 4, envelope: pointer.envelope)])
    }

    @Test func nativeFetchScopeIncludesOnlyEnrolledVaultsAndPreservesOtherScopeLimits() {
        let first = CloudKitMapping.zoneID(SyncZone.vault(profileID: UUID(), vaultID: UUID()))
        let second = CloudKitMapping.zoneID(SyncZone.vault(profileID: UUID(), vaultID: UUID()))
        let tabs = CloudKitMapping.zoneID(SyncZone.devices)
        let pending = [first, second, tabs]
        let none = CloudKitMapping.fetchScope(.all, pending: pending, enrolled: [])
        #expect(none.contains(tabs) && !none.contains(first) && !none.contains(second))
        let shared = CloudKitMapping.fetchScope(.allExcluding([tabs]), pending: pending, enrolled: [first.zoneName])
        #expect(shared.contains(first) && !shared.contains(second) && !shared.contains(tabs))
        let selected = CloudKitMapping.fetchScope(.zoneIDs([second, tabs]), pending: pending, enrolled: [first.zoneName])
        #expect(selected.contains(tabs) && !selected.contains(first) && !selected.contains(second))
    }

    @Test func interruptedUploadAndDownloadResumeWithTheOriginalPointerAndChunks() async throws {
        try await withDevicePair { pair in
            let bytes = Data(repeating: 0x35, count: VaultAssetRef.maxBytes + 37)
            let file = try await attach(bytes, to: pair.managerA, in: pair)
            let entry = CredentialAccount(id: UUID(), username: "", origins: [], loginURLs: [], passkeys: [], attachments: [file])
            let ordinary = pair.account("independent")
            try await pair.save([entry, ordinary], in: pair.managerA)
            var uploaded: [String] = []
            pair.engineA.beforeVaultUpload = { name in
                guard uploaded.isEmpty else { throw URLError(.networkConnectionLost) }
                uploaded.append(name)
            }
            try await pair.enableA()
            let itemID = id(entry, in: pair)
            #expect(uploaded.count == 1 && pair.cloud.record(itemID) == nil)
            #expect(pair.syncA.record(for: itemID) == nil)
            let database = try #require(try VaultSyncDatabase.open(directory: pair.envA.directory, create: false))
            let queued = try #require(try database.read { try $0.outbox(pair.vaultID, entry.id) })
            #expect(queued.remainingAssets.count == 2)
            #expect(pair.cloud.record(id(ordinary, in: pair)) != nil)

            await pair.relaunch(onA: true) { engine in
                engine.beforeVaultUpload = { name in #expect(!uploaded.contains(name), "confirmed chunks survive relaunch") }
            }
            try await pair.pump()
            #expect(pair.cloud.record(itemID)?.payload == queued.envelope, "resumed the exact sealed version")

            var downloaded: [String] = []
            pair.engineB.beforeVaultDownload = { name in
                guard downloaded.count < 2 else { throw URLError(.networkConnectionLost) }
                downloaded.append(name)
            }
            try await pair.addToB()
            try await pair.unlockB()
            let manager = try #require(pair.managerB)
            let partial = try await pair.accounts(manager)
            #expect(downloaded.count == 2 && partial[entry.id] == nil && partial[ordinary.id] != nil)
            await pair.relaunch(onA: false) { engine in
                engine.beforeVaultDownload = { name in #expect(!downloaded.contains(name), "verified cached parts survive relaunch") }
            }
            try await pair.pump()
            let received = try #require(try await pair.accounts(manager)[entry.id]?.attachments?.first)
            let destination = pair.envA.directory.appending(path: "verified")
            try await manager.readAttachment(received, to: destination)
            #expect(try Data(contentsOf: destination) == bytes)
            #expect(received.id == file.id && received.wrappedKey != file.wrappedKey)
            #expect(pair.statusA == .synced && pair.statusB == .synced)
        }
    }

    @Test func deletingAnUnpublishedEntryThenLosingItsStagingDoesNotLeaveAnUploadWaiting() async throws {
        try await withDevicePair { pair in
            var entry = pair.account("discarded")
            entry.attachments = [try await attach(Data("discarded fixture".utf8), to: pair.managerA, in: pair)]
            try await pair.save([entry], in: pair.managerA)
            pair.engineA.beforeVaultUpload = { _ in throw URLError(.networkConnectionLost) }
            try await pair.enableA()
            let recordID = id(entry, in: pair)
            #expect(pair.statusA == .sending(1) && pair.cloud.record(recordID) == nil)

            let revision = try await pair.managerA.snapshot().revision
            let epoch = try #require(pair.managerA.authorizationEpoch)
            _ = try await pair.managerA.delete(.account(entry.id), expectedRevision: revision, authorizedEpoch: epoch)
            let staging = pair.envA.directory.appending(path: "VaultSyncAssets/\(pair.vaultID.uuidString.lowercased())")
            try FileManager.default.removeItem(at: staging)
            await pair.relaunch(onA: true)
            pair.syncA.beat()
            try await pair.pump()
            #expect(pair.statusA == .synced)
            if let tombstone = pair.cloud.record(recordID) {
                let key = try await pair.managerA.syncKey()
                #expect(try VaultSyncCodec.openItem(tombstone.payload, accountID: entry.id, key: key).account == nil)
            }
        }
    }

    @Test func corruptCiphertextAndAnExpiredLeaseLeaveTheIncomingFileQueued() async throws {
        try await withDevicePair { pair in
            var entry = pair.account("corrupt")
            entry.attachments = [try await attach(Data("synthetic vault file".utf8), to: pair.managerA, in: pair)]
            try await pair.save([entry], in: pair.managerA)
            try await pair.enableA()
            let recordID = id(entry, in: pair)
            let record = try #require(pair.cloud.record(recordID))
            let key = try await pair.managerA.syncKey()
            let (version, bodyRef) = try VaultSyncCodec.assetReference(record.payload, accountID: entry.id, key: key)
            let body = try #require(pair.cloud.encryptedVaultAssets[SyncRecordID(zone: recordID.zone, name: bodyRef.name)])
            let portable = try VaultSyncCodec.openAssetAccount(body, accountID: entry.id, version: version, key: key)
            let chunk = try #require(portable.chunks.values.first?.first)
            let chunkID = SyncRecordID(zone: recordID.zone, name: chunk.name)
            let original = try #require(pair.cloud.encryptedVaultAssets[chunkID])
            var damaged = original
            damaged[damaged.startIndex] ^= 1
            pair.cloud.encryptedVaultAssets[chunkID] = damaged
            try await pair.addToB()
            try await pair.unlockB()
            let manager = try #require(pair.managerB)
            #expect(try await pair.accounts(manager)[entry.id] == nil && pair.statusB == .sending(1))
            pair.cloud.encryptedVaultAssets[chunkID] = original
            pair.engineB.beforeVaultDownload = { name in
                guard name == chunk.name else { return }
                manager.lock(reason: .manual)
                pair.syncB.vaultLocked(profileID: pair.profile.id, vaultID: pair.vaultID)
            }
            pair.syncB.beat()
            await pair.syncB.settle()
            #expect(pair.statusB == .waitingForUnlock(1))
            pair.engineB.beforeVaultDownload = nil
            try await pair.unlockB()
            try await pair.pump()
            #expect(try await pair.accounts(manager)[entry.id]?.attachments?.first?.id == entry.attachments?.first?.id)
        }
    }

    @Test func accountChangeDuringUploadClearsConsentAndStaging() async throws {
        try await withDevicePair { pair in
            var entry = pair.account("pending")
            entry.attachments = [try await attach(Data("synthetic".utf8), to: pair.managerA, in: pair)]
            try await pair.save([entry], in: pair.managerA)
            pair.engineA.beforeVaultUpload = { _ in
                pair.cloud.switchUser("other-account")
                await pair.engineA.simulateAccount(.switchAccounts(user: "other-account"))
            }
            try await pair.enableA()
            #expect(pair.statusA == .accountChanged)
            #expect(pair.cloud.encryptedVaultAssets.isEmpty && pair.cloud.record(id(entry, in: pair)) == nil)
            #expect(try await pair.accounts(pair.managerA)[entry.id] == entry)
            let root = pair.envA.directory.appending(path: "VaultSyncAssets/\(pair.vaultID.uuidString.lowercased())")
            #expect(!FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test func twoPopulatedMacsAndAFreshMacConvergeOnInlineAndLargeCredentials() async throws {
        let rig = VaultSyncRig()
        defer { rig.finish() }
        var large = SyncVaultFixtures.account(username: "large")
        large.notes = [CredentialNote(text: String(repeating: "n", count: 800_000))]
        let other = SyncVaultFixtures.account(username: "local")
        let (first, a) = try await rig.syncedMac(holding: [large])
        let (second, b) = try rig.mac(holding: [other])
        try await second.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await converge([first, second])
        let (third, c) = try await rig.addedMac()
        try await converge([first, second, third])
        for vault in [a, b, c] {
            #expect(vault.account(large.id) == large && vault.account(other.id) == other)
        }
        #expect(rig.item(large)?.payload.first == VaultSyncCodec.assetFormat && rig.item(other)?.payload.first == 1)
    }

    @Test func populatedMacKeepsItsOwnVaultAndAdoptsACompleteVaultWithItsPasskey() async throws {
        try await withDevicePair { pair in
            let unrelated = try await VaultManagerFixture.make(profile: pair.profile, passkeys: pair.passkeysB, vaults: [.unlocked]).vaults[0].manager
            let local = pair.account("already-here")
            try await pair.save([local], in: unrelated)
            var large = pair.account("oversized")
            large.notes = [CredentialNote(text: String(repeating: "a", count: 800_000))]
            let file = try await attach(Data("file-only fixture".utf8), to: pair.managerA, in: pair)
            let fileOnly = CredentialAccount(id: UUID(), username: "", origins: [], loginURLs: [], passkeys: [], attachments: [file])
            try await pair.save([large, fileOnly], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            #expect(!(try #require(pair.managerB)).isUnlocked)
            try await pair.unlockB()
            try await pair.converge()
            let shared = try await pair.accounts(try #require(pair.managerB))
            #expect(shared[large.id] == large && shared[fileOnly.id]?.attachments?.first?.id == file.id)
            #expect(try await pair.accounts(unrelated) == [local.id: local])
            #expect(!pair.syncB.isSyncing(profileID: pair.profile.id, vaultID: unrelated.vaultID))
            #expect(pair.passkeysB.assertions.contains(pair.proof.credentialID))
        }
    }

    @Test func legacyChangePreservesFilesAndRepublishesTheCompleteEntryForALateJoin() async throws {
        try await withDevicePair { pair in
            var entry = pair.account("legacy")
            let file = try await attach(Data("retained".utf8), to: pair.managerA, in: pair)
            entry.attachments = [file]
            try await pair.save([entry], in: pair.managerA)
            try await pair.enableA()
            var legacy = entry
            legacy.attachments = nil
            legacy.password = "edited-on-an-older-Mac"
            let inline = try VaultSyncCodec.sealItem(SyncItem(accountID: entry.id, version: 2, account: legacy), key: try await pair.managerA.syncKey())
            let recordID = id(entry, in: pair)
            pair.cloud.overwrite(recordID, payload: inline)
            try await pair.engineA.fetchNow()
            try await pair.pump()
            let repaired = try #require(pair.cloud.record(recordID))
            #expect(repaired.payload.first == VaultSyncCodec.assetFormat)
            #expect(try VaultSyncCodec.version(of: repaired.payload) == 3)
            try await pair.addToB()
            try await pair.unlockB()
            let manager = try #require(pair.managerB)
            let copy = try #require(try await pair.accounts(manager)[entry.id])
            #expect(copy.password == legacy.password && copy.attachments?.first?.id == file.id)
        }
    }

    @Test func competingFileReplacementsRemainRecoverableAfterReview() async throws {
        try await withDevicePair { pair in
            var entry = pair.account("review")
            entry.attachments = [try await attach(Data("base".utf8), to: pair.managerA, in: pair)]
            try await pair.save([entry], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let manager = try #require(pair.managerB)
            let first = try await attach(Data("new on A".utf8), to: pair.managerA, in: pair)
            let second = try await attach(Data("new on B".utf8), to: manager, in: pair)
            try await pair.edit(pair.managerA, entry.id) { $0.attachments = [first] }
            try await pair.edit(manager, entry.id) { $0.attachments = [second] }
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.engineA.sendNow()
            try await pair.engineB.fetchNow()
            await pair.syncB.settle()

            let reviews = try await pair.syncB.conflicts(profileID: pair.profile.id, vaultID: pair.vaultID)
            let conflict = try #require(reviews.first)
            #expect(conflict.id == entry.id && conflict.parts == [.attachments])
            let incoming = try #require(conflict.incoming?.attachments?.first)
            #expect(incoming.id == first.id && conflict.local?.attachments?.first?.id == second.id)
            try await manager.discardAttachments([incoming.id])
            #expect(!manager.hasAttachment(incoming), "an unanswered conflict holds no permanent store pin")
            try await pair.syncB.resolve(profileID: pair.profile.id, vaultID: pair.vaultID, accountIDs: [entry.id], keepLocal: false)
            try await pair.converge()
            #expect(try await pair.accounts(manager)[entry.id]?.attachments?.first?.id == first.id)
            try await manager.discardAttachments([second.id])
            #expect(manager.hasAttachment(second), "the replaced local version remains in History")
        }
    }

    @Test func removingTheLastFileKeepsHistoryAndTrashRecoverableUntilLocalPurge() async throws {
        try await withDevicePair { pair in
            let first = try await attach(Data("prior file".utf8), to: pair.managerA, in: pair)
            let second = try await attach(Data("current file".utf8), to: pair.managerA, in: pair)
            var entry = pair.account("history")
            entry.attachments = [first]
            try await pair.save([entry], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            let manager = try #require(pair.managerB)
            let prior = try #require(try await pair.accounts(manager)[entry.id]?.attachments?.first)
            try await pair.edit(pair.managerA, entry.id) { $0.attachments = [second] }
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()
            let received = try #require(try await pair.accounts(manager)[entry.id]?.attachments?.first)
            #expect(received.id == second.id)
            try await manager.discardAttachments([prior.id])
            #expect(manager.hasAttachment(prior), "an attachment revision owns the prior file")
            try await pair.edit(pair.managerA, entry.id) { $0.attachments = nil }
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()
            let empty = try #require(pair.cloud.record(id(entry, in: pair)))
            #expect(empty.payload.first == VaultSyncCodec.assetFormat)
            #expect(try await pair.accounts(manager)[entry.id]?.attachments == nil)
            let revision = try await pair.managerA.snapshot().revision
            let epoch = try #require(pair.managerA.authorizationEpoch)
            _ = try await pair.managerA.delete(.account(entry.id), expectedRevision: revision, authorizedEpoch: epoch)
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()
            #expect(try await manager.trashPage(after: nil).items.count == 1)
            try await manager.discardAttachments([prior.id, received.id])
            #expect(manager.hasAttachment(prior) && manager.hasAttachment(received), "the Trash retains both revisions")
            let cloudAssets = pair.cloud.encryptedVaultAssets
            _ = try await manager.purge(entryIDs: [], emptyAll: true, in: VaultManagerFixture.anchor())
            #expect(!manager.hasAttachment(prior) && !manager.hasAttachment(received))
            #expect(pair.cloud.encryptedVaultAssets == cloudAssets && pair.managerA.hasAttachment(first))
            pair.syncA.removeFromICloud(profileID: pair.profile.id, vaultID: pair.vaultID)
            try await pair.pump()
            #expect(pair.cloud.encryptedVaultAssets.isEmpty)
        }
    }
}
