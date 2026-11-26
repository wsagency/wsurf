// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Full backups of the vault (`VaultBackup`): written as a `.wsurfvault` file under a backup password or as plain JSON, and read back
/// into the import review. Writing one always asks for Touch ID first: every kind of secret leaves the vault.
extension CredentialSettingsModel {
    /// How reading a backup file for import ended.
    enum BackupRead {
        case backup(VaultBackup)
        /// The file is an encrypted backup WSurf can try a password on: ask for it and call `openBackup` with these bytes. They are
        /// the encrypted file, so holding them reveals nothing.
        case needsPassword(Data)
        /// The password is wrong or the file was changed. Nothing was read.
        case wrongPassword
        /// The page says why (`ownMessage`).
        case failed
    }

    /// Writes the entries `accountIDs` as a backup at `url`, which the user chose in the save panel the caller ran BEFORE this call:
    /// sealed under `password`, or plain JSON when it is nil. Returns whether a file was written.
    @discardableResult
    func exportBackup(accountIDs: [UUID], epoch: UInt64, to url: URL, password: String?) async -> Bool {
        let vault = manager?.vaultID
        ownMessage = nil
        var written: CredentialExchangeCoordinator.BackupExport?
        let saved = await perform(describe: { Self.exportMessage(for: $0) }) {
            let stamps = try await self.exportStamps(epoch: epoch)
            let reason = password == nil
                ? String(localized: "export every password, passkey, code, card, note and file without encryption")
                : String(localized: "export an encrypted backup of your passwords, passkeys, codes, cards, notes and files")
            guard try await self.verifyOwner(reason) == epoch else { throw CredentialVaultError.unauthorized }
            written = try await self.exchange.exportBackup(
                accountIDs: accountIDs, expectedStamps: stamps, epoch: epoch, from: $0, to: url, password: password
            )
        }
        if !saved, ownMessage?.message.kind == .exportSelectionChanged {
            await load()
        }
        if saved, let written {
            ownMessage = (
                .backupExported(entries: written.entries, files: written.files, omittedFiles: written.omittedFiles, encrypted: password != nil),
                vault
            )
        }
        return saved
    }

    /// Reads the backup at `url` once, off the main actor: a plain backup is decoded, an encrypted one is handed back for its password.
    /// The file is only read, never changed. Nothing is staged: the caller passes the backup to `beginBackupImport`. `epoch` is the
    /// authorization the page had before its open panel; a lock or re-unlock since reads nothing into the page.
    func readBackup(from url: URL, epoch: UInt64) async -> BackupRead {
        ownMessage = nil
        let data: Data
        do {
            data = try await Task.detached { try CredentialCSV.read(url, limit: VaultBackupCodec.fileSizeLimit) }.value
        } catch CredentialCSVError.tooLarge {
            return failing(.backupUnreadable(tooLarge: true))
        } catch {
            return failing(.csvNotOpened())
        }
        guard VaultBackupCodec.isEncrypted(data) else { return await decoding(data, password: nil, epoch: epoch) }
        // A damaged header, or one from a newer build, opens with no password: say so rather than ask for one again and again.
        guard VaultBackupCodec.isOpenable(data) else { return failing(.backupUnreadable()) }
        return .needsPassword(data)
    }

    /// Decrypts and decodes the encrypted backup `container` (from `.needsPassword`) with `password`.
    func openBackup(_ container: Data, password: String, epoch: UInt64) async -> BackupRead {
        await decoding(container, password: password, epoch: epoch)
    }

    /// The decrypted backup is returned only while the vault is still under `epoch`: a lock or re-unlock while the key was derived
    /// drops it here, so no plaintext reaches a page that was already cleared.
    private func decoding(_ data: Data, password: String?, epoch: UInt64) async -> BackupRead {
        let backup: VaultBackup
        do {
            backup = try await exchange.readBackup(data, password: password)
        } catch VaultBackupError.wrongPasswordOrCorrupted {
            return .wrongPassword
        } catch VaultBackupError.tooLarge {
            return failing(.backupUnreadable(tooLarge: true))
        } catch {
            return failing(.backupUnreadable())
        }
        guard manager?.authorizationEpoch == epoch else {
            return failing(.discarded(.csvFile))
        }
        return .backup(backup)
    }

    /// Stages `backup` for the same review a CSV file gets. `epoch` is the authorization the page had BEFORE its open panel: a lock or
    /// re-unlock since stages nothing.
    func beginBackupImport(_ backup: VaultBackup, epoch: UInt64) async {
        importResult = nil
        ownMessage = nil
        _ = await perform(epoch: epoch) { manager in
            try await self.exchange.beginBackupImport(backup, into: manager, owner: self.owner, onEnding: self.importEnding(in: manager))
        }
    }

    private func failing(_ message: CredentialTransferMessage) -> BackupRead {
        ownMessage = (message, manager?.vaultID)
        return .failed
    }
}
