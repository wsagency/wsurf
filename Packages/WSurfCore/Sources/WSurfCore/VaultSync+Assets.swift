// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation
import WSurfVault

/// A transfer holds no authority across an await. The local grant, Apple Account and enrollment must still match.
struct VaultTransfer {
    let key: VaultKey
    let session: Int
    let lease: UInt64
    let user: String?
}

extension VaultSync {
    func transfer(_ key: VaultKey, lease: UInt64) -> VaultTransfer {
        VaultTransfer(key: key, session: token(key), lease: lease, user: state.accountUser)
    }

    func current(_ transfer: VaultTransfer) -> Bool {
        let key = transfer.key
        return stillOpen(key, transfer.session) && state.accountUser == transfer.user && accountAvailable != false
            && host.currentLease(profileID: key.profileID, vaultID: key.vaultID) == transfer.lease && summaries[key]?.enabled == true
            && !halted.contains(key) && (summaries[key]?.stored == .active || summaries[key]?.stored == .iCloudFull)
    }

    func assetDirectory(_ key: VaultKey) -> URL? {
        host.syncDirectory(profileID: key.profileID)?.appending(path: "VaultSyncAssets/\(key.vaultID.sqlText)", directoryHint: .isDirectory)
    }

    func clearAssets(_ key: VaultKey, account: UUID? = nil, incoming: Bool = false) {
        guard var directory = assetDirectory(key) else { return }
        if let account {
            directory = directory.appending(path: "\(incoming ? "in" : "out")/\(account.sqlText)", directoryHint: .isDirectory)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    /// A crash before a queue transaction can leave private ciphertext with no owner.
    func pruneAssets(_ key: VaultKey, database: VaultSyncDatabase) {
        guard let root = assetDirectory(key), FileManager.default.fileExists(atPath: root.path),
              let owned = try? database.read({ tx in
                  try [("out", Set(tx.outbox(key.vaultID, unfinishedOnly: true).map(\.accountID))), ("in", tx.inboxAccounts(key.vaultID).union(tx.conflictAccounts(key.vaultID)))]
              }) else { return }
        for (name, accounts) in owned {
            let folder = root.appending(path: name)
            for child in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                if let id = UUID(uuidString: child.lastPathComponent), !accounts.contains(id) {
                    try? FileManager.default.removeItem(at: child)
                }
            }
        }
    }

    private func directory(_ transfer: VaultTransfer, account: UUID, incoming: Bool) throws -> URL {
        guard current(transfer), let root = assetDirectory(transfer.key) else { throw VaultSyncFailure.unavailable }
        let folder = root.appending(path: "\(incoming ? "in" : "out")/\(account.sqlText)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    nonisolated private static func stage(_ data: Data, in folder: URL) throws -> VaultAssetRef {
        let ref = try VaultAssetRef(data)
        let destination = folder.appending(path: ref.name)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return ref
    }

    func sealAssetRow(_ entry: SyncableAccount, version: UInt64, syncKey: VaultSyncKey, transfer: VaultTransfer) async throws -> OutboxRow {
        let key = transfer.key
        let id = entry.account.id
        let folder = try directory(transfer, account: id, incoming: false)
        var account = entry.account
        var chunks: [UUID: [VaultAssetRef]] = [:]
        var remaining: [VaultAssetRef] = []
        var descriptors: [CredentialAttachment] = []
        for file in account.attachments ?? [] {
            guard let files = host as? any VaultAttachmentHost, current(transfer) else { throw VaultSyncFailure.locked }
            let exported = try await files.exportAttachment(file, profile: key.profileID, vault: key.vaultID, lease: transfer.lease)
            guard current(transfer) else { throw VaultSyncFailure.locked }
            let parts = try await Self.stageFile(exported.encryptedFile, in: folder)
            guard current(transfer) else { throw VaultSyncFailure.locked }
            chunks[file.id] = parts
            remaining += parts
            descriptors.append(exported.descriptor)
        }
        account.attachments = descriptors.isEmpty ? nil : descriptors
        let portable = try VaultAssetAccount(account: account, chunks: chunks)
        let sealed = try VaultSyncCodec.sealAssetAccount(portable, version: version, key: syncKey)
        remaining.append(try Self.stage(sealed.body, in: folder))
        let parts = try VaultSyncCodec.sealParts(entry.parts, accountID: id, version: version, key: syncKey)
        return OutboxRow(accountID: id, version: version, envelope: sealed.envelope, parts: parts, remainingAssets: remaining)
    }

    @concurrent private static func stageFile(_ source: URL, in folder: URL) async throws -> [VaultAssetRef] {
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var refs: [VaultAssetRef] = []
        while let bytes = try handle.read(upToCount: VaultAssetRef.maxBytes), !bytes.isEmpty {
            refs.append(try stage(bytes, in: folder))
        }
        return refs
    }

    /// Checkpoint every accepted immutable asset before allowing its Item to be sent. A lost reply repeats the same upload.
    func uploadAssets(_ transfer: VaultTransfer, database: VaultSyncDatabase) async {
        let key = transfer.key
        guard let transport = engine as? any VaultAssetTransport, let user = transfer.user, current(transfer),
              let rows = try? database.read({ try $0.outbox(key.vaultID, unfinishedOnly: true) }) else { return }
        for var row in rows {
            guard current(transfer) else { return }
            do {
                let folder = try directory(transfer, account: row.accountID, incoming: false)
                while let ref = row.remainingAssets.first {
                    let file = folder.appending(path: ref.name)
                    guard FileManager.default.fileExists(atPath: file.path) else { throw VaultFileError.missing }
                    try await transport.uploadVaultAsset(ref, from: file, zone: key.zone, user: user)
                    guard current(transfer) else { return }
                    row.remainingAssets.removeFirst()
                    let recorded = try database.write { tx in
                        guard let existing = try tx.outbox(key.vaultID, row.accountID), existing.envelope == row.envelope,
                              existing.remainingAssets.first == ref else { return false }
                        try tx.save(row, vault: key.vaultID)
                        return true
                    }
                    guard recorded else { break }
                    if row.remainingAssets.isEmpty {
                        clearAssets(key, account: row.accountID)
                        engine?.add([.saveRecord(key.itemRecord(row.accountID))])
                    }
                }
            } catch VaultSyncError.authenticationFailed {
                pendingBases[key] = nil
            } catch VaultFileError.missing {
                // Rebuild the sealed row from the store after a crash that lost a staged file.
                pendingBases[key] = nil
            } catch let error as CKError where error.code == .quotaExceeded {
                if current(transfer) {
                    zoneSaveOverQuota(key.zone)
                }
                return
            } catch {
                continue
            }
        }
    }

    func staged(_ row: OutboxRow, key: VaultKey) -> Bool {
        guard !row.remainingAssets.isEmpty else { return true }
        guard let folder = assetDirectory(key)?.appending(path: "out/\(row.accountID.sqlText)") else { return false }
        return row.remainingAssets.allSatisfy { (try? Self.cached($0, in: folder)) != nil }
    }

    private static func cached(_ ref: VaultAssetRef, in folder: URL) throws -> Data? {
        let url = folder.appending(path: ref.name)
        guard ref.valid, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == ref.size else { return nil }
        let data = try Data(contentsOf: url)
        return ref.matches(data) ? data : nil
    }

    private func download(_ ref: VaultAssetRef, transfer: VaultTransfer, folder: URL) async throws -> Data {
        guard current(transfer) else { throw VaultSyncFailure.locked }
        if let cached = try Self.cached(ref, in: folder) {
            return cached
        }
        guard let transport = engine as? any VaultAssetTransport, let user = transfer.user else { throw VaultSyncFailure.unavailable }
        let data = try await transport.downloadVaultAsset(ref, zone: transfer.key.zone, user: user)
        guard current(transfer), ref.matches(data) else { throw VaultSyncFailure.unavailable }
        _ = try Self.stage(data, in: folder)
        return data
    }

    func materialize(
        _ envelope: Data, accountID id: UUID, syncKey: VaultSyncKey, transfer: VaultTransfer, pins: inout [VaultImportedAttachment]
    ) async throws -> SyncItem {
        guard envelope.first == VaultSyncCodec.assetFormat else { return try VaultSyncCodec.openItem(envelope, accountID: id, key: syncKey) }
        let (version, ref) = try VaultSyncCodec.assetReference(envelope, accountID: id, key: syncKey)
        // Once authenticated, a pointer stays in the inbox until its entire verified account is available.
        let folder: URL
        let body: Data
        do {
            folder = try directory(transfer, account: id, incoming: true)
            body = try await download(ref, transfer: transfer, folder: folder)
        } catch {
            throw VaultSyncFailure.unavailable
        }
        let portable = try VaultSyncCodec.openAssetAccount(body, accountID: id, version: version, key: syncKey)
        do {
            var account = portable.account
            var local: [CredentialAttachment] = []
            for file in account.attachments ?? [] {
                let imported = try await importFile(file, refs: portable.chunks[file.id] ?? [], transfer: transfer, folder: folder)
                pins.append(imported)
                local.append(imported.descriptor)
            }
            account.attachments = local.isEmpty ? nil : local
            return SyncItem(accountID: id, version: version, account: account, includesFiles: true)
        } catch {
            throw VaultSyncFailure.unavailable
        }
    }

    private func importFile(
        _ file: CredentialAttachment, refs: [VaultAssetRef], transfer: VaultTransfer, folder: URL
    ) async throws -> VaultImportedAttachment {
        let key = transfer.key
        guard let files = host as? any VaultAttachmentHost, current(transfer) else { throw VaultSyncFailure.unavailable }
        do {
            return try await files.importAttachment(file, from: nil, profile: key.profileID, vault: key.vaultID, lease: transfer.lease)
        } catch VaultFileError.missing {
            let joined = folder.appending(path: "assembling-\(file.id.uuidString)")
            defer { try? FileManager.default.removeItem(at: joined) }
            try Data().write(to: joined)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: joined.path)
            let handle = try FileHandle(forWritingTo: joined)
            defer { try? handle.close() }
            for ref in refs {
                let data = try await download(ref, transfer: transfer, folder: folder)
                try handle.write(contentsOf: data)
            }
            try handle.close()
            guard current(transfer) else { throw VaultSyncFailure.locked }
            return try await files.importAttachment(file, from: joined, profile: key.profileID, vault: key.vaultID, lease: transfer.lease)
        }
    }
}
