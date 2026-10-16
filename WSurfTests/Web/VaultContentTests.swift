// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

struct VaultContentTests {
    nonisolated enum Owner: CaseIterable, Hashable, Sendable {
        case password, totp, passkey, metadata

        func part(of account: CredentialAccount) -> CredentialPart {
            switch self {
            case .password:
                .password(account)
            case .totp:
                .totp(account)
            case .passkey:
                .passkey(account.passkeys[0])
            case .metadata:
                .metadata(account)
            }
        }
    }

    /// One semantic field per case; each must change exactly the hash of its owning part.
    nonisolated enum SemanticField: CaseIterable, Sendable {
        case username, password
        case totpSecret, totpAlgorithm, totpPeriod, totpDigits, totpIssuer, totpUserName
        case rpID, credentialID, userHandle, privateKey
        case origins, loginURLs, displayName

        var owner: Owner {
            switch self {
            case .username, .password:
                .password
            case .totpSecret, .totpAlgorithm, .totpPeriod, .totpDigits, .totpIssuer, .totpUserName:
                .totp
            case .rpID, .credentialID, .userHandle, .privateKey:
                .passkey
            case .origins, .loginURLs, .displayName:
                .metadata
            }
        }

        func apply(to account: inout CredentialAccount) throws {
            switch self {
            case .username:
                account.username = "grace"
            case .password:
                account.password = "other"
            case .totpSecret:
                account.totp?.secret = Data([9, 9, 9])
            case .totpAlgorithm:
                account.totp?.algorithm = .sha256
            case .totpPeriod:
                account.totp?.period = 60
            case .totpDigits:
                account.totp?.digits = 8
            case .totpIssuer:
                account.totp?.issuer = "Other"
            case .totpUserName:
                account.totp?.userName = "ada"
            case .rpID:
                account.passkeys[0].rpID = "other.test"
            case .credentialID:
                account.passkeys[0].credentialID = Data([1, 2, 3])
            case .userHandle:
                account.passkeys[0].userHandle = Data([3, 2, 1])
            case .privateKey:
                let key = try P256.Signing.PrivateKey(rawRepresentation: Data((2...33).map { UInt8($0) }))
                account.passkeys[0].privateKeyPKCS8 = try PasskeyKeyEncoding.exportPKCS8(key)
            case .origins:
                account.origins = ["https://example.test", "https://other.test"]
            case .loginURLs:
                account.loginURLs = [URL(string: "https://example.test/other")!]
            case .displayName:
                account.displayName = "Home"
            }
        }
    }

    private func hashes(of account: CredentialAccount) throws -> [Owner: Data] {
        var result: [Owner: Data] = [:]
        for owner in Owner.allCases {
            result[owner] = try CredentialContent.hash(owner.part(of: account))
        }
        return result
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func metadataAccount(_ edit: (inout VaultFixtures.ExchangeMetadata) -> Void) throws -> CredentialAccount {
        var metadata = VaultFixtures.exchangeMetadata()
        edit(&metadata)
        var account = try VaultFixtures.richAccount()
        account.exchangeMetadata = try VaultFixtures.sortedJSON(metadata)
        return account
    }

    private static func isInvalidData(_ error: Error) -> Bool {
        guard let vaultError = error as? CredentialVaultError, case .invalidData = vaultError else {
            return false
        }
        return true
    }

    @Test func hashIgnoresTimestampsCountersAndExchangeDates() throws {
        let base = try VaultFixtures.richAccount()
        let baseline = try hashes(of: base)
        let events = CredentialEvents(
            lastImportedAt: VaultFixtures.reference(1),
            lastExportHandoffAt: VaultFixtures.reference(2),
            remoteLastObservedAt: VaultFixtures.reference(3),
            lastExportHandoffHash: Data(repeating: 9, count: 32)
        )
        let exchangeBase = ExchangeBase(contentHash: Data(repeating: 7, count: 32), itemID: Data([1]))

        var changed = base
        changed.createdAt = VaultFixtures.reference(10)
        changed.modifiedAt = VaultFixtures.reference(11)
        changed.migratedAt = VaultFixtures.reference(12)
        changed.passwordEvents = events
        changed.totpEvents = events
        changed.passwordBase = exchangeBase
        changed.totpBase = exchangeBase
        changed.passkeys[0].events = events
        changed.passkeys[0].base = exchangeBase
        changed.passkeys[0].lastSignedAt = VaultFixtures.reference(13)
        changed.passkeys[0].createdAt = VaultFixtures.reference(14)
        #expect(try hashes(of: changed) == baseline)

        var redated = try metadataAccount { metadata in
            metadata.created = VaultFixtures.reference(5_000)
            metadata.lastModified = VaultFixtures.reference(6_000)
            metadata.collections[0].created = VaultFixtures.reference(7_000)
            metadata.collections[0].lastModified = VaultFixtures.reference(8_000)
            metadata.collections[0].subcollections[0].created = VaultFixtures.reference(9_000)
            metadata.collections[0].subcollections[0].lastModified = VaultFixtures.reference(9_500)
        }
        redated.exchangeAccountID = Data([0xFE])
        redated.exchangeItemID = Data([0xFD])
        #expect(try hashes(of: redated) == baseline)
    }

    @Test(arguments: SemanticField.allCases)
    func hashChangesForEverySemanticField(field: SemanticField) throws {
        let base = try VaultFixtures.richAccount()
        let baseline = try hashes(of: base)

        var changed = base
        try field.apply(to: &changed)
        let after = try hashes(of: changed)

        for owner in Owner.allCases {
            #expect((after[owner] != baseline[owner]) == (owner == field.owner), "\(field) vs \(owner)")
        }
    }

    @Test func equivalentPasskeyDERHashesEqual() throws {
        var full = try VaultFixtures.fixedPasskey()
        full.privateKeyPKCS8 = try VaultFixtures.fixedPKCS8(embeddingPublicKey: true)
        var bare = full
        bare.privateKeyPKCS8 = try VaultFixtures.fixedPKCS8(embeddingPublicKey: false)

        #expect(full.privateKeyPKCS8 != bare.privateKeyPKCS8)
        #expect(try CredentialContent.hash(.passkey(full)) == CredentialContent.hash(.passkey(bare)))
    }

    @Test func passkeyHashExcludesDERSpellingNamesFlagsSourceAndDates() throws {
        let base = try VaultFixtures.fixedPasskey()
        let baseline = try CredentialContent.hash(.passkey(base))
        let events = CredentialEvents(lastImportedAt: VaultFixtures.reference(1))

        var ignored: [WebsitePasskey] = []
        func variant(_ edit: (inout WebsitePasskey) throws -> Void) rethrows {
            var passkey = base
            try edit(&passkey)
            ignored.append(passkey)
        }
        variant { $0.userName = "someone-else" }
        variant { $0.userDisplayName = "Someone Else" }
        variant { $0.backupState = true }
        variant { $0.backupEligible = false }
        variant { $0.exchangeFIDO2Metadata = Data([1, 2, 3]) }
        variant { $0.source = .imported }
        variant { $0.createdAt = VaultFixtures.reference(5) }
        variant { $0.lastSignedAt = VaultFixtures.reference(6) }
        variant { $0.events = events }
        variant { $0.base = ExchangeBase(contentHash: Data(repeating: 1, count: 32), itemID: nil) }
        variant { $0.rpID = "EXAMPLE.TEST" }
        try variant { $0.privateKeyPKCS8 = try VaultFixtures.fixedPKCS8(embeddingPublicKey: false) }

        for passkey in ignored {
            #expect(try CredentialContent.hash(.passkey(passkey)) == baseline)
        }

        var other = base
        other.rpID = "other.test"
        let rpHash = try CredentialContent.hash(.passkey(other))
        other = base
        other.credentialID = Data([1])
        let credentialHash = try CredentialContent.hash(.passkey(other))
        other = base
        other.userHandle = Data([4])
        let handleHash = try CredentialContent.hash(.passkey(other))
        other = base
        other.privateKeyPKCS8 = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let keyHash = try CredentialContent.hash(.passkey(other))
        let changed = [baseline, rpHash, credentialHash, handleHash, keyHash]
        #expect(Set(changed).count == changed.count)
    }

    @Test func passwordHashCoversUsernamePasswordAndBasicAuthMetadata() throws {
        func hash(_ edit: (inout CredentialAccount) -> Void) throws -> Data {
            var account = try VaultFixtures.richAccount()
            edit(&account)
            return try CredentialContent.hash(.password(account))
        }
        func metadata(_ edit: (inout CredentialBasicAuthenticationMetadata) -> Void) throws -> Data {
            var value = CredentialBasicAuthenticationMetadata(
                username: CredentialEditableFieldMetadata(id: Data([1]), label: "User", fieldType: .string),
                password: CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)
            )
            edit(&value)
            return try hash { $0.basicAuthenticationMetadata = value }
        }

        let hashes = try [
            hash { _ in },
            hash { $0.username = "grace" },
            hash { $0.password = "other" },
            hash { $0.password = nil },
            hash { $0.password = "" },
            metadata { _ in },
            metadata { $0.username?.id = Data([2]) },
            metadata { $0.username?.id = nil },
            metadata { $0.username?.label = "Name" },
            metadata { $0.username?.label = nil },
            metadata { $0.username?.fieldType = .email },
            metadata { $0.username = nil },
            metadata { $0.password?.id = Data([1]) },
            metadata { $0.password?.label = "Pass" },
            metadata { $0.password?.fieldType = .string },
            metadata { $0.password = nil },
        ]
        #expect(Set(hashes).count == hashes.count)
    }

    @Test func totpHashCoversAllSixFields() throws {
        func hash(_ edit: (inout TOTPGenerator?) -> Void) throws -> Data {
            var account = try VaultFixtures.richAccount()
            edit(&account.totp)
            return try CredentialContent.hash(.totp(account))
        }

        let hashes = try [
            hash { _ in },
            hash { $0 = nil },
            hash { $0?.secret = Data([1, 2, 3, 4, 6]) },
            hash { $0?.algorithm = .sha512 },
            hash { $0?.period = 31 },
            hash { $0?.digits = 7 },
            hash { $0?.issuer = nil },
            hash { $0?.issuer = "" },
            hash { $0?.userName = "ada" },
            hash { $0?.userName = "" },
        ]
        #expect(Set(hashes).count == hashes.count)
    }

    @Test func noteHashCoversTextAndField() throws {
        func hash(_ notes: [CredentialNote]?) throws -> Data {
            var account = try VaultFixtures.richAccount()
            account.notes = notes
            return try CredentialContent.hash(.note(account))
        }
        func note(_ text: String = "first", _ field: CredentialEditableFieldMetadata? = nil) -> CredentialNote {
            CredentialNote(text: text, field: field)
        }
        let described = CredentialEditableFieldMetadata(id: Data([1]), label: "Note", fieldType: .string)

        let hashes = try [
            hash(nil),
            hash([note()]),
            hash([note("second")]),
            hash([note("first", described)]),
            hash([note("first", CredentialEditableFieldMetadata(id: Data([2]), label: "Note", fieldType: .string))]),
            hash([note("first", CredentialEditableFieldMetadata(id: Data([1]), label: "Other", fieldType: .string))]),
            hash([note("first", CredentialEditableFieldMetadata(id: nil, label: "Note", fieldType: .string))]),
            hash([note("first", CredentialEditableFieldMetadata(id: Data([1]), label: nil, fieldType: .string))]),
            hash([note("first", CredentialEditableFieldMetadata(id: Data([1]), label: "Note", fieldType: .concealedString))]),
            hash([note("first"), note("second")]),
            hash([note("second"), note("first")]),
            // The exact UTF-8 counts: a composed and a decomposed "é" are two different notes.
            hash([note("\u{e9}")]),
            hash([note("e\u{301}")]),
        ]
        #expect(Set(hashes).count == hashes.count)

        // Notes belong to their own part: no other part's hash moves with them, and no other part's change moves the note hash.
        var withNotes = try VaultFixtures.richAccount()
        withNotes.notes = [note()]
        let plain = try VaultFixtures.richAccount()
        for owner in Owner.allCases {
            #expect(try CredentialContent.hash(owner.part(of: withNotes)) == CredentialContent.hash(owner.part(of: plain)), "\(owner)")
        }
        var edited = withNotes
        edited.password = "other"
        edited.totp?.secret = Data([9])
        edited.displayName = "Home"
        #expect(try CredentialContent.hash(.note(edited)) == CredentialContent.hash(.note(withNotes)))
    }

    @Test func metadataHashExcludesInheritedDatesAndIDsButCoversEveryOtherKnownField() throws {
        let baseline = try CredentialContent.hash(.metadata(VaultFixtures.richAccount()))

        // Unknown keys in the stored JSON are not part of the typed value.
        var withUnknownKey = try VaultFixtures.richAccount()
        let raw = try #require(withUnknownKey.exchangeMetadata)
        var object = try #require(JSONSerialization.jsonObject(with: raw) as? [String: Any])
        object["futureKey"] = "ignored"
        withUnknownKey.exchangeMetadata = try JSONSerialization.data(withJSONObject: object)
        #expect(try CredentialContent.hash(.metadata(withUnknownKey)) == baseline)

        let edits: [(inout VaultFixtures.ExchangeMetadata) -> Void] = [
            { $0.accountName = "grace@example.test" },
            { $0.email = "grace@example.test" },
            { $0.fullName = nil },
            { $0.fullName = "Grace H" },
            { $0.subtitle = nil },
            { $0.subtitle = "Home login" },
            { $0.favorite = false },
            { $0.tags = ["a"] },
            { $0.tags = ["b", "a"] },
            { $0.collections = [] },
            { $0.collections[0].id = Data([0x11]) },
            { $0.collections[0].title = "Other" },
            { $0.collections[0].subtitle = "Now" },
            { $0.collections[0].items = [] },
            { $0.collections[0].items[0].item = Data([0x22]) },
            { $0.collections[0].items[0].account = nil },
            { $0.collections[0].items[1].account = Data([0x33]) },
            { $0.collections[0].items.append(VaultFixtures.ExchangeLink(item: Data([6]), account: nil)) },
            { $0.collections[0].subcollections = [] },
            { $0.collections[0].subcollections[0].id = Data([0x55]) },
            { $0.collections[0].subcollections[0].title = "Other" },
            { $0.collections[0].subcollections[0].subtitle = nil },
            { $0.collections[0].subcollections[0].items = [VaultFixtures.ExchangeLink(item: Data([7]), account: nil)] },
            { metadata in
                let deeper = VaultFixtures.ExchangeCollection(
                    id: Data([0x66]),
                    created: nil,
                    lastModified: nil,
                    title: "Deeper",
                    subtitle: nil,
                    items: [],
                    subcollections: []
                )
                metadata.collections[0].subcollections[0].subcollections = [deeper]
            },
        ]
        var hashes = [baseline]
        for edit in edits {
            hashes.append(try CredentialContent.hash(.metadata(metadataAccount(edit))))
        }
        #expect(Set(hashes).count == hashes.count)
    }

    @Test func hashThrowsInsteadOfTrapping() throws {
        let good = try VaultFixtures.fixedPasskey()
        var malformed = good
        malformed.privateKeyPKCS8 = Data([1, 2, 3])
        var truncated = good
        truncated.privateKeyPKCS8 = try Data(VaultFixtures.fixedPKCS8().dropLast(5))
        var empty = good
        empty.privateKeyPKCS8 = Data()
        var wrongAlgorithm = good
        wrongAlgorithm.algorithm = -8

        for passkey in [malformed, truncated, empty, wrongAlgorithm] {
            #expect { try CredentialContent.hash(.passkey(passkey)) } throws: { Self.isInvalidData($0) }
        }

        var undecodable = try VaultFixtures.richAccount()
        undecodable.exchangeMetadata = Data("not json".utf8)
        #expect(throws: CredentialStoreError.metadataUndecodable) {
            try CredentialContent.hash(.metadata(undecodable))
        }

        // No raw-byte fallback and no cross-part failure: the other parts of that account still hash.
        #expect(try CredentialContent.hash(.password(undecodable)) == CredentialContent.hash(.password(VaultFixtures.richAccount())))
        #expect(try CredentialContent.hash(.totp(undecodable)).count == 32)
        #expect(try CredentialContent.hash(.passkey(undecodable.passkeys[0])).count == 32)
    }

    /// Accounts without notes hash exactly as they did before the note part existed (tags 1-4 untouched). The digests come from
    /// the documented `StoreWriter` bytes (u8 tag, text = u32 length + UTF-8, opt = u8 0/1 + value, array = u32 count + elements),
    /// computed with an independent script before the note part was written.
    @Test func noteLessAccountHashesAreUnchanged() throws {
        let plain = CredentialAccount(
            id: VaultFixtures.fixedAccountID, username: "ada", displayName: "Work", origins: ["https://example.test"],
            loginURLs: [URL(string: "https://example.test/login")!], password: "s3cret", passkeys: [], totp: nil,
            exchangeAccountID: nil, exchangeItemID: nil
        )
        let usernameOnly = CredentialAccount(
            id: VaultFixtures.fixedAccountID, username: "grace", displayName: nil, origins: [], loginURLs: [], password: nil,
            passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        #expect(hex(try CredentialContent.hash(.password(plain))) == "17b1675505ae09f51daaca310d30133f57b72ddb49083cda63f2f41eb51e86b8")
        #expect(hex(try CredentialContent.hash(.totp(plain))) == "99be5efb88ca2013bd8e4eb035fd42d5245468fe9afa70d8ba9c1c419a48c4e8")
        #expect(hex(try CredentialContent.hash(.metadata(plain))) == "db7e2be921061085334969afc4eac69abb1268d8ae6007a0b9024afeb6506beb")
        #expect(hex(try CredentialContent.hash(.password(usernameOnly))) == "5f78d5f6811d3e5a01429d1d3f3375f7890b4f27effd5e8d65cea547e3a54e16")
        #expect(hex(try CredentialContent.hash(.metadata(usernameOnly))) == "c6f378205327fa9e8eb42cfdbeff1702d60a5fbf5e1a909ba6c6ca0ecd971907")

        // The persisted payload of a note-less account never mentions notes, so stored vaults stay byte-identical.
        let json = String(decoding: try CredentialContent.canonicalJSON(plain), as: UTF8.self)
        #expect(!json.contains("notes"))
    }

    /// Golden digests computed outside the app (throwaway script, SHA-256 over the documented `StoreWriter` bytes:
    /// u8 tag, text = u32 length + UTF-8, opt = u8 0/1 + value, array = u32 count + elements) before any
    /// implementation existed. The passkey public point is the P-256 point for scalar 0x01...0x20.
    @Test func hashIsStable() throws {
        let rich = try VaultFixtures.richAccount()

        var basicAuth = rich
        basicAuth.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: Data([1]), label: "User", fieldType: .string),
            password: CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)
        )

        var noTOTP = rich
        noTOTP.totp = nil

        var noExchange = rich
        noExchange.exchangeMetadata = nil

        #expect(hex(try CredentialContent.hash(.password(rich))) == "17b1675505ae09f51daaca310d30133f57b72ddb49083cda63f2f41eb51e86b8")
        #expect(hex(try CredentialContent.hash(.password(basicAuth))) == "51123fe515522c2fe477d5f2c15ea79a05f7ba52cf93fe09ebb86b531e4089cf")
        #expect(hex(try CredentialContent.hash(.totp(rich))) == "cfd280502e85b4de0a6fac52d0968651a1d48fbd4243f0310054f3d1225d2da1")
        #expect(hex(try CredentialContent.hash(.totp(noTOTP))) == "99be5efb88ca2013bd8e4eb035fd42d5245468fe9afa70d8ba9c1c419a48c4e8")
        #expect(hex(try CredentialContent.hash(.passkey(rich.passkeys[0]))) == "3290ec9caa92ed4bdb6ecb0289d8545556f15f3c7762d317fd90fe1f71ee56c0")
        #expect(hex(try CredentialContent.hash(.metadata(rich))) == "8461c70568b54c9b8520ead97f6a332457760c38c3e4f67e3f894b8c8916eea1")
        #expect(hex(try CredentialContent.hash(.metadata(noExchange))) == "db7e2be921061085334969afc4eac69abb1268d8ae6007a0b9024afeb6506beb")
    }
}
