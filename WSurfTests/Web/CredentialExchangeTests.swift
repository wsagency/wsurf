// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation
import Security
import Testing

@testable import WSurf

@MainActor
struct CredentialExchangeTests {
    let accountID = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    let passkeyID = UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!
    let accountExternalID = Data([0xA0, 0x01])
    let itemExternalID = Data([0xB0, 0x01])
    let origin = "https://example.test"

    private func securityVerifiesX963PublicKey(_ x963: Data, message: Data, signature: Data) throws -> Bool {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: 256,
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
        if count < 128 {
            return Data([UInt8(count)])
        }
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

    func rsaPKCS8() throws -> Data {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 1024,
        ]
        let key = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let pkcs1 = try #require(SecKeyCopyExternalRepresentation(key, nil)) as Data
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        var body = derValue(0x02, Data([0]))
        body.append(algorithm)
        body.append(derValue(0x04, pkcs1))
        return derValue(0x30, body)
    }

    func snapshot(_ accounts: [CredentialAccount], revision: UInt64 = 3) -> VaultSnapshot {
        VaultSnapshot(revision: revision, accounts: accounts, blockedPasswordOrigins: [])
    }

    func account(
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

    func basicAuthentication(
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

    func passkey(
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

    func totp(
        secret: Data = Data("independent-test-seed".utf8),
        period: UInt16 = 45,
        digits: UInt16 = 10,
        algorithm: ASImportableCredential.TOTP.Algorithm = .sha512,
        issuer: String? = "Example Issuer",
        username: String? = "ada"
    ) -> ASImportableCredential {
        .totp(.init(secret: secret, period: period, digits: digits, userName: username, algorithm: algorithm, issuer: issuer))
    }

    func importableItem(
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

    func data(
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

    func credentials(in data: ASExportedCredentialData) -> [ASImportableCredential] {
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
            totp(),
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
        let importedRecord = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(importedPasskey)) as? [String: Any])
        #expect(importedRecord["source"] as? String == "imported")
        #expect(importedRecord["createdAt"] == nil, "a provider item timestamp is not the passkey creation time")
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
    @Test func replacingAnImportedPasskeyPreservesTheExistingLocalMetadata() throws {
        let oldKey = P256.Signing.PrivateKey()
        let oldInput = data(credentials: [passkey(key: try PasskeyKeyEncoding.exportPKCS8(oldKey))])
        var existingPasskeyJSON = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try #require(CredentialExchangeCodec.preview(oldInput, against: snapshot([])).candidates.first?.passkeys.first))
        ) as? [String: Any])
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        let lastSignedAt = Date(timeIntervalSince1970: 1_700_000_200)
        existingPasskeyJSON["source"] = "created"
        existingPasskeyJSON["createdAt"] = createdAt.timeIntervalSinceReferenceDate
        existingPasskeyJSON["lastSignedAt"] = lastSignedAt.timeIntervalSinceReferenceDate
        let existingPasskey = try JSONDecoder().decode(
            WebsitePasskey.self, from: JSONSerialization.data(withJSONObject: existingPasskeyJSON)
        )
        let existing = account(
            id: accountID, externalID: accountExternalID, itemID: itemExternalID, username: "ada",
            password: nil, passkeys: [existingPasskey]
        )
        let newKey = P256.Signing.PrivateKey()
        let incoming = data(
            credentials: [passkey(key: try PasskeyKeyEncoding.exportPKCS8(newKey))]
        )
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([existing]))
        let conflict = try #require(preview.conflicts.first)
        let reconciled = try CredentialExchangeCodec.apply(
            preview, decisions: [.replace(incoming: conflict.incoming, target: conflict.existing)]
        )
        let updated = try #require(reconciled.first?.passkeys.first)
        let updatedRecord = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(updated)) as? [String: Any])

        #expect(updated.credentialID == existingPasskey.credentialID)
        #expect(updatedRecord["source"] as? String == "created")
        #expect((updatedRecord["createdAt"] as? NSNumber)?.doubleValue == createdAt.timeIntervalSinceReferenceDate)
        #expect((updatedRecord["lastSignedAt"] as? NSNumber)?.doubleValue == lastSignedAt.timeIntervalSinceReferenceDate)
    }


    @Test func preservesProviderAndItemMetadataAndPrunesUnselectedCollectionLinks() throws {
        let providerID = Data([0xA0, 0x41])
        let firstItemID = Data([0xB0, 0x41])
        let secondItemID = Data([0xB0, 0x42])
        let created = Date(timeIntervalSince1970: 1_700_000_100)
        let modified = Date(timeIntervalSince1970: 1_700_000_200)
        let input = providerMetadataInput(
            providerID: providerID,
            firstItemID: firstItemID,
            secondItemID: secondItemID,
            created: created,
            modified: modified
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

    private func providerMetadataInput(
        providerID: Data,
        firstItemID: Data,
        secondItemID: Data,
        created: Date,
        modified: Date
    ) -> ASExportedCredentialData {
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
                ASImportableLinkedItem(item: secondItemID, account: providerID),
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
        return ASExportedCredentialData(
            accounts: [
                ASImportableAccount(
                    id: providerID,
                    userName: "password-manager-user",
                    email: "vault-owner@example.test",
                    fullName: "Vault Owner",
                    collections: [collection, emptyCollection],
                    items: [firstItem, secondItem]
                ),
            ],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: created
        )
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
            accounts: [
                ASImportableAccount(
                    id: providerID,
                    userName: "owner",
                    email: "owner@example.test",
                    collections: [collection],
                    items: items
                ),
            ],
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
            )),
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
            )),
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
            )),
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
}
