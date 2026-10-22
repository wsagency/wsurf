// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WSurfVault

/// The editor's Files section. A file is encrypted into the vault's folder as soon as it is added and the draft keeps its record; Save
/// stores the record with the entry, and Cancel removes the files the editor added (a save that left one out removes that one).
/// Preview and Open With decrypt into this run's private folder (`VaultFilePreviewFolder`), Save Copy… into the place the person
/// chose. An export to another app never carries files (owner decision 4).
extension CredentialSettingsModel {
    /// How many files the vault's entries hold and their bytes, from the summaries: what the 2 GB limit counts.
    var fileUsage: (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        for summary in summaries {
            count += summary.fileCount
            bytes += summary.fileBytes
        }
        return (count, bytes)
    }

    /// Encrypts each of `urls` into the vault and adds it to the open draft, in order. The first one a limit refuses stops the rest, and
    /// the ones before it stay added.
    func addFiles(_ urls: [URL]) async throws {
        guard let manager, let epoch = live?.epoch else { throw CredentialVaultError.unauthorized }
        for url in urls {
            guard let draft = live?.draft else { return }
            try Self.checkRoom(for: url, in: draft, vaultBytes: fileUsage.bytes)
            let file = try await manager.addAttachment(from: url)
            guard live?.epoch == epoch, live?.draft?.accountID == draft.accountID, live?.draft != nil else {
                // The editor closed or the vault locked while the file was encrypted: nothing will refer to it.
                try? await manager.discardAttachments([file.id])
                throw CredentialVaultError.unauthorized
            }
            try update(epoch) { $0.draft?.addAttachment(file) }
        }
    }

    /// The limits a new file must pass before anything is encrypted: 64 per entry, 50 MB each, 2 GB of live files per vault. `vaultBytes`
    /// counts the stored entries, this one as it was stored; the draft's own list replaces that part.
    static func checkRoom(for url: URL, in draft: CredentialDraft, vaultBytes: Int64) throws {
        guard draft.attachments.count < CredentialAttachment.entryLimit else { throw VaultFileError.entryFull }
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
              let size = values.fileSize.map(Int64.init)
        else { throw VaultFileError.unreadable(name: name) }
        guard size <= CredentialAttachment.fileBytes else { throw VaultFileError.tooLarge(name: name) }
        let stored = draft.original?.attachments?.reduce(Int64(0)) { $0 + $1.size } ?? 0
        let drafted = draft.attachments.reduce(Int64(0)) { $0 + $1.size }
        guard vaultBytes - stored + drafted + size <= CredentialAttachment.vaultBytes else { throw VaultFileError.vaultFull }
    }

    func removeFile(_ id: UUID) {
        draft?.removeAttachment(id)
    }

    /// Removes the files the open editor added that the saved entry does not hold (all of them when nothing was saved). Best effort: a
    /// file this misses is removed by the next sweep.
    func discardAddedFiles(of draft: CredentialDraft, keeping saved: CredentialAccount?) {
        let kept = Set(saved?.attachments?.map(\.id) ?? [])
        let unused = draft.addedFileIDs.subtracting(kept)
        guard !unused.isEmpty, let manager else { return }
        fileDiscard = Task { try? await manager.discardAttachments(unused) }
    }

    /// Whether `file`'s encrypted file is in the vault's folder.
    func hasFile(_ file: CredentialAttachment) -> Bool {
        manager?.hasAttachment(file) ?? false
    }

    /// Decrypts `file` to `destination`, which the person chose in a save panel.
    func saveFileCopy(_ file: CredentialAttachment, to destination: URL) async throws {
        guard let manager else { throw CredentialVaultError.unauthorized }
        try await manager.readAttachment(file, to: destination)
        showNotice("File Saved")
    }

    /// A decrypted copy of `file` in this run's private folder, for Quick Look or another app. Remove it with `previewFolder.remove`.
    func temporaryCopy(of file: CredentialAttachment) async throws -> URL {
        guard let manager else { throw CredentialVaultError.unauthorized }
        let url = try previewFolder.newCopyURL(named: file.name)
        do {
            try await manager.readAttachment(file, to: url)
        } catch {
            previewFolder.remove(url)
            throw error
        }
        return url
    }
}
