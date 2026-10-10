// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Security
import Testing

@testable import WSurf

@MainActor
struct CredentialExchangeTests {
    private let accountID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    private let passkeyID = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
    private let accountExternalID = Data([0xA0, 0x01])
    private let itemExternalID = Data([0xB0, 0x01])
    private let origin = "https://example.test"

    private func securityVerifiesX963PublicKey(_ x963: Data, message: Data, signature: Data) throws -> Bool {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256
        ]
        let publicKey = try #require(SecKeyCreateWithData(x963 as CFData, attributes as CFDictionary, nil))
        return SecKeyVerifySignature(
            publicKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            signature as CFData,
            nil
        )
    }

    private func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var remaining = count
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    private func derValue(_ tag: UInt8, _ value: Data) -> Data {
        var result = Data([tag])
        result.append(derLength(value.count))
        result.append(value)
        return result
    }

    private func rsaPKCS8() throws -> Data {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 1024
        ]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        var body = derValue(0x02, Data([0]))
        body.append(algorithm)
        body.append(derValue(0x04, pkcs1))
        return derValue(0x30, body)
    }

    private func snapshot(_ accounts: [CredentialAccount], revision: UInt64 = 3) -> VaultSnapshot {
        VaultSnapshot(revision: revision, accounts: accounts, blockedPasswordOrigins: [])
    }

    private func account(
        id: UUID = UUID(),
        externalID: Data? = nil,
        itemID: Data? = nil,
        username: String = "ada",
        password: String? = "old-password",
        passkeys: [WebsitePasskey] = [],
        totp: TOTPGenerator? = nil
    ) -> CredentialAccount {
        CredentialAccount(
            id: id,
            username: username,
            displayName: nil,
            origins: [origin],
            loginURLs: [],
            password: password,
            passkeys: passkeys,
            totp: totp,
            exchangeAccountID: externalID,
            exchangeItemID: itemID
        )
    }

    private func basicAuthentication(
        username: String,
        password: String,
        usernameID: Data? = Data([0x11]),
        passwordID: Data? = Data([0x12])
    ) -> ASImportableCredential {
        .basicAuthentication(.init(
            userName: .init(id: usernameID, fieldType: .string, value: username, label: "Login"),
            password: .init(id: passwordID, fieldType: .concealedString, value: password, label: "Secret")
        ))
    }

    private func passkey(
        id: Data = Data([0xC0, 0x01]),
        rpID: String = "example.test",
        userHandle: Data = Data([0x31, 0x32]),
        key: Data
    ) -> ASImportableCredential {
        .passkey(.init(
            credentialID: id,
            relyingPartyIdentifier: rpID,
            userName: "ada",
            userDisplayName: "Ada Lovelace",
            userHandle: userHandle,
            key: key
        ))
    }

    private func totp(
        secret: Data = Data("independent-test-seed".utf8),
        period: UInt16 = 45,
        digits: UInt16 = 10,
        algorithm: ASImportableCredential.TOTP.Algorithm = .sha512,
        issuer: String? = "Example Issuer",
        username: String? = "ada"
    ) -> ASImportableCredential {
        .totp(.init(secret: secret, period: period, digits: digits, userName: username, algorithm: algorithm, issuer: issuer))
    }

    private func importableItem(
        id: Data,
        title: String,
        created: Date? = nil,
        lastModified: Date? = nil,
        subtitle: String? = nil,
        favorite: Bool = false,
        scope: ASImportableCredentialScope? = nil,
        credentials: [ASImportableCredential],
        tags: [String] = []
    ) -> ASImportableItem {
        var item = ASImportableItem(
            id: id,
            created: created ?? .distantPast,
            lastModified: lastModified ?? .distantPast,
            title: title,
            scope: scope,
            credentials: credentials,
            tags: tags
        )
        item.created = created
        item.lastModified = lastModified
        item.subtitle = subtitle
        item.favorite = favorite
        return item
    }

    private func data(
        accountID: Data = Data([0xA0, 0x01]),
        itemID: Data = Data([0xB0, 0x01]),
        title: String = "Example account",
        scope: ASImportableCredentialScope? = ASImportableCredentialScope(urls: [URL(string: "https://example.test/login")!], androidApps: []),
        credentials: [ASImportableCredential]
    ) -> ASExportedCredentialData {
        let item = importableItem(id: itemID, title: title, scope: scope, credentials: credentials)
        let account = ASImportableAccount(id: accountID, userName: "ada", email: "ada@example.test", collections: [], items: [item])
        return ASExportedCredentialData(
            accounts: [account],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func credentials(in data: ASExportedCredentialData) -> [ASImportableCredential] {
        data.accounts.flatMap(\.items).flatMap(\.credentials)
    }

    @Test func linkedPasswordPasskeyAndNondefaultTOTPExportReimportByUse() throws {
        let sourceKey = P256.Signing.PrivateKey()
        let pkcs8 = try PasskeyKeyEncoding.exportPKCS8(sourceKey)
        let challenge = Data("exchange codec use fixture".utf8)
        let generator = TOTPGenerator(
            secret: Data("independent-test-seed".utf8),
            algorithm: .sha512,
            period: 45,
            digits: 10,
            issuer: "Example Issuer",
            userName: "ada"
        )
        let incoming = data(credentials: [
            .basicAuthentication(.init(
                userName: .init(id: Data([0x21]), fieldType: .concealedString, value: "ada", label: "Imported account identifier"),
                password: .init(id: Data([0x22]), fieldType: .string, value: "new-password", label: "Imported secret field")
            )),
            passkey(key: pkcs8),
            totp()
        ])

        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([]))
        let imported = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(imported.count == 1)
        let importedAccount = try #require(imported.first)
        #expect(importedAccount.username == "ada")
        #expect(importedAccount.password == "new-password")
        #expect(importedAccount.exchangeAccountID == accountExternalID)
        #expect(importedAccount.exchangeItemID == itemExternalID)
        #expect(importedAccount.totp?.secret == generator.secret)
        #expect(importedAccount.totp?.algorithm == .sha512)
        #expect(importedAccount.totp?.period == 45 && importedAccount.totp?.digits == 10)
        #expect(importedAccount.totp?.issuer == "Example Issuer" && importedAccount.totp?.userName == "ada")
        let importedPasskey = try #require(importedAccount.passkeys.first)
        #expect(importedPasskey.credentialID == Data([0xC0, 0x01]))
        #expect(importedPasskey.rpID == "example.test")
        #expect(importedPasskey.userHandle == Data([0x31, 0x32]))
        let importedSigner = try PasskeyKeyEncoding.importPKCS8(importedPasskey.privateKeyPKCS8)
        #expect(try securityVerifiesX963PublicKey(
            sourceKey.publicKey.x963Representation,
            message: challenge,
            signature: importedSigner.signature(for: challenge).derRepresentation
        ))
        let importedGenerator = try #require(importedAccount.totp)
        for time in [1_700_000_017.0, 1_700_000_054.0, 1_700_000_055.0] {
            #expect(try TOTP.code(importedGenerator, at: time).value == TOTP.code(generator, at: time).value)
        }

        let exported = try CredentialExchangeCodec.export(
            snapshot(imported),
            selection: [.init(accountID: importedAccount.id, password: true, passkeyIDs: [importedPasskey.id], totp: true)],
            format: .v1
        )
        let exportedCredentials = credentials(in: exported)
        let exportedBasic = try #require(exportedCredentials.compactMap { credential -> ASImportableCredential.BasicAuthentication? in
            guard case let .basicAuthentication(value) = credential else { return nil }
            return value
        }.first)
        #expect(exportedBasic.userName?.value == "ada")
        #expect(exportedBasic.password?.value == "new-password")
        #expect(exportedBasic.userName?.id == Data([0x21]) && exportedBasic.userName?.label == "Imported account identifier")
        #expect(exportedBasic.password?.id == Data([0x22]) && exportedBasic.password?.label == "Imported secret field")
        #expect(exportedBasic.userName?.fieldType == .concealedString)
        #expect(exportedBasic.password?.fieldType == .string)
        let exportedItem = try #require(exported.accounts.flatMap(\.items).first)
        #expect(exportedItem.scope?.urls == [URL(string: "https://example.test/login")!])
        #expect(exported.accounts.first?.id == accountExternalID)
        #expect(exportedItem.id == itemExternalID)
        let exportedPasskey = try #require(exportedCredentials.compactMap { credential -> ASImportableCredential.Passkey? in
            guard case let .passkey(value) = credential else { return nil }
            return value
        }.first)
        #expect(exportedPasskey.credentialID == Data([0xC0, 0x01]))
        #expect(exportedPasskey.relyingPartyIdentifier == "example.test")
        #expect(exportedPasskey.userHandle == Data([0x31, 0x32]))
        let exportedTOTP = try #require(exportedCredentials.compactMap { credential -> ASImportableCredential.TOTP? in
            guard case let .totp(value) = credential else { return nil }
            return value
        }.first)
        let exportedSigner = try PasskeyKeyEncoding.importPKCS8(exportedPasskey.key)
        #expect(try securityVerifiesX963PublicKey(
            sourceKey.publicKey.x963Representation,
            message: challenge,
            signature: exportedSigner.signature(for: challenge).derRepresentation
        ))
        #expect(exportedTOTP.secret == generator.secret)
        #expect(exportedTOTP.period == 45 && exportedTOTP.digits == 10)
        #expect(exportedTOTP.algorithm == .sha512)
        #expect(exportedTOTP.issuer == "Example Issuer" && exportedTOTP.userName == "ada")
    }

    @Test func preservesProviderAndItemMetadataAndPrunesUnselectedCollectionLinks() throws {
        let providerID = Data([0xA0, 0x41])
        let firstItemID = Data([0xB0, 0x41])
        let secondItemID = Data([0xB0, 0x42])
        let created = Date(timeIntervalSince1970: 1_700_000_100)
        let modified = Date(timeIntervalSince1970: 1_700_000_200)
        let child = ASImportableCollection(
            id: Data([0xC0, 0x42]),
            created: created,
            lastModified: modified,
            title: "Unselected folder",
            subtitle: nil,
            items: [ASImportableLinkedItem(item: secondItemID, account: providerID)],
            subcollections: []
        )
        let emptyCollection = ASImportableCollection(
            id: Data([0xC0, 0x43]),
            created: created,
            lastModified: modified,
            title: "Empty",
            subtitle: nil,
            items: [],
            subcollections: []
        )
        let collection = ASImportableCollection(
            id: Data([0xC0, 0x41]),
            created: created,
            lastModified: modified,
            title: "Work",
            subtitle: "Selected and unselected records",
            items: [
                ASImportableLinkedItem(item: firstItemID, account: providerID),
                ASImportableLinkedItem(item: secondItemID, account: providerID)
            ],
            subcollections: [child]
        )
        let firstItem = ASImportableItem(
            id: firstItemID,
            created: created,
            lastModified: modified,
            title: "Work login",
            subtitle: "Primary website account",
            favorite: true,
            scope: ASImportableCredentialScope(urls: [URL(string: "https://example.test/login")!], androidApps: []),
            credentials: [basicAuthentication(username: "site-login", password: "site-secret-one")],
            tags: ["work", "important"]
        )
        let secondItem = ASImportableItem(
            id: secondItemID,
            created: created,
            lastModified: modified,
            title: "Other login",
            subtitle: "Do not export this",
            favorite: false,
            scope: nil,
            credentials: [basicAuthentication(username: "other-login", password: "site-secret-two")],
            tags: ["private"]
        )
        let input = ASExportedCredentialData(
            accounts: [ASImportableAccount(
                id: providerID,
                userName: "password-manager-user",
                email: "vault-owner@example.test",
                fullName: "Vault Owner",
                collections: [collection, emptyCollection],
                items: [firstItem, secondItem]
            )],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: created
        )

        let imported = try CredentialExchangeCodec.apply(
            CredentialExchangeCodec.preview(input, against: snapshot([])),
            decisions: []
        )
        #expect(imported.count == 2)
        let first = try #require(imported.first)
        let second = try #require(imported.last)
        let metadata = try #require(first.exchangeMetadata)
        let metadataText = String(decoding: metadata, as: UTF8.self)
        #expect(!metadataText.contains("site-secret-one"))
        #expect(!metadataText.contains("site-login"))

        let all = try CredentialExchangeCodec.export(
            snapshot(imported),
            selection: imported.map {
                .init(accountID: $0.id, password: true, passkeyIDs: [], totp: false)
            },
            format: .v1
        )
        let allAccount = try #require(all.accounts.first)
        #expect(allAccount.userName == "password-manager-user")
        #expect(allAccount.email == "vault-owner@example.test")
        #expect(allAccount.fullName == "Vault Owner")
        #expect(allAccount.collections.first?.items.map(\.item) == [firstItemID, secondItemID])
        #expect(allAccount.collections.first?.subcollections.first?.items.map(\.item) == [secondItemID])
        let exportedFirst = try #require(allAccount.items.first(where: { $0.id == firstItemID }))
        #expect(exportedFirst.title == "Work login")
        #expect(exportedFirst.subtitle == "Primary website account")
        #expect(exportedFirst.favorite)
        #expect(exportedFirst.created == created && exportedFirst.lastModified == modified)
        #expect(exportedFirst.tags == ["work", "important"])

        var renamed = imported
        renamed[0].displayName = "Renamed in WSurf"
        let selected = try CredentialExchangeCodec.export(
            snapshot(renamed),
            selection: [.init(accountID: first.id, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        let selectedAccount = try #require(selected.accounts.first)
        #expect(selectedAccount.items.map(\.id) == [firstItemID])
        #expect(selectedAccount.items.first?.title == "Renamed in WSurf")
        #expect(selectedAccount.collections.map(\.title) == ["Work"])
        #expect(selectedAccount.collections.first?.items.map(\.item) == [firstItemID])
        #expect(selectedAccount.collections.first?.subcollections.isEmpty == true)
        var cleared = imported
        cleared[0].displayName = nil
        let clearedExport = try CredentialExchangeCodec.export(
            snapshot(cleared),
            selection: [.init(accountID: first.id, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        #expect(clearedExport.accounts.first?.items.first?.title == "")
        #expect(second.exchangeItemID == secondItemID)
    }
    @Test func emptyImportedItemTitleRemainsEmptyAcrossExchange() throws {
        let input = data(title: "", scope: nil, credentials: [
            basicAuthentication(username: "ada", password: "secret")
        ])
        let imported = try CredentialExchangeCodec.apply(
            CredentialExchangeCodec.preview(input, against: snapshot([])),
            decisions: []
        )
        let account = try #require(imported.first)
        let exported = try CredentialExchangeCodec.export(
            snapshot(imported),
            selection: [.init(accountID: account.id, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        #expect(exported.accounts.first?.items.first?.title == "")
    }

    @Test func missingItemDatesStayAbsentAcrossExchange() throws {
        let imported = try CredentialExchangeCodec.apply(
            CredentialExchangeCodec.preview(
                data(credentials: [basicAuthentication(username: "ada", password: "secret")]),
                against: snapshot([])
            ),
            decisions: []
        )
        let account = try #require(imported.first)
        let exported = try CredentialExchangeCodec.export(
            snapshot(imported),
            selection: [.init(accountID: account.id, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        let item = try #require(exported.accounts.first?.items.first)
        #expect(item.created == nil)
        #expect(item.lastModified == nil)
    }
    @Test func hundredsOfLinkedItemsStayWithinVaultBudgetOnRoundTrip() throws {
        let providerID = Data([0xA0, 0x90])
        let created = Date(timeIntervalSince1970: 1_700_000_300)
        let itemIDs = (0..<600).map { index in
            withUnsafeBytes(of: UInt32(index).bigEndian) { Data($0) }
        }
        let items = itemIDs.enumerated().map { index, id in
            importableItem(
                id: id,
                title: "Record \(index)",
                credentials: [basicAuthentication(username: "user-\(index)", password: "secret-\(index)")]
            )
        }
        let collection = ASImportableCollection(
            id: Data([0xC0, 0x90]),
            created: created,
            lastModified: created,
            title: "All records",
            subtitle: nil,
            items: itemIDs.map { ASImportableLinkedItem(item: $0, account: providerID) },
            subcollections: []
        )
        let input = ASExportedCredentialData(
            accounts: [ASImportableAccount(
                id: providerID,
                userName: "owner",
                email: "owner@example.test",
                collections: [collection],
                items: items
            )],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: created
        )
        let imported = try CredentialExchangeCodec.apply(
            CredentialExchangeCodec.preview(input, against: snapshot([])),
            decisions: []
        )
        #expect(imported.count == itemIDs.count)

        let exported = try CredentialExchangeCodec.export(
            snapshot(imported),
            selection: imported.map {
                .init(accountID: $0.id, password: true, passkeyIDs: [], totp: false)
            },
            format: .v1
        )
        let output = try #require(exported.accounts.first)
        #expect(output.items.map(\.id) == itemIDs)
        #expect(output.collections.first?.items.map(\.item) == itemIDs)
        #expect(try JSONEncoder().encode(exported).count <= CredentialVaultLimits.payloadBytes)
    }


    @Test func importedPasskeyRejectsPublicSuffixRelyingParty() throws {
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let input = data(scope: nil, credentials: [passkey(rpID: "com", key: key)])
        #expect(throws: (any Error).self) {
            try CredentialExchangeCodec.preview(input, against: snapshot([]))
        }
    }

    @Test func absentUsernameFieldStaysAbsentAcrossExchange() throws {
        let incoming = data(credentials: [
            .basicAuthentication(.init(
                userName: nil,
                password: .init(id: Data([0x24]), fieldType: .concealedString, value: "only-password", label: "Password")
            ))
        ])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([]))
        let imported = try CredentialExchangeCodec.apply(preview, decisions: [])
        let account = try #require(imported.first)
        let exported = try CredentialExchangeCodec.export(
            snapshot(imported),
            selection: [.init(accountID: account.id, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        let basic = try #require(credentials(in: exported).compactMap { credential -> ASImportableCredential.BasicAuthentication? in
            guard case let .basicAuthentication(value) = credential else { return nil }
            return value
        }.first)
        #expect(basic.userName == nil)
        #expect(basic.password?.value == "only-password")
        #expect(basic.password?.id == Data([0x24]))
        #expect(basic.password?.fieldType == .concealedString)
        #expect(basic.password?.label == "Password")
    }

    @Test func presentEmptyPasswordRemainsPresentAcrossExchange() throws {
        let input = data(credentials: [
            .basicAuthentication(.init(
                userName: .init(id: Data([0x27]), fieldType: .string, value: "ada", label: "Login"),
                password: .init(id: Data([0x28]), fieldType: .concealedString, value: "", label: "Empty password")
            ))
        ])
        let imported = try CredentialExchangeCodec.apply(
            CredentialExchangeCodec.preview(input, against: snapshot([])),
            decisions: []
        )
        let account = try #require(imported.first)
        #expect(account.password == "")
        let output = try CredentialExchangeCodec.export(
            snapshot(imported),
            selection: [.init(accountID: account.id, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        let basic = try #require(credentials(in: output).compactMap { credential -> ASImportableCredential.BasicAuthentication? in
            guard case let .basicAuthentication(value) = credential else { return nil }
            return value
        }.first)
        #expect(basic.password != nil)
        #expect(basic.password?.value == "")
        #expect(basic.password?.id == Data([0x28]))
        #expect(basic.password?.fieldType == .concealedString)
        #expect(basic.password?.label == "Empty password")
    }

    @Test func emailUsernameFieldTypeSurvivesExchange() throws {
        let input = data(credentials: [
            .basicAuthentication(.init(
                userName: .init(id: Data([0x25]), fieldType: .email, value: "ada@example.test", label: "Email login"),
                password: .init(id: Data([0x26]), fieldType: .concealedString, value: "secret", label: "Password")
            ))
        ])
        let imported = try CredentialExchangeCodec.apply(
            CredentialExchangeCodec.preview(input, against: snapshot([])),
            decisions: []
        )
        let account = try #require(imported.first)
        let output = try CredentialExchangeCodec.export(
            snapshot(imported),
            selection: [.init(accountID: account.id, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        let basic = try #require(credentials(in: output).compactMap { credential -> ASImportableCredential.BasicAuthentication? in
            guard case let .basicAuthentication(value) = credential else { return nil }
            return value
        }.first)
        #expect(basic.userName?.value == "ada@example.test")
        #expect(basic.userName?.fieldType == .email)
    }

    @Test func TOTPissuerNeverCreatesAWebsiteOrigin() throws {
        let input = data(
            scope: nil,
            credentials: [totp(issuer: "https://issuer-is-not-a-site.example")]
        )
        let preview = try CredentialExchangeCodec.preview(input, against: snapshot([]))
        let imported = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(imported.count == 1)
        #expect(imported[0].totp?.issuer == "https://issuer-is-not-a-site.example")
        #expect(imported[0].origins.isEmpty)
    }

    @Test func passwordWithoutApprovedOriginRemainsUnassociated() throws {
        let input = data(scope: nil, credentials: [basicAuthentication(username: "ada", password: "secret")])
        let preview = try CredentialExchangeCodec.preview(input, against: snapshot([]))
        let imported = try CredentialExchangeCodec.apply(preview, decisions: [])
        let account = try #require(imported.first)
        #expect(account.password == "secret")
        #expect(account.origins.isEmpty)
        #expect(account.loginURLs.isEmpty)
    }

    @Test func sameOriginDoesNotReplaceNeighboursAndExplicitConflictDecisionIsLocal() throws {
        let protectedKey = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let protectedPasskey = WebsitePasskey(
            id: passkeyID,
            credentialID: Data([0xC0, 0x99]),
            rpID: "example.test",
            userHandle: Data([0x99]),
            userName: "user-0",
            userDisplayName: "User Zero",
            algorithm: -7,
            privateKeyPKCS8: protectedKey,
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        let protectedTOTP = TOTPGenerator(secret: Data([0x70]), algorithm: .sha256, period: 45, digits: 8, issuer: "Protected", userName: "user-0")
        let existing = [account(
            id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            externalID: Data([0xA0, 0x00]),
            itemID: Data([0xB0, 0x00]),
            username: "user-0",
            password: "password-0",
            passkeys: [protectedPasskey],
            totp: protectedTOTP
        )] + (1..<10).map { index in
            account(
                id: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", index + 1))!,
                externalID: Data([0xA0, UInt8(index)]),
                itemID: Data([0xB0, UInt8(index)]),
                username: "user-\(index)",
                password: "password-\(index)"
            )
        }
        let incoming = data(
            accountID: Data([0xA0, 0x00]),
            itemID: Data([0xB0, 0x00]),
            credentials: [basicAuthentication(username: "user-0", password: "attacker-replacement")]
        )
        let base = snapshot(existing)
        let preview = try CredentialExchangeCodec.preview(incoming, against: base)
        let conflict = try #require(preview.conflicts.first)
        guard case let .password(conflictingAccountID) = conflict.existing else {
            Issue.record("Expected a conflict with the incoming password identity")
            return
        }
        #expect(conflictingAccountID == existing[0].id)
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.apply(preview, decisions: []) }

        let kept = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: conflict.incoming)])
        #expect(kept.map(\.id) == existing.map(\.id))
        #expect(kept.map(\.password) == (0..<10).map { "password-\($0)" })

        let replaced = try CredentialExchangeCodec.apply(
            preview,
            decisions: [.replace(incoming: conflict.incoming, target: conflict.existing)]
        )
        #expect(replaced.map(\.password) == ["attacker-replacement"] + (1..<10).map { "password-\($0)" })
        #expect(replaced[0].passkeys.first?.credentialID == Data([0xC0, 0x99]))
        #expect(replaced[0].totp?.secret == protectedTOTP.secret)

        let sameDomainNewRecord = data(
            accountID: Data([0xA0, 0x55]),
            itemID: Data([0xB0, 0x55]),
            credentials: [basicAuthentication(username: "new-user", password: "new-password")]
        )
        let addPreview = try CredentialExchangeCodec.preview(sameDomainNewRecord, against: base)
        #expect(addPreview.conflicts.isEmpty)
        let added = try CredentialExchangeCodec.apply(addPreview, decisions: [])
        #expect(added.count == 11)
        #expect(Array(added.prefix(10)).map(\.id) == existing.map(\.id))
        #expect(Array(added.prefix(10)).map(\.password) == existing.map(\.password))
    }
    @Test func addingConflictSeparatelyForksTheExternalItemIdentity() throws {
        let existing = account(externalID: accountExternalID, itemID: itemExternalID)
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "new-password")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([existing]))
        let conflict = try #require(preview.conflicts.first)
        let added = try CredentialExchangeCodec.apply(
            preview,
            decisions: [.add(incoming: conflict.incoming, targetAccountID: nil)]
        )

        #expect(added.count == 2)
        let exported = try CredentialExchangeCodec.export(
            snapshot(added),
            selection: added.map {
                .init(accountID: $0.id, password: true, passkeyIDs: [], totp: false)
            },
            format: .v1
        )
        let items = exported.accounts.flatMap(\.items)
        #expect(items.count == 2)
        #expect(Set(exported.accounts.map(\.id)).count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        _ = try CredentialExchangeCodec.preview(exported, against: snapshot([]))
    }

    @Test func anExplicitSkipWorksForARecordThatIsNotAConflict() throws {
        let existing = [account(username: "grace", password: "kept")]
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot(existing))
        #expect(preview.conflicts.isEmpty)
        let candidate = try #require(preview.candidates.first)

        let result = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: .password(accountID: candidate.id))])
        #expect(result.map(\.id) == existing.map(\.id))
        #expect(result.map(\.password) == ["kept"])
    }

    @Test func aNonConflictingAddKeepsTheExporterIdentifiers() throws {
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([]))
        let result = try CredentialExchangeCodec.apply(preview, decisions: [])
        let added = try #require(result.first)
        #expect(result.count == 1)
        #expect(added.exchangeAccountID == Data([0xA0, 0x01]))
        #expect(added.exchangeItemID == Data([0xB0, 0x01]))
    }

    @Test func mergingTakesTheChosenTargetsWebsitesAndKeepsItsOtherSecrets() throws {
        var bare = account(username: "", password: nil, totp: TOTPGenerator(
            secret: Data([0x71]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil
        ))
        bare.origins = [origin, "https://second.example.test"]
        let neighbour = account(username: "grace", password: "neighbour")
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare, neighbour]))
        let candidate = try #require(preview.candidates.first)
        let identity = CredentialIdentity.password(accountID: candidate.id)

        let result = try CredentialExchangeCodec.apply(
            preview, decisions: [.add(incoming: identity, targetAccountID: bare.id)]
        )
        #expect(result.count == 2)
        let merged = try #require(result.first { $0.id == bare.id })
        #expect(merged.password == "incoming")
        #expect(merged.totp?.secret == Data([0x71]))
        #expect(merged.origins == bare.origins)
        #expect(result.first { $0.id == neighbour.id } == neighbour)
    }

    @Test func mergingCarriesTheImportedItemsMetadataAndRefusesAnotherImportedItem() throws {
        let totp = TOTPGenerator(secret: Data([0x71]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil)
        let bare = account(username: "", password: nil, totp: totp)
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare]))
        let candidate = try #require(preview.candidates.first)
        let identity = CredentialIdentity.password(accountID: candidate.id)
        #expect(candidate.exchangeMetadata != nil)

        // A plain account takes the item's identifiers and metadata, so its tags, dates and collections survive.
        #expect(CredentialExchangeCodec.canMerge(candidate, into: bare))
        let merged = try #require(CredentialExchangeCodec.apply(
            preview, decisions: [.add(incoming: identity, targetAccountID: bare.id)]
        ).first)
        #expect(merged.exchangeMetadata == candidate.exchangeMetadata)
        #expect(merged.exchangeAccountID == candidate.exchangeAccountID && merged.exchangeItemID == candidate.exchangeItemID)
        #expect(merged.totp?.secret == Data([0x71]))

        // An account that already stands for a different exporter item would lose one of the two: refused.
        let other = account(externalID: Data([0xA0, 0x09]), itemID: Data([0xB0, 0x09]), username: "", password: nil, totp: totp)
        #expect(!CredentialExchangeCodec.canMerge(candidate, into: other))
        let refused = try CredentialExchangeCodec.preview(incoming, against: snapshot([other]))
        let refusedIdentity = CredentialIdentity.password(accountID: try #require(refused.candidates.first).id)
        #expect(throws: (any Error).self) {
            try CredentialExchangeCodec.apply(refused, decisions: [.add(incoming: refusedIdentity, targetAccountID: other.id)])
        }
    }

    private func passkeyOnlyAccount(_ seed: UInt8) throws -> CredentialAccount {
        let stored = WebsitePasskey(
            id: UUID(),
            credentialID: Data([0xC0, seed]),
            rpID: "example.test",
            userHandle: Data([seed]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        return account(username: "", password: nil, passkeys: [stored])
    }

    private func externalIdentities(_ accounts: [CredentialAccount]) -> Set<Data> {
        Set(accounts.flatMap { [$0.exchangeAccountID, $0.exchangeItemID].compactMap { $0 } })
    }

    @Test func anItemSplitAcrossDestinationsGivesTheIdentifiersToOneAndForksTheRest() throws {
        let destination = try passkeyOnlyAccount(1)
        let second = try passkeyOnlyAccount(2)
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming"), totp()])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([destination, second]))
        let candidate = try #require(preview.candidates.first)
        let login = CredentialIdentity.password(accountID: candidate.id)
        let code = CredentialIdentity.totp(accountID: candidate.id)
        #expect(candidate.displayName == "Example account" && candidate.exchangeMetadata != nil)

        // The login goes into one account; the code, undecided, becomes its own account. Both keep the name and
        // metadata, exactly one holds the exporter's identifiers, and the whole plan is valid.
        let oneMerged = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: login, targetAccountID: destination.id)])
        #expect(oneMerged.count == 3)
        let merged = try #require(oneMerged.first { $0.id == destination.id })
        let separate = try #require(oneMerged.last)
        #expect(merged.password == "incoming" && merged.totp == nil && merged.displayName == "Example account")
        #expect(merged.exchangeItemID == candidate.exchangeItemID && merged.exchangeMetadata == candidate.exchangeMetadata)
        #expect(separate.totp != nil && separate.password == nil && separate.displayName == "Example account")
        #expect(separate.exchangeItemID != candidate.exchangeItemID && separate.exchangeMetadata != nil)
        #expect(externalIdentities(oneMerged.filter { $0.id == merged.id || $0.id == separate.id }).count == 4)

        // Each credential into its own plain account.
        let twoMerged = try CredentialExchangeCodec.apply(preview, decisions: [
            .add(incoming: login, targetAccountID: destination.id),
            .add(incoming: code, targetAccountID: second.id),
        ])
        #expect(twoMerged.count == 2)
        let first = try #require(twoMerged.first { $0.id == destination.id })
        let other = try #require(twoMerged.first { $0.id == second.id })
        #expect(first.exchangeItemID == candidate.exchangeItemID)
        #expect(other.exchangeItemID != candidate.exchangeItemID && other.exchangeItemID != nil && other.totp != nil)
        #expect(first.displayName == "Example account" && other.displayName == "Example account")
        #expect(other.exchangeMetadata != nil)

        // Both into one account carry the item once.
        let both = try CredentialExchangeCodec.apply(preview, decisions: [
            .add(incoming: login, targetAccountID: destination.id),
            .add(incoming: code, targetAccountID: destination.id),
        ])
        #expect(both.count == 2)
        let combined = try #require(both.first { $0.id == destination.id })
        #expect(combined.password == "incoming" && combined.totp != nil && combined.exchangeItemID == candidate.exchangeItemID)
    }

    @Test func aDifferentlyNamedAccountIsNeverRenamedByAMerge() throws {
        var named = try passkeyOnlyAccount(3)
        named.displayName = "My own name"
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([named]))
        let candidate = try #require(preview.candidates.first)
        #expect(!CredentialExchangeCodec.canMerge(candidate, into: named))
        #expect(throws: (any Error).self) {
            try CredentialExchangeCodec.apply(
                preview, decisions: [.add(incoming: .password(accountID: candidate.id), targetAccountID: named.id)]
            )
        }

        named.displayName = "Example account"
        #expect(CredentialExchangeCodec.canMerge(candidate, into: named))
    }

    @Test func decisionsTheImportDoesNotOfferAreRejected() throws {
        let bare = account(username: "", password: nil, totp: TOTPGenerator(
            secret: Data([0x71]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil
        ))
        let withLogin = account(username: "grace", password: "neighbour")
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "incoming")])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare, withLogin]))
        let identity = CredentialIdentity.password(accountID: try #require(preview.candidates.first).id)

        // Unknown incoming record, two decisions for one record, a target that doesn't exist and one that already
        // holds a login.
        let rejected: [[CredentialImportDecision]] = [
            [.keep(incoming: .password(accountID: UUID()))],
            [.keep(incoming: identity), .add(incoming: identity, targetAccountID: nil)],
            [.add(incoming: identity, targetAccountID: UUID())],
            [.add(incoming: identity, targetAccountID: withLogin.id)],
        ]
        for decisions in rejected {
            #expect(throws: (any Error).self) { try CredentialExchangeCodec.apply(preview, decisions: decisions) }
        }
        // The preview is a value: a refused decision set leaves it, and so the next valid one, untouched.
        #expect(try CredentialExchangeCodec.apply(preview, decisions: []).count == 3)
    }

    @Test func localAccountsUseExporterFallbackIDsForConflictMatching() throws {
        let localID = UUID(uuidString: "10000000-0000-4000-8000-000000000099")!
        let fallbackID = withUnsafeBytes(of: localID.uuid) { Data($0) }
        let local = account(id: localID, externalID: nil, itemID: nil)
        let incoming = data(accountID: fallbackID, itemID: fallbackID, credentials: [
            basicAuthentication(username: "ada", password: "incoming-password")
        ])

        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([local]))
        let conflict = try #require(preview.conflicts.first)
        #expect(conflict.existing == .password(accountID: localID))
    }

    @Test func exportPreservesOriginsWithoutLoginURLHints() throws {
        var source = account(id: accountID)
        source.origins = ["https://example.test", "https://second.example.test"]
        source.loginURLs = [URL(string: "https://example.test/login")!]

        let exported = try CredentialExchangeCodec.export(
            snapshot([source]),
            selection: [.init(accountID: accountID, password: true, passkeyIDs: [], totp: false)],
            format: .v1
        )
        let urls = try #require(exported.accounts.first?.items.first?.scope?.urls)
        #expect(urls == [
            URL(string: "https://example.test/login")!,
            URL(string: "https://second.example.test")!
        ])
    }

    @Test func oversizedRawFIDO2DataIsRejectedDuringBudgetAccounting() throws {
        guard #available(macOS 26.4, *) else { return }
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let metadata = ASImportableFIDO2Extensions(
            hmacCredentials: nil,
            largeBlob: .init(
                uncompressedSize: CredentialVaultLimits.payloadBytes,
                data: Data(repeating: 0, count: CredentialVaultLimits.payloadBytes)
            )
        )
        let credential = ASImportableCredential.passkey(.init(
            credentialID: Data([0xC0, 0x09]),
            relyingPartyIdentifier: "example.test",
            userName: "ada",
            userDisplayName: "Ada",
            userHandle: Data([0x49]),
            key: key,
            fido2Extensions: metadata
        ))
        do {
            _ = try CredentialExchangeCodec.preview(data(credentials: [credential]), against: snapshot([]))
            Issue.record("Expected oversized FIDO2 data rejection")
        } catch {
            let diagnostic = try #require(error as? CredentialExchangeError)
            #expect(diagnostic.record == .credential(account: 0, item: 0, credential: 0))
            #expect(diagnostic.reason == .oversized)
        }
    }


    @Test func invalidAndAmbiguousImportsRejectBeforeChangingSnapshot() throws {
        let existing = account(externalID: accountExternalID, itemID: itemExternalID)
        let base = snapshot([existing])
        let malformedKey = data(credentials: [passkey(key: Data([0x30, 0x82, 0x01]))])
        do {
            _ = try CredentialExchangeCodec.preview(malformedKey, against: base)
            Issue.record("Expected malformed key rejection")
        } catch {
            let diagnostic = try #require(error as? CredentialExchangeError)
            #expect(diagnostic.record == .credential(account: 0, item: 0, credential: 0))
            #expect(diagnostic.reason == .invalidData)
        }

        let invalidScope = data(
            scope: ASImportableCredentialScope(urls: [URL(string: "javascript:alert(1)")!], androidApps: []),
            credentials: [basicAuthentication(username: "other", password: "secret")]
        )
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(invalidScope, against: base) }

        let secret = "must-not-appear-in-diagnostics"
        let secretBearingInvalidInput = data(
            scope: ASImportableCredentialScope(urls: [URL(string: "javascript:alert(1)")!], androidApps: []),
            credentials: [basicAuthentication(username: "other", password: secret)]
        )
        do {
            _ = try CredentialExchangeCodec.preview(secretBearingInvalidInput, against: base)
            Issue.record("Expected malformed scope rejection")
        } catch {
            let diagnostic = try #require(error as? CredentialExchangeError)
            #expect(diagnostic.record == .item(account: 0, item: 0))
            #expect(diagnostic.reason == .invalidData)
            let description = String(describing: error)
            #expect(description.contains("account[0]/item[0]"))
            #expect(!description.contains(secret))
        }

        let invalidTOTP = data(credentials: [totp(period: 0)])
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(invalidTOTP, against: base) }

        let unsupportedCredential = data(credentials: [
            .generatedPassword(.init(password: "must-not-appear-in-diagnostics"))
        ])
        do {
            _ = try CredentialExchangeCodec.preview(unsupportedCredential, against: base)
            Issue.record("Expected unsupported credential rejection")
        } catch {
            let diagnostic = try #require(error as? CredentialExchangeError)
            #expect(diagnostic.record == .credential(account: 0, item: 0, credential: 0))
            #expect(diagnostic.reason == .unsupported)
            let description = String(describing: error)
            #expect(description.contains("account[0]/item[0]/credential[0]"))
            #expect(!description.contains("must-not-appear-in-diagnostics"))
        }
        let unsupportedAPIKey = data(credentials: [
            .apiKey(.init(
                key: .init(id: Data([0x67]), fieldType: .concealedString, value: "unsupported-api-secret"),
                userName: nil,
                keyType: nil,
                url: nil,
                validFrom: nil,
                expiryDate: nil
            ))
        ])
        do {
            _ = try CredentialExchangeCodec.preview(unsupportedAPIKey, against: base)
            Issue.record("Expected unsupported API key rejection")
        } catch {
            let diagnostic = try #require(error as? CredentialExchangeError)
            #expect(diagnostic.record == .credential(account: 0, item: 0, credential: 0))
            #expect(diagnostic.reason == .unsupported)
            let description = String(describing: error)
            #expect(description.contains("account[0]/item[0]/credential[0]"))
            #expect(!description.contains("unsupported-api-secret"))
        }

        let unsupportedWiFi = data(credentials: [
            .wifi(.init(
                ssid: .init(id: Data([0x68]), fieldType: .string, value: "unsupported-network"),
                networkSecurityType: nil,
                passphrase: .init(id: Data([0x69]), fieldType: .concealedString, value: "unsupported-wifi-secret")
            ))
        ])
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(unsupportedWiFi, against: base) }

        let duplicateFieldIDs = data(credentials: [
            basicAuthentication(username: "same-id", password: "same-id", usernameID: Data([0x66]), passwordID: Data([0x66]))
        ])
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(duplicateFieldIDs, against: base) }

        let oversized = data(credentials: [
            totp(secret: Data(repeating: 0xA5, count: 4_000_001))
        ])
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(oversized, against: base) }

        let unsupportedAlgorithm = data(credentials: [
            passkey(key: try rsaPKCS8())
        ])
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(unsupportedAlgorithm, against: base) }

        let duplicateAccountID = ASExportedCredentialData(
            accounts: [
                ASImportableAccount(id: accountExternalID, userName: "one", email: "", collections: [], items: []),
                ASImportableAccount(id: accountExternalID, userName: "two", email: "", collections: [], items: [])
            ],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(duplicateAccountID, against: base) }

        let duplicateItemID = ASExportedCredentialData(
            accounts: [ASImportableAccount(
                id: Data([0xA0, 0x77]),
                userName: "duplicate-items",
                email: "",
                collections: [],
                items: [
                    importableItem(id: itemExternalID, title: "first", credentials: [basicAuthentication(username: "one", password: "one")]),
                    importableItem(id: itemExternalID, title: "second", credentials: [basicAuthentication(username: "two", password: "two")])
                ]
            )],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(duplicateItemID, against: base) }

        let validThenInvalidItem = ASExportedCredentialData(
            accounts: [ASImportableAccount(
                id: Data([0xA0, 0x78]),
                userName: "mixed",
                email: "",
                collections: [],
                items: [
                    importableItem(id: Data([0xB0, 0x78]), title: "valid", credentials: [basicAuthentication(username: "valid", password: "valid")]),
                    importableItem(id: Data([0xB0, 0x79]), title: "invalid", credentials: [totp(period: 0)])
                ]
            )],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(throws: (any Error).self) { try CredentialExchangeCodec.preview(validThenInvalidItem, against: base) }
    }

    @Test func sharedCollectionAncestryReencodedPerItemIsBudgetedBeforeItIsRetained() throws {
        let providerID = Data([0xA0, 0x90])
        let itemIDs = [Data([0xB0, 0x91]), Data([0xB0, 0x92]), Data([0xB0, 0x93])]
        // 32 nested levels of 100 KB titles: ~3.2 MB, inside the raw budget, but linked from every item.
        var chain = ASImportableCollection(
            id: Data([0xC0, 0]), created: nil, lastModified: nil, title: String(repeating: "a", count: 100_000),
            subtitle: nil, items: itemIDs.map { ASImportableLinkedItem(item: $0, account: providerID) }, subcollections: []
        )
        for level in 1..<32 {
            chain = ASImportableCollection(
                id: Data([0xC0, UInt8(level)]), created: nil, lastModified: nil,
                title: String(repeating: "a", count: 100_000), subtitle: nil, items: [], subcollections: [chain]
            )
        }
        let exported = ASExportedCredentialData(
            accounts: [ASImportableAccount(
                id: providerID, userName: "ada", email: "", collections: [chain],
                items: itemIDs.enumerated().map { index, id in
                    importableItem(id: id, title: "item \(index)", credentials: [basicAuthentication(username: "u\(index)", password: "p")])
                }
            )],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        do {
            _ = try CredentialExchangeCodec.preview(exported, against: snapshot([]))
            Issue.record("Expected the multiplied metadata to be rejected")
        } catch let error as CredentialExchangeError {
            // Rejected while the second item is built, not after every candidate has been retained.
            #expect(error.reason == .oversized)
            #expect(error.record == .item(account: 0, item: 1))
        }
    }

    @Test func unsupportedCredentialDiagnosticUsesExactRecordIndices() throws {
        let secret = "must-not-appear-in-diagnostics"
        let firstAccount = ASImportableAccount(
            id: Data([0xA1]),
            userName: "first",
            email: "",
            collections: [],
            items: [importableItem(id: Data([0xB1]), title: "first", credentials: [
                basicAuthentication(username: "first", password: "first")
            ])]
        )
        let secondAccount = ASImportableAccount(
            id: Data([0xA2]),
            userName: "second",
            email: "",
            collections: [],
            items: [
                importableItem(id: Data([0xB2]), title: "valid", credentials: [
                    basicAuthentication(username: "valid", password: "valid")
                ]),
                importableItem(id: Data([0xB3]), title: "invalid", credentials: [
                    basicAuthentication(username: "safe", password: "safe"),
                    .generatedPassword(.init(password: secret))
                ])
            ]
        )
        let data = ASExportedCredentialData(
            accounts: [firstAccount, secondAccount],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        do {
            _ = try CredentialExchangeCodec.preview(data, against: snapshot([]))
            Issue.record("Expected unsupported credential rejection")
        } catch {
            let diagnostic = try #require(error as? CredentialExchangeError)
            #expect(diagnostic.record == .credential(account: 1, item: 1, credential: 1))
            let description = String(describing: error)
            #expect(description.contains("account[1]/item[1]/credential[1]"))
            #expect(!description.contains(secret))
        }
    }

    @Test func exportSelectionContainsOnlyRequestedCredentialKinds() throws {
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let p = WebsitePasskey(
            id: passkeyID,
            credentialID: Data([0xC0, 0x02]),
            rpID: "example.test",
            userHandle: Data([0x42]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: key,
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        let siblingID = UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!
        let sibling = WebsitePasskey(
            id: siblingID,
            credentialID: Data([0xC0, 0x03]),
            rpID: "example.test",
            userHandle: Data([0x43]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
        let sourceWithSibling = account(id: accountID, passkeys: [p, sibling], totp: TOTPGenerator(secret: Data([1]), algorithm: .sha1, period: 30, digits: 6, issuer: "Issuer", userName: "ada"))
        let selected = try CredentialExchangeCodec.export(
            snapshot([sourceWithSibling]),
            selection: [.init(accountID: accountID, password: false, passkeyIDs: [passkeyID], totp: false)],
            format: .v1
        )
        #expect(selected.exporterRelyingPartyIdentifier == "wsurf.app")
        let exported = credentials(in: selected)
        #expect(exported.count == 1)
        guard case let .passkey(exportedPasskey) = try #require(exported.first) else {
            Issue.record("Selection exported a credential other than the requested passkey")
            return
        }
        #expect(exportedPasskey.credentialID == Data([0xC0, 0x02]))
    }

    @Test func supportedFIDO2MetadataSurvivesTheExchange() throws {
        if #available(macOS 26.4, *) {
            let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
            let metadata = ASImportableFIDO2Extensions(
                hmacCredentials: .init(algorithm: .sha256, credentialWithUV: Data([1, 2]), credentialWithoutUV: Data([3, 4])),
                largeBlob: .init(uncompressedSize: 4, data: Data([5, 6, 7, 8]))
            )
            let credential = ASImportableCredential.passkey(.init(
                credentialID: Data([0xC0, 0x03]),
                relyingPartyIdentifier: "example.test",
                userName: "ada",
                userDisplayName: "Ada",
                userHandle: Data([0x43]),
                key: key,
                fido2Extensions: metadata
            ))
            let preview = try CredentialExchangeCodec.preview(data(credentials: [credential]), against: snapshot([]))
            let imported = try CredentialExchangeCodec.apply(preview, decisions: [])
            #expect(imported.first?.passkeys.first?.exchangeFIDO2Metadata != nil)
            let output = try CredentialExchangeCodec.export(
                snapshot(imported),
                selection: [.init(accountID: try #require(imported.first?.id), password: false, passkeyIDs: [try #require(imported.first?.passkeys.first?.id)], totp: false)],
                format: .v1
            )
            let exportedPasskey = try #require(credentials(in: output).compactMap { credential -> ASImportableCredential.Passkey? in
                guard case let .passkey(value) = credential else { return nil }
                return value
            }.first)
            let roundTrip = try #require(exportedPasskey.fido2Extensions)
            #expect(roundTrip.hmacCredentials?.algorithm == metadata.hmacCredentials?.algorithm)
            #expect(roundTrip.hmacCredentials?.credentialWithUV == metadata.hmacCredentials?.credentialWithUV)
            #expect(roundTrip.hmacCredentials?.credentialWithoutUV == metadata.hmacCredentials?.credentialWithoutUV)
            #expect(roundTrip.largeBlob?.uncompressedSize == metadata.largeBlob?.uncompressedSize)
            #expect(roundTrip.largeBlob?.data == metadata.largeBlob?.data)
        }
    }

    @Test func olderSystemsRejectFIDO2MetadataInsteadOfDroppingIt() throws {
        guard #unavailable(macOS 26.4) else { return }
        let key = try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        let metadataPasskey = WebsitePasskey(
            id: passkeyID,
            credentialID: Data([0xC0, 0x04]),
            rpID: "example.test",
            userHandle: Data([0x44]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: key,
            backupEligible: false,
            backupState: false,
            exchangeFIDO2Metadata: Data([0x7b, 0x7d])
        )
        let source = account(id: accountID, passkeys: [metadataPasskey])
        #expect(throws: (any Error).self) {
            try CredentialExchangeCodec.export(
                snapshot([source]),
                selection: [.init(accountID: accountID, password: false, passkeyIDs: [passkeyID], totp: false)],
                format: .v1
            )
        }
    }
}
