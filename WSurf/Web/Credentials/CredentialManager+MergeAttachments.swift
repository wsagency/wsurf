// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

extension CredentialManager {
    /// Encrypts a backup's file into the vault's folder under a new id; the record is stored by the import's commit.
    func restoreAttachment(_ contents: Data, as original: CredentialAttachment) async throws -> CredentialAttachment {
        try await reading { access in
            try await store.restoreAttachment(vaultID: vaultID, contents: contents, as: original, using: access)
        }
    }

    func verifyMergeAttachments(_ files: [CredentialAttachment], destinationEpoch: UInt64) async throws {
        try await reading { access in
            guard access.epoch == destinationEpoch else { throw CredentialVaultError.unauthorized }
            try await store.verifyMergeAttachments(files, vaultID: vaultID, using: access)
        }
    }

    func checkMergeAttachments(_ files: [CredentialAttachment], destinationEpoch: UInt64) async throws {
        try await reading { access in
            guard access.epoch == destinationEpoch else { throw CredentialVaultError.unauthorized }
            try await store.checkMergeAttachments(files, vaultID: vaultID, using: access)
        }
    }

    /// Stage the selected file under the same two leases that authorized the merge review.
    func copyMergeAttachment(
        _ file: CredentialAttachment, from source: CredentialManager, sourceEpoch: UInt64, destinationEpoch: UInt64
    ) async throws -> VaultImportedAttachment {
        let sourceAccess = try source.currentAccess()
        let destinationAccess = try currentAccess()
        guard sourceAccess.epoch == sourceEpoch, destinationAccess.epoch == destinationEpoch else { throw CredentialVaultError.unauthorized }
        var staged = false
        do {
            let pin = try await store.copyMergeAttachment(
                file, from: source.store, sourceVaultID: source.vaultID, sourceAccess: sourceAccess,
                vaultID: vaultID, using: destinationAccess
            )
            staged = true
            guard try source.currentAccess() === sourceAccess, try currentAccess() === destinationAccess else {
                throw CredentialVaultError.unauthorized
            }
            return pin
        } catch {
            if staged {
                try? await discardMergeAttachments([file.id], destinationEpoch: destinationEpoch)
            }
            throw error
        }
    }

    func discardMergeAttachments(_ ids: Set<UUID>, destinationEpoch: UInt64) async throws {
        guard !ids.isEmpty else { return }
        _ = try await reading { access in
            guard access.epoch == destinationEpoch else { throw CredentialVaultError.unauthorized }
            return try await store.sweepAttachments(vaultID: vaultID, only: ids, discardingPending: false, using: access)
        }
    }
}
