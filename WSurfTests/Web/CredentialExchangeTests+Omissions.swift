// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Testing

@testable import WSurf

// A transfer is never refused for something WSurf cannot keep: the part is left out, named in the review, and the rest is
// imported. Only the checks that protect the vault still refuse a whole transfer.
extension CredentialExchangeTests {
    typealias Kind = CredentialExchangeError.CredentialKind
    typealias Omission = CredentialImportOmission

    private func field(_ value: String, type: ASImportableEditableField.FieldType = .concealedString) -> ASImportableEditableField {
        ASImportableEditableField(id: Data([0x51]), fieldType: type, value: value)
    }

    /// One credential of every kind WSurf does not store, each carrying `secret` so a leak into the review would show.
    private func unsupportedCredentials(_ secret: String) -> [(credential: ASImportableCredential, kind: Kind)] {
        let value = field(secret)
        return [
            (.address(.init(streetAddress: value, postalCode: nil, city: nil, territory: nil, country: nil, telephone: nil)), .address),
            (.apiKey(.init(key: value, userName: nil, keyType: nil, url: nil, validFrom: nil, expiryDate: nil)), .apiKey),
            (.creditCard(.init(number: value, fullName: nil, cardType: nil, verificationNumber: nil, pin: nil, expiryDate: nil, validFrom: nil)), .creditCard),
            (.customFields(.init(fields: [value])), .customFields),
            (.driversLicense(.init(
                fullName: value, birthDate: nil, issueDate: nil, expiryDate: nil, issuingAuthority: nil, territory: nil, country: nil,
                licenseNumber: nil, licenseClass: nil
            )), .driversLicense),
            (.generatedPassword(.init(password: secret)), .generatedPassword),
            (.identityDocument(.init(
                issuingCountry: nil, documentNumber: value, identificationNumber: nil, nationality: nil, fullName: nil, birthDate: nil,
                birthPlace: nil, sex: nil, issueDate: nil, expiryDate: nil, issuingAuthority: nil
            )), .identityDocument),
            (.itemReference(.init(reference: ASImportableLinkedItem(item: Data([0x52]), account: nil))), .itemReference),
            (.passport(.init(
                issuingCountry: nil, passportType: nil, passportNumber: value, nationalIdentificationNumber: nil, nationality: nil,
                fullName: nil, birthDate: nil, birthPlace: nil, sex: nil, issueDate: nil, expiryDate: nil, issuingAuthority: nil
            )), .passport),
            (.personName(.init(
                title: nil, given: value, givenInformal: nil, given2: nil, surnamePrefix: nil, surname: nil, surname2: nil,
                credentials: nil, generation: nil
            )), .personName),
            (.sshKey(.init(keyType: "ssh-ed25519", privateKey: Data(secret.utf8), keyComment: nil, creationDate: nil, expiryDate: nil, keyGenerationSource: nil)), .sshKey),
            (.wifi(.init(ssid: field("network", type: .string), networkSecurityType: nil, passphrase: value)), .wifi),
        ]
    }

    private struct UnkeptPart {
        let name: String
        let before: [ASImportableCredential]
        let credential: ASImportableCredential
        let kind: Kind
        let reason: Omission.Reason
    }

    private func imported(
        _ credentials: [ASImportableCredential],
        scope: ASImportableCredentialScope? = ASImportableCredentialScope(urls: [URL(string: "https://example.test/login")!], androidApps: [])
    ) throws -> CredentialImportPreview {
        try CredentialExchangeCodec.preview(data(scope: scope, credentials: credentials), against: snapshot([]))
    }

    private func omission(_ kind: Kind?, _ reason: Omission.Reason, credential: Int? = nil) -> Omission {
        Omission(
            record: credential.map { .credential(account: 0, item: 0, credential: $0) } ?? .item(account: 0, item: 0),
            title: "Example account", kind: kind, reason: reason
        )
    }

    // MARK: Kinds WSurf does not store

    @Test func unsupportedKindsAreOmittedAndDisclosed() throws {
        let secret = "must-not-appear-in-the-review"
        let cases = unsupportedCredentials(secret)
        #expect(cases.count == 12, "every kind WSurf does not store yet")
        for (credential, kind) in cases {
            let preview = try imported([basicAuthentication(username: "ada", password: "pw"), credential])

            let candidate = try #require(preview.candidates.first, "\(kind)")
            #expect(candidate.password == "pw" && candidate.username == "ada", "\(kind) must not stop the login")
            #expect(preview.omitted == [omission(kind, .unsupportedKind, credential: 1)], "\(kind)")
            #expect(!preview.omitted.map(\.text).joined().contains(secret))
            #expect(!String(describing: preview.omitted).contains(secret))
        }
    }

    @Test func omissionsNameTheExactPositionAndNeverTheContent() throws {
        let secret = "must-not-appear-in-diagnostics"
        let first = ASImportableAccount(
            id: Data([0xA1]), userName: "first", email: "", collections: [],
            items: [importableItem(id: Data([0xB1]), title: "first", credentials: [basicAuthentication(username: "first", password: "first")])]
        )
        let second = ASImportableAccount(
            id: Data([0xA2]), userName: "second", email: "", collections: [],
            items: [
                importableItem(id: Data([0xB2]), title: "valid", credentials: [basicAuthentication(username: "valid", password: "valid")]),
                importableItem(id: Data([0xB3]), title: "mixed", credentials: [
                    basicAuthentication(username: "safe", password: "safe"),
                    .generatedPassword(.init(password: secret)),
                ]),
            ]
        )
        let exported = ASExportedCredentialData(
            accounts: [first, second], formatVersion: .v1, exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture", timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let preview = try CredentialExchangeCodec.preview(exported, against: snapshot([]))

        #expect(preview.candidates.count == 3, "all three logins are imported")
        #expect(preview.omitted == [
            Omission(record: .credential(account: 1, item: 1, credential: 1), title: "mixed", kind: .generatedPassword, reason: .unsupportedKind),
        ])
        #expect(preview.omitted[0].record.description == "account[1]/item[1]/credential[1]")
        #expect(!String(describing: preview.omitted).contains(secret) && !preview.omitted[0].text.contains(secret))
    }

    @Test func anItemWithNothingToKeepIsSkippedAndNamed() throws {
        let preview = try imported([.wifi(.init(ssid: field("network", type: .string), networkSecurityType: nil, passphrase: field("pw")))])

        #expect(preview.candidates.isEmpty)
        #expect(preview.omitted == [
            omission(.wifi, .unsupportedKind, credential: 0),
            omission(nil, .nothingToKeep),
        ])

        let empty = try imported([])
        #expect(empty.candidates.isEmpty && empty.omitted == [omission(nil, .nothingToKeep)])
    }

    @Test func aValidItemSurvivesAnItemThatCannotBeKept() throws {
        let mixed = ASExportedCredentialData(
            accounts: [
                ASImportableAccount(
                    id: Data([0xA0, 0x78]), userName: "mixed", email: "", collections: [],
                    items: [
                        importableItem(id: Data([0xB0, 0x78]), title: "valid", credentials: [basicAuthentication(username: "valid", password: "valid")]),
                        importableItem(id: Data([0xB0, 0x79]), title: "invalid", credentials: [totp(period: 0)]),
                    ]
                ),
            ],
            formatVersion: .v1, exporterRelyingPartyIdentifier: "example.test", exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let preview = try CredentialExchangeCodec.preview(mixed, against: snapshot([]))

        #expect(preview.candidates.map(\.username) == ["valid"])
        #expect(preview.omitted.map(\.reason) == [.codeNotKept, .nothingToKeep])
        #expect(preview.omitted.map(\.title) == ["invalid", "invalid"])
    }

    // MARK: Parts that cannot be kept

    @Test func partsThatCannotBeKeptAreOmittedAndTheRestOfTheItemImports() throws {
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let login = basicAuthentication(username: "ada", password: "pw")
        func part(_ name: String, after before: [ASImportableCredential], _ credential: ASImportableCredential, _ kind: Kind, _ reason: Omission.Reason) -> UnkeptPart {
            UnkeptPart(name: name, before: before, credential: credential, kind: kind, reason: reason)
        }
        let cases = [
            part("invalid code", after: [login], totp(period: 0), .totp, .codeNotKept),
            part("second code", after: [login, totp()], totp(), .totp, .extraCode),
            part(
                "second login", after: [login, totp()],
                basicAuthentication(username: "two", password: "two", usernameID: Data([0x21]), passwordID: Data([0x22])),
                .basicAuthentication, .extraLogin
            ),
            part("unreadable key", after: [login, totp()], passkey(key: Data([0x30, 0x82, 0x01])), .passkey, .passkeyNotKept),
            part("key that is not ES256", after: [login, totp()], passkey(key: try rsaPKCS8()), .passkey, .passkeyNotKept),
            part("website the vault will not serve", after: [login, totp()], passkey(rpID: "com", key: key), .passkey, .passkeyNotKept),
        ]
        for unkept in cases {
            let name = unkept.name
            // What came first is kept; the part that follows is the one left out.
            let preview = try imported(unkept.before + [unkept.credential])

            let candidate = try #require(preview.candidates.first, "\(name)")
            #expect(candidate.password == "pw" && candidate.username == "ada", "\(name)")
            #expect(candidate.totp?.period == (unkept.before.count == 2 ? 45 : nil), "\(name)")
            #expect(candidate.passkeys.isEmpty, "\(name)")
            #expect(preview.omitted == [omission(unkept.kind, unkept.reason, credential: unkept.before.count)], "\(name)")
        }

        // A login with neither a username nor a password has nothing to keep; the code beside it is imported.
        let emptyLogin = try imported([totp(), .basicAuthentication(.init())])
        #expect(emptyLogin.candidates.first?.totp != nil && emptyLogin.candidates.first?.basicAuthenticationMetadata == nil)
        #expect(emptyLogin.omitted == [omission(.basicAuthentication, .emptyLogin, credential: 1)])

        // The same passkey twice is a duplicate identity, not a part to leave out.
        #expect(throws: CredentialExchangeError.self) {
            try imported([passkey(key: key), passkey(key: key)])
        }
    }

    @Test func aSkippedPasskeyDoesNotUseUpItsIdentity() throws {
        // The same invalid passkey twice is two skipped parts, not a duplicate: nothing was kept for it to duplicate.
        let preview = try imported([basicAuthentication(username: "ada", password: "pw"), passkey(key: Data([1])), passkey(key: Data([1]))])

        #expect(preview.candidates.first?.passkeys.isEmpty == true)
        #expect(preview.omitted.map(\.reason) == [.passkeyNotKept, .passkeyNotKept])
    }

    @Test func anUnusualFieldTypeIsKeptAsPlainText() throws {
        let preview = try imported([
            .basicAuthentication(.init(
                userName: .init(id: Data([1]), fieldType: .string, value: "ada"),
                password: .init(id: Data([2]), fieldType: .number, value: "123456")
            )),
            note("dated", type: .date),
        ])

        let candidate = try #require(preview.candidates.first)
        #expect(candidate.password == "123456" && candidate.basicAuthenticationMetadata?.password?.fieldType == .string)
        #expect(candidate.notes?.map(\.text) == ["dated"])
        #expect(preview.omitted == [omission(.basicAuthentication, .fieldDetailsSimplified, credential: 0), omission(.note, .fieldDetailsSimplified, credential: 1)])
    }

    @Test func aFieldDescriptionOverTheLimitIsDroppedNotRefused() throws {
        let preview = try imported([note("kept text", id: Data(count: 2_000), label: String(repeating: "l", count: 3_000))])

        let kept = try #require(preview.candidates.first?.notes?.first)
        #expect(kept.text == "kept text" && kept.field == nil)
        #expect(preview.omitted == [omission(.note, .fieldDetailsSimplified, credential: 0)])
    }

    // MARK: Websites and sharing

    @Test func websitesThatCannotBeKeptAreDroppedAndNamed() throws {
        let scope = ASImportableCredentialScope(
            urls: [
                URL(string: "https://example.test/login?token=secret#section")!,
                URL(string: "http://insecure.test/")!,
                URL(string: "javascript:alert(1)")!,
                URL(string: "https://user:pass@other.test/path")!,
            ],
            androidApps: [.init(bundleID: "test.example.app", certificate: nil, name: nil)]
        )

        let preview = try imported([basicAuthentication(username: "ada", password: "pw")], scope: scope)

        let candidate = try #require(preview.candidates.first)
        #expect(candidate.origins == ["https://example.test", "https://other.test"])
        #expect(candidate.loginURLs.map(\.absoluteString) == ["https://example.test/login", "https://other.test/path"])
        #expect(preview.omitted == [omission(nil, .websitesNotKept), omission(nil, .androidAppsNotKept)])
        #expect(!String(describing: preview.omitted).contains("secret"))
    }

    @Test func itemSharingIsIgnoredAndNamed() throws {
        guard #available(macOS 26.4, *) else { return }
        var item = importableItem(id: itemExternalID, title: "Shared", credentials: [basicAuthentication(username: "ada", password: "pw")])
        item.extensions = [.shared(.init(accessors: []))]
        let exported = ASExportedCredentialData(
            accounts: [ASImportableAccount(id: accountExternalID, userName: "ada", email: "", collections: [], items: [item])],
            formatVersion: .v1, exporterRelyingPartyIdentifier: "example.test", exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let preview = try CredentialExchangeCodec.preview(exported, against: snapshot([]))

        #expect(preview.candidates.count == 1)
        #expect(preview.omitted == [Omission(record: .item(account: 0, item: 0), title: "Shared", kind: nil, reason: .sharingNotKept)])
    }

    // MARK: What still refuses

    private func expectRefused(
        _ input: ASExportedCredentialData,
        against base: StoreSnapshot,
        _ reason: CredentialExchangeError.Reason,
        at record: CredentialExchangeError.Record,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try CredentialExchangeCodec.preview(input, against: base)
            Issue.record("Expected the transfer to be refused", sourceLocation: sourceLocation)
        } catch let error as CredentialExchangeError {
            #expect(error.reason == reason, sourceLocation: sourceLocation)
            #expect(error.record == record, sourceLocation: sourceLocation)
        } catch {
            Issue.record("Expected a positioned refusal, got \(error)", sourceLocation: sourceLocation)
        }
    }

    private func transfer(_ items: [ASImportableItem], collections: [ASImportableCollection] = []) -> ASExportedCredentialData {
        ASExportedCredentialData(
            accounts: [ASImportableAccount(id: accountExternalID, userName: "ada", email: "", collections: collections, items: items)],
            formatVersion: .v1, exporterRelyingPartyIdentifier: "example.test", exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test func structuralErrorsStillRefuse() throws {
        let base = snapshot([account(externalID: accountExternalID, itemID: itemExternalID)])
        let login = basicAuthentication(username: "ada", password: "pw")
        let secret = "must-not-appear-in-diagnostics"

        // The same field id for the username and the password: refused, and the diagnostic carries no value.
        let sameIDs = data(credentials: [basicAuthentication(username: "same-id", password: secret, usernameID: Data([0x66]), passwordID: Data([0x66]))])
        expectRefused(sameIDs, against: base, .duplicateIdentifier, at: .credential(account: 0, item: 0, credential: 0))
        do {
            _ = try CredentialExchangeCodec.preview(sameIDs, against: base)
        } catch {
            #expect(!String(describing: error).contains(secret))
        }

        expectRefused(data(credentials: [totp(secret: Data(repeating: 0xA5, count: 4_000_001))]), against: base, .oversized, at: .credential(account: 0, item: 0, credential: 0))

        let duplicateAccount = ASExportedCredentialData(
            accounts: [
                ASImportableAccount(id: accountExternalID, userName: "one", email: "", collections: [], items: []),
                ASImportableAccount(id: accountExternalID, userName: "two", email: "", collections: [], items: []),
            ],
            formatVersion: .v1, exporterRelyingPartyIdentifier: "example.test", exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        expectRefused(duplicateAccount, against: base, .duplicateIdentifier, at: .account(index: 1))

        let first = importableItem(id: itemExternalID, title: "first", credentials: [login])
        let second = importableItem(id: itemExternalID, title: "second", credentials: [basicAuthentication(username: "two", password: "two")])
        expectRefused(transfer([first, second]), against: base, .invalidData, at: .item(account: 0, item: 1))
        expectRefused(transfer([importableItem(id: Data(), title: "no id", credentials: [login])]), against: base, .invalidData, at: .item(account: 0, item: 0))

        // The same passkey (website and credential id) in two items is one identity claimed twice.
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let onePasskey = importableItem(id: Data([0xB1]), title: "one", credentials: [passkey(key: key)])
        let samePasskey = importableItem(id: Data([0xB2]), title: "two", credentials: [passkey(key: key)])
        expectRefused(transfer([onePasskey, samePasskey]), against: base, .duplicateIdentifier, at: .credential(account: 0, item: 1, credential: 0))

        // Size budgets: more than 64 websites for one item, and collections nested deeper than 32 levels.
        let manyWebsites = ASImportableCredentialScope(urls: (0...64).map { URL(string: "https://site\($0).example.test/")! }, androidApps: [])
        expectRefused(data(scope: manyWebsites, credentials: [login]), against: base, .oversized, at: .item(account: 0, item: 0))
        var chain = ASImportableCollection(id: Data([0xC0, 0]), created: nil, lastModified: nil, title: "leaf", subtitle: nil, items: [], subcollections: [])
        for level in 1...33 {
            chain = ASImportableCollection(
                id: Data([0xC0, UInt8(level)]), created: nil, lastModified: nil, title: "level", subtitle: nil, items: [], subcollections: [chain]
            )
        }
        expectRefused(transfer([first], collections: [chain]), against: base, .oversized, at: .collection(account: 0, path: [0]))

        // A stored vault that already fails its own checks is never imported into: two stored accounts claiming one exporter item.
        let twin = account(id: UUID(), externalID: accountExternalID, itemID: itemExternalID, username: "twin")
        #expect(throws: CredentialVaultError.duplicateIdentifier) {
            try CredentialExchangeCodec.preview(data(credentials: [login]), against: snapshot([base.accounts[0], twin]))
        }
    }
}
