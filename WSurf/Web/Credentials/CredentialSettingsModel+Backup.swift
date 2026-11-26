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
        /// The file is encrypted: ask for its password and read it again.
        case needsPassword
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

    /// Reads, and with `password` decrypts, the backup at `url`. The file is only read, never changed. Nothing is staged: the caller
    /// passes the backup to `beginBackupImport` once the password sheet is gone.
    func readBackup(from url: URL, password: String?) async -> BackupRead {
        ownMessage = nil
        let data: Data
        do {
            data = try CredentialCSV.read(url, limit: VaultBackupCodec.fileSizeLimit)
        } catch CredentialCSVError.tooLarge {
            return failing(.backupUnreadable(tooLarge: true))
        } catch {
            return failing(.csvNotOpened())
        }
        if VaultBackupCodec.isEncrypted(data), password?.isEmpty ?? true {
            return .needsPassword
        }
        do {
            return .backup(try await exchange.readBackup(data, password: password))
        } catch VaultBackupError.wrongPasswordOrCorrupted {
            return .wrongPassword
        } catch VaultBackupError.tooLarge {
            return failing(.backupUnreadable(tooLarge: true))
        } catch {
            return failing(.backupUnreadable())
        }
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
