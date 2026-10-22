// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurfVault

// iCloud sync, sealing (spec amendment 2026-10-22): the Item envelope, the vault name beside its wrapper list, the sync key, the key
// check and the sealed base. Every value opens only as itself; nothing here reaches a store, a defaults domain or the disk.

private nonisolated func syncKey(
    dek: SymmetricKey = SymmetricKey(size: .bits256), profile: UUID = UUID(), vault: UUID = UUID(),
    generation: UInt64 = VaultSyncCodec.generation
) -> VaultSyncKey {
    VaultSyncKey.derive(dek: dek, profileID: profile, vaultID: vault, generation: generation)
}

private nonisolated func bytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

private nonisolated func attachment() -> CredentialAttachment {
    CredentialAttachment(
        id: UUID(), name: "scan.pdf", contentType: "com.adobe.pdf", size: 10, sha256: Data(repeating: 7, count: 32),
        wrappedKey: Data(repeating: 9, count: CredentialAttachment.wrappedKeyBytes), addedAt: nil
    )
}

/// An envelope built by hand, so a test can seal what `sealItem` would refuse and see `openItem` refuse it.
private nonisolated func forged(
    _ plaintext: Data, state: UInt8, version: UInt64 = 1, accountID: UUID, key: VaultSyncKey, format: UInt8 = VaultSyncCodec.itemFormat
) throws -> Data {
    var header = StoreWriter()
    header.u8(format)
    header.u8(state)
    header.u64(version)
    let aad = VaultSyncCodec.itemAAD(key: key, accountID: accountID, format: format, state: state, version: version)
    let sealed = try #require(try AES.GCM.seal(plaintext, using: key.key, authenticating: aad).combined)
    return header.data + sealed
}

private nonisolated func flipped(_ data: Data, at index: Int) -> Data {
    var copy = data
    copy[copy.startIndex + index] ^= 0x01
    return copy
}

private nonisolated func setting(_ data: Data, at index: Int, to value: UInt8) -> Data {
    var copy = data
    copy[copy.startIndex + index] = value
    return copy
}

private enum Other: CaseIterable, CustomTestStringConvertible {
    case account, vault, profile, version, generation, key, stateByte, ciphertext, nonce, tag, truncated, empty

    var testDescription: String {
        "\(self)"
    }
}

private enum Refused: CaseIterable, CustomTestStringConvertible {
    case withFiles, otherID, invalidAccount, notAnAccount, removedWithContent, unknownFormat, unknownState, versionZero, tooBig

    var testDescription: String {
        "\(self)"
    }
}

struct VaultSyncCodecTests {
    private static let marker = "marker-\(UUID().uuidString)"

    private func richAccount() throws -> CredentialAccount {
        var account = try VaultFixtures.richAccount()
        account.notes = [CredentialNote(text: Self.marker)]
        account.secureItems = [SecureItemFixtures.card()]
        return account
    }

    // MARK: Item

    @Test func itemRoundTripsWithoutFiles() throws {
        let key = syncKey()
        var account = try richAccount()
        account.attachments = [attachment()]
        let syncable = try #require(VaultSyncCodec.syncable(account))
        #expect(syncable.account.attachments == nil)
        #expect(syncable.parts == (try SyncParts.of(account)), "the files are no part")

        let envelope = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 3, account: syncable.account), key: key)
        let opened = try VaultSyncCodec.openItem(envelope, accountID: account.id, key: key)
        #expect(opened.version == 3)
        var expected = account
        expected.attachments = nil
        #expect(try CredentialContent.canonicalJSON(try #require(opened.account)) == (try CredentialContent.canonicalJSON(expected)))
        #expect(opened.account == syncable.account)

        // The caller strips the files; an account that still has them is not sealed.
        #expect(throws: VaultSyncError.malformed) {
            _ = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 1, account: account), key: key)
        }
    }

    @Test(arguments: Other.allCases)
    private func itemOpensOnlyAsItself(other: Other) throws {
        let (dek, profile, vault, account) = (SymmetricKey(size: .bits256), UUID(), UUID(), try richAccount())
        let key = syncKey(dek: dek, profile: profile, vault: vault)
        let envelope = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 3, account: account), key: key)
        _ = try VaultSyncCodec.openItem(envelope, accountID: account.id, key: key)  // the control

        var data = envelope
        var id = account.id
        var opening = key
        switch other {
        case .account:
            id = UUID()
        case .vault:
            opening = syncKey(dek: dek, profile: profile, vault: UUID())
        case .profile:
            opening = syncKey(dek: dek, profile: UUID(), vault: vault)
        case .version:
            data = flipped(envelope, at: 9)  // the version, 3 -> 2
        case .generation:
            opening = syncKey(dek: dek, profile: profile, vault: vault, generation: 2)
        case .key:
            opening = syncKey(profile: profile, vault: vault)
        case .stateByte:
            data = setting(envelope, at: 1, to: VaultSyncCodec.removedState)
        case .ciphertext:
            data = flipped(envelope, at: VaultSyncCodec.headerBytes + 12 + 20)
        case .nonce:
            data = flipped(envelope, at: VaultSyncCodec.headerBytes)
        case .tag:
            data = flipped(envelope, at: envelope.count - 1)
        case .truncated:
            data = envelope.dropLast(1)
        case .empty:
            data = Data()
        }
        #expect(throws: VaultSyncError.self) {
            _ = try VaultSyncCodec.openItem(data, accountID: id, key: opening)
        }
    }

    @Test func theAADBindsKindProfileVaultAccountFormatStateVersionAndGeneration() {
        let key = syncKey()
        let account = UUID()
        let format = VaultSyncCodec.itemFormat
        let item = VaultSyncCodec.itemAAD(key: key, accountID: account, format: format, state: 1, version: 1)
        let variants = [
            VaultSyncCodec.itemAAD(
                key: syncKey(profile: key.profileID, vault: key.vaultID, generation: 2), accountID: account, format: format, state: 1, version: 1
            ),
            VaultSyncCodec.itemAAD(key: key, accountID: UUID(), format: format, state: 1, version: 1),
            VaultSyncCodec.itemAAD(key: key, accountID: account, format: format + 1, state: 1, version: 1),
            VaultSyncCodec.itemAAD(key: key, accountID: account, format: format, state: 2, version: 1),
            VaultSyncCodec.itemAAD(key: key, accountID: account, format: format, state: 1, version: 2),
            VaultSyncCodec.itemAAD(key: syncKey(profile: UUID(), vault: key.vaultID), accountID: account, format: format, state: 1, version: 1),
            VaultSyncCodec.itemAAD(key: syncKey(profile: key.profileID, vault: UUID()), accountID: account, format: format, state: 1, version: 1),
        ]
        #expect(Set(variants + [item]).count == variants.count + 1)
        // The three kinds never share a layout: a value sealed for one kind does not open as another.
        let parts = VaultSyncCodec.partsAAD(key: key, accountID: account, version: 1)
        let vault = VaultSyncCodec.vaultAAD(key: key, wrappers: Data())
        #expect(Set([item, parts, vault]).count == 3)
    }

    @Test func aGenerationThisBuildDoesNotKnowIsRefusedBothWays() throws {
        let known = syncKey()
        let future = syncKey(profile: known.profileID, vault: known.vaultID, generation: 2)
        let account = VaultFixtures.account()
        #expect(throws: VaultSyncError.unsupportedGeneration) {
            _ = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 1, account: account), key: future)
        }
        let envelope = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 1, account: account), key: known)
        #expect(throws: VaultSyncError.unsupportedGeneration) {
            _ = try VaultSyncCodec.openItem(envelope, accountID: account.id, key: future)
        }
        #expect(throws: VaultSyncError.unsupportedGeneration) {
            _ = try VaultSyncCodec.sealVault(name: "Personal", wrappers: Data([1]), key: future)
        }
    }

    @Test func removedStateCarriesOnlyIDs() throws {
        let key = syncKey()
        let id = UUID()
        let envelope = try VaultSyncCodec.sealItem(SyncItem(accountID: id, version: 5, account: nil), key: key)
        #expect(envelope.count == 38, "format, state, version and the authenticator of an empty plaintext")
        let opened = try VaultSyncCodec.openItem(envelope, accountID: id, key: key)
        #expect(opened == SyncItem(accountID: id, version: 5, account: nil))
        #expect(try opened.parts() == SyncParts.removedParts)
        #expect(try VaultSyncCodec.sealItem(SyncItem(accountID: id, version: 5, account: nil), key: key) != envelope, "a fresh nonce each time")
    }

    @Test func versionIsReadableWithoutTheKey() throws {
        let key = syncKey()
        let account = VaultFixtures.account()
        let live = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 0x0102_0304_0506, account: account), key: key)
        let removed = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 7, account: nil), key: key)
        #expect(try VaultSyncCodec.version(of: live) == 0x0102_0304_0506)
        #expect(try VaultSyncCodec.version(of: removed) == 7)

        // It is not authenticated by that read, but nobody can raise it: the AAD carries it.
        let raised = flipped(live, at: 9)
        #expect(try VaultSyncCodec.version(of: raised) == 0x0102_0304_0507)
        #expect(throws: VaultSyncError.authenticationFailed) {
            _ = try VaultSyncCodec.openItem(raised, accountID: account.id, key: key)
        }
        #expect(throws: VaultSyncError.malformed) { _ = try VaultSyncCodec.version(of: Data(live.prefix(20))) }
        #expect(throws: VaultSyncError.unsupportedFormat) { _ = try VaultSyncCodec.version(of: flipped(live, at: 0)) }
    }

    @Test func tooLargeOrFilesOnlyEntriesAreNotSyncable() throws {
        let key = syncKey()
        var big = VaultFixtures.account()
        big.notes = [CredentialNote(text: String(repeating: "a", count: 800_000))]
        #expect(VaultSyncCodec.syncable(big) == nil)
        #expect(throws: VaultSyncError.tooLarge) {
            _ = try VaultSyncCodec.sealItem(SyncItem(accountID: big.id, version: 1, account: big), key: key)
        }
        var fits = VaultFixtures.account()
        fits.notes = [CredentialNote(text: String(repeating: "a", count: 700_000))]
        let syncable = try #require(VaultSyncCodec.syncable(fits))
        let envelope = try VaultSyncCodec.sealItem(SyncItem(accountID: fits.id, version: 1, account: syncable.account), key: key)
        #expect(envelope.count <= VaultSyncCodec.maxItemBytes)

        let filesOnly = CredentialAccount(id: UUID(), username: "", origins: [], loginURLs: [], passkeys: [], attachments: [attachment()])
        try filesOnly.validate()  // a valid entry in the vault
        #expect(VaultSyncCodec.syncable(filesOnly) == nil, "nothing is left of it without its files")

        var undecodable = VaultFixtures.account()
        undecodable.exchangeMetadata = Data([0xFF, 0x00])
        #expect(VaultSyncCodec.syncable(undecodable) == nil, "its name and websites cannot be hashed")
    }

    /// What `openItem` refuses even when the bytes authenticate: a value no honest Mac would have sealed.
    @Test(arguments: Refused.allCases)
    private func openRefusesWhatTheVaultWouldNot(case refused: Refused) throws {
        let key = syncKey()
        let account = VaultFixtures.account()
        let encoded = try CredentialContent.canonicalJSON(account)
        let envelope: Data
        switch refused {
        case .withFiles:
            var files = account
            files.attachments = [attachment()]
            envelope = try forged(try CredentialContent.canonicalJSON(files), state: 1, accountID: account.id, key: key)
        case .otherID:
            var other = account
            other.id = UUID()
            envelope = try forged(try CredentialContent.canonicalJSON(other), state: 1, accountID: account.id, key: key)
        case .invalidAccount:
            var empty = account
            empty.username = ""
            empty.password = nil
            envelope = try forged(try CredentialContent.canonicalJSON(empty), state: 1, accountID: account.id, key: key)
        case .notAnAccount:
            envelope = try forged(Data("{}".utf8), state: 1, accountID: account.id, key: key)
        case .removedWithContent:
            envelope = try forged(encoded, state: 2, accountID: account.id, key: key)
        case .unknownFormat:
            envelope = try forged(encoded, state: 1, accountID: account.id, key: key, format: 2)
        case .unknownState:
            envelope = try forged(encoded, state: 3, accountID: account.id, key: key)
        case .versionZero:
            envelope = try forged(encoded, state: 1, version: 0, accountID: account.id, key: key)
        case .tooBig:
            envelope = Data(repeating: 1, count: VaultSyncCodec.maxItemBytes + 1)
        }
        #expect(throws: VaultSyncError.self) {
            _ = try VaultSyncCodec.openItem(envelope, accountID: account.id, key: key)
        }
        // The control: the same bytes, honestly made, open.
        let honest = try forged(encoded, state: 1, accountID: account.id, key: key)
        #expect(try VaultSyncCodec.openItem(honest, accountID: account.id, key: key).account == account)
    }

    // MARK: Vault

    private func wrapperList(_ dek: SymmetricKey, profile: UUID, vault: UUID, proofs: [VaultUnlockProof]) throws -> Data {
        try VaultWrapperList.encode(try proofs.map { try CredentialVaultCrypto.wrap(dek, with: $0, profileID: profile, vaultID: vault) })
    }

    @Test func vaultNameAuthenticatesTheWrapperList() throws {
        let (dek, profile, vault) = (SymmetricKey(size: .bits256), UUID(), UUID())
        let key = syncKey(dek: dek, profile: profile, vault: vault)
        let list = try wrapperList(dek, profile: profile, vault: vault, proofs: [VaultFixtures.proof(1), VaultFixtures.proof(2)])
        let sealed = try VaultSyncCodec.sealVault(name: "Personal", wrappers: list, key: key)
        #expect(try VaultSyncCodec.openVault(sealed, wrappers: list, key: key) == "Personal")

        // A list with one wrapper more, fewer, or one byte changed: another list, so the name does not open.
        let wrappers = try VaultWrapperList.decode(list)
        let extra = try CredentialVaultCrypto.wrap(dek, with: VaultFixtures.proof(3), profileID: profile, vaultID: vault)
        let other = [
            try VaultWrapperList.encode(Array(wrappers.dropLast())),
            try VaultWrapperList.encode(wrappers + [extra]),
            flipped(list, at: list.count / 2),
        ]
        for changed in other {
            #expect(throws: VaultSyncError.authenticationFailed) { _ = try VaultSyncCodec.openVault(sealed, wrappers: changed, key: key) }
        }
        #expect(throws: VaultSyncError.authenticationFailed) {
            _ = try VaultSyncCodec.openVault(flipped(sealed, at: 20), wrappers: list, key: key)
        }
        #expect(throws: VaultSyncError.authenticationFailed) {
            _ = try VaultSyncCodec.openVault(sealed, wrappers: list, key: syncKey(profile: profile, vault: vault))
        }
        #expect(throws: VaultSyncError.authenticationFailed) {
            _ = try VaultSyncCodec.openVault(sealed, wrappers: list, key: syncKey(dek: dek, profile: profile, vault: UUID()))
        }
        // The same name for another vault is another value.
        let elsewhere = try VaultSyncCodec.sealVault(name: "Personal", wrappers: list, key: syncKey(dek: dek, profile: profile, vault: UUID()))
        #expect(elsewhere != sealed)
    }

    @Test func vaultNamesFollowTheCreationRule() throws {
        let key = syncKey()
        for name in ["", " ", " Personal", "Personal\n", String(repeating: "n", count: StoreFormat.nameLimit + 1)] {
            #expect(throws: VaultSyncError.malformed) { _ = try VaultSyncCodec.sealVault(name: name, wrappers: Data([1]), key: key) }
        }
        let longest = String(repeating: "é", count: StoreFormat.nameLimit)
        let sealed = try VaultSyncCodec.sealVault(name: longest, wrappers: Data([1]), key: key)
        #expect(try VaultSyncCodec.openVault(sealed, wrappers: Data([1]), key: key) == longest)
    }

    @Test func theUploadedMarkChangesWithTheNameTheListAndTheKey() {
        let key = syncKey()
        let mark = VaultSyncCodec.vaultMark(name: "Personal", wrappers: Data([1, 2]), key: key)
        #expect(mark == VaultSyncCodec.vaultMark(name: "Personal", wrappers: Data([1, 2]), key: key))
        #expect(mark.count == 32)
        #expect(mark != VaultSyncCodec.vaultMark(name: "Work", wrappers: Data([1, 2]), key: key))
        #expect(mark != VaultSyncCodec.vaultMark(name: "Personal", wrappers: Data([1, 3]), key: key))
        #expect(mark != VaultSyncCodec.vaultMark(name: "Personal", wrappers: Data([1, 2]), key: syncKey()))
    }

    @Test func theMarkHasItsOwnKeyAndStaysStable() {
        let key = syncKey()
        let markKey = VaultSyncCodec.markKey(key)
        var message = StoreWriter()
        message.text("Personal")
        message.bytes(Data([1, 2]))

        #expect(bytes(markKey).count == 32)
        #expect(bytes(markKey) != bytes(key.key), "the HMAC never uses the sealing key")
        #expect(bytes(markKey) == bytes(VaultSyncCodec.markKey(key)))
        #expect(bytes(markKey) != bytes(VaultSyncCodec.markKey(syncKey())))
        let mark = VaultSyncCodec.vaultMark(name: "Personal", wrappers: Data([1, 2]), key: key)
        #expect(mark == VaultSyncCodec.vaultMark(name: "Personal", wrappers: Data([1, 2]), key: key))
        #expect(mark == Data(HMAC<SHA256>.authenticationCode(for: message.data, using: markKey)))
        #expect(mark != Data(HMAC<SHA256>.authenticationCode(for: message.data, using: key.key)))
    }

    // MARK: Keys

    @Test func syncKeyDependsOnVaultKeyProfileVaultAndGenerationOnly() {
        let (dek, profile, vault) = (SymmetricKey(size: .bits256), UUID(), UUID())
        let key = syncKey(dek: dek, profile: profile, vault: vault)
        #expect(bytes(key.key) == bytes(syncKey(dek: dek, profile: profile, vault: vault).key))
        #expect(key.generation == VaultSyncCodec.generation)
        let others = [
            syncKey(profile: profile, vault: vault),
            syncKey(dek: dek, profile: UUID(), vault: vault),
            syncKey(dek: dek, profile: profile, vault: UUID()),
            syncKey(dek: dek, profile: profile, vault: vault, generation: 2),
        ]
        for other in others {
            #expect(bytes(other.key) != bytes(key.key))
        }
        #expect(Set(others.map { bytes($0.key) }).count == others.count)
        #expect(bytes(key.key) != bytes(dek), "never the vault's own key")
        #expect(bytes(key.key).count == 32)
    }

    @Test func keyCheckIsStableAndNotThePRF() {
        let prf = SymmetricKey(size: .bits256)
        let credential = Data(repeating: 4, count: 32)
        let check = CredentialVaultCrypto.keyCheck(prf: prf, credentialID: credential)
        #expect(check.range(of: "^[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}$", options: .regularExpression) != nil, "\(check)")
        #expect(check == CredentialVaultCrypto.keyCheck(prf: prf, credentialID: credential))
        #expect(check != CredentialVaultCrypto.keyCheck(prf: SymmetricKey(size: .bits256), credentialID: credential))
        #expect(check != CredentialVaultCrypto.keyCheck(prf: prf, credentialID: Data(repeating: 5, count: 32)))

        let hex = bytes(prf).map { String(format: "%02X", $0) }.joined()
        #expect(!hex.contains(check.replacingOccurrences(of: "-", with: "")), "no stretch of the PRF output")
    }

    // MARK: Base at rest

    @Test func partsAreSealedAtRest() throws {
        let key = syncKey()
        let account = try richAccount()
        let parts = try SyncParts.of(account)
        let (id, version) = (account.id, UInt64(4))
        let sealed = try VaultSyncCodec.sealParts(parts, accountID: id, version: version, key: key)
        #expect(try VaultSyncCodec.openParts(sealed, accountID: id, version: version, key: key) == parts)

        let hashes = [parts.password, parts.totp, parts.notes, parts.secureItems, parts.metadata] + parts.passkeys.flatMap { [$0.identity, $0.hash] }
        for hash in hashes {
            #expect(sealed.range(of: hash) == nil, "a hash of a secret rests in the clear")
            #expect(sealed.range(of: Data(hash.base64EncodedString().utf8)) == nil)
        }
        #expect(sealed.range(of: Data(Self.marker.utf8)) == nil)

        #expect(throws: VaultSyncError.self) { _ = try VaultSyncCodec.openParts(sealed, accountID: UUID(), version: version, key: key) }
        #expect(throws: VaultSyncError.self) { _ = try VaultSyncCodec.openParts(sealed, accountID: id, version: version + 1, key: key) }
        #expect(throws: VaultSyncError.self) { _ = try VaultSyncCodec.openParts(sealed, accountID: id, version: version, key: syncKey()) }
        #expect(throws: VaultSyncError.self) { _ = try VaultSyncCodec.openParts(flipped(sealed, at: 30), accountID: id, version: version, key: key) }
    }

    @Test func nothingSecretIsInAnEnvelope() throws {
        let key = syncKey()
        let account = try richAccount()
        let envelope = try VaultSyncCodec.sealItem(SyncItem(accountID: account.id, version: 1, account: account), key: key)
        for secret in [Self.marker, "s3cret", SecureItemFixtures.cardNumber, account.id.uuidString] {
            #expect(envelope.range(of: Data(secret.utf8)) == nil)
            #expect(envelope.range(of: Data(Data(secret.utf8).base64EncodedString().utf8)) == nil)
        }
    }
}
