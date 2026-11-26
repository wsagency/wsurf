// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// Full backups (`VaultBackupCodec`) through the real codec, the real coordinator and real vaults: every kind of entry, the password
/// container and its failures, and a restore into an empty vault and into the vault the backup came from. Synthetic data only. The
/// key derivation runs with few rounds here, except where the default work factor itself is checked.
@MainActor
struct VaultBackupTests {
    let base = CredentialExchangeCoordinatorTests()
    static let rounds: UInt32 = 1_000
    static let password = "correct horse battery staple"
    static let when = Date(timeIntervalSinceReferenceDate: 790_000_000)

    // MARK: - Fixtures

    func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "vault-backup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func passkey(rp: String = "example.test", seed: UInt8) throws -> WebsitePasskey {
        WebsitePasskey(
            id: UUID(), credentialID: Data(repeating: seed, count: 32), rpID: rp, userHandle: Data([seed, 0x42]), userName: "ada",
            userDisplayName: "Ada", algorithm: -7, privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: true, backupState: true, createdAt: Self.when, source: .created, lastSignedAt: Self.when.addingTimeInterval(60)
        )
    }

    /// One entry of every kind a vault keeps, files excluded: a login with a website, notes and a code; a login without a website;
    /// a passkey only; a note only; a card and an address only.
    func everyKind() throws -> [CredentialAccount] {
        var login = base.account(username: "ada", password: "pw-website")
        login.displayName = "Example"
        login.loginURLs = [URL(string: "https://example.test/login")!]
        login.totp = base.generator()
        login.notes = [CredentialNote(text: "recovery: 1234-5678")]
        login.createdAt = Self.when
        login.modifiedAt = Self.when.addingTimeInterval(5)
        var offline = base.account(username: "router-admin", password: "pw-no-website")
        offline.origins = []
        offline.displayName = "Home router"
        var passkeyOnly = base.account(username: "", password: nil, passkeys: [try passkey(seed: 7)])
        passkeyOnly.displayName = "Passkey only"
        var note = base.account(username: "", password: nil)
        note.origins = []
        note.displayName = "Note"
        note.notes = [CredentialNote(text: "Secret note")]
        var items = base.account(username: "", password: nil)
        items.origins = []
        items.displayName = "Wallet"
        items.secureItems = [
            SecureItem(kind: .creditCard, fields: [
                SecureItemField(name: "number", value: "4111111111111111"), SecureItemField(name: "verificationNumber", value: "123"),
            ]),
            SecureItem(kind: .address, fields: [SecureItemField(name: "city", value: "Zagreb")]),
        ]
        return [login, offline, passkeyOnly, note, items]
    }

    func attachment(for contents: Data, name: String = "scan.pdf") -> CredentialAttachment {
        CredentialAttachment(
            id: UUID(), name: name, contentType: "com.adobe.pdf", size: Int64(contents.count), sha256: Data(SHA256.hash(data: contents)),
            wrappedKey: Data(repeating: 1, count: CredentialAttachment.wrappedKeyBytes), addedAt: Self.when
        )
    }

    /// Adds a real file to `manager`'s vault and returns its record.
    func addFile(_ contents: Data, to manager: CredentialManager, name: String = "scan.pdf") async throws -> CredentialAttachment {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: name)
        try contents.write(to: url)
        return try await manager.addAttachment(from: url)
    }

    func readFile(_ file: CredentialAttachment, from manager: CredentialManager) async throws -> Data {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "out")
        try await manager.readAttachment(file, to: url)
        return try Data(contentsOf: url)
    }

    static func mode(_ url: URL) throws -> Int {
        try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue & 0o777
    }

    // MARK: - Codec

    @Test func everyKindRoundTripsThroughJSONAndThroughTheEncryptedContainer() async throws {
        var accounts = try everyKind()
        let contents = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        var fileOnly = base.account(username: "", password: nil)
        fileOnly.origins = []
        fileOnly.attachments = [attachment(for: contents)]
        accounts.append(fileOnly)
        let files = [fileOnly.attachments![0].id: contents]
        let built = try VaultBackupCodec.backup(of: accounts, files: files, vaultName: "Personal", exportedAt: Self.when)
        #expect(built.omitted == VaultBackupCodec.Omitted())

        let json = try VaultBackupCodec.encode(built.backup)
        #expect(try VaultBackupCodec.decode(json) == built.backup)
        let sealed = try await VaultBackupCodec.seal(json, password: Self.password, iterations: Self.rounds)
        #expect(VaultBackupCodec.isEncrypted(sealed) && !VaultBackupCodec.isEncrypted(json))
        #expect(sealed.range(of: Data("recovery: 1234".utf8)) == nil && sealed.range(of: Data("4111111111111111".utf8)) == nil)
        let opened = try await VaultBackupCodec.open(sealed, password: Self.password, minimumIterations: Self.rounds)
        let restored = try VaultBackupCodec.decode(opened)
        #expect(restored == built.backup)
        // Everything as the vault held it, but the files' wrapped keys, which are the vault's own and stay behind.
        #expect(restored.accounts.flatMap { $0.attachments ?? [] }.allSatisfy { $0.wrappedKey == Data(count: CredentialAttachment.wrappedKeyBytes) })
        var expected = accounts
        expected[expected.count - 1].attachments?[0].wrappedKey = Data(count: CredentialAttachment.wrappedKeyBytes)
        #expect(restored.accounts == expected)
        #expect(restored.files.first?.contents == contents)

        // The restored secrets work: the same codes at the same moments, and a signature the original key's public half accepts.
        let generator = try #require(restored.accounts[0].totp)
        let originalGenerator = try #require(accounts[0].totp)
        for time in [0.0, 1_700_000_000, 1_900_000_123] {
            let restoredCode = try TOTP.code(generator, at: time)
            let originalCode = try TOTP.code(originalGenerator, at: time)
            #expect(restoredCode == originalCode)
        }
        let original = try PasskeyKeyEncoding.importPKCS8(accounts[2].passkeys[0].privateKeyPKCS8)
        let copy = try PasskeyKeyEncoding.importPKCS8(restored.accounts[2].passkeys[0].privateKeyPKCS8)
        let challenge = Data("challenge".utf8)
        #expect(original.publicKey.isValidSignature(try copy.signature(for: challenge), for: challenge))
        #expect(restored.accounts[2].passkeys[0].isBackedUp && restored.accounts[2].passkeys[0].source == .created)
    }

    @Test func aFileTheVaultCouldNotReadIsLeftOutAndAnEntryLeftEmptyGoesWithIt() throws {
        var withLogin = base.account()
        withLogin.attachments = [attachment(for: Data("a".utf8))]
        var onlyFile = base.account(username: "", password: nil)
        onlyFile.attachments = [attachment(for: Data("b".utf8))]
        let built = try VaultBackupCodec.backup(of: [withLogin, onlyFile], files: [:], vaultName: nil, exportedAt: Self.when)
        #expect(built.omitted == VaultBackupCodec.Omitted(files: 2, entries: 1))
        #expect(built.backup.accounts.map(\.id) == [withLogin.id])
        #expect(built.backup.accounts[0].attachments == nil)
    }

    @Test func decodeRefusesAnotherFormatAFileThatDoesNotMatchItsRecordAndOversizedFiles() throws {
        let contents = Data("file".utf8)
        var account = base.account()
        account.attachments = [attachment(for: contents)]
        var backup = try VaultBackupCodec.backup(
            of: [account], files: [account.attachments![0].id: contents], vaultName: nil, exportedAt: Self.when
        ).backup
        var other = backup
        other.format = "something-else"
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupCodec.decode(try VaultBackupCodec.encode(other)) }
        other = backup
        other.version = 2
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupCodec.decode(try VaultBackupCodec.encode(other)) }
        #expect(throws: VaultBackupError.notABackup) { try VaultBackupCodec.decode(Data("{\"format\":1}".utf8)) }
        backup.files = [VaultBackup.File(id: account.attachments![0].id, contents: Data("FILE".utf8))]
        #expect(throws: VaultBackupError.invalidContent) { try VaultBackupCodec.decode(try VaultBackupCodec.encode(backup)) }
        #expect(throws: VaultBackupError.tooLarge) {
            try VaultBackupCodec.backup(
                of: [account], files: [account.attachments![0].id: Data(count: Int(VaultBackupCodec.fileBytesLimit) + 1)], vaultName: nil,
                exportedAt: Self.when
            )
        }
    }

    // MARK: - Password container

    @Test func aWrongPasswordAndAnyChangedByteFailTheSameWay() async throws {
        let plaintext = Data("{\"secret\":\"value\"}".utf8)
        let sealed = try await VaultBackupCodec.seal(plaintext, password: Self.password, iterations: Self.rounds)
        await #expect(throws: VaultBackupError.wrongPasswordOrCorrupted) {
            try await VaultBackupCodec.open(sealed, password: "wrong password", minimumIterations: Self.rounds)
        }
        // One bit in each part: magic, version, KDF, rounds, salt, nonce, ciphertext and tag.
        let positions = [0, 8, 9, 13, 14, 45, 46, 57, VaultBackupCodec.headerBytes, sealed.count - 16, sealed.count - 1]
        for position in positions {
            var changed = sealed
            changed[position] ^= 0x01
            await #expect(throws: VaultBackupError.wrongPasswordOrCorrupted, "byte \(position)") {
                try await VaultBackupCodec.open(changed, password: Self.password, minimumIterations: 1)
            }
        }
        for length in [0, 10, VaultBackupCodec.headerBytes + 15, sealed.count - 1] {
            await #expect(throws: VaultBackupError.wrongPasswordOrCorrupted, "length \(length)") {
                try await VaultBackupCodec.open(sealed.prefix(length), password: Self.password, minimumIterations: 1)
            }
        }
        await #expect(throws: VaultBackupError.emptyPassword) { try await VaultBackupCodec.seal(plaintext, password: "") }
    }

    @Test func eachSealHasItsOwnSaltAndNonceAndTheDefaultWorkFactorIsWritten() async throws {
        let plaintext = Data("same".utf8)
        let first = try await VaultBackupCodec.seal(plaintext, password: Self.password, iterations: Self.rounds)
        let second = try await VaultBackupCodec.seal(plaintext, password: Self.password, iterations: Self.rounds)
        #expect(first[14..<46] != second[14..<46])
        #expect(first[46..<58] != second[46..<58])
        #expect(first.suffix(from: 58) != second.suffix(from: 58))

        let strong = try await VaultBackupCodec.seal(plaintext, password: Self.password)
        let rounds = strong[10..<14].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(rounds >= 600_000 && rounds == VaultBackupCodec.defaultIterations)
        // A file asking for fewer rounds than WSurf writes is refused before any key is derived.
        await #expect(throws: VaultBackupError.wrongPasswordOrCorrupted) {
            try await VaultBackupCodec.open(first, password: Self.password)
        }
        #expect(try await VaultBackupCodec.open(strong, password: Self.password) == plaintext)
    }

    // MARK: - Through the coordinator and real vaults

    /// Seeds `f.manager` with every kind of entry, a login with a file and an entry with only a file, and returns them with the files'
    /// plaintext by stored record.
    func seedEveryKind(_ f: CredentialExchangeCoordinatorTests.Fixture) async throws -> (accounts: [CredentialAccount], files: [Data]) {
        try await f.seed([])
        var accounts = try everyKind()
        let first = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        let second = Data("only a file".utf8)
        accounts[0].attachments = [try await addFile(first, to: f.manager)]
        var fileOnly = base.account(username: "", password: nil)
        fileOnly.origins = []
        fileOnly.displayName = "Scans"
        fileOnly.attachments = [try await addFile(second, to: f.manager, name: "id.png")]
        accounts.append(fileOnly)
        _ = try await f.manager.commit(
            accounts, expectedRevision: try await f.stored().revision, authorizedEpoch: try #require(f.manager.authorizationEpoch)
        )
        return (try await f.stored().accounts, [first, second])
    }

    func export(_ f: CredentialExchangeCoordinatorTests.Fixture, to url: URL, password: String?) async throws -> CredentialExchangeCoordinator.BackupExport {
        let snapshot = try await f.stored()
        return try await f.coordinator.exportBackup(
            accountIDs: snapshot.accounts.map(\.id), expectedStamps: snapshot.stamps, epoch: try #require(f.manager.authorizationEpoch),
            from: f.manager, to: url, password: password
        )
    }

    /// The parts a restore must keep, without the local ids and the identity the import records.
    func content(_ account: CredentialAccount) -> [String] {
        let websites: String = account.origins.joined(separator: " ") + " " + account.loginURLs.map(\.absoluteString).joined(separator: " ")
        let notes: String = account.notes?.map(\.text).joined(separator: "|") ?? "-"
        let code: String = account.totp.map { "\($0.secret.base64EncodedString()) \($0.digits) \($0.period)" } ?? "-"
        let items: String = "\(account.secureItems ?? [])"
        let created: String = "\(account.createdAt?.timeIntervalSinceReferenceDate ?? -1)"
        let passkeys: [String] = account.passkeys.map { key in
            let source: String = key.source?.rawValue ?? "-"
            let parts: [String] = [
                key.credentialID.base64EncodedString(), key.rpID, key.userHandle.base64EncodedString(),
                key.privateKeyPKCS8.base64EncodedString(), "\(key.backupState)", source,
            ]
            return parts.joined(separator: " ")
        }
        let files: [String] = (account.attachments ?? []).map { file in
            "\(file.name) \(file.contentType) \(file.size) \(file.sha256.base64EncodedString())"
        }
        return [
            account.username, account.displayName ?? "-", websites, account.password ?? "-", notes, code, items, created,
            passkeys.joined(separator: "|"), files.joined(separator: "|"),
        ]
    }

    @Test(arguments: [true, false])
    func aBackupRestoresEveryEntryAndFileIntoAnEmptyVault(encrypted: Bool) async throws {
        try await base.withFixture { f in
            let (source, files) = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appending(path: encrypted ? "backup.wsurfvault" : "backup.json")
            let result = try await export(f, to: url, password: encrypted ? Self.password : nil)
            #expect(result == CredentialExchangeCoordinator.BackupExport(entries: source.count, files: 2, omittedFiles: 0))
            #expect(try Self.mode(url) == 0o600)
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [url.lastPathComponent])

            let data = try Data(contentsOf: url)
            #expect(VaultBackupCodec.isEncrypted(data) == encrypted)
            if encrypted {
                await #expect(throws: VaultBackupError.wrongPasswordOrCorrupted) { try await f.coordinator.readBackup(data, password: "nope") }
            }
            let backup = try await f.coordinator.readBackup(data, password: encrypted ? Self.password : nil)

            try await f.seed([], into: f.other)
            try await f.coordinator.beginBackupImport(backup, into: f.other, owner: f.owner) { _ in }
            let review = try #require(f.coordinator.importReview(for: f.other, owner: f.owner))
            #expect(review.backupFiles == 2 && review.backupFileOnlyEntries == 1 && review.isResolved)
            _ = try await f.coordinator.commitImport(into: f.other, owner: f.owner)

            let restored = try await f.stored(f.other).accounts
            let restoredContent: [String] = restored.map { content($0).joined(separator: "\u{1F}") }.sorted()
            let sourceContent: [String] = source.map { content($0).joined(separator: "\u{1F}") }.sorted()
            #expect(restoredContent == sourceContent)
            var restoredFiles: [Data] = []
            for file in restored.flatMap({ $0.attachments ?? [] }) {
                restoredFiles.append(try await readFile(file, from: f.other))
            }
            #expect(restoredFiles.sorted { $0.count < $1.count } == files.sorted { $0.count < $1.count })
            let passkey = try #require(restored.flatMap(\.passkeys).first)
            let original = try #require(source.flatMap(\.passkeys).first)
            let challenge = Data("assertion".utf8)
            let signature = try PasskeyKeyEncoding.importPKCS8(passkey.privateKeyPKCS8).signature(for: challenge)
            #expect(try PasskeyKeyEncoding.importPKCS8(original.privateKeyPKCS8).publicKey.isValidSignature(signature, for: challenge))
            let totp = try #require(restored.compactMap(\.totp).first)
            let sourceTOTP = try #require(source.compactMap(\.totp).first)
            let restoredCode = try TOTP.code(totp, at: 1_800_000_000)
            let sourceCode = try TOTP.code(sourceTOTP, at: 1_800_000_000)
            #expect(restoredCode == sourceCode)
        }
    }

    @Test func restoringIntoTheVaultItCameFromChangesNothingAndAChangedPasswordIsAConflict() async throws {
        try await base.withFixture { f in
            let (source, _) = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appending(path: "backup.json")
            _ = try await export(f, to: url, password: nil)
            let backup = try await f.coordinator.readBackup(try Data(contentsOf: url), password: nil)

            let before = try f.diskBytes()
            try await f.coordinator.beginBackupImport(backup, into: f.manager, owner: f.owner) { _ in }
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.isResolved && review.tally.writes == 0)
            await #expect(throws: CredentialTransferFailure.self) { _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner) }
            #expect(try f.diskBytes() == before)
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)

            // A password changed since the backup was written needs the user's choice; Keep Saved writes nothing.
            var changed = try #require(source.first { $0.password == "pw-website" })
            changed.password = "pw-changed-here"
            _ = try await f.manager.commit(
                try await f.stored().accounts.map { $0.id == changed.id ? changed : $0 }, expectedRevision: try await f.stored().revision,
                authorizedEpoch: try #require(f.manager.authorizationEpoch)
            )
            try await f.coordinator.beginBackupImport(backup, into: f.manager, owner: f.owner) { _ in }
            let conflicted = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            let undecided = conflicted.conflicts.filter { $0.choice == nil }
            let conflict = try #require(undecided.first)
            #expect(undecided.count == 1 && conflict.kind == .password && !conflicted.isResolved)
            try f.coordinator.choose(.replace, for: conflict.incoming, owner: f.owner)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(try await f.stored().accounts.first { $0.id == changed.id }?.password == "pw-website")
            #expect(try await f.stored().accounts.count == source.count)
        }
    }

    @Test func aLockDropsTheStagedBackupAndAStaleSelectionWritesNoFile() async throws {
        try await base.withFixture { f in
            let (source, _) = try await seedEveryKind(f)
            let folder = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appending(path: "backup.wsurfvault")
            let snapshot = try await f.stored()
            let epoch = try #require(f.manager.authorizationEpoch)

            // A stamp the vault no longer has, then an epoch it no longer has: nothing is written.
            var stale = snapshot.stamps
            stale[source[0].id] = snapshot.stamps[source[1].id]
            await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.exportBackup(
                    accountIDs: [source[0].id], expectedStamps: stale, epoch: epoch, from: f.manager, to: url, password: Self.password
                )
            }
            await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.exportBackup(
                    accountIDs: [source[0].id], expectedStamps: snapshot.stamps, epoch: epoch + 1, from: f.manager, to: url, password: Self.password
                )
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

            _ = try await export(f, to: url, password: Self.password)
            let backup = try await f.coordinator.readBackup(try Data(contentsOf: url), password: Self.password)
            try await f.seed([], into: f.other)
            try await f.coordinator.beginBackupImport(backup, into: f.other, owner: f.owner) { _ in }
            #expect(f.coordinator.importReview(for: f.other, owner: f.owner) != nil)
            let before = try f.diskBytes(f.otherProfile)
            f.other.lock(reason: .manual)
            #expect(f.coordinator.session == nil)
            #expect(f.coordinator.importReview(for: f.other, owner: f.owner) == nil)
            #expect(try f.diskBytes(f.otherProfile) == before)
        }
    }
}
