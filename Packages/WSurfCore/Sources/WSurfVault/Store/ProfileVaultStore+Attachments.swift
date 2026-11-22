// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import GRDB

/// Files kept with vault entries (`CredentialAttachment`, stored by `VaultBlob`). Every call needs the vault unlocked under `access`,
/// like every other read and write. These are the only ways to a file's plaintext, and nothing the assistant or an MCP client can call
/// reaches them (`VaultAttachmentIsolationTests`). A file is written before the commit that refers to it and removed only once nothing
/// refers to it: a sweep after a purge, Delete Vault, or an editor discarding the files it added.
extension ProfileVaultStore {
    nonisolated func blobFolder(_ vaultID: UUID) -> URL {
        VaultBlob.folder(in: directory, vaultID: vaultID)
    }

    /// Whether the encrypted file of `file` is on disk: a stat, nothing is read.
    public nonisolated func hasBlob(_ file: CredentialAttachment, vaultID: UUID) -> Bool {
        StoreAnchors.exists(VaultBlob.file(file.id, in: blobFolder(vaultID)))
    }

    private func fileWrappingKey(vaultID: UUID, using access: VaultAccess) throws -> SymmetricKey {
        let grant = try authorizedGrant(vaultID, access)
        return VaultBlob.fileKey(dek: grant.dek, ids: grant.ids, vaultID: vaultID)
    }

    /// Encrypts `source` into the vault's folder and returns the record a commit then stores. Until that commit, or until
    /// `sweepAttachments(only:)` discards it, no sweep removes the file.
    public func addAttachment(vaultID: UUID, from source: URL, using access: VaultAccess) async throws -> CredentialAttachment {
        let fileKey = try fileWrappingKey(vaultID: vaultID, using: access)
        let id = UUID()
        pendingBlobs[vaultID, default: []].insert(id)
        do {
            return try await VaultBlob.write(from: source, id: id, into: blobFolder(vaultID), fileKey: fileKey, fileOps: fileOps, now: wall())
        } catch {
            pendingBlobs[vaultID]?.remove(id)
            throw error
        }
    }

    /// Decrypts `file` into `destination`. A lock that lands meanwhile removes what was written: nothing decrypted outlives the lease.
    public func readAttachment(vaultID: UUID, _ file: CredentialAttachment, to destination: URL, using access: VaultAccess) async throws {
        let fileKey = try fileWrappingKey(vaultID: vaultID, using: access)
        try await VaultBlob.read(file, in: blobFolder(vaultID), fileKey: fileKey, to: destination)
        do {
            _ = try authorizedGrant(vaultID, access)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Authenticate every destination file a merge will present as already saved. Nothing decrypted leaves the verifier.
    public func verifyMergeAttachments(_ files: [CredentialAttachment], vaultID: UUID, using access: VaultAccess) throws {
        _ = try authorizedGrant(vaultID, access)
        var verified: [UUID: CredentialAttachment] = [:]
        for file in files where verified[file.id] != file {
            _ = try verifiedMergeBlob(file, vaultID: vaultID, using: access)
            verified[file.id] = file
        }
        try access.checkAuthorization(at: now())
    }

    /// Check the batch once before staging. A file that a live row, history or Trash already names must be restored before its ID is reused.
    public func checkMergeAttachments(_ files: [CredentialAttachment], vaultID: UUID, using access: VaultAccess) async throws {
        _ = try authorizedGrant(vaultID, access)
        let folder = blobFolder(vaultID)
        let missing = Set(files.map(\.id)).filter { !StoreAnchors.exists(VaultBlob.file($0, in: folder)) }
        guard !missing.isEmpty else { return }
        let reserved = try await readHistory(vaultID, access) { db, grant, opened in
            guard opened.catalog.schema >= StoreFormat.fileSchema else { return false }
            return try !Self.referencedBlobs(db, grant: grant, opened: opened).isDisjoint(with: missing)
        }
        _ = try authorizedGrant(vaultID, access)
        guard !reserved, missing.isDisjoint(with: pendingBlobs[vaultID] ?? []), missing.isDisjoint(with: importPins.ids(in: vaultID))
        else { throw VaultFileError.missing }
    }

    /// Copy one attachment from a checked batch between unlocked vaults. Hold the returned pin through the commit of the reviewed revision.
    public func copyMergeAttachment(
        _ file: CredentialAttachment, from source: ProfileVaultStore, sourceVaultID: UUID, sourceAccess: VaultAccess,
        vaultID: UUID, using access: VaultAccess
    ) async throws -> VaultImportedAttachment {
        _ = try authorizedGrant(vaultID, access)
        let origin = try await source.verifiedMergeBlob(file, vaultID: sourceVaultID, using: sourceAccess)
        let destinationKey = try fileWrappingKey(vaultID: vaultID, using: access)
        return try installAttachment(file, key: origin.key, wrappingKey: destinationKey, from: origin.url, vaultID: vaultID) {
            try sourceAccess.checkAuthorization(at: source.now())
            try access.checkAuthorization(at: now())
        }
    }

    private func verifiedMergeBlob(
        _ file: CredentialAttachment, vaultID: UUID, using access: VaultAccess
    ) throws -> (key: SymmetricKey, url: URL) {
        try file.validate()
        let key = try VaultBlob.unwrap(file, under: fileWrappingKey(vaultID: vaultID, using: access))
        let url = VaultBlob.file(file.id, in: blobFolder(vaultID))
        try VaultBlob.verify(file, at: url, key: key)
        try access.checkAuthorization(at: now())
        return (key, url)
    }

    /// Removes the vault's encrypted files that no live entry, earlier version or Trash entry refers to, and any half-written file;
    /// only those of `candidates` when given. An editor discards its own pending additions here. Import cleanup leaves every editor
    /// claim intact with `discardingPending: false`. Returns how many finished files went.
    @discardableResult
    public func sweepAttachments(
        vaultID: UUID, only candidates: Set<UUID>? = nil, discardingPending: Bool = true, using access: VaultAccess
    ) async throws -> Int {
        if discardingPending, let candidates {
            _ = try authorizedGrant(vaultID, access)
            pendingBlobs[vaultID]?.subtract(candidates)
        }
        let folder = blobFolder(vaultID)
        return try await readHistory(vaultID, access) { db, grant, opened in
            let pending = pendingBlobs[vaultID] ?? []
            let contents = VaultBlob.contents(of: folder)
            if discardingPending || candidates == nil {
                for id in contents.partial.subtracting(pending) {
                    VaultBlob.removePartial(id, in: folder)
                }
            }
            var unneeded = contents.stored.subtracting(pending).subtracting(importPins.ids(in: vaultID))
            if let candidates {
                unneeded.formIntersection(candidates)
            }
            guard !unneeded.isEmpty else { return 0 }
            unneeded.subtract(try Self.referencedBlobs(db, grant: grant, opened: opened))
            return unneeded.filter { VaultBlob.remove($0, in: folder) }.count
        }
    }

    /// Every file a row of the vault or its Trash names: the live entries, the earlier file lists (`attachment` revisions, on either
    /// side), and the entries in the Trash. Only those rows are opened; no file is read.
    nonisolated static func referencedBlobs(_ db: Database, grant: VaultGrant, opened: OpenedVault) throws -> Set<UUID> {
        var ids = Set<UUID>()
        for account in try readSnapshot(db, grant: grant, vaultID: opened.head.vaultID).accounts {
            ids.formUnion(account.attachments?.map(\.id) ?? [])
        }
        let trash = try openTrash(db, grant: grant, opened: opened)
        try mapIntegrity(grant.ordinal) {
            for (vaultID, key) in [(opened.head.vaultID, grant.dek), (trash.side.vaultID, trash.side.key)] {
                try StoreTables.forEachHistoryRecord(db, vaultID: vaultID) { row in
                    switch (row.kind, row.subject) {
                    case (.revision, .attachment):
                        let body = try JSONDecoder().decode(RevisionBody.self, from: row.opened(key: key, ids: grant.ids))
                        ids.formUnion(try JSONDecoder().decode([CredentialAttachment].self, from: body.value).map(\.id))
                    case (.trashEntry, .account):
                        let body = try JSONDecoder().decode(TrashEntryBody.self, from: row.opened(key: key, ids: grant.ids))
                        ids.formUnion(body.snapshot?.attachments?.map(\.id) ?? [])
                    default:
                        break
                    }
                }
            }
        }
        return ids
    }
}
