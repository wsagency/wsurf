// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// The vault's encrypted files without a store (`VaultBlob`), their limits, and the private folder of decrypted copies. Synthetic bytes
/// in a temporary folder only.
struct VaultAttachmentTests {
    private static let marker = Data("SYNTHETIC-PLAINTEXT-MARKER-4f1e".utf8)

    private struct Place {
        let root: URL
        let fileKey = SymmetricKey(size: .bits256)

        var folder: URL {
            root.appending(path: "blobs", directoryHint: .isDirectory)
        }

        var out: URL {
            root.appending(path: "out", directoryHint: .isDirectory)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "vault-files-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: "out", directoryHint: .isDirectory), withIntermediateDirectories: true)
        }

        /// `count` bytes starting with the marker (when it fits), then a pattern.
        func source(_ name: String = "scan.pdf", bytes count: Int) throws -> (url: URL, data: Data) {
            var data = count >= VaultAttachmentTests.marker.count ? VaultAttachmentTests.marker : Data()
            data.append(contentsOf: (data.count..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let url = root.appending(path: name, directoryHint: .notDirectory)
            try data.write(to: url)
            return (url, data)
        }

        func add(_ source: URL, fileOps: StoreFileOps = .live) async throws -> CredentialAttachment {
            try await VaultBlob.write(
                from: source, id: UUID(), into: folder, fileKey: fileKey, fileOps: fileOps, now: Date(timeIntervalSinceReferenceDate: 800_000_000)
            )
        }

        func open(_ file: CredentialAttachment, key: SymmetricKey? = nil) async throws -> Data {
            let destination = out.appending(path: "copy", directoryHint: .notDirectory)
            try await VaultBlob.read(file, in: folder, fileKey: key ?? fileKey, to: destination)
            return try Data(contentsOf: destination)
        }

        func stored(_ file: CredentialAttachment) throws -> Data {
            try Data(contentsOf: VaultBlob.file(file.id, in: folder))
        }

        func replaceStored(_ file: CredentialAttachment, with data: Data) throws {
            try data.write(to: VaultBlob.file(file.id, in: folder))
        }

        func outNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: out.path)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func withPlace(_ body: (Place) async throws -> Void) async throws {
        let place = try Place()
        do { try await body(place) } catch { place.cleanUp(); throw error }
        place.cleanUp()
    }

    private static func mode(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    private static func record(size: Int64 = 10) -> CredentialAttachment {
        CredentialAttachment(
            id: UUID(), name: "scan.pdf", contentType: "com.adobe.pdf", size: size, sha256: Data(count: 32), wrappedKey: Data(count: 60),
            addedAt: nil
        )
    }

    // MARK: - Round trip

    @Test(arguments: [0, 1, 4_096, 1_048_576, 2_621_441])
    func aFileRoundTripsThroughItsEncryptedCopy(size: Int) async throws {
        try await withPlace { place in
            let (url, data) = try place.source(bytes: size)
            let file = try await place.add(url)
            try file.validate()
            #expect(file.name == "scan.pdf" && file.size == Int64(size) && file.sha256 == Data(SHA256.hash(data: data)))
            #expect(file.contentType == "com.adobe.pdf")

            // On disk: the exact padded length, 0600 in a 0700 folder, never the plaintext, nothing half written.
            let stored = try place.stored(file)
            #expect(Int64(stored.count) == VaultBlob.storedBytes(size: Int64(size)))
            #expect((stored.count - VaultBlob.magic.count - VaultBlob.chunkLengths(size: Int64(size)).count * VaultBlob.chunkOverhead) % 4_096 == 0)
            #expect(MoveFixtures.occurrences(of: String(decoding: Self.marker, as: UTF8.self), in: stored) == 0)
            #expect(try Self.mode(VaultBlob.file(file.id, in: place.folder)) == 0o600)
            #expect(try Self.mode(place.folder) == 0o700)
            #expect(VaultBlob.contents(of: place.folder).stored == [file.id] && VaultBlob.contents(of: place.folder).partial.isEmpty)

            #expect(try await place.open(file) == data)
            #expect(try Self.mode(place.out.appending(path: "copy")) == 0o600)
        }
    }

    @Test func theChunksArePaddedToFourKilobytes() {
        #expect(VaultBlob.chunkLengths(size: 0) == [4_096])
        #expect(VaultBlob.chunkLengths(size: 4_097) == [8_192])
        #expect(VaultBlob.chunkLengths(size: 1_048_576) == [1_048_576])
        #expect(VaultBlob.chunkLengths(size: 1_048_577) == [1_048_576, 4_096])
        #expect(VaultBlob.storedBytes(size: 1_048_577) == 8 + 1_048_576 + 28 + 4_096 + 28)
    }

    @Test func eachVaultHasItsOwnFileKey() {
        let dek = SymmetricKey(size: .bits256)
        let ids = StoreIDs(storeID: UUID(), profileID: UUID())
        let first = VaultBlob.fileKey(dek: dek, ids: ids, vaultID: UUID()).withUnsafeBytes { Data($0) }
        let second = VaultBlob.fileKey(dek: dek, ids: ids, vaultID: UUID()).withUnsafeBytes { Data($0) }
        #expect(first != second && first != dek.withUnsafeBytes { Data($0) })
    }

    // MARK: - Tampering

    nonisolated enum Tamper: CaseIterable, Sendable {
        case truncateTail, dropLastChunk, extend, swapChunks, foreignChunk, flipByte, wrongKey, otherSize, otherDigest, otherID
    }

    /// Three chunks (2.5 MiB). Every change refuses with `damaged`, and nothing decrypted is left behind.
    @Test(arguments: Tamper.allCases)
    func aChangedFileOrRecordDoesNotOpen(_ tamper: Tamper) async throws {
        try await withPlace { place in
            let (url, _) = try place.source(bytes: 2_621_441)
            var file = try await place.add(url)
            let stored = try place.stored(file)
            let chunk = VaultBlob.chunkBytes + VaultBlob.chunkOverhead
            let start = { (index: Int) in VaultBlob.magic.count + index * chunk }
            var key: SymmetricKey?
            switch tamper {
            case .truncateTail:
                try place.replaceStored(file, with: stored.dropLast(16))
            case .dropLastChunk:
                try place.replaceStored(file, with: stored.prefix(start(2)))
            case .extend:
                try place.replaceStored(file, with: stored + Data(repeating: 0, count: 4_096))
            case .swapChunks:
                var swapped = stored
                swapped.replaceSubrange(start(0)..<start(1), with: stored[start(1)..<start(2)])
                swapped.replaceSubrange(start(1)..<start(2), with: stored[start(0)..<start(1)])
                try place.replaceStored(file, with: swapped)
            case .foreignChunk:
                let (other, _) = try place.source("other.pdf", bytes: 2_621_441)
                let foreign = try place.stored(try await place.add(other))
                var mixed = stored
                mixed.replaceSubrange(start(1)..<start(2), with: foreign[start(1)..<start(2)])
                try place.replaceStored(file, with: mixed)
            case .flipByte:
                try place.replaceStored(file, with: VaultStoreFixture.flipped(stored))
            case .wrongKey:
                key = SymmetricKey(size: .bits256)
            case .otherSize:
                file.size -= 1
            case .otherDigest:
                file.sha256 = Data(repeating: 0xAB, count: 32)
            case .otherID:
                let moved = UUID()
                try stored.write(to: VaultBlob.file(moved, in: place.folder))
                file.id = moved
            }
            await #expect(throws: VaultFileError.damaged) {
                _ = try await place.open(file, key: key)
            }
            #expect(try place.outNames().isEmpty, "no plaintext, whole or partial, is left")
        }
    }

    @Test func aFileThatIsGoneSaysSo() async throws {
        try await withPlace { place in
            let file = try await place.add(try place.source(bytes: 100).url)
            #expect(VaultBlob.remove(file.id, in: place.folder))
            await #expect(throws: VaultFileError.missing) {
                _ = try await place.open(file)
            }
        }
    }

    // MARK: - Writing safely

    nonisolated enum WriteStep: CaseIterable, Sendable {
        case flush, rename, folder
    }

    /// A failure at any step of the write leaves neither a partial nor a finished file: nothing would refer to it.
    @Test(arguments: WriteStep.allCases)
    func aWriteThatFailsLeavesNothing(_ step: WriteStep) async throws {
        try await withPlace { place in
            var ops = StoreFileOps.live
            let failure = StoreFileError.io(EIO)
            switch step {
            case .flush:
                ops.fullFsync = { _ in throw failure }
            case .rename:
                ops.renameExclusive = { _, _ in throw failure }
            case .folder:
                ops.fsyncDirectory = { _ in throw failure }
            }
            let (url, _) = try place.source(bytes: 5_000)
            await #expect(throws: StoreFileError.io(EIO)) {
                _ = try await place.add(url, fileOps: ops)
            }
            let contents = VaultBlob.contents(of: place.folder)
            #expect(contents.stored.isEmpty && contents.partial.isEmpty)
        }
    }

    // MARK: - Limits

    @Test func aFileOverFiftyMegabytesOrAFolderIsRefusedBeforeAnythingIsWritten() async throws {
        try await withPlace { place in
            let big = place.root.appending(path: "big.zip")
            #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
            let handle = try FileHandle(forWritingTo: big)
            try handle.truncate(atOffset: UInt64(CredentialAttachment.fileBytes + 1))  // sparse: nothing is really written
            try handle.close()
            await #expect(throws: VaultFileError.tooLarge(name: "big.zip")) {
                _ = try await place.add(big)
            }
            await #expect(throws: VaultFileError.unreadable(name: "out")) {
                _ = try await place.add(place.out)
            }
            #expect(VaultBlob.contents(of: place.folder).stored.isEmpty)
        }
    }

    @MainActor
    @Test func theEditorChecksEachLimitWithItsOwnMessage() async throws {
        try await withPlace { place in
            let small = try place.source(bytes: 10).url
            let exact = place.root.appending(path: "exact.bin")
            #expect(FileManager.default.createFile(atPath: exact.path, contents: nil))
            let handle = try FileHandle(forWritingTo: exact)
            try handle.truncate(atOffset: UInt64(CredentialAttachment.fileBytes))
            try handle.close()

            var draft = CredentialDraft(editing: nil, revision: 0)
            try CredentialSettingsModel.checkRoom(for: exact, in: draft, vaultBytes: 0)  // exactly 50 MB is allowed
            #expect(throws: VaultFileError.vaultFull) {
                try CredentialSettingsModel.checkRoom(for: exact, in: draft, vaultBytes: CredentialAttachment.vaultBytes - 10)
            }
            for _ in 0..<CredentialAttachment.entryLimit {
                draft.addAttachment(Self.record())
            }
            #expect(draft.attachments.count == 64)
            #expect(throws: VaultFileError.entryFull) {
                try CredentialSettingsModel.checkRoom(for: small, in: draft, vaultBytes: 0)
            }
            draft.addAttachment(Self.record())
            #expect(draft.attachments.count == 64, "the draft itself never holds a 65th")
            for error in [VaultFileError.tooLarge(name: "big.zip"), .entryFull, .vaultFull, .unreadable(name: "x"), .missing, .damaged, .lastFile] {
                #expect(!error.message.isEmpty)
            }
            #expect(VaultFileError.tooLarge(name: "big.zip").message.contains("big.zip"))
        }
    }

    @Test func aRecordOutsideItsLimitsIsInvalid() throws {
        var account = VaultFixtures.account()
        account.attachments = (0...CredentialAttachment.entryLimit).map { _ in Self.record() }
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        let twin = Self.record()
        account.attachments = [twin, twin]
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        account.attachments = []
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        var bad = Self.record(size: CredentialAttachment.fileBytes + 1)
        account.attachments = [bad]
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        bad = Self.record()
        bad.wrappedKey = Data(count: 32)
        account.attachments = [bad]
        #expect(throws: CredentialVaultError.invalidData) { try account.validate() }
        // An entry may hold only files: a name and a scan is an entry.
        var filesOnly = SecureItemFixtures.account([])
        filesOnly.secureItems = nil
        filesOnly.attachments = [Self.record()]
        try filesOnly.validate()
    }

    @Test func theVaultBudgetIsTwoGigabytesOfLiveFiles() throws {
        let full = (0..<40).map { _ in
            var account = VaultFixtures.account()
            account.attachments = [Self.record(size: CredentialAttachment.fileBytes)]
            return account
        }
        #expect(CredentialAttachment.liveBytes(of: full) == CredentialAttachment.vaultBytes)
        try ProfileVaultStore.validate(full, blockedOrigins: [])
        var over = full
        over[0].attachments?.append(Self.record(size: 1))
        #expect(throws: VaultFileError.vaultFull) { try ProfileVaultStore.validate(over, blockedOrigins: []) }
    }

    @Test func mergingCarriesEveryFileToThePrimaryOnce() throws {
        let shared = Self.record()
        var primary = VaultFixtures.account(username: "ada")
        primary.attachments = [shared]
        var other = VaultFixtures.account(username: "ada", password: "secret")
        other.attachments = [shared, Self.record()]
        let picks = try #require(CredentialMerge.defaultPicks(for: [primary, other], survivor: primary.id))
        let merged = try CredentialMerge.merged([primary, other], picks: picks)
        #expect(merged.attachments?.map(\.id) == [shared.id, other.attachments![1].id])

        other.attachments = (0..<CredentialAttachment.entryLimit).map { _ in Self.record() }
        #expect(throws: CredentialMergeError.fileLimit) {
            _ = try CredentialMerge.merged([primary, other], picks: picks)
        }
    }

    // MARK: - Decrypted copies

    @Test func copiesGoInAPrivateFolderOfThisRunAndAreRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "previews-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let earlier = VaultFilePreviewFolder(root: root, run: UUID())
        let leftover = try earlier.newCopyURL(named: "left.pdf")
        try Data("left".utf8).write(to: leftover)

        let folder = VaultFilePreviewFolder(root: root, run: UUID())
        let copy = try folder.newCopyURL(named: "../.hidden/scan:1.pdf")
        #expect(copy.lastPathComponent == "-.hidden-scan-1.pdf", "no folder separator, not hidden")
        try Data("copy".utf8).write(to: copy)
        for directory in [root, folder.runFolder, copy.deletingLastPathComponent()] {
            #expect(try Self.mode(directory) == 0o700, "\(directory.path)")
        }
        #expect(copy.path.hasPrefix(folder.runFolder.path))

        // Launch: an earlier run's copies go, this run's stay.
        folder.removeLeftovers()
        #expect(!StoreAnchors.exists(earlier.runFolder))
        #expect(StoreAnchors.exists(copy))

        // Quick Look closed: the copy and its folder go; nothing outside this run's folder is touched.
        let outside = root.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: outside)
        folder.remove(outside)
        #expect(StoreAnchors.exists(outside))
        folder.remove(copy)
        #expect(!StoreAnchors.exists(copy.deletingLastPathComponent()))

        // A lock or a quit: every copy of this run goes.
        let second = try folder.newCopyURL(named: "second.png")
        try Data("second".utf8).write(to: second)
        folder.removeAll()
        #expect(!StoreAnchors.exists(folder.runFolder))
        #expect(VaultFilePreviewFolder.safeName("") == "File" && VaultFilePreviewFolder.safeName("...") == "File")
        #expect(VaultFilePreviewFolder.safeName(String(repeating: "é", count: 300)).utf8.count <= 200)
    }

    @Test func theSharedFolderIsInTheUsersCachesNotTheSharedTemporaryFolder() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #expect(VaultFilePreviewFolder.shared.root.path.hasPrefix(caches.path))
        #expect(!VaultFilePreviewFolder.shared.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!VaultFilePreviewFolder.shared.root.path.hasPrefix("/tmp"))
    }
}
