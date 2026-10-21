// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

// Cards, addresses, names, Wi-Fi networks, keys, documents and custom fields leave in an export as the credentials they came in as, and
// an import of that export gives back the same items: every value, its field type, id and label, and every hidden value still hidden.
// Synthetic values only.
extension CredentialExchangeTests {
    /// One item of `kind` holding every member in the SDK's order, each value with its own id and label so a lost one shows. A few
    /// members a person normally sees are hidden here, as an exporter may send them, so a hidden type alone must survive too.
    private func everyMember(_ kind: SecureItemKind) -> SecureItem {
        guard kind != .customFields else {
            return SecureItem(kind: .customFields, id: Data([0xC0, 0x02]), label: "Locker", fields: [
                SecureItemField(name: "", value: "Row 4", field: .init(id: Data([0xF0, 1]), label: "Where", fieldType: .string)),
                SecureItemField(name: "", value: "4711", field: .init(id: Data([0xF0, 2]), label: "Code", fieldType: .concealedString)),
                SecureItemField(name: "", value: "2032-02-29", field: .init(id: nil, label: "Renew by", fieldType: .date)),
            ])
        }
        let hiddenByExporter: Set<String> = ["fullName", "telephone", "surname", "userName"]
        let fields = kind.members.enumerated().map { index, member -> SecureItemField in
            if member.isPlain {
                return SecureItemField(name: member.name, value: plainValue(member.name), field: nil)
            }
            let type = hiddenByExporter.contains(member.name) ? .concealedString : member.type
            return SecureItemField(
                name: member.name, value: sample(type, index),
                field: CredentialEditableFieldMetadata(id: Data([0xE0, UInt8(index)]), label: "Label \(index)", fieldType: type)
            )
        }
        return SecureItem(kind: kind, fields: fields)
    }

    private func sample(_ type: CredentialEditableFieldType, _ index: Int) -> String {
        switch type {
        case .string:
            "synthetic value \(index)"
        case .concealedString:
            "synthetic-secret-\(index)"
        case .email:
            "ada@example.test"
        case .number:
            "42"
        case .boolean:
            "true"
        case .date:
            "2030-01-31"
        case .yearMonth:
            "2031-07"
        case .wifiNetworkSecurityType:
            "wpa3-personal"
        case .countryCode:
            "HR"
        case .subdivisionCode:
            "HR-21"
        }
    }

    /// An SSH key's plain values: its type, its private key as base64url text, and its comment.
    private func plainValue(_ name: String) -> String {
        switch name {
        case "keyType":
            "ssh-ed25519"
        case "privateKey":
            WebAuthnWire.base64URL(Data("synthetic-openssh-private-key".utf8))
        default:
            "ada@example.test"
        }
    }

    /// Which values of each item are hidden, by the vault's own rule.
    private func hidden(_ items: [SecureItem]) -> [[Bool]] {
        items.map { item in item.fields.map(item.isConcealed) }
    }

    private func itemsOnly(_ account: CredentialAccount) -> CredentialExportSelection {
        CredentialExportSelection(accountID: account.id, password: false, passkeyIDs: [], totp: false, secureItems: true)
    }

    @Test func everyKindExportsAndImportsBackUnchangedWithHiddenValuesStillHidden() throws {
        let items = SecureItemKind.allCases.map(everyMember)
        let stored = SecureItemFixtures.account(items, name: "Every kind")
        try stored.validate()

        let exported = try CredentialExchangeCodec.export(snapshot([stored]), selection: [itemsOnly(stored)], format: .v1)
        let sent = credentials(in: exported)
        #expect(sent.count == SecureItemKind.allCases.count, "one credential per item, nothing else")

        // On the wire: a value stored hidden goes out with the exchange's hidden type, and every other one with its own.
        let wire = sent.compactMap(CredentialExchangeCodec.secureItemSource)
        #expect(wire.map(\.kind) == SecureItemKind.allCases)
        #expect(wire.map { $0.fields.map { $0.field.fieldType == .concealedString } }
            == items.map { $0.fields.compactMap(\.field).map { $0.fieldType == .concealedString } })
        #expect(wire.flatMap(\.fields).filter { $0.field.fieldType == .concealedString }.count >= 10)

        let reread = try CredentialExchangeCodec.preview(exported, against: snapshot([]))
        #expect(reread.omitted.isEmpty, "nothing is left out on the way back")
        let candidate = try #require(reread.candidates.first)
        #expect(candidate.secureItems == items)
        #expect(hidden(candidate.secureItems ?? []) == hidden(items))
        #expect(hidden(items).joined().contains(false) && hidden(items).joined().contains(true))
        #expect(candidate.displayName == "Every kind")
    }

    @Test func itemsLeaveOnlyWhenSelectedAndAlone() throws {
        var stored = account(username: "ada", password: "pw")
        stored.secureItems = [SecureItemFixtures.card(), SecureItemFixtures.wifi()]
        try stored.validate()

        let login = try CredentialExchangeCodec.export(
            snapshot([stored]), selection: [.init(accountID: stored.id, password: true, passkeyIDs: [], totp: false)], format: .v1
        )
        #expect(credentials(in: login).count == 1)
        #expect(credentials(in: login).allSatisfy { CredentialExchangeCodec.secureItemSource($0) == nil })

        let items = try CredentialExchangeCodec.export(snapshot([stored]), selection: [itemsOnly(stored)], format: .v1)
        #expect(credentials(in: items).compactMap(CredentialExchangeCodec.secureItemSource).map(\.kind) == [.creditCard, .wifi])
        #expect(credentials(in: items).count == 2, "the login stays when only the items are chosen")
        #expect(try CredentialExchangeCodec.preview(items, against: snapshot([])).candidates.first?.secureItems == stored.secureItems)
    }
}
