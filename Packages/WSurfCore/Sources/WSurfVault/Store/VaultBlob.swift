// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The encrypted files of a vault (`CredentialAttachment`), one per attachment, beside the store:
/// `<support>/Credentials.blobs/<vaultID>/<blobID>.wsb`. A vault and its Trash share the folder, so moving an entry to the Trash and
/// back never touches a file. Folders are 0700 and files 0600. Like the store they are backed up, and only ciphertext ever is.
///
/// A file is `magic ‖ chunk₀ ‖ … ‖ chunkₙ₋₁`. The plaintext is cut into 1 MiB chunks, the last one padded with zeros so the whole is a
/// multiple of 4 KiB (the size on disk tells the size only to 4 KiB), and each chunk is sealed with AES-256-GCM under the file's own
/// random key with the AAD `label ‖ blobID ‖ index ‖ isFinal`, so a truncated, reordered or swapped chunk, or one of another file, fails
/// to open. The number and lengths of the chunks follow from the size sealed in the record, so a file of any other length is refused
/// before anything is decrypted, and the plaintext's SHA-256 is checked at the end. Memory is two chunks, whatever the file's size.
nonisolated enum VaultBlob {
    static let folderName = "Credentials.blobs"
    static let chunkBytes = 1_048_576
    static let padding = 4_096
    static let magic = Data("WSURFB01".utf8)
    /// AES-GCM's nonce and tag around each chunk.
    static let chunkOverhead = 28
    private static let chunkLabel = "WSurf vault file v1"
    private static let keyLabel = "WSurf vault file key v1"

    // MARK: Paths

    static func folder(in support: URL, vaultID: UUID) -> URL {
        support.appending(path: folderName, directoryHint: .isDirectory)
            .appending(path: vaultID.uuidString.lowercased(), directoryHint: .isDirectory)
    }

    static func file(_ id: UUID, in folder: URL) -> URL {
        folder.appending(path: "\(id.uuidString.lowercased()).wsb", directoryHint: .notDirectory)
    }

    /// A file still being written, which nothing refers to yet.
    static func partial(_ id: UUID, in folder: URL) -> URL {
        folder.appending(path: ".\(id.uuidString.lowercased()).partial", directoryHint: .notDirectory)
    }

    /// The ids of the finished files in `folder`, and of the half-written ones. A missing folder holds neither.
    static func contents(of folder: URL) -> (stored: Set<UUID>, partial: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return ([], []) }
        var stored = Set<UUID>()
        var partial = Set<UUID>()
        for name in names {
            if name.hasSuffix(".wsb"), let id = UUID(uuidString: String(name.dropLast(4))) {
                stored.insert(id)
            } else if name.hasPrefix("."), name.hasSuffix(".partial"), let id = UUID(uuidString: String(name.dropFirst().dropLast(8))) {
                partial.insert(id)
            }
        }
        return (stored, partial)
    }

    /// Whether the file was there and is gone now.
    @discardableResult
    static func remove(_ id: UUID, in folder: URL) -> Bool {
        (try? FileManager.default.removeItem(at: file(id, in: folder))) != nil
    }

    static func removePartial(_ id: UUID, in folder: URL) {
        try? FileManager.default.removeItem(at: partial(id, in: folder))
    }

    // MARK: Keys

    /// The vault's file key: HKDF-SHA256 of the vault key, bound to the store and the vault. It wraps the vault's file keys and nothing
    /// else, so the vault key itself never leaves the store.
    static func fileKey(dek: SymmetricKey, ids: StoreIDs, vaultID: UUID) -> SymmetricKey {
        var info = StoreWriter()
        info.text("WSurf vault files v1")
        ids.write(to: &info)
        info.uuid(vaultID)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: dek, info: info.data, outputByteCount: 32)
    }

    /// `key` sealed under the vault's file key. The tag binds it to the file's id, size and plaintext digest: a record that names
    /// another file, or claims another size or content, does not unwrap.
    static func wrap(_ key: SymmetricKey, under fileKey: SymmetricKey, id: UUID, size: Int64, sha256: Data) throws -> Data {
        let bytes = key.withUnsafeBytes { Data($0) }
        guard let combined = try AES.GCM.seal(bytes, using: fileKey, authenticating: keyAAD(id, size, sha256)).combined else {
            throw VaultFileError.damaged
        }
        return combined
    }

    static func unwrap(_ file: CredentialAttachment, under fileKey: SymmetricKey) throws -> SymmetricKey {
        do {
            let bytes = try AES.GCM.open(
                AES.GCM.SealedBox(combined: file.wrappedKey), using: fileKey, authenticating: keyAAD(file.id, file.size, file.sha256)
            )
            guard bytes.count == 32 else { throw VaultFileError.damaged }
            return SymmetricKey(data: bytes)
        } catch {
            throw VaultFileError.damaged
        }
    }

    private static func keyAAD(_ id: UUID, _ size: Int64, _ sha256: Data) -> Data {
        var writer = StoreWriter()
        writer.text(keyLabel)
        writer.uuid(id)
        writer.u64(UInt64(clamping: size))
        writer.bytes(sha256)
        return writer.data
    }

    private static func chunkAAD(_ id: UUID, index: Int, isFinal: Bool) -> Data {
        var writer = StoreWriter()
        writer.text(chunkLabel)
        writer.uuid(id)
        writer.u64(UInt64(index))
        writer.bool(isFinal)
        return writer.data
    }

    // MARK: Layout

    /// The plaintext length of each chunk of a file of `size` bytes: whole chunks, then the rest padded to 4 KiB (at least one 4 KiB
    /// chunk, so an empty file is a file too).
    static func chunkLengths(size: Int64) -> [Int] {
        let step = Int64(padding)
        var left = max(step, (size + step - 1) / step * step)
        var lengths: [Int] = []
        while left > 0 {
            let length = min(Int64(chunkBytes), left)
            lengths.append(Int(length))
            left -= length
        }
        return lengths
    }

    /// The exact length of the encrypted file of a `size`-byte attachment.
    static func storedBytes(size: Int64) -> Int64 {
        chunkLengths(size: size).reduce(Int64(magic.count)) { $0 + Int64($1 + chunkOverhead) }
    }

    // MARK: Writing

    /// Encrypts `source` into `folder` as file `id` under a fresh key, and returns its record with that key wrapped under `fileKey`.
    /// It is written as `.partial`, flushed to disk, then renamed: a crash leaves a partial file, which a later sweep removes, and never
    /// a finished file that is cut short. Off every actor: a 50 MB file takes a moment.
    @concurrent
    static func write(
        from source: URL, id: UUID, into folder: URL, fileKey: SymmetricKey, fileOps: StoreFileOps, now: Date
    ) async throws -> CredentialAttachment {
        let name = source.lastPathComponent
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey]),
              values.isRegularFile == true, let rawSize = values.fileSize
        else { throw VaultFileError.unreadable(name: name) }
        let size = Int64(rawSize)
        guard size <= CredentialAttachment.fileBytes else { throw VaultFileError.tooLarge(name: name) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let key = SymmetricKey(size: .bits256)
        let temp = partial(id, in: folder)
        let finished = file(id, in: folder)
        do {
            let digest = try encrypt(source, name: name, size: size, key: key, id: id, to: temp)
            try fileOps.fullFsync(temp)
            try fileOps.renameExclusive(temp, finished)
            try fileOps.fsyncDirectory(folder)
            return CredentialAttachment(
                id: id, name: name, contentType: values.contentType?.identifier ?? UTType.data.identifier, size: size, sha256: digest,
                wrappedKey: try wrap(key, under: fileKey, id: id, size: size, sha256: digest), addedAt: now
            )
        } catch {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: finished)
            throw error
        }
    }

    /// Streams exactly `size` bytes of `source` into `temp`, sealed chunk by chunk; returns the plaintext's SHA-256.
    private static func encrypt(_ source: URL, name: String, size: Int64, key: SymmetricKey, id: UUID, to temp: URL) throws -> Data {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw VaultFileError.unreadable(name: name)
        }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: temp.path, contents: magic, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        try output.seekToEnd()
        var hash = SHA256()
        var left = size
        let lengths = chunkLengths(size: size)
        for (index, length) in lengths.enumerated() {
            try Task.checkCancellation()
            let wanted = Int(min(Int64(length), left))
            var chunk = try readFully(input, count: wanted)
            // A file that shrank while it was read is not stored half; one that grew keeps the size it had when it was chosen.
            guard chunk.count == wanted else { throw VaultFileError.unreadable(name: name) }
            hash.update(data: chunk)
            left -= Int64(wanted)
            chunk.append(Data(count: length - wanted))
            guard let sealed = try AES.GCM.seal(chunk, using: key, authenticating: chunkAAD(id, index: index, isFinal: index == lengths.count - 1))
                .combined
            else { throw VaultFileError.damaged }
            try output.write(contentsOf: sealed)
        }
        try output.close()
        return Data(hash.finalize())
    }

    // MARK: Reading

    /// Decrypts the file of `attachment` into `destination` (replacing it), through a 0600 partial file beside it that is removed on any
    /// failure: a damaged file never leaves half a plaintext behind. Off every actor.
    @concurrent
    static func read(_ attachment: CredentialAttachment, in folder: URL, fileKey: SymmetricKey, to destination: URL) async throws {
        let source = file(attachment.id, in: folder)
        guard StoreAnchors.exists(source) else { throw VaultFileError.missing }
        let stored = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value
        guard stored == storedBytes(size: attachment.size) else { throw VaultFileError.damaged }
        let key = try unwrap(attachment, under: fileKey)
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw VaultFileError.damaged
        }
        defer { try? input.close() }
        guard try readFully(input, count: magic.count) == magic else { throw VaultFileError.damaged }
        let temp = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).partial", directoryHint: .notDirectory)
        guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            try decrypt(attachment, key: key, from: input, to: temp)
            if StoreAnchors.exists(destination) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    private static func decrypt(_ attachment: CredentialAttachment, key: SymmetricKey, from input: FileHandle, to temp: URL) throws {
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        var hash = SHA256()
        var left = attachment.size
        let lengths = chunkLengths(size: attachment.size)
        for (index, length) in lengths.enumerated() {
            try Task.checkCancellation()
            let sealed = try readFully(input, count: length + chunkOverhead)
            let plain: Data
            do {
                plain = try AES.GCM.open(
                    AES.GCM.SealedBox(combined: sealed), using: key,
                    authenticating: chunkAAD(attachment.id, index: index, isFinal: index == lengths.count - 1)
                )
            } catch {
                throw VaultFileError.damaged
            }
            guard plain.count == length else { throw VaultFileError.damaged }
            let kept = plain.prefix(Int(min(Int64(length), left)))
            hash.update(data: kept)
            left -= Int64(kept.count)
            try output.write(contentsOf: kept)
        }
        try output.close()
        guard left == 0, Data(hash.finalize()) == attachment.sha256 else { throw VaultFileError.damaged }
    }

    /// Up to `count` bytes, fewer only at the end of the file.
    private static func readFully(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let more = try handle.read(upToCount: count - data.count), !more.isEmpty else { break }
            data.append(more)
        }
        return data
    }
}
