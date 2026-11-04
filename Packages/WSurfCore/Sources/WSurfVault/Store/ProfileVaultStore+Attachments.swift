// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

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

    /// Encrypts `source` into the vault's folder and returns the record a commit then stores. Until that commit, or until
    /// `sweepAttachments(only:)` discards it, no sweep removes the file.
    public func addAttachment(vaultID: UUID, from source: URL, using access: VaultAccess) async throws -> CredentialAttachment {
        let grant = try authorizedGrant(vaultID, access)
        let fileKey = VaultBlob.fileKey(dek: grant.dek, ids: grant.ids, vaultID: vaultID)
        let id = UUID()
        pendingBlobs.insert(id)
        do {
            return try await VaultBlob.write(from: source, id: id, into: blobFolder(vaultID), fileKey: fileKey, fileOps: fileOps, now: wall())
        } catch {
            pendingBlobs.remove(id)
            throw error
        }
    }

    /// Decrypts `file` into `destination`. A lock that lands meanwhile removes what was written: nothing decrypted outlives the lease.
    public func readAttachment(vaultID: UUID, _ file: CredentialAttachment, to destination: URL, using access: VaultAccess) async throws {
        let grant = try authorizedGrant(vaultID, access)
        let fileKey = VaultBlob.fileKey(dek: grant.dek, ids: grant.ids, vaultID: vaultID)
        try await VaultBlob.read(file, in: blobFolder(vaultID), fileKey: fileKey, to: destination)
        do {
            _ = try authorizedGrant(vaultID, access)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Removes the vault's encrypted files that no live entry, earlier version or Trash entry refers to, and any half-written file;
    /// only those of `candidates` when given (an editor discarding what it added, which then stops being pending). A file another
    /// editor added and has not saved yet is never removed. Returns how many finished files went.
    @discardableResult
    public func sweepAttachments(vaultID: UUID, only candidates: Set<UUID>? = nil, using access: VaultAccess) async throws -> Int {
        if let candidates {
            pendingBlobs.subtract(candidates)
        }
        let pending = pendingBlobs
        let folder = blobFolder(vaultID)
        return try await readHistory(vaultID, access) { db, grant, opened in
            let contents = VaultBlob.contents(of: folder)
            for id in contents.partial.subtracting(pending) {
                VaultBlob.removePartial(id, in: folder)
            }
            var unneeded = contents.stored.subtracting(pending)
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
