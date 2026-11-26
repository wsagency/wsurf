// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CommonCrypto
import CryptoKit
import Foundation

/// A complete, portable copy of vault entries: every `CredentialAccount` record as the vault keeps it (logins with and without a
/// website, passkeys with their private keys and flags, verification code setups, notes, cards and the other items) and the plaintext
/// of every file kept with them. It is the payload of both backup formats: a plain JSON file, which the user protects, and a
/// `.wsurfvault` file, which seals the same JSON under a password (`VaultBackupCodec.seal`). Nothing in it depends on the vault key.
public nonisolated struct VaultBackup: Codable, Sendable, Equatable {
    public static let formatName = "wsurf-vault-backup"
    public static let currentVersion = 1

    /// The plaintext of one attachment, by the attachment's id in the account that names it.
    public struct File: Codable, Sendable, Equatable {
        public let id: UUID
        public let contents: Data

        public init(id: UUID, contents: Data) {
            self.id = id
            self.contents = contents
        }
    }

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var vaultName: String?
    public var accounts: [CredentialAccount]
    public var files: [File]
}

/// Why a backup could not be written or read. It never carries a value, a name or the system's own text.
public nonisolated enum VaultBackupError: Error, Equatable, Sendable {
    /// The password is wrong, or the encrypted file was changed or cut short. The two cannot be told apart, by design.
    case wrongPasswordOrCorrupted
    /// The file is not a WSurf backup, or not one this version reads.
    case notABackup
    /// The backup, or its files, are over `VaultBackupCodec`'s limits.
    case tooLarge
    /// An entry or a file in the backup does not pass the vault's own checks.
    case invalidContent
    /// An encrypted backup needs a password that is not empty.
    case emptyPassword
}

public nonisolated enum VaultBackupCodec {
    // MARK: Limits

    // ponytail: the whole backup is held in memory (base64 inside JSON, then sealed), about four copies at peak; a streaming
    // container is the upgrade path if backups of the vault's full 2 GB of files are needed.
    /// The most plaintext bytes of files one backup carries.
    public static let fileBytesLimit: Int64 = 256_000_000
    /// The most bytes of a backup file, encrypted or not, that are read or written.
    public static let fileSizeLimit = 512_000_000

    // MARK: Building

    /// What `backup(of:)` left out because the vault could not read its bytes: the files, and the entries that held nothing else.
    public struct Omitted: Sendable, Equatable {
        public var files = 0
        public var entries = 0
    }

    /// The backup of `accounts`, with the plaintext of their files from `files` (by attachment id). A file whose bytes are not in
    /// `files` is left out of its entry, and an entry left with nothing is left out: the backup never names a file it cannot restore.
    /// Each file's wrapped key is the vault's own key-wrapping material, so it is zeroed: a restore stores every file under a new key.
    public static func backup(
        of accounts: [CredentialAccount], files: [UUID: Data], vaultName: String?, exportedAt: Date
    ) throws -> (backup: VaultBackup, omitted: Omitted) {
        var omitted = Omitted()
        var kept: [CredentialAccount] = []
        var carried: [VaultBackup.File] = []
        var total: Int64 = 0
        for var account in accounts {
            let all = account.attachments ?? []
            let readable = all.filter { files[$0.id] != nil }.map { file in
                var copy = file
                copy.wrappedKey = Data(count: CredentialAttachment.wrappedKeyBytes)
                return copy
            }
            omitted.files += all.count - readable.count
            account.attachments = readable.isEmpty ? nil : readable
            guard account.holdsContent else {
                omitted.entries += 1
                continue
            }
            for file in readable {
                guard let contents = files[file.id] else { continue }
                total += Int64(contents.count)
                guard total <= fileBytesLimit else { throw VaultBackupError.tooLarge }
                carried.append(VaultBackup.File(id: file.id, contents: contents))
            }
            kept.append(account)
        }
        let backup = VaultBackup(
            format: VaultBackup.formatName, version: VaultBackup.currentVersion, exportedAt: exportedAt, vaultName: vaultName,
            accounts: kept, files: carried
        )
        try validate(backup)
        return (backup, omitted)
    }

    /// The backup as JSON: sorted keys and indented, so a person can read the plain file; data is base64.
    public static func encode(_ backup: VaultBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(backup)
        guard data.count <= fileSizeLimit else { throw VaultBackupError.tooLarge }
        return data
    }

    /// The backup in `json`, checked whole: its format and version, every entry by the vault's own rules, and every file against the
    /// size and SHA-256 its entry records. Any problem refuses the whole backup.
    public static func decode(_ json: Data) throws -> VaultBackup {
        guard json.count <= fileSizeLimit else { throw VaultBackupError.tooLarge }
        let backup: VaultBackup
        do {
            backup = try JSONDecoder().decode(VaultBackup.self, from: json)
        } catch {
            throw VaultBackupError.notABackup
        }
        guard backup.format == VaultBackup.formatName, backup.version == VaultBackup.currentVersion else {
            throw VaultBackupError.notABackup
        }
        try validate(backup)
        return backup
    }

    private static func validate(_ backup: VaultBackup) throws {
        guard backup.accounts.count <= CredentialVaultLimits.accounts,
              (backup.vaultName?.utf8.count ?? 0) <= 2_048 else { throw VaultBackupError.tooLarge }
        var described: [UUID: CredentialAttachment] = [:]
        do {
            for account in backup.accounts {
                try account.validate()
                for file in account.attachments ?? [] {
                    guard described.updateValue(file, forKey: file.id) == nil else { throw VaultBackupError.invalidContent }
                }
            }
        } catch let error as VaultBackupError {
            throw error
        } catch {
            throw VaultBackupError.invalidContent
        }
        var seen = Set<UUID>()
        var total: Int64 = 0
        for file in backup.files {
            total += Int64(file.contents.count)
            guard total <= fileBytesLimit else { throw VaultBackupError.tooLarge }
            guard seen.insert(file.id).inserted, let record = described[file.id], record.size == Int64(file.contents.count),
                  Data(SHA256.hash(data: file.contents)) == record.sha256 else { throw VaultBackupError.invalidContent }
        }
    }

    // MARK: Password encryption

    /// The `.wsurfvault` container: `magic | version | kdf | iterations (UInt32, big-endian) | salt (32) | nonce (12)`, then the
    /// AES-256-GCM ciphertext and its 16-byte tag. The whole header is the AAD, so a changed byte anywhere fails to open. The key is
    /// PBKDF2-HMAC-SHA256 of the password's UTF-8 bytes over the salt. Salt and nonce are fresh for every file.
    static let magic = Data("WSURFBAK".utf8)
    static let containerVersion: UInt8 = 1
    static let pbkdf2SHA256: UInt8 = 1
    static let saltBytes = 32
    static let nonceBytes = 12
    static let headerBytes = 8 + 1 + 1 + 4 + 32 + 12
    /// OWASP's 2023 figure for PBKDF2-HMAC-SHA256.
    public static let defaultIterations: UInt32 = 600_000
    /// The most rounds a file may ask for, so a changed or hostile header cannot make opening it run for hours.
    static let maximumIterations: UInt32 = 10_000_000

    /// Whether `data` is a `.wsurfvault` container rather than plain JSON.
    public static func isEncrypted(_ data: Data) -> Bool {
        data.prefix(magic.count) == magic
    }

    /// Seals `plaintext` under `password` with `defaultIterations` rounds: no caller can write a weaker file. Off every actor: the key
    /// derivation takes a moment by design.
    @concurrent
    public static func seal(_ plaintext: Data, password: String) async throws -> Data {
        try await seal(plaintext, password: password, iterations: defaultIterations)
    }

    /// Opens a `.wsurfvault` container that asks for at least `defaultIterations` rounds.
    @concurrent
    public static func open(_ container: Data, password: String) async throws -> Data {
        try await open(container, password: password, minimumIterations: defaultIterations)
    }

    /// Whether `container` is a `.wsurfvault` file WSurf can try a password on: its header is whole, of a version and key derivation
    /// this build reads, and asks for a number of rounds `open` accepts. A file that fails this is damaged or from a newer build, and
    /// no password opens it, so the import says so instead of asking for one.
    public static func isOpenable(_ container: Data, minimumIterations: UInt32 = defaultIterations) -> Bool {
        guard container.count >= headerBytes + 16, container.count <= fileSizeLimit else { return false }
        let bytes = container.prefix(headerBytes).map { $0 }
        guard Data(bytes[0..<8]) == magic, bytes[8] == containerVersion, bytes[9] == pbkdf2SHA256 else { return false }
        let iterations = bytes[10..<14].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return iterations >= minimumIterations && iterations <= maximumIterations
    }

    /// `seal` with another number of rounds, for tests that cannot spend the default work factor on every case.
    @concurrent
    static func seal(_ plaintext: Data, password: String, iterations: UInt32) async throws -> Data {
        guard !password.isEmpty else { throw VaultBackupError.emptyPassword }
        guard iterations > 0, iterations <= maximumIterations else { throw VaultBackupError.invalidContent }
        guard plaintext.count + headerBytes + 16 <= fileSizeLimit else { throw VaultBackupError.tooLarge }
        let salt = try randomBytes(saltBytes)
        let nonce = try AES.GCM.Nonce(data: randomBytes(nonceBytes))
        var header = magic
        header.append(containerVersion)
        header.append(pbkdf2SHA256)
        withUnsafeBytes(of: iterations.bigEndian) { header.append(contentsOf: $0) }
        header.append(salt)
        header.append(contentsOf: nonce)
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
        return header + sealed.ciphertext + sealed.tag
    }

    /// Opens a `.wsurfvault` container. Every way it can fail is `wrongPasswordOrCorrupted`. `minimumIterations` refuses a file that
    /// asks for fewer rounds than WSurf writes; tests lower it to stay fast.
    @concurrent
    static func open(_ container: Data, password: String, minimumIterations: UInt32) async throws -> Data {
        guard container.count <= fileSizeLimit else { throw VaultBackupError.tooLarge }
        guard !password.isEmpty else { throw VaultBackupError.emptyPassword }
        let bytes = [UInt8](container)
        guard bytes.count >= headerBytes + 16, Data(bytes[0..<8]) == magic, bytes[8] == containerVersion, bytes[9] == pbkdf2SHA256
        else { throw VaultBackupError.wrongPasswordOrCorrupted }
        let iterations = bytes[10..<14].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard iterations >= minimumIterations, iterations <= maximumIterations else { throw VaultBackupError.wrongPasswordOrCorrupted }
        let header = Data(bytes[0..<headerBytes])
        let salt = Data(bytes[14..<46])
        do {
            let nonce = try AES.GCM.Nonce(data: bytes[46..<headerBytes])
            let box = try AES.GCM.SealedBox(
                nonce: nonce, ciphertext: bytes[headerBytes..<(bytes.count - 16)], tag: bytes[(bytes.count - 16)...]
            )
            let key = try deriveKey(password: password, salt: salt, iterations: iterations)
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw VaultBackupError.wrongPasswordOrCorrupted
        }
    }

    /// PBKDF2-HMAC-SHA256. The password's bytes and the derived bytes are overwritten before returning; CryptoKit keeps its own copy
    /// of the key and erases it when released. A Swift `String` cannot be erased: the caller drops its own as soon as it can.
    private static func deriveKey(password: String, salt: Data, iterations: UInt32) throws -> SymmetricKey {
        var secret = [UInt8](password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        defer {
            _ = memset_s(&secret, secret.count, 0, secret.count)
            _ = memset_s(&derived, derived.count, 0, derived.count)
        }
        let status = salt.withUnsafeBytes { saltBytes in
            secret.withUnsafeBufferPointer { passwordBytes in
                passwordBytes.withMemoryRebound(to: Int8.self) { password in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress, password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress, saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, &derived, derived.count
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw VaultBackupError.wrongPasswordOrCorrupted }
        return SymmetricKey(data: derived)
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw VaultBackupError.invalidContent }
        return Data(bytes)
    }
}

// MARK: - Restore

nonisolated extension VaultBackupCodec {
    /// A backup staged against a vault for the import review. Its candidates are the backup's entries under fresh local ids, with the
    /// exporter identity a Credential Exchange export gives them (their own, else one their original id gives), so a backup restored
    /// into the vault it came from finds every entry it holds and changes nothing that is the same.
    public struct Staged: Sendable {
        public let preview: CredentialImportPreview
        /// Entries that keep only files: they have no part the review decides, so they are added, or their files go to the entry that
        /// already holds their item.
        public let fileOnly: [CredentialAccount]
        /// The plaintext of every file the candidates name, by the id the backup gave it.
        public let files: [UUID: Data]
        /// File-only entries the vault deleted since (in its Trash, or purged): they are not restored, as a deleted credential an import
        /// meets is not, and the review says how many.
        public var removedFileOnly = 0

        /// The files the candidates and the file-only entries name.
        public var fileCount: Int {
            (preview.candidates + fileOnly).reduce(0) { $0 + ($1.attachments?.count ?? 0) }
        }
    }

    /// `removed` is what the vault deleted (`ProfileVaultStore.removedIdentifiers`); a file-only entry whose item no saved entry holds
    /// and the vault deleted is left out.
    public static func stage(
        _ backup: VaultBackup, against base: StoreSnapshot, removed: RemovedIdentifiers? = nil
    ) throws -> Staged {
        try CredentialExchangeCodec.validateAccounts(base.accounts, blockedOrigins: base.blockedPasswordOrigins)
        let files = Dictionary(backup.files.map { ($0.id, $0.contents) }, uniquingKeysWith: { first, _ in first })
        var candidates: [CredentialAccount] = []
        var fileOnly: [CredentialAccount] = []
        for original in backup.accounts {
            var candidate = original
            candidate.id = UUID()
            candidate.exchangeAccountID = try CredentialExchangeCodec.externalID(original.exchangeAccountID, fallback: original.id)
            candidate.exchangeItemID = try CredentialExchangeCodec.externalID(original.exchangeItemID, fallback: original.id)
            candidate.passkeys = original.passkeys.map { passkey in
                var copy = passkey
                copy.id = UUID()
                return copy
            }
            // Links to other entries of the vault it came from, by their ids there: they mean nothing in another vault.
            candidate.mergedFrom = nil
            candidate.notSameAs = nil
            candidate.importTrace = nil
            // A file the backup has no bytes for cannot be restored, so it is not named.
            let restorable = original.attachments?.filter { files[$0.id] != nil } ?? []
            candidate.attachments = restorable.isEmpty ? nil : restorable
            guard candidate.holdsContent else { continue }
            if CredentialExchangeCodec.identities(in: candidate).isEmpty {
                fileOnly.append(candidate)
            } else {
                candidates.append(candidate)
            }
        }
        do {
            try CredentialExchangeCodec.validateAccounts(candidates + fileOnly)
        } catch {
            throw VaultBackupError.invalidContent
        }
        let conflicts = try CredentialExchangeCodec.makeConflicts(candidates, against: base.accounts)
        let held = try itemHolders(base.accounts)
        var deleted = Set<CredentialExchangeCodec.ExternalItemID>()
        for item in removed?.items ?? [] where item.passkeyCredentialID == nil {
            deleted.insert(CredentialExchangeCodec.ExternalItemID(
                account: try CredentialExchangeCodec.externalID(item.exchangeAccountID, fallback: item.accountID),
                item: try CredentialExchangeCodec.externalID(item.exchangeItemID, fallback: item.accountID)
            ))
        }
        let restorable = try fileOnly.filter { entry in
            let key = try CredentialExchangeCodec.externalItemID(for: entry)
            return held[key] != nil || !deleted.contains(key)
        }
        var staged = Staged(
            preview: CredentialImportPreview(base: base, candidates: candidates, conflicts: conflicts), fileOnly: restorable, files: files
        )
        staged.removedFileOnly = fileOnly.count - restorable.count
        return staged
    }

    /// The account that holds each item: its own, or one merged into it (`MergedItemLink`), so an item merged away is found in the
    /// credential it went into and never added again beside it. An account's own item wins over a merged one.
    static func itemHolders(_ accounts: [CredentialAccount]) throws -> [CredentialExchangeCodec.ExternalItemID: UUID] {
        var holders: [CredentialExchangeCodec.ExternalItemID: UUID] = [:]
        for account in accounts {
            holders[try CredentialExchangeCodec.externalItemID(for: account)] = account.id
        }
        for account in accounts {
            for link in account.mergedFrom ?? [] where holders[link.identity] == nil {
                holders[link.identity] = account.id
            }
        }
        return holders
    }

    /// What the import adds to the plan the review's choices made (`touched`, the accounts it writes) so nothing of the backup is lost:
    /// an entry the import creates gets the dates and events the backup recorded, and the files of each backup entry go where its item
    /// is after the import (the new entry, or the saved one that holds the same item) unless that entry already holds a file with the
    /// same size and SHA-256. An item merged into another entry since the backup is found in that entry. An item the import puts nowhere
    /// brings no files. A file-only entry joins the saved entry of its item, or is added. The files keep the backup's records: the caller
    /// stores each file before the commit and puts the stored record in its place.
    public static func restoring(
        _ staged: Staged, into touched: [CredentialAccount]
    ) throws -> (touched: [CredentialAccount], added: Int, updated: Int) {
        var result = touched
        var position = Dictionary(result.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // What the import writes wins over what the vault held: an item the plan placed is where the plan put it.
        let holders = try itemHolders(staged.preview.base.accounts).merging(try itemHolders(result)) { _, planned in planned }
        let saved = Dictionary(staged.preview.base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added = 0
        var updated = 0

        func carryFiles(of candidate: CredentialAccount, to id: UUID) throws {
            let at = position[id]
            guard var account = at.map({ result[$0] }) ?? saved[id] else { return }
            var files = account.attachments ?? []
            for file in candidate.attachments ?? [] where !files.contains(where: { $0.hasSameFileContents(as: file) }) {
                files.append(file)
            }
            guard files.count <= CredentialAttachment.entryLimit else { throw CredentialVaultError.invalidData }
            account.attachments = files.isEmpty ? nil : files
            if let at {
                result[at] = account
            } else if account != saved[id] {
                position[id] = result.count
                result.append(account)
                updated += 1
            }
        }

        for candidate in staged.preview.candidates {
            if let at = position[candidate.id] {
                result[at].createdAt = candidate.createdAt
                result[at].modifiedAt = candidate.modifiedAt
                result[at].migratedAt = candidate.migratedAt
                result[at].passwordEvents = candidate.passwordEvents
                result[at].totpEvents = candidate.totpEvents
                try carryFiles(of: candidate, to: candidate.id)
            } else if let holder = holders[try CredentialExchangeCodec.externalItemID(for: candidate)] {
                try carryFiles(of: candidate, to: holder)
            }
        }
        for entry in staged.fileOnly {
            if let holder = holders[try CredentialExchangeCodec.externalItemID(for: entry)] {
                try carryFiles(of: entry, to: holder)
            } else {
                position[entry.id] = result.count
                result.append(entry)
                added += 1
            }
        }
        return (result, added, updated)
    }
}
