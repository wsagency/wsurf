// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Full backups (`VaultBackup`): every part of the chosen entries and the plaintext of their files, written as a JSON file the user
/// protects or sealed under a backup password, and read back into the same import review as any other transfer.
extension CredentialExchangeCoordinator {
    /// What an exported backup holds, for the message the page shows.
    struct BackupExport: Equatable {
        let entries: Int
        let files: Int
        let omittedFiles: Int
    }

    /// Writes the entries `accountIDs` to `url`, which the user chose in the save panel BEFORE this call, as a backup: sealed under
    /// `password` (a `.wsurfvault` file), or plain JSON when `password` is nil. The stamps are proved against the vault here, after
    /// that panel: a changed or removed entry, a lock or a cancel writes nothing and leaves whatever is at `url` as it was. A file the
    /// vault cannot read (missing or damaged) is left out and counted.
    func exportBackup(
        accountIDs: [UUID],
        expectedStamps: [UUID: AccountStamp],
        epoch: UInt64,
        from manager: CredentialManager,
        to url: URL,
        password: String?
    ) async throws -> BackupExport {
        do {
            guard !accountIDs.isEmpty else { throw CredentialExchangeCoordinatorError.emptySelection }
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            let snapshot = try await manager.snapshot()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            let byID = Dictionary(snapshot.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var chosen: [CredentialAccount] = []
            for id in Set(accountIDs) {
                guard let known = expectedStamps[id], snapshot.stamps[id] == known, let account = byID[id] else {
                    throw CredentialVaultError.staleRevision
                }
                chosen.append(account)
            }
            // The vault's own order, so two backups of the same vault list the same entries the same way.
            let order = Dictionary(snapshot.accounts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            chosen.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            let files = try await Self.readFiles(of: chosen, from: manager)
            let vaultName = try await manager.displayNames().vault
            try Task.checkCancellation()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            let built = try VaultBackupCodec.backup(of: chosen, files: files, vaultName: vaultName, exportedAt: now())
            let backup = built.backup
            let iterations = backupIterations
            let data = try await Task.detached {
                var json = try VaultBackupCodec.encode(backup)
                guard let password else { return json }
                defer { json.resetBytes(in: 0..<json.count) }
                return try await VaultBackupCodec.seal(json, password: password, iterations: iterations)
            }.value
            try Task.checkCancellation()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            try CredentialCSV.save(data, to: url, temporaryName: ".wsurf-backup-\(UUID().uuidString).tmp")
            let result = BackupExport(
                entries: backup.accounts.count, files: backup.files.count, omittedFiles: built.omitted.files
            )
            onMessage?(.backupExported(
                entries: result.entries, files: result.files, omittedFiles: result.omittedFiles, encrypted: password != nil
            ))
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch CredentialExchangeCoordinatorError.emptySelection {
            throw CredentialExchangeCoordinatorError.emptySelection
        } catch CredentialCSVError.notWritten {
            throw end(.backupNotSaved())
        } catch VaultBackupError.tooLarge {
            throw end(.backupNotSaved(tooLarge: true))
        } catch {
            switch error {
            case CredentialVaultError.unauthorized, CredentialVaultError.expired, CredentialVaultError.staleRevision:
                throw end(.exportSelectionChanged())
            default:
                throw end(.exportNotSent())
            }
        }
    }

    /// The plaintext of every file `accounts` keep, by attachment id. A file that is missing from the vault's folder or does not
    /// decrypt is left out; any other failure (a lock, a cancel) ends the export. Each file passes through a private folder of its
    /// own that is removed before this returns.
    private static func readFiles(of accounts: [CredentialAccount], from manager: CredentialManager) async throws -> [UUID: Data] {
        let wanted = accounts.flatMap { $0.attachments ?? [] }
        guard !wanted.isEmpty else { return [:] }
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appending(path: "wsurf-backup-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: folder) }
        var files: [UUID: Data] = [:]
        var total: Int64 = 0
        for file in wanted {
            try Task.checkCancellation()
            total += file.size
            guard total <= VaultBackupCodec.fileBytesLimit else { throw VaultBackupError.tooLarge }
            let destination = folder.appending(path: file.id.uuidString, directoryHint: .notDirectory)
            defer { try? fileManager.removeItem(at: destination) }
            do {
                try await manager.readAttachment(file, to: destination)
            } catch VaultFileError.missing, VaultFileError.damaged {
                continue
            }
            files[file.id] = try Data(contentsOf: destination)
        }
        return files
    }

    /// Stores the backup's files that the plan puts into `touched` and that the saved entry does not already hold, and puts the
    /// stored record in each one's place. `stored` collects every file stored, so the caller can discard them if the commit fails.
    static func storingFiles(
        of backup: VaultBackupCodec.Staged, in touched: [CredentialAccount], base: StoreSnapshot, manager: CredentialManager,
        stored: inout Set<UUID>
    ) async throws -> [CredentialAccount] {
        let held = Dictionary(base.accounts.map { ($0.id, Set(($0.attachments ?? []).map(\.id))) }, uniquingKeysWith: { first, _ in first })
        var result = touched
        for index in result.indices {
            guard var files = result[index].attachments else { continue }
            for at in files.indices {
                let file = files[at]
                guard held[result[index].id]?.contains(file.id) != true, let contents = backup.files[file.id] else { continue }
                try Task.checkCancellation()
                let restored = try await manager.restoreAttachment(contents, as: file)
                stored.insert(restored.id)
                files[at] = restored
            }
            result[index].attachments = files
        }
        return result
    }

    /// The backup in `data`: a `.wsurfvault` file opened with `password`, or a plain JSON backup. Off the main actor: the key
    /// derivation and the decoding take a moment. The decrypted JSON is overwritten once decoded.
    func readBackup(_ data: Data, password: String?) async throws -> VaultBackup {
        let iterations = backupIterations
        return try await Task.detached {
            guard VaultBackupCodec.isEncrypted(data) else { return try VaultBackupCodec.decode(data) }
            guard let password else { throw VaultBackupError.emptyPassword }
            var json = try await VaultBackupCodec.open(data, password: password, minimumIterations: iterations)
            defer { json.resetBytes(in: 0..<json.count) }
            return try VaultBackupCodec.decode(json)
        }.value
    }
}
