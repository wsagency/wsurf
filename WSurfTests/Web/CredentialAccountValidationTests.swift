// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

/// Account/passkey/TOTP validation and the v1 envelope field decoders: pure value checks with no vault, store or manager.
struct CredentialAccountValidationTests {
    private func validTestPasskey(rpID: String) throws -> WebsitePasskey {
        try VaultFixtures.passkey(rpID: rpID)
    }

    @Test func accountValidationKeepsOriginsCanonicalAndLoginURLsPathOnly() throws {
        var record = VaultFixtures.account()
        record.origins = ["https://EXAMPLE.test:443"]
        #expect(throws: (any Error).self) { try record.validate() }

        let sanitized = try CredentialAccount.sanitizedLoginURL(URL(string: "https://ada:secret@example.test:443/login?token=private#section")!)
        #expect(sanitized.absoluteString == "https://example.test/login")
        #expect(CredentialAccount.origin(for: URL(string: "http://example.test/login")!) == nil)
        #expect(CredentialAccount.origin(for: URL(string: "https://user@example.test/login")!) == nil)
    }

    @Test func invalidTOTPAndPKCS8InputsAreRejected() throws {
        for (period, digits) in [(UInt16(0), UInt16(6)), (UInt16(30), UInt16(5)), (UInt16(30), UInt16(11))] {
            let generator = TOTPGenerator(secret: Data([1, 2, 3]), algorithm: .sha1, period: period, digits: digits, issuer: nil, userName: nil)
            #expect(throws: (any Error).self) { try generator.validate() }
        }

        let oversized = Data(repeating: 0, count: 4_000_001)
        let key = P256.Signing.PrivateKey()
        let valid = try PasskeyKeyEncoding.exportPKCS8(key)
        let imported = try PasskeyKeyEncoding.importPKCS8(valid)
        #expect(imported.rawRepresentation == key.rawRepresentation)
        let message = Data("key-use fixture".utf8)
        let signature = try imported.signature(for: message)
        #expect(key.publicKey.isValidSignature(signature, for: message))
        var wrongCurve = valid
        let p256OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
        if let oidRange = wrongCurve.range(of: p256OID) {
            wrongCurve[oidRange.upperBound - 1] = 0x22
        } else {
            Issue.record("PKCS#8 fixture did not contain the P-256 curve OID")
        }
        var contradictoryPublicKey = valid
        if let publicKeyRange = contradictoryPublicKey.range(of: key.publicKey.x963Representation) {
            contradictoryPublicKey[publicKeyRange.upperBound - 1] ^= 1
        } else {
            Issue.record("PKCS#8 fixture did not contain its public key")
        }
        var nonminimalLength = valid
        let lengthByte = nonminimalLength[1]
        if lengthByte & 0x80 == 0 {
            nonminimalLength[1] = 0x81
            nonminimalLength.insert(lengthByte, at: 2)
        } else {
            nonminimalLength[1] += 1
            nonminimalLength.insert(0, at: 2)
        }
        for der in [Data(), Data([0x30, 0x82, 0x01]), wrongCurve, contradictoryPublicKey, nonminimalLength, oversized] {
            #expect(throws: (any Error).self) { try PasskeyKeyEncoding.importPKCS8(der) }
        }
    }

    @Test func pkcs8ImportAcceptsNonzeroStartIndexDataSlice() throws {
        let key = P256.Signing.PrivateKey()
        let encoded = try PasskeyKeyEncoding.exportPKCS8(key)
        let padded = Data([0xFF]) + encoded + Data([0xFF])
        let start = padded.index(after: padded.startIndex)
        let end = padded.index(before: padded.endIndex)
        let slice = padded[start..<end]

        #expect(slice.startIndex == start)
        #expect(try PasskeyKeyEncoding.importPKCS8(slice).rawRepresentation == key.rawRepresentation)
    }

    @Test func canonicalRelyingPartyIDsAreUsableByStoredPasskeys() throws {
        let idna = try RelyingPartyPolicy.validate(
            rpID: "bücher.de",
            origin: URL(string: "https://login.bücher.de")!
        )
        #expect(idna == "xn--bcher-kva.de")
        try validTestPasskey(rpID: idna).validate()

        let trailingDot = try RelyingPartyPolicy.validate(
            rpID: "example.com.",
            origin: URL(string: "https://login.example.com.")!
        )
        #expect(trailingDot == "example.com.")
        try validTestPasskey(rpID: trailingDot).validate()
    }

    @Test func publicSuffixAndIPAddressRelyingPartiesRemainRejectedForCeremonies() throws {
        for rpID in ["com", "127.0.0.1"] {
            #expect(throws: (any Error).self) {
                try RelyingPartyPolicy.validate(rpID: rpID, origin: URL(string: "https://\(rpID)")!)
            }
        }
        #expect(throws: (any Error).self) { try validTestPasskey(rpID: "127.0.0.1").validate() }
    }

    @Test func passwordWithoutApprovedOriginRemainsValidForManualAssociation() throws {
        var unscoped = VaultFixtures.account()
        unscoped.origins = []
        unscoped.loginURLs = []
        try unscoped.validate()
        #expect(unscoped.origins.isEmpty && unscoped.loginURLs.isEmpty)
    }

    @Test func backupStateRequiresBackupEligibility() throws {
        var passkey = try validTestPasskey(rpID: "example.test")
        passkey.backupEligible = false
        try passkey.validate()

        passkey.backupState = true
        #expect(throws: (any Error).self) { try passkey.validate() }
    }

    @Test func envelopeFieldDecodersRejectOutOfBoundsDataWhileDecoding() throws {
        func wrapper(
            id: Int = 32, prf: Int = 32, nonce: Int = 12, ciphertext: Int = 32, tag: Int = 16
        ) -> CredentialKeyWrapper {
            CredentialKeyWrapper(
                credentialID: Data(repeating: 1, count: id), prfInput: Data(repeating: 2, count: prf),
                nonce: Data(repeating: 3, count: nonce), ciphertext: Data(repeating: 4, count: ciphertext),
                tag: Data(repeating: 5, count: tag)
            )
        }
        func sealed(nonce: Int = 12, ciphertext: Int = 32, tag: Int = 16) -> CredentialSealedData {
            CredentialSealedData(
                nonce: Data(repeating: 3, count: nonce), ciphertext: Data(repeating: 4, count: ciphertext),
                tag: Data(repeating: 5, count: tag)
            )
        }
        func decode<T: Codable>(_ value: T) throws -> T {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            return try PropertyListDecoder().decode(T.self, from: encoder.encode(value))
        }
        let limit = CredentialVaultCrypto.maximumUnlockFieldBytes

        // Valid boundary values keep their wire shape.
        #expect(try decode(wrapper(id: limit, prf: 1)).credentialID.count == limit)
        #expect(try decode(sealed(ciphertext: CredentialVaultLimits.payloadBytes)).ciphertext.count == CredentialVaultLimits.payloadBytes)

        for invalid in [
            wrapper(id: 0), wrapper(id: limit + 1), wrapper(prf: 0), wrapper(prf: limit + 1),
            wrapper(nonce: 11), wrapper(nonce: 13), wrapper(ciphertext: 31), wrapper(ciphertext: 33),
            wrapper(tag: 15), wrapper(tag: 17),
        ] {
            #expect(throws: (any Error).self) { try decode(invalid) }
        }
        for invalid in [
            sealed(nonce: 11), sealed(nonce: 13), sealed(ciphertext: CredentialVaultLimits.payloadBytes + 1),
            sealed(tag: 15), sealed(tag: 17),
        ] {
            #expect(throws: (any Error).self) { try decode(invalid) }
        }
    }

    @Test func basicAuthenticationMetadataPreservesEmptyAndAbsentPasswords() throws {
        let usernameField = CredentialEditableFieldMetadata(id: Data([1]), label: "Login", fieldType: .string)
        let passwordField = CredentialEditableFieldMetadata(id: Data([2]), label: "Password", fieldType: .concealedString)
        var presentEmpty = VaultFixtures.account(password: "")
        presentEmpty.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(username: usernameField, password: passwordField)
        try presentEmpty.validate()
        #expect(presentEmpty.password == "")

        var absent = VaultFixtures.account(password: nil)
        absent.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(username: usernameField, password: nil)
        try absent.validate()
        #expect(absent.password == nil)

        absent.password = ""
        #expect(throws: (any Error).self) { try absent.validate() }
        presentEmpty.basicAuthenticationMetadata?.password = nil
        #expect(throws: (any Error).self) { try presentEmpty.validate() }
        presentEmpty.basicAuthenticationMetadata?.password = CredentialEditableFieldMetadata(id: Data([1]), label: "Password", fieldType: .email)
        #expect(throws: (any Error).self) { try presentEmpty.validate() }
    }

    @Test func basicAuthenticationMetadataContributesToPayloadBudget() throws {
        let id = Data(repeating: 7, count: 1_024)
        let label = String(repeating: "x", count: 2_048)
        var record = VaultFixtures.account(username: String(repeating: "a", count: 3_994_000), password: "")
        record.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: id, label: label, fieldType: .string),
            password: CredentialEditableFieldMetadata(id: Data(repeating: 8, count: 1_024), label: label, fieldType: .concealedString)
        )
        record.basicAuthenticationMetadata?.username?.id = Data(repeating: 7, count: 1_025)
        #expect(throws: (any Error).self) { try record.validate() }
        record.basicAuthenticationMetadata?.username?.id = id
        record.basicAuthenticationMetadata?.username?.label = String(repeating: "x", count: 2_049)
        #expect(throws: (any Error).self) { try record.validate() }
        record.basicAuthenticationMetadata?.username?.label = label
        let payload = CredentialVaultPayload(revision: 0, accounts: [record], blockedPasswordOrigins: [])
        #expect(throws: (any Error).self) { try CredentialVaultCrypto.validate(payload) }

        record.username = "ada"
        record.basicAuthenticationMetadata?.password?.id = id
        #expect(throws: (any Error).self) { try record.validate() }
    }

    // MARK: Notes

    private func noteOnlyAccount(_ notes: [CredentialNote]?) -> CredentialAccount {
        var account = CredentialAccount(
            id: UUID(), username: "", displayName: nil, origins: [], loginURLs: [], password: nil, passkeys: [], totp: nil,
            exchangeAccountID: nil, exchangeItemID: nil
        )
        account.notes = notes
        return account
    }

    @Test func noteOnlyAccountValidates() throws {
        try noteOnlyAccount([CredentialNote(text: "only a note", field: nil)]).validate()
        try noteOnlyAccount([
            CredentialNote(text: "first", field: CredentialEditableFieldMetadata(id: Data([1]), label: "Note", fieldType: .string)),
            CredentialNote(text: "second", field: nil),
        ]).validate()

        // An account with nothing at all is still invalid.
        #expect(throws: (any Error).self) { try noteOnlyAccount(nil).validate() }
    }

    @Test func emptyNotesArrayRejected() throws {
        #expect(throws: (any Error).self) { try noteOnlyAccount([]).validate() }
        var withLogin = VaultFixtures.account()
        withLogin.notes = []
        #expect(throws: (any Error).self) { try withLogin.validate() }
    }

    @Test func noteLimitsAreEnforced() throws {
        #expect(throws: (any Error).self) { try noteOnlyAccount([CredentialNote(text: "", field: nil)]).validate() }

        let atLimit = (0..<CredentialAccount.noteLimit).map { CredentialNote(text: "note \($0)", field: nil) }
        try noteOnlyAccount(atLimit).validate()
        #expect(throws: (any Error).self) { try noteOnlyAccount(atLimit + [CredentialNote(text: "one more", field: nil)]).validate() }

        let oversizedField = CredentialEditableFieldMetadata(id: Data(count: 1_025), label: nil, fieldType: .string)
        #expect(throws: (any Error).self) { try noteOnlyAccount([CredentialNote(text: "x", field: oversizedField)]).validate() }

        let tooLong = String(repeating: "n", count: CredentialVaultLimits.payloadBytes + 1)
        #expect(throws: (any Error).self) { try noteOnlyAccount([CredentialNote(text: tooLong, field: nil)]).validate() }
    }

    @Test func notesCountTowardThePayloadBudget() throws {
        let half = String(repeating: "n", count: CredentialVaultLimits.payloadBytes / 2 + 1)
        let account = noteOnlyAccount([CredentialNote(text: half, field: nil), CredentialNote(text: half, field: nil)])
        try account.validate()
        let payload = CredentialVaultPayload(revision: 0, accounts: [account], blockedPasswordOrigins: [])
        #expect(throws: (any Error).self) { try CredentialVaultCrypto.validate(payload) }
    }

    // MARK: Live budgets

    /// Accounts that all share one note string, so a vault of megabytes costs the test no memory.
    private func noteAccounts(_ count: Int, bytes: Int) -> [CredentialAccount] {
        let text = String(repeating: "n", count: bytes)
        return (0..<count).map { _ in noteOnlyAccount([CredentialNote(text: text, field: nil)]) }
    }

    @Test func liveBytesCountEachVariableField() throws {
        var account = VaultFixtures.account()
        // username 3 + password 6 + origin 20 + login address 26
        #expect(try CredentialVaultCrypto.liveBytes(of: account) == 55)
        account.notes = [CredentialNote(text: "memo", field: CredentialEditableFieldMetadata(id: Data([1, 2]), label: "Note", fieldType: .string))]
        account.totp = VaultFixtures.totp()
        // note text 4 + field id 2 + label 4, then the code: secret 5 + issuer 7
        #expect(try CredentialVaultCrypto.liveBytes(of: account) == 55 + 10 + 12)
    }

    /// A write checks an account the store holds byte for byte (`unchanged`) only towards the totals and the uniqueness rules; every
    /// other account is checked one by one.
    @Test func aWriteChecksOnlyItsChangedAccountsOneByOne() throws {
        var stored = VaultFixtures.account(username: "ada")
        stored.notes = []  // never valid: notes are nil or not empty
        let other = VaultFixtures.account(username: "grace", origin: "https://b.example")
        let payload = CredentialVaultPayload(revision: 0, accounts: [stored, other], blockedPasswordOrigins: [])
        #expect(throws: CredentialVaultError.invalidData) { try CredentialVaultCrypto.validate(payload) }
        try CredentialVaultCrypto.validate(payload, unchanged: [stored.id])
        #expect(throws: CredentialVaultError.invalidData) { try CredentialVaultCrypto.validate(payload, unchanged: [other.id]) }

        // An unchanged account still counts: no other account may hold its passkey's credential ID.
        let holder = VaultFixtures.account(username: "linus", origin: "https://c.example", passkeys: [try VaultFixtures.passkey()])
        let copy = VaultFixtures.account(username: "mary", origin: "https://d.example", passkeys: [try VaultFixtures.passkey()])
        #expect(throws: CredentialVaultError.duplicateIdentifier) {
            try CredentialVaultCrypto.validate(
                CredentialVaultPayload(revision: 0, accounts: [holder, copy], blockedPasswordOrigins: []), unchanged: [holder.id]
            )
        }
    }

    @Test func liveBytesAreCappedPerAccountAndInTotal() throws {
        func payload(_ accounts: [CredentialAccount], origins: Set<String> = []) -> CredentialVaultPayload {
            CredentialVaultPayload(revision: 0, accounts: accounts, blockedPasswordOrigins: origins)
        }
        // 32 accounts of 3.9 MB are 124.8 MB: inside the 128 MB total, and every account is inside its own 4 MB.
        let fits = noteAccounts(32, bytes: 3_900_000)
        try CredentialVaultCrypto.validate(payload(fits))
        try ProfileVaultStore.validate(fits, blockedOrigins: [])

        // The 33rd takes the total over 128 MB although no account is over its own cap.
        let overTotal = noteAccounts(33, bytes: 3_900_000)
        #expect(throws: CredentialVaultError.oversized) { try CredentialVaultCrypto.validate(payload(overTotal)) }
        #expect(throws: CredentialStoreError.limit(.payloadBytes)) { try ProfileVaultStore.validate(overTotal, blockedOrigins: []) }

        // One account of 4.1 MB is over its own cap, however small the vault is.
        let bigNotes = [
            CredentialNote(text: String(repeating: "n", count: 3_900_000), field: nil),
            CredentialNote(text: String(repeating: "n", count: 200_000), field: nil),
        ]
        let overOne = [noteOnlyAccount(bigNotes)]
        #expect(throws: CredentialVaultError.oversized) { try CredentialVaultCrypto.validate(payload(overOne)) }
        #expect(throws: CredentialStoreError.limit(.accountBytes)) { try ProfileVaultStore.validate(overOne, blockedOrigins: []) }

        // One account at exactly its cap is kept.
        try CredentialVaultCrypto.validate(payload(noteAccounts(1, bytes: CredentialVaultLimits.accountBytes)))
    }

    @Test func blockedOriginsCountTowardTheTotal() throws {
        // 32 accounts of 3,999,000 B are 127,968,000 B: 32,000 B of room.
        let accounts = noteAccounts(32, bytes: 3_999_000)
        let origins = Set((0..<2_000).map { "https://origin\($0).example.test" })
        #expect(origins.reduce(0) { $0 + $1.utf8.count } > 32_000)

        try ProfileVaultStore.validate(accounts, blockedOrigins: [])
        #expect(throws: CredentialStoreError.limit(.payloadBytes)) {
            try ProfileVaultStore.validate(accounts, blockedOrigins: Array(origins))
        }
    }

    @Test func legacyPayloadOver1000AccountsIsRefused() throws {
        func decoded(_ count: Int) throws -> CredentialVaultPayload {
            let accounts = (0..<count).map { VaultFixtures.account(username: "user\($0)") }
            let encoded = try JSONEncoder().encode(CredentialVaultPayload(revision: 1, accounts: accounts, blockedPasswordOrigins: []))
            return try JSONDecoder().decode(CredentialVaultPayload.self, from: encoded)
        }
        #expect(CredentialVaultLimits.legacyAccounts == 1_000)
        #expect(try decoded(CredentialVaultLimits.legacyAccounts).accounts.count == 1_000)
        #expect(throws: CredentialVaultError.oversized) { try decoded(CredentialVaultLimits.legacyAccounts + 1) }
    }

    @Test func legacyFileStaysAtFourMegabytesWhateverTheLiveCaps() throws {
        // An account of exactly 4 MB is inside the live caps, but its encoding is not inside the v1 file's 4 MB plaintext.
        let account = noteOnlyAccount([
            CredentialNote(text: String(repeating: "n", count: 3_000_000), field: nil),
            CredentialNote(text: String(repeating: "m", count: 1_000_000), field: nil),
        ])
        let payload = CredentialVaultPayload(revision: 0, accounts: [account], blockedPasswordOrigins: [])
        try CredentialVaultCrypto.validate(payload)
        #expect(throws: CredentialVaultError.oversized) { try CredentialVaultCrypto.encodePayload(payload) }
    }

    // MARK: Stored size

    /// A note of `count` control characters: one byte each as text, six once the store escapes them (`\u0001`).
    private func controlNote(_ count: Int) -> CredentialNote {
        CredentialNote(text: String(repeating: "\u{01}", count: count), field: nil)
    }

    @Test func aHistoryRowAlwaysHoldsAnAccountAtTheEncodedCap() {
        // A removed account holds its encoding; a revision or a removed credential holds a part of it as base64 text (4/3).
        let encoded = CredentialVaultLimits.encodedAccountBytes
        #expect(encoded + StoreFormat.historyBodyBytes <= StoreFormat.historyRowBytes)
        #expect(4 * ((encoded + 2) / 3) + StoreFormat.historyBodyBytes <= StoreFormat.historyRowBytes)
        // Every raw cap is under it, so the encoded cap is the one that decides for text that escapes.
        #expect(CredentialVaultLimits.accountBytes < encoded)
    }

    @Test func anAccountThatGrowsWhenEncodedIsRefusedWhateverItsRawSize() throws {
        // 1.2 MB of control characters is under every raw cap but encodes to about 7.2 MB, more than a history row can carry.
        let account = noteOnlyAccount([controlNote(1_200_000)])
        #expect(try CredentialVaultCrypto.liveBytes(of: account) == 1_200_000)
        #expect(try CredentialVaultCrypto.storedBytes(of: account) > CredentialVaultLimits.encodedAccountBytes)

        let payload = CredentialVaultPayload(revision: 0, accounts: [account], blockedPasswordOrigins: [])
        #expect(throws: CredentialVaultError.oversized) { try CredentialVaultCrypto.validate(payload) }
        #expect(throws: CredentialStoreError.limit(.accountBytes)) { try ProfileVaultStore.validate([account], blockedOrigins: []) }
        #expect(throws: CredentialVaultError.oversized) { try CredentialExchangeCodec.validateAccounts([account]) }

        // 900,000 of them encode to 5.4 MB and are kept, by the store and by the import's check alike.
        let kept = noteOnlyAccount([controlNote(900_000)])
        try ProfileVaultStore.validate([kept], blockedOrigins: [])
        try CredentialExchangeCodec.validateAccounts([kept])
    }
}
