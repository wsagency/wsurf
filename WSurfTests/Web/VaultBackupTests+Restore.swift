// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// Restores into a vault that changed since the backup (a merge, a deletion), files that are already there, a commit that fails after
/// the files were stored, and a lock while a backup is decrypted.
extension VaultBackupTests {
    /// Writes a plain backup of every entry of `f.manager` and reads it back.
    func backupOfEverything(_ f: CredentialExchangeCoordinatorTests.Fixture, in folder: URL) async throws -> VaultBackup {
        let url = folder.appending(path: "backup-\(UUID().uuidString).json")
        _ = try await export(f, to: url, password: nil)
        return try await f.coordinator.readBackup(try Data(contentsOf: url), password: nil)
    }

    /// Merges `absorbed` into `survivor` the way the Merge sheet commits it, with `login` and `code` taken from `picks`.
    @discardableResult
    func merge(
        _ absorbed: CredentialAccount, into survivor: CredentialAccount, login: UUID? = nil, in f: CredentialExchangeCoordinatorTests.Fixture
    ) async throws -> CredentialAccount {
        let picks = MergePicks(survivor: survivor.id, name: survivor.id, login: login ?? survivor.id, code: login ?? survivor.id)
        let merged = try CredentialMerge.merged([survivor, absorbed], picks: picks)
        let stored = try await f.stored()
        let accounts = stored.accounts.filter { $0.id != absorbed.id }.map { $0.id == survivor.id ? merged : $0 }
        _ = try await f.manager.commit(
            accounts, expectedRevision: stored.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch),
            merging: [absorbed.id: survivor.id]
        )
        return merged
    }

    /// Every later transfer still validates the vault: a backup staged against it, a system import previewed against it, an export.
    func expectTransfersStillWork(_ f: CredentialExchangeCoordinatorTests.Fixture, backup: VaultBackup) async throws {
        let stored = try await f.stored()
        _ = try VaultBackupCodec.stage(backup, against: stored)
        let exported = try base.exported(stored.accounts.filter { $0.password != nil || !$0.passkeys.isEmpty })
        _ = try CredentialExchangeCodec.preview(exported, against: stored)
    }

    func decideEveryOpenChoice(_ f: CredentialExchangeCoordinatorTests.Fixture, _ choice: CredentialImportChoice) throws {
        let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
        for record in review.conflicts where record.choice == nil {
            try f.coordinator.choose(choice, for: record.incoming, owner: f.owner)
        }
    }

    @Test func aFileOnlyEntryMergedSinceTheBackupJoinsItsSurvivorAndLeavesTheVaultImportable() async throws {
        try await base.withFixture { f in
            let (source, _) = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let backup = try await backupOfEverything(f, in: folder)
            let scans = try #require(source.first { $0.displayName == "Scans" })
            let survivor = try #require(source.first { $0.displayName == "Example" })
            try await merge(scans, into: survivor, in: f)
            let before = try await f.stored().accounts

            try await f.coordinator.beginBackupImport(backup, into: f.manager, owner: f.owner) { _ in }
            try decideEveryOpenChoice(f, .skip)
            _ = try? await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            // The survivor already holds the merged entry's file, so nothing is added beside it.
            let after = try await f.stored().accounts
            #expect(after.count == before.count && !after.contains { $0.displayName == "Scans" })
            #expect(after.first { $0.id == survivor.id }?.attachments?.count == 2)
            try await expectTransfersStillWork(f, backup: backup)
        }
    }

    @Test func aMergedEntrysFilesGoToTheEntryItWasMergedInto() async throws {
        try await base.withFixture { f in
            let (source, files) = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let backup = try await backupOfEverything(f, in: folder)
            let login = try #require(source.first { $0.displayName == "Example" })
            let survivor = try #require(source.first { $0.displayName == "Passkey only" })
            var merged = try await merge(login, into: survivor, login: login.id, in: f)
            // The merged entry's file was removed afterwards: the backup is the only copy.
            merged.attachments = nil
            let stored = try await f.stored()
            _ = try await f.manager.commit(
                stored.accounts.map { $0.id == merged.id ? merged : $0 }, expectedRevision: stored.revision,
                authorizedEpoch: try #require(f.manager.authorizationEpoch)
            )
            let count = try await f.stored().accounts.count

            try await f.coordinator.beginBackupImport(backup, into: f.manager, owner: f.owner) { _ in }
            try decideEveryOpenChoice(f, .skip)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            let after = try await f.stored().accounts
            #expect(after.count == count)
            let restored = try #require(after.first { $0.id == survivor.id }?.attachments?.first)
            #expect(try await readFile(restored, from: f.manager) == files[0])
            try await expectTransfersStillWork(f, backup: backup)
        }
    }

    @Test func aFileOnlyEntryDeletedSinceTheBackupIsNotRestored() async throws {
        try await base.withFixture { f in
            let (source, _) = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let backup = try await backupOfEverything(f, in: folder)
            let stored = try await f.stored()
            _ = try await f.manager.commit(
                stored.accounts.filter { $0.displayName != "Scans" }, expectedRevision: stored.revision,
                authorizedEpoch: try #require(f.manager.authorizationEpoch)
            )
            let before = try f.diskBytes()

            try await f.coordinator.beginBackupImport(backup, into: f.manager, owner: f.owner) { _ in }
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.backupRemovedFileOnly == 1 && review.backupFileOnlyEntries == 0)
            await #expect(throws: CredentialTransferFailure.self) { _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner) }
            #expect(try f.diskBytes() == before)
            #expect(try await f.stored().accounts.count == source.count - 1)
        }
    }

    @Test func restoringAddsAFileOnlyOnceAndNeverOneTheEntryAlreadyHolds() throws {
        let contents = Data("the same file".utf8)
        var saved = base.account()
        saved.attachments = [attachment(for: contents)]
        let backup = try VaultBackupCodec.backup(
            of: [saved], files: [saved.attachments![0].id: contents], vaultName: nil, exportedAt: Self.when
        ).backup
        #expect(backup.accounts[0].attachments?[0].wrappedKey == Data(count: CredentialAttachment.wrappedKeyBytes))

        // Held under another record with the same size and SHA-256: nothing to write.
        var holding = saved
        holding.attachments = [attachment(for: contents)]
        let held = StoreSnapshot(vaultID: UUID(), revision: 1, accounts: [holding], blockedPasswordOrigins: [], stamps: [:])
        #expect(try VaultBackupCodec.restoring(VaultBackupCodec.stage(backup, against: held), into: []).touched.isEmpty)

        // Missing from the entry: added once, as an update of that entry.
        var lacking = saved
        lacking.attachments = nil
        let bare = StoreSnapshot(vaultID: UUID(), revision: 1, accounts: [lacking], blockedPasswordOrigins: [], stamps: [:])
        let restored = try VaultBackupCodec.restoring(VaultBackupCodec.stage(backup, against: bare), into: [])
        #expect(restored.updated == 1 && restored.added == 0)
        #expect(restored.touched.map(\.id) == [saved.id] && restored.touched[0].attachments?.count == 1)
    }

    @Test func aCommitThatFailsAfterTheFilesWereStoredRemovesThem() async throws {
        try await base.withFixture { f in
            _ = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let backup = try await backupOfEverything(f, in: folder)
            try await f.seed([], into: f.other)
            try await f.coordinator.beginBackupImport(backup, into: f.other, owner: f.owner) { _ in }
            let withFile = try #require(f.coordinator.session?.preview.candidates.first { $0.attachments != nil })
            // After the last check, an entry with the id the import creates appears: the commit refuses, after the files were stored.
            f.coordinator.afterLastCheck = {
                var intruder = base.account(username: "intruder", password: "pw-intruder")
                intruder.id = withFile.id
                let epoch = f.other.authorizationEpoch ?? 0
                _ = try? await f.other.commit([intruder], expectedRevision: try await f.other.snapshot().revision, authorizedEpoch: epoch)
            }
            await #expect(throws: CredentialTransferFailure.self) { _ = try await f.coordinator.commitImport(into: f.other, owner: f.owner) }

            let blobs = f.other.store.blobFolder(f.other.vaultID)
            #expect(FileManager.default.fileExists(atPath: blobs.path))
            let left = VaultBlob.contents(of: blobs)
            #expect(left.stored.isEmpty && left.partial.isEmpty)
            #expect(try await f.stored(f.other).accounts.map(\.username) == ["intruder"])
        }
    }

    @Test func aLockWhileABackupIsDecryptedHandsNoPlaintextToThePage() async throws {
        try await base.withFixture { f in
            _ = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appending(path: "backup.wsurfvault")
            _ = try await export(f, to: url, password: Self.password)
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            let epoch = try #require(f.manager.authorizationEpoch)

            guard case let .needsPassword(container) = await model.readBackup(from: url, epoch: epoch) else {
                Issue.record("an encrypted backup asks for its password")
                return
            }
            guard case .wrongPassword = await model.openBackup(container, password: "not it", epoch: epoch) else {
                Issue.record("a wrong password is said to be wrong")
                return
            }
            f.coordinator.afterBackupRead = { f.manager.lock(reason: .manual) }
            guard case .failed = await model.openBackup(container, password: Self.password, epoch: epoch) else {
                Issue.record("a lock during the key derivation hands no backup back")
                return
            }
            #expect(f.coordinator.session == nil)
        }
    }

    @Test func aDamagedHeaderIsUnreadableInsteadOfAPasswordPrompt() async throws {
        try await base.withFixture { f in
            _ = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appending(path: "backup.wsurfvault")
            _ = try await export(f, to: url, password: Self.password)
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            let epoch = try #require(f.manager.authorizationEpoch)
            var data = try Data(contentsOf: url)
            #expect(VaultBackupCodec.isOpenable(data))
            for position in [8, 9, 10] {
                var changed = data
                changed[position] ^= 0x7F
                #expect(!VaultBackupCodec.isOpenable(changed), "byte \(position)")
            }
            data[8] ^= 0x01
            try data.write(to: url)
            guard case .failed = await model.readBackup(from: url, epoch: epoch) else {
                Issue.record("a damaged header is reported, not prompted for")
                return
            }
            #expect(model.transferMessage?.kind == .csvUnreadable)
        }
    }
}
