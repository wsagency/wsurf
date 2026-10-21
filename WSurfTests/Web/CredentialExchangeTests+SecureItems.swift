// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

// Cards, addresses, names, Wi-Fi networks, keys, documents and custom fields arrive in a transfer as items of their credential: every
// value in the order the SDK lists it, with its exact field type, id and label. Synthetic values only.
extension CredentialExchangeTests {
    // MARK: Builders

    /// One value of an item as the exporter sends it. `type` is the exporter's field type, and `described` is false for a value
    /// that has no id or label of its own. Values are listed in the SDK's member order.
    private struct ItemValue {
        let name: String
        let text: String
        let type: CredentialEditableFieldType
        let described: Bool

        init(_ name: String, _ text: String, _ type: CredentialEditableFieldType = .string, described: Bool = true) {
            self.name = name
            self.text = text
            self.type = type
            self.described = described
        }
    }

    /// The exporter's own name for each field type WSurf keeps, written out so the raw values are not what is under test.
    private func sdkType(_ type: CredentialEditableFieldType) -> ASImportableEditableField.FieldType {
        switch type {
        case .string:
            .string
        case .concealedString:
            .concealedString
        case .email:
            .email
        case .number:
            .number
        case .boolean:
            .boolean
        case .date:
            .date
        case .yearMonth:
            .yearMonth
        case .wifiNetworkSecurityType:
            .wifiNetworkSecurityType
        case .countryCode:
            .countryCode
        case .subdivisionCode:
            .subdivisionCode
        }
    }

    /// The description a value gets from its place in the list: different for every value, so what an item keeps shows in an assertion.
    private func details(_ value: ItemValue, at index: Int) -> CredentialEditableFieldMetadata {
        CredentialEditableFieldMetadata(
            id: value.described ? Data([0x70, UInt8(index)]) : nil,
            label: value.described ? "Label \(index)" : nil,
            fieldType: value.type
        )
    }

    private func exporterFields(_ values: [ItemValue]) -> [ASImportableEditableField] {
        values.enumerated().map { index, value in
            let described = details(value, at: index)
            return ASImportableEditableField(id: described.id, fieldType: sdkType(value.type), value: value.text, label: described.label)
        }
    }

    /// The exporter's fields by member name: a kind's initializer takes the ones it has, and `nil` for the rest.
    private func exporterMembers(_ values: [ItemValue]) -> [String: ASImportableEditableField] {
        Dictionary(uniqueKeysWithValues: zip(values.map(\.name), exporterFields(values)))
    }

    /// What an item must keep of `values`: each value under its member name, with the description the exporter gave it.
    private func keptFields(_ values: [ItemValue]) -> [SecureItemField] {
        values.enumerated().map { index, value in
            SecureItemField(name: value.name, value: value.text, field: details(value, at: index))
        }
    }

    private func sdkValue(_ text: String, _ type: ASImportableEditableField.FieldType = .string) -> ASImportableEditableField {
        ASImportableEditableField(id: nil, fieldType: type, value: text)
    }

    /// `SecureItemFixtures.card`, as the exporter sends it.
    private func sdkCard(
        number: String = SecureItemFixtures.cardNumber,
        code: String = SecureItemFixtures.cardCode
    ) -> ASImportableCredential {
        .creditCard(.init(
            number: sdkValue(number), fullName: sdkValue("Ada Lovelace"), cardType: nil,
            verificationNumber: sdkValue(code, .concealedString), pin: nil, expiryDate: sdkValue("2031-07", .yearMonth), validFrom: nil
        ))
    }

    private func sdkAddress() -> ASImportableCredential {
        .address(.init(
            streetAddress: sdkValue("1 Synthetic Way"), postalCode: sdkValue("10000"), city: sdkValue("Testville"), territory: nil,
            country: sdkValue("HR", .countryCode), telephone: nil
        ))
    }

    /// `SecureItemFixtures.wifi`, as the exporter sends it.
    private func sdkWifi() -> ASImportableCredential {
        .wifi(.init(
            ssid: sdkValue("Synthetic-Net"), networkSecurityType: sdkValue("WPA3-Personal", .wifiNetworkSecurityType),
            passphrase: sdkValue(SecureItemFixtures.wifiPassphrase, .concealedString), hidden: sdkValue("false", .boolean)
        ))
    }

    private func itemPreview(_ credentials: [ASImportableCredential]) throws -> CredentialImportPreview {
        try CredentialExchangeCodec.preview(data(credentials: credentials), against: snapshot([]))
    }

    /// The candidate `credentials` import as. Everything in them is kept, so nothing is named as left out.
    private func itemCandidate(
        _ credentials: [ASImportableCredential],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> CredentialAccount {
        let preview = try itemPreview(credentials)
        #expect(preview.omitted.isEmpty, "nothing is left out", sourceLocation: sourceLocation)
        return try #require(preview.candidates.first, sourceLocation: sourceLocation)
    }

    /// Imports `credential` and checks it became exactly one item of `kind` holding `values`, with nothing else in the credential.
    @discardableResult
    private func expectItem(
        _ credential: ASImportableCredential,
        _ kind: SecureItemKind,
        _ values: [ItemValue],
        id: Data? = nil,
        label: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> CredentialAccount {
        let candidate = try itemCandidate([credential], sourceLocation: sourceLocation)
        let expected = SecureItem(kind: kind, id: id, label: label, fields: keptFields(values))
        #expect(candidate.secureItems == [expected], sourceLocation: sourceLocation)
        #expect(CredentialExchangeCodec.identities(in: candidate) == [.secureItems(accountID: candidate.id)], sourceLocation: sourceLocation)
        try candidate.validate()
        return candidate
    }

    private func itemOmission(_ kind: Kind?, _ reason: Omission.Reason, credential: Int? = nil) -> Omission {
        Omission(
            record: credential.map { .credential(account: 0, item: 0, credential: $0) } ?? .item(account: 0, item: 0),
            title: "Example account", kind: kind, reason: reason
        )
    }

    /// The account held after `incoming` is applied to an empty vault.
    private func importedAccount(_ incoming: ASExportedCredentialData) throws -> CredentialAccount {
        let placed = try CredentialExchangeCodec.apply(CredentialExchangeCodec.preview(incoming, against: snapshot([])), decisions: [])
        return try #require(placed.first)
    }

    /// The saved credential of the exporter item `data` brings, holding `items` and the login `password`.
    private func linkedAccount(items: [SecureItem]?, password: String? = "old") -> CredentialAccount {
        var stored = account(id: accountID, externalID: accountExternalID, itemID: itemExternalID, username: "ada", password: password)
        stored.secureItems = items
        return stored
    }

    /// How the items of `incoming` classify against `accounts` only: the preview is made against an empty vault.
    private func classifyItems(_ incoming: ASExportedCredentialData, against accounts: [CredentialAccount]) throws -> CredentialImportClass {
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([]))
        let candidate = try #require(preview.candidates.first)
        return try CredentialExchangeCodec.classify(
            .secureItems(accountID: candidate.id),
            in: preview,
            destination: ImportDestinationView(accounts: accounts, removed: RemovedIdentifiers(items: []))
        )
    }

    // MARK: Every kind

    @Test func aCardKeepsEveryValueInTheSDKsOrderWithItsFieldDetails() throws {
        let values = [
            ItemValue("number", SecureItemFixtures.cardNumber), ItemValue("fullName", "Ada Lovelace"), ItemValue("cardType", "visa"),
            ItemValue("verificationNumber", SecureItemFixtures.cardCode, .concealedString), ItemValue("pin", "2468", .concealedString),
            ItemValue("expiryDate", "2031-07", .yearMonth), ItemValue("validFrom", "2026-01", .yearMonth),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.creditCard(.init(
            number: sdk["number"], fullName: sdk["fullName"], cardType: sdk["cardType"], verificationNumber: sdk["verificationNumber"],
            pin: sdk["pin"], expiryDate: sdk["expiryDate"], validFrom: sdk["validFrom"]
        )), .creditCard, values)
    }

    @Test func aCardWithoutSomeValuesKeepsTheOthersInTheSameOrder() throws {
        // The exporter sent no card type, PIN or start date: nothing stands in for them, and the rest keeps the SDK's order.
        let values = [
            ItemValue("number", SecureItemFixtures.cardNumber), ItemValue("fullName", "Ada Lovelace"),
            ItemValue("verificationNumber", SecureItemFixtures.cardCode, .concealedString), ItemValue("expiryDate", "2031-07", .yearMonth),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.creditCard(.init(
            number: sdk["number"], fullName: sdk["fullName"], cardType: nil, verificationNumber: sdk["verificationNumber"],
            pin: nil, expiryDate: sdk["expiryDate"], validFrom: nil
        )), .creditCard, values)
    }

    @Test func anAddressKeepsEveryValueInTheSDKsOrderWithItsFieldDetails() throws {
        let values = [
            ItemValue("streetAddress", "1 Synthetic Way"), ItemValue("postalCode", "10000"), ItemValue("city", "Testville"),
            ItemValue("territory", "HR-21", .subdivisionCode), ItemValue("country", "HR", .countryCode),
            ItemValue("telephone", "+385 1 000 0000"),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.address(.init(
            streetAddress: sdk["streetAddress"], postalCode: sdk["postalCode"], city: sdk["city"], territory: sdk["territory"],
            country: sdk["country"], telephone: sdk["telephone"]
        )), .address, values)
    }

    @Test func aPersonNameKeepsEveryValueInTheSDKsOrderWithItsFieldDetails() throws {
        let values = [
            ItemValue("title", "Countess"), ItemValue("given", "Ada"), ItemValue("givenInformal", "Addie"), ItemValue("given2", "Augusta"),
            ItemValue("surnamePrefix", "de"), ItemValue("surname", "Lovelace"), ItemValue("surname2", "King"),
            ItemValue("credentials", "FRS"), ItemValue("generation", "II"),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.personName(.init(
            title: sdk["title"], given: sdk["given"], givenInformal: sdk["givenInformal"], given2: sdk["given2"],
            surnamePrefix: sdk["surnamePrefix"], surname: sdk["surname"], surname2: sdk["surname2"], credentials: sdk["credentials"],
            generation: sdk["generation"]
        )), .personName, values)
    }

    @Test func aWifiNetworkKeepsEveryValueInTheSDKsOrderWithItsFieldDetails() throws {
        let values = [
            ItemValue("ssid", "Synthetic-Net"), ItemValue("networkSecurityType", "WPA3-Personal", .wifiNetworkSecurityType),
            ItemValue("passphrase", SecureItemFixtures.wifiPassphrase, .concealedString), ItemValue("hidden", "false", .boolean),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.wifi(.init(
            ssid: sdk["ssid"], networkSecurityType: sdk["networkSecurityType"], passphrase: sdk["passphrase"], hidden: sdk["hidden"]
        )), .wifi, values)
    }

    @Test func anAPIKeyKeepsEveryValueInTheSDKsOrderWithItsFieldDetails() throws {
        let values = [
            ItemValue("key", "synthetic-api-key-0001", .concealedString), ItemValue("userName", "ada"), ItemValue("keyType", "bearer"),
            ItemValue("url", "https://api.example.test"), ItemValue("validFrom", "2026-01-01", .date), ItemValue("expiryDate", "2027-01-01", .date),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.apiKey(.init(
            key: sdk["key"], userName: sdk["userName"], keyType: sdk["keyType"], url: sdk["url"], validFrom: sdk["validFrom"],
            expiryDate: sdk["expiryDate"]
        )), .apiKey, values)
    }

    @Test func aDriversLicenseKeepsEveryValueInTheSDKsOrderWithItsFieldDetails() throws {
        let values = [
            ItemValue("fullName", "Ada Lovelace"), ItemValue("birthDate", "1990-12-10", .date), ItemValue("issueDate", "2020-01-01", .date),
            ItemValue("expiryDate", "2030-01-01", .date), ItemValue("issuingAuthority", "Synthetic Authority"),
            ItemValue("territory", "HR-21", .subdivisionCode), ItemValue("country", "HR", .countryCode),
            ItemValue("licenseNumber", "DL-0000-SYN"), ItemValue("licenseClass", "B"),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.driversLicense(.init(
            fullName: sdk["fullName"], birthDate: sdk["birthDate"], issueDate: sdk["issueDate"], expiryDate: sdk["expiryDate"],
            issuingAuthority: sdk["issuingAuthority"], territory: sdk["territory"], country: sdk["country"],
            licenseNumber: sdk["licenseNumber"], licenseClass: sdk["licenseClass"]
        )), .driversLicense, values)
    }

    @Test func aPassportKeepsEveryValueInTheSDKsOrderWithItsFieldDetails() throws {
        let values = [
            ItemValue("issuingCountry", "HR", .countryCode), ItemValue("passportType", "P"), ItemValue("passportNumber", "P0000SYN"),
            ItemValue("nationalIdentificationNumber", "NID-000-SYN"), ItemValue("nationality", "Croatian"),
            ItemValue("fullName", "Ada Lovelace"), ItemValue("birthDate", "1990-12-10", .date), ItemValue("birthPlace", "Testville"),
            ItemValue("sex", "F"), ItemValue("issueDate", "2020-01-01", .date), ItemValue("expiryDate", "2030-01-01", .date),
            ItemValue("issuingAuthority", "Synthetic Authority"),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.passport(.init(
            issuingCountry: sdk["issuingCountry"], passportType: sdk["passportType"], passportNumber: sdk["passportNumber"],
            nationalIdentificationNumber: sdk["nationalIdentificationNumber"], nationality: sdk["nationality"], fullName: sdk["fullName"],
            birthDate: sdk["birthDate"], birthPlace: sdk["birthPlace"], sex: sdk["sex"], issueDate: sdk["issueDate"],
            expiryDate: sdk["expiryDate"], issuingAuthority: sdk["issuingAuthority"]
        )), .passport, values)
    }

    @Test func anIdentityDocumentKeepsEveryValueInTheSDKsOrderWithItsFieldDetails() throws {
        let values = [
            ItemValue("issuingCountry", "HR", .countryCode), ItemValue("documentNumber", "ID-0000-SYN"),
            ItemValue("identificationNumber", "IDN-000-SYN"), ItemValue("nationality", "Croatian"), ItemValue("fullName", "Ada Lovelace"),
            ItemValue("birthDate", "1990-12-10", .date), ItemValue("birthPlace", "Testville"), ItemValue("sex", "F"),
            ItemValue("issueDate", "2020-01-01", .date), ItemValue("expiryDate", "2030-01-01", .date),
            ItemValue("issuingAuthority", "Synthetic Authority"),
        ]
        let sdk = exporterMembers(values)
        try expectItem(.identityDocument(.init(
            issuingCountry: sdk["issuingCountry"], documentNumber: sdk["documentNumber"], identificationNumber: sdk["identificationNumber"],
            nationality: sdk["nationality"], fullName: sdk["fullName"], birthDate: sdk["birthDate"], birthPlace: sdk["birthPlace"],
            sex: sdk["sex"], issueDate: sdk["issueDate"], expiryDate: sdk["expiryDate"], issuingAuthority: sdk["issuingAuthority"]
        )), .identityDocument, values)
    }

    /// The key, its type and its comment are plain values of the SDK, not editable fields: they keep no field description, and the
    /// key (bytes) is kept as base64url text that decodes back to the same bytes.
    @Test func anSSHKeyKeepsItsKeyAsBase64URLAndItsPlainValuesWithoutFieldDetails() throws {
        // Bytes that make `+`, `/` and padding in standard base64, so the URL-safe alphabet and the missing padding show.
        let privateKey = Data([0xFB, 0xFF, 0xBF, 0x00, 0x01, 0x02, 0x03, 0xFE, 0xFF, 0xFA])
        let dated = [ItemValue("creationDate", "2026-01-01", .date), ItemValue("keyGenerationSource", "synthetic-generator")]
        let sdk = exporterMembers(dated)
        let key = ASImportableCredential.sshKey(.init(
            keyType: "ssh-ed25519", privateKey: privateKey, keyComment: "ada@synthetic", creationDate: sdk["creationDate"],
            expiryDate: nil, keyGenerationSource: sdk["keyGenerationSource"]
        ))
        let candidate = try itemCandidate([key])

        let item = try #require(candidate.secureItems?.first)
        #expect(candidate.secureItems?.count == 1 && item.kind == .sshKey)
        #expect(item.fields == [
            SecureItemField(name: "keyType", value: "ssh-ed25519", field: nil),
            SecureItemField(name: "privateKey", value: "-_-_AAECA_7_-g", field: nil),
            SecureItemField(name: "keyComment", value: "ada@synthetic", field: nil),
            SecureItemField(name: "creationDate", value: "2026-01-01", field: details(dated[0], at: 0)),
            SecureItemField(name: "keyGenerationSource", value: "synthetic-generator", field: details(dated[1], at: 1)),
        ])
        let stored = try #require(item.value("privateKey"))
        #expect(!stored.contains("+") && !stored.contains("/") && !stored.contains("="))
        #expect(try WebAuthnWire.base64URLDecode(stored, maximum: 1_000) == privateKey)
        try candidate.validate()

        // A comment the exporter left out is no value, and the key beside it is still kept.
        let uncommented = ASImportableCredential.sshKey(.init(
            keyType: "ssh-ed25519", privateKey: privateKey, keyComment: nil, creationDate: nil, expiryDate: nil, keyGenerationSource: nil
        ))
        let bare = try itemCandidate([uncommented])
        #expect(bare.secureItems?.first?.fields.map(\.name) == ["keyType", "privateKey"])
    }

    @Test func customFieldsKeepTheirGroupIDLabelAndEveryFieldInOrderWithItsLabelAndType() throws {
        let values = [
            ItemValue("", "4711", .concealedString), ItemValue("", "locker-room"), ItemValue("", "true", .boolean),
            ItemValue("", "ada@example.test", .email), ItemValue("", "bare value", described: false),
        ]
        let groupID = Data([0xC0, 0x01])
        let candidate = try expectItem(
            .customFields(.init(id: groupID, label: "Locker", fields: exporterFields(values))), .customFields, values, id: groupID, label: "Locker"
        )

        let item = try #require(candidate.secureItems?.first)
        #expect(item.fields.map(\.value) == ["4711", "locker-room", "true", "ada@example.test", "bare value"])
        #expect(item.fields.first?.field == CredentialEditableFieldMetadata(id: Data([0x70, 0]), label: "Label 0", fieldType: .concealedString))
        #expect(item.fields.last?.field == CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .string))
        #expect(item.fields.allSatisfy { $0.name.isEmpty })
    }

    // MARK: A credential that holds only items

    @Test func aCardOnlyItemImportsWithoutALoginAndIsPlaced() throws {
        let preview = try itemPreview([sdkCard()])
        let candidate = try #require(preview.candidates.first)

        #expect(preview.omitted.isEmpty && preview.conflicts.isEmpty)
        #expect(candidate.username.isEmpty && candidate.password == nil && candidate.passkeys.isEmpty)
        #expect(candidate.totp == nil && candidate.notes == nil)
        #expect(candidate.secureItems == [SecureItemFixtures.card()])
        #expect(CredentialExchangeCodec.identities(in: candidate) == [.secureItems(accountID: candidate.id)])
        try candidate.validate()

        let placed = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(placed.count == 1 && placed[0].secureItems == [SecureItemFixtures.card()] && placed[0].password == nil)
        #expect(placed[0].displayName == "Example account" && placed[0].exchangeItemID == itemExternalID)
        #expect(placed[0].secureItemsBase?.itemID == itemExternalID)
    }

    // MARK: Field types and limits

    @Test func anItemKeepsEveryFieldTypeExactlyAndNamesNothing() throws {
        let types: [CredentialEditableFieldType] = [
            .string, .concealedString, .email, .number, .boolean, .date, .yearMonth, .wifiNetworkSecurityType, .countryCode, .subdivisionCode,
        ]
        let values = types.enumerated().map { ItemValue("", "value \($0.offset)", $0.element) }
        let preview = try itemPreview([.customFields(.init(fields: exporterFields(values)))])

        #expect(preview.omitted.isEmpty, "a type an item keeps is not a simplification")
        let item = try #require(preview.candidates.first?.secureItems?.first)
        #expect(item.fields.compactMap { $0.field?.fieldType } == types)
        #expect(item.fields.map(\.value) == values.map(\.text))
        // The persisted names are the enum's raw values (hashed and stored), not the exchange's kebab-case ones.
        #expect(types.map(\.rawValue) == [
            "string", "concealedString", "email", "number", "boolean", "date", "yearMonth", "wifiNetworkSecurityType", "countryCode",
            "subdivisionCode",
        ])
        #expect(types.map(sdkType) == types.map(\.exchangeType))
    }

    @Test func aLoginAndANoteStillSimplifyAnUnusualTypeWhileAnItemKeepsIt() throws {
        let preview = try itemPreview([
            .basicAuthentication(.init(
                userName: .init(id: Data([1]), fieldType: .string, value: "ada"),
                password: .init(id: Data([2]), fieldType: .number, value: "123456")
            )),
            note("dated", id: Data([4]), type: .date),
            .creditCard(.init(
                number: ASImportableEditableField(id: Data([3]), fieldType: .number, value: SecureItemFixtures.cardNumber),
                fullName: nil, cardType: nil, verificationNumber: nil, pin: nil, expiryDate: nil, validFrom: nil
            )),
        ])

        let candidate = try #require(preview.candidates.first)
        #expect(candidate.password == "123456" && candidate.basicAuthenticationMetadata?.password?.fieldType == .string)
        #expect(candidate.notes?.map(\.text) == ["dated"] && candidate.notes?.first?.field?.fieldType == .string)
        #expect(candidate.secureItems?.first?.fields == [
            SecureItemField(
                name: "number", value: SecureItemFixtures.cardNumber,
                field: CredentialEditableFieldMetadata(id: Data([3]), label: nil, fieldType: .number)
            ),
        ])
        #expect(preview.omitted == [
            itemOmission(.basicAuthentication, .fieldDetailsSimplified, credential: 0),
            itemOmission(.note, .fieldDetailsSimplified, credential: 1),
        ])
    }

    @Test func theFieldTypeTablesMapEveryExchangeTypeBothWays() {
        let exchange: [ASImportableEditableField.FieldType] = [
            .string, .concealedString, .email, .number, .boolean, .date, .yearMonth, .wifiNetworkSecurityType, .countryCode, .subdivisionCode,
        ]
        #expect(exchange.compactMap(CredentialEditableFieldType.init(exchange:)).map(\.exchangeType) == exchange)
        #expect(Set(exchange.map(\.rawValue)).count == exchange.count, "the exchange's own names are distinct")
    }

    @Test func aDescriptionOverTheLimitIsDroppedFromAnItemNotRefused() throws {
        let long = ASImportableEditableField(id: Data(count: 2_000), fieldType: .concealedString, value: "kept value", label: String(repeating: "l", count: 3_000))
        let preview = try itemPreview([.customFields(.init(id: Data(count: 2_000), label: "Locker", fields: [long]))])

        let item = try #require(preview.candidates.first?.secureItems?.first)
        #expect(item.id == nil)
        #expect(item.fields == [
            SecureItemField(name: "", value: "kept value", field: CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)),
        ])
        let simplified = itemOmission(.customFields, .fieldDetailsSimplified, credential: 0)
        #expect(preview.omitted == [simplified, simplified], "the value's description and the group's are each named")
    }

    @Test func emptyValuesAreDroppedAndAnItemLeftWithNoValuesIsNotKept() throws {
        let values = [ItemValue("number", ""), ItemValue("fullName", "Ada Lovelace"), ItemValue("verificationNumber", "", .concealedString)]
        let sdk = exporterMembers(values)
        let card = ASImportableCredential.creditCard(.init(
            number: sdk["number"], fullName: sdk["fullName"], cardType: nil, verificationNumber: sdk["verificationNumber"],
            pin: nil, expiryDate: nil, validFrom: nil
        ))
        let candidate = try itemCandidate([card])
        let name = SecureItemField(name: "fullName", value: "Ada Lovelace", field: details(values[1], at: 1))
        #expect(candidate.secureItems == [SecureItem(kind: .creditCard, fields: [name])])

        // Every value empty: the item is not kept. Beside a login it is simply absent; alone, nothing in the transfer is left to import.
        let blank = ASImportableCredential.wifi(.init(ssid: sdkValue(""), networkSecurityType: nil, passphrase: sdkValue("", .concealedString)))
        let beside = try itemPreview([basicAuthentication(username: "ada", password: "pw"), blank])
        #expect(beside.candidates.first?.password == "pw" && beside.candidates.first?.secureItems == nil)
        #expect(beside.omitted.isEmpty)

        let alone = try itemPreview([blank])
        #expect(alone.candidates.isEmpty)
        #expect(alone.omitted == [itemOmission(nil, .nothingToKeep)])
    }

    @Test func aGeneratedPasswordAndALinkToAnotherItemStayUnsupportedWhileTheLoginAndTheItemImport() throws {
        let preview = try itemPreview([
            basicAuthentication(username: "ada", password: "pw"),
            .generatedPassword(.init(password: "synthetic-generated")),
            sdkCard(),
            .itemReference(.init(reference: ASImportableLinkedItem(item: Data([0x52]), account: nil))),
        ])

        let candidate = try #require(preview.candidates.first)
        #expect(candidate.password == "pw" && candidate.username == "ada")
        #expect(candidate.secureItems == [SecureItemFixtures.card()])
        #expect(preview.omitted == [
            itemOmission(.generatedPassword, .unsupportedKind, credential: 1),
            itemOmission(.itemReference, .unsupportedKind, credential: 3),
        ])
        #expect(!String(describing: preview.omitted).contains("synthetic-generated"))
    }

    @Test func anItemKeepsItsFirst64CardsAndNamesTheRest() throws {
        let cards = (0..<65).map { sdkCard(number: "42424242424242" + String(format: "%02ld", $0)) }
        let preview = try itemPreview(cards)

        let candidate = try #require(preview.candidates.first)
        #expect(candidate.secureItems?.count == 64)
        #expect(candidate.secureItems?.first?.value("number") == "4242424242424200")
        #expect(candidate.secureItems?.last?.value("number") == "4242424242424263", "the first 64 are kept, in order")
        try candidate.validate()
        #expect(preview.omitted == [itemOmission(.creditCard, .extraItems, credential: 64)])
        let text = try #require(preview.omitted.first?.text)
        #expect(text.contains("64") && !text.contains("4242"), "the wording names the bound, never a value")
    }

    @Test func aCustomItemKeepsItsFirst256ValuesAndNamesTheRest() throws {
        let fields = (0..<257).map { ASImportableEditableField(id: nil, fieldType: .string, value: "value \($0)") }
        let preview = try itemPreview([.customFields(.init(id: Data([0xC0, 0x02]), label: "Many", fields: fields))])

        let candidate = try #require(preview.candidates.first)
        let item = try #require(candidate.secureItems?.first)
        #expect(item.fields.count == 256 && item.fields.first?.value == "value 0" && item.fields.last?.value == "value 255")
        #expect(item.id == Data([0xC0, 0x02]) && item.label == "Many", "the group keeps its own id and title")
        try candidate.validate()
        #expect(preview.omitted == [itemOmission(.customFields, .extraFields, credential: 0)])
    }

    @Test func omissionsNeverCarryTheValuesOfAnItem() throws {
        let manyValues = (0..<257).map { index in
            ASImportableEditableField(
                id: nil, fieldType: .concealedString, value: index == 0 ? SecureItemFixtures.wifiPassphrase : "value \(index)"
            )
        }
        var credentials: [ASImportableCredential] = [
            basicAuthentication(username: "ada", password: "pw"),
            .generatedPassword(.init(password: SecureItemFixtures.cardNumber)),
        ]
        // The custom group is the first item and keeps 256 values; 64 cards follow, so the last one is past the item limit.
        credentials.append(.customFields(.init(label: "Many", fields: manyValues)))
        credentials += (0..<64).map { _ in sdkCard() }
        let preview = try itemPreview(credentials)

        #expect(preview.omitted.map(\.reason) == [.unsupportedKind, .extraFields, .extraItems])
        let texts = preview.omitted.map(\.text).joined(separator: "\n") + String(describing: preview.omitted)
        for secret in [SecureItemFixtures.cardNumber, SecureItemFixtures.cardCode, SecureItemFixtures.wifiPassphrase] {
            #expect(!texts.contains(secret), "a value of an item reached the review")
        }
    }

    @Test func anOversizedItemIsRefusedWithoutItsValues() throws {
        // 16 bytes a repeat: past the 4 MB an item may hold.
        let value = String(repeating: SecureItemFixtures.cardNumber, count: 250_001)
        let card = ASImportableCredential.creditCard(.init(
            number: sdkValue(value), fullName: nil, cardType: nil, verificationNumber: nil, pin: nil, expiryDate: nil, validFrom: nil
        ))
        let input = data(credentials: [card])
        do {
            _ = try CredentialExchangeCodec.preview(input, against: snapshot([]))
            Issue.record("Expected the item size limit to refuse the transfer")
        } catch let error as CredentialExchangeError {
            #expect(error.reason == .oversized && error.limit == .itemBytes)
            #expect(error.record == .credential(account: 0, item: 0, credential: 0) && error.credentialKind == .creditCard)
            #expect(!String(describing: error).contains(SecureItemFixtures.cardNumber))
        } catch {
            Issue.record("Expected a positioned refusal, got \(error)")
        }
    }

    // MARK: Store round trip

    @Test func itemsRoundTripThroughImportStoreAndReload() async throws {
        let incoming = data(credentials: [
            basicAuthentication(username: "ada", password: "pw"), sdkCard(), sdkWifi(),
            .sshKey(.init(
                keyType: "ssh-ed25519", privateKey: Data([0xFB, 0xFF, 0xBF, 0x01]), keyComment: "ada@synthetic", creationDate: nil,
                expiryDate: nil, keyGenerationSource: nil
            )),
            .customFields(.init(id: Data([0xC0, 0x01]), label: "Locker", fields: [sdkValue("4711", .concealedString)])),
        ])
        let accounts = try CredentialExchangeCodec.apply(try CredentialExchangeCodec.preview(incoming, against: snapshot([])), decisions: [])
        let imported = try #require(accounts.first)
        let items = try #require(imported.secureItems)
        #expect(items.map(\.kind) == [.creditCard, .wifi, .sshKey, .customFields])
        #expect(items[0] == SecureItemFixtures.card() && items[1] == SecureItemFixtures.wifi())
        let base = ExchangeBase(contentHash: try CredentialContent.hash(.secureItems(imported)), itemID: itemExternalID)
        #expect(imported.secureItemsBase == base)

        try await VaultStoreFixture.with { f in
            try await f.withWallStore { store, access in
                let before = try await store.snapshot(vaultID: f.vaultID, using: access)
                _ = try await store.commit(vaultID: f.vaultID, accounts, expectedRevision: before.revision, cause: nil, using: access)
            }
            // A second store reads the vault from disk.
            try await f.withWallStore { store, access in
                let stored = try await store.snapshot(vaultID: f.vaultID, using: access)
                let account = try #require(stored.accounts.first)
                #expect(account.secureItems == items)
                #expect(account.secureItemsBase == base)
                #expect(account.password == "pw")

                // What came back is what the next import of the same transfer brings: nothing to review.
                #expect(try classifyItems(incoming, against: stored.accounts) == .unchanged)
            }
            try f.verify()
        }
    }

    // MARK: Re-import classification

    @Test func reimportClassifiesItemsAgainstTheRecordedBase() throws {
        let first = data(credentials: [sdkCard()])
        let second = data(credentials: [sdkCard(number: "4242424242424250")])
        let imported = try importedAccount(first)
        #expect(imported.secureItemsBase?.itemID == itemExternalID)
        var editedLocally = imported
        editedLocally.secureItems?[0].fields[0].value = "4000000000000002"

        #expect(try classifyItems(first, against: [imported]) == .unchanged)
        #expect(try classifyItems(second, against: [imported]) == .remoteChanged)
        #expect(try classifyItems(first, against: [editedLocally]) == .localChanged)
        #expect(try classifyItems(second, against: [editedLocally]) == .bothChanged)
    }

    @Test func itemsTheSavedCredentialAlreadyHoldsAreUnchanged() throws {
        let incoming = data(credentials: [sdkCard()])
        let imported = try importedAccount(incoming)

        // An item added here beside the imported one: the other app sent nothing that isn't saved.
        var withExtra = imported
        withExtra.secureItems?.append(SecureItemFixtures.wifi())
        #expect(try classifyItems(incoming, against: [withExtra]) == .unchanged)

        // Saved before imports recorded a base: the same bytes are the same credential, anything else waits for the user.
        var unbound = imported
        unbound.secureItemsBase = nil
        #expect(try classifyItems(incoming, against: [unbound]) == .unchanged)
        #expect(try classifyItems(data(credentials: [sdkCard(number: "4242424242424250")]), against: [unbound]) == .ambiguous)
    }

    // MARK: Conflicts

    @Test func identicalItemsAreNoConflictAndDifferentOnesAreExactlyOne() throws {
        let incoming = data(credentials: [sdkCard()])
        let same = linkedAccount(items: try itemCandidate([sdkCard()]).secureItems)
        let identical = try CredentialExchangeCodec.preview(incoming, against: snapshot([same]))
        #expect(identical.conflicts.isEmpty)
        let placed = try CredentialExchangeCodec.apply(identical, decisions: [])
        #expect(placed.count == 1 && placed[0].secureItems == same.secureItems, "merging identical items adds nothing")

        let different = linkedAccount(items: [SecureItemFixtures.wifi()])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([different]))
        let candidate = try #require(preview.candidates.first)
        #expect(preview.conflicts.count == 1)
        let conflict = try #require(preview.conflicts.first)
        #expect(conflict.incoming == .secureItems(accountID: candidate.id) && conflict.existing == .secureItems(accountID: different.id))

        // The conflict must be decided: the default never overwrites or merges it silently.
        #expect(throws: CredentialVaultError.invalidData) { try CredentialExchangeCodec.apply(preview, decisions: []) }
    }

    @Test func aSavedCredentialWithoutItemsTakesTheImportedOnesByDefault() throws {
        let stored = linkedAccount(items: nil)
        let preview = try CredentialExchangeCodec.preview(data(credentials: [sdkCard()]), against: snapshot([stored]))

        #expect(preview.conflicts.isEmpty)
        let placed = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(placed.count == 1 && placed[0].id == stored.id && placed[0].secureItems == [SecureItemFixtures.card()])
    }

    @Test func mergeUnitesItemsKeepingAnIdenticalOneOnceAndReplaceOverwrites() throws {
        let card = try #require(try itemCandidate([sdkCard()]).secureItems?.first)
        let address = try #require(try itemCandidate([sdkAddress()]).secureItems?.first)
        let stored = linkedAccount(items: [card, SecureItemFixtures.wifi()])
        let preview = try CredentialExchangeCodec.preview(data(credentials: [sdkCard(), sdkAddress()]), against: snapshot([stored]))
        let candidate = try #require(preview.candidates.first)
        let identity = CredentialIdentity.secureItems(accountID: candidate.id)
        #expect(preview.conflicts.map(\.incoming) == [identity])

        let merged = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: identity, targetAccountID: stored.id)])
        #expect(merged.count == 1 && merged[0].secureItems == [card, SecureItemFixtures.wifi(), address])

        let replaced = try CredentialExchangeCodec.apply(
            preview, decisions: [.replace(incoming: identity, target: .secureItems(accountID: stored.id))]
        )
        #expect(replaced[0].secureItems == [card, address])

        let skipped = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: identity)])
        #expect(skipped == [stored])
    }

    // MARK: Items follow their login

    @Test func skippingTheLoginSkipsItsUndecidedItems() throws {
        let stored = linkedAccount(items: nil)
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "old"), sdkCard()])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([stored]))
        let candidate = try #require(preview.candidates.first)

        // Only the login is a conflict (the saved credential has no items to clash with); skipping it takes the card with it.
        #expect(preview.conflicts.map(\.incoming) == [.password(accountID: candidate.id)])
        let placed = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: .password(accountID: candidate.id))])
        #expect(placed == [stored])
    }

    @Test func anItemWithAConflictOfItsOwnDoesNotFollowTheLogin() throws {
        let stored = linkedAccount(items: [SecureItemFixtures.wifi()])
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "old"), sdkCard()])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([stored]))
        let candidate = try #require(preview.candidates.first)
        let login = CredentialIdentity.password(accountID: candidate.id)
        let items = CredentialIdentity.secureItems(accountID: candidate.id)
        #expect(preview.conflicts.map(\.incoming) == [login, items])

        // Skipping the login does not decide the items: they have a conflict of their own.
        #expect(throws: CredentialVaultError.invalidData) { try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: login)]) }

        let both = try CredentialExchangeCodec.apply(
            preview, decisions: [.keep(incoming: login), .add(incoming: items, targetAccountID: stored.id)]
        )
        #expect(both.count == 1 && both[0].secureItems == [SecureItemFixtures.wifi(), SecureItemFixtures.card()])
    }

    @Test func anUndecidedItemGoesWhereItsLoginGoes() throws {
        let bare = account(
            username: "", password: nil, totp: TOTPGenerator(secret: Data([1]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil)
        )
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "pw"), sdkCard()])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare]))
        let candidate = try #require(preview.candidates.first)
        let login = CredentialIdentity.password(accountID: candidate.id)

        let skipped = try CredentialExchangeCodec.apply(preview, decisions: [.keep(incoming: login)])
        #expect(skipped == [bare])

        let merged = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: login, targetAccountID: bare.id)])
        #expect(merged.count == 1 && merged[0].password == "pw" && merged[0].secureItems == [SecureItemFixtures.card()])

        let separate = try CredentialExchangeCodec.apply(preview, decisions: [.add(incoming: login, targetAccountID: nil)])
        #expect(separate.count == 2 && separate[0] == bare)
        #expect(separate[1].password == "pw" && separate[1].secureItems == [SecureItemFixtures.card()])

        let byDefault = try CredentialExchangeCodec.apply(preview, decisions: [])
        #expect(byDefault.count == 2 && byDefault[1].password == "pw" && byDefault[1].secureItems == [SecureItemFixtures.card()])
    }

    @Test func anItemDecidedOnItsOwnIgnoresTheLogin() throws {
        let bare = account(
            username: "", password: nil, totp: TOTPGenerator(secret: Data([1]), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil)
        )
        let incoming = data(credentials: [basicAuthentication(username: "ada", password: "pw"), sdkCard()])
        let preview = try CredentialExchangeCodec.preview(incoming, against: snapshot([bare]))
        let candidate = try #require(preview.candidates.first)

        let placed = try CredentialExchangeCodec.apply(preview, decisions: [
            .keep(incoming: .password(accountID: candidate.id)),
            .add(incoming: .secureItems(accountID: candidate.id), targetAccountID: bare.id),
        ])
        #expect(placed.count == 1 && placed[0].password == nil && placed[0].secureItems == [SecureItemFixtures.card()])
    }
}
