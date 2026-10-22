// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A file kept with a vault entry: a scan, a PDF, a ZIP, anything. The bytes are not in the record. They are a separate encrypted
/// file in the vault's folder (`VaultBlob`), named by `id`, under a key of their own; the record holds that key wrapped under the
/// vault's file key (`wrappedKey`, whose tag binds it to `id`, `size` and `sha256`). So a vault read, which opens every record, never
/// opens a file, and a file is decrypted only when someone asks for it. Like every other part of a record it is never named in a log
/// and never reaches the assistant or an MCP client.
public nonisolated struct CredentialAttachment: Codable, Sendable, Equatable, Identifiable {
    /// The encrypted file's random name. Two copies of the same document get different ids, so nothing on disk links them.
    public var id: UUID
    public var name: String
    /// The uniform type identifier (`public.jpeg`, `com.adobe.pdf`…), for the icon and the apps that open it.
    public var contentType: String
    public var size: Int64
    /// SHA-256 of the plaintext, checked every time the file is decrypted.
    var sha256: Data
    /// The file's own AES-256 key, sealed with AES-GCM under the vault's file key: 12-byte nonce, 32 bytes, 16-byte tag.
    var wrappedKey: Data
    var addedAt: Date?

    /// Owner decision 3. Decimal megabytes and gigabytes, as Finder counts them.
    public static let fileBytes: Int64 = 50_000_000
    public static let vaultBytes: Int64 = 2_000_000_000
    public static let entryLimit = 64
    static let nameBytes = 1_024
    static let wrappedKeyBytes = 60

    func validate() throws {
        guard !name.isEmpty, name.utf8.count <= Self.nameBytes, !name.contains("\u{0}"),
              !contentType.isEmpty, contentType.utf8.count <= 256,
              (0...Self.fileBytes).contains(size), sha256.count == 32, wrappedKey.count == Self.wrappedKeyBytes
        else { throw CredentialVaultError.invalidData }
    }

    /// The bytes the live files of `accounts` take: what the 2 GB vault limit counts. Earlier versions and the Trash keep their files
    /// until a purge, outside this count.
    static func liveBytes(of accounts: [CredentialAccount]) -> Int64 {
        var total: Int64 = 0
        for account in accounts {
            for file in account.attachments ?? [] {
                total += file.size
            }
        }
        return total
    }
}

/// Why a file was not added, saved or opened. It names the rule or the file's own name, never its content.
public nonisolated enum VaultFileError: Error, Equatable, Sendable {
    /// Over `CredentialAttachment.fileBytes`.
    case tooLarge(name: String)
    /// The entry already holds `CredentialAttachment.entryLimit` files.
    case entryFull
    /// The vault's live files would pass `CredentialAttachment.vaultBytes`.
    case vaultFull
    /// The chosen item is not a regular file, or it could not be read to its end.
    case unreadable(name: String)
    /// The encrypted file is not in the vault's folder (for example after restoring only the store from a backup).
    case missing
    /// The encrypted file does not open under its key, or what it decrypts to is not the file that was added.
    case damaged
}

nonisolated extension VaultFileError {
    public var message: String {
        let limit = ByteCountFormatter.string(fromByteCount: CredentialAttachment.fileBytes, countStyle: .file)
        let vault = ByteCountFormatter.string(fromByteCount: CredentialAttachment.vaultBytes, countStyle: .file)
        switch self {
        case .tooLarge(let name):
            return String(localized: "“\(name)” is larger than \(limit). Each file in the vault can be up to \(limit).")
        case .entryFull:
            return String(localized: "An entry can hold up to \(CredentialAttachment.entryLimit) files. Remove one to add another.")
        case .vaultFull:
            return String(localized: "The files in this vault would take more than \(vault). Remove files from entries to make room.")
        case .unreadable(let name):
            return String(localized: "“\(name)” couldn’t be read. Choose a file, not a folder, and try again.")
        case .missing:
            return String(localized: "This file is missing from the vault’s folder. Restore the vault’s files from a backup, or remove the file.")
        case .damaged:
            return String(localized: "This file couldn’t be decrypted. It may be damaged. Nothing was saved or opened.")
        }
    }
}
