// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import Synchronization

/// The manifest carries the attachment with its file key wrapped for this synced vault. The file itself stays encrypted.
public nonisolated struct VaultSyncAttachment: Sendable {
    public let descriptor: CredentialAttachment
    public let encryptedFile: URL
}

/// Keeps a verified blob alive until the receiving transaction has committed or released it.
public nonisolated final class VaultImportedAttachment: Sendable {
    public let descriptor: CredentialAttachment
    private let release: @Sendable () -> Void

    init(_ file: CredentialAttachment, release: @escaping @Sendable () -> Void) {
        descriptor = file
        self.release = release
    }

    deinit {
        release()
    }
}

nonisolated final class VaultImportPins: Sendable {
    private let files = Mutex<[UUID: (vault: UUID, blob: UUID)]>([:])

    func pin(_ file: CredentialAttachment, in vaultID: UUID) -> VaultImportedAttachment {
        let token = UUID()
        files.withLock { $0[token] = (vaultID, file.id) }
        return VaultImportedAttachment(file) { [self] in files.withLock { $0[token] = nil } }
    }

    func ids(in vaultID: UUID) -> Set<UUID> {
        files.withLock { Set($0.values.compactMap { $0.vault == vaultID ? $0.blob : nil }) }
    }
}

extension CredentialAttachment {
    public nonisolated var encryptedSize: Int64 {
        VaultBlob.storedBytes(size: size)
    }
}

extension ProfileVaultStore {
    private func attachmentKeys(_ vaultID: UUID, access: VaultAccess) throws -> (local: SymmetricKey, cloud: SymmetricKey) {
        let grant = try authorizedGrant(vaultID, access)
        let local = VaultBlob.fileKey(dek: grant.dek, ids: grant.ids, vaultID: vaultID)
        let sync = VaultSyncKey.derive(dek: grant.dek, profileID: profileID, vaultID: vaultID)
        let cloud = HKDF<SHA256>.deriveKey(inputKeyMaterial: sync.key, salt: Data(), info: Data("WSurf synced file keys v1".utf8), outputByteCount: 32)
        return (local, cloud)
    }

    public func exportSyncAttachment(_ attachment: CredentialAttachment, vaultID: UUID, using access: VaultAccess) throws -> VaultSyncAttachment {
        try attachment.validate()
        let keys = try attachmentKeys(vaultID, access: access)
        let key = try VaultBlob.unwrap(attachment, under: keys.local)
        let file = VaultBlob.file(attachment.id, in: blobFolder(vaultID))
        try VaultBlob.verify(attachment, at: file, key: key)
        var descriptor = attachment
        descriptor.wrappedKey = try VaultBlob.wrap(key, under: keys.cloud, id: attachment.id, size: attachment.size, sha256: attachment.sha256)
        _ = try authorizedGrant(vaultID, access)
        return VaultSyncAttachment(descriptor: descriptor, encryptedFile: file)
    }

    /// Reuse a verified local ciphertext, or install the downloaded ciphertext without replacing any existing file.
    public func importSyncAttachment(
        _ descriptor: CredentialAttachment, from source: URL?, vaultID: UUID, using access: VaultAccess
    ) throws -> VaultImportedAttachment {
        try descriptor.validate()
        let keys = try attachmentKeys(vaultID, access: access)
        let key = try VaultBlob.unwrap(descriptor, under: keys.cloud)
        return try installAttachment(descriptor, key: key, wrappingKey: keys.local, from: source, vaultID: vaultID) {
            try access.checkAuthorization(at: now())
        }
    }

    /// Sync and local merges install the same sealed blob. Both verify even a previously staged copy.
    func installAttachment(
        _ descriptor: CredentialAttachment, key: SymmetricKey, wrappingKey: SymmetricKey, from source: URL?, vaultID: UUID,
        checkAuthorization: () throws -> Void
    ) throws -> VaultImportedAttachment {
        try checkAuthorization()
        var local = descriptor
        local.wrappedKey = try VaultBlob.wrap(key, under: wrappingKey, id: descriptor.id, size: descriptor.size, sha256: descriptor.sha256)
        let folder = blobFolder(vaultID)
        let destination = VaultBlob.file(descriptor.id, in: folder)
        if StoreAnchors.exists(destination) {
            try VaultBlob.verify(descriptor, at: destination, key: key)
            try checkAuthorization()
            return importPins.pin(local, in: vaultID)
        }
        guard let source else { throw VaultFileError.missing }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = VaultBlob.partial(UUID(), in: folder)
        defer { try? manager.removeItem(at: temp) }
        var installed = false
        do {
            try manager.copyItem(at: source, to: temp)
            try VaultBlob.verify(descriptor, at: temp, key: key)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            try fileOps.fullFsync(temp)
            try Task.checkCancellation()
            try checkAuthorization()
            do {
                try fileOps.renameExclusive(temp, destination)
                installed = true
            } catch StoreFileError.exists {
                try VaultBlob.verify(descriptor, at: destination, key: key)
            }
            try fileOps.fsyncDirectory(folder)
            try checkAuthorization()
            return importPins.pin(local, in: vaultID)
        } catch {
            if installed {
                VaultBlob.remove(local.id, in: folder)
            }
            throw error
        }
    }
}
