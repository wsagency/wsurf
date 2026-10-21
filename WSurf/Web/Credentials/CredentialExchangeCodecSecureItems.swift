// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation

nonisolated extension CredentialExchangeCodec {
    /// What one Credential Exchange credential of a `SecureItemKind` holds, before it is checked and budgeted: its editable fields
    /// and plain values by member name, in the SDK's member order. Custom fields keep their own order, each under the name "".
    struct SecureItemSource {
        let kind: SecureItemKind
        var id: Data?
        var label: String?
        var plain: [(name: String, value: String)] = []
        var fields: [(name: String, field: ASImportableEditableField)] = []
    }

    /// The item `credential` holds, or `nil` for a kind WSurf does not keep as an item (a login, a passkey, a code, a note, a
    /// generated password, a link to another item, or a kind added after this build).
    static func secureItemSource(_ credential: ASImportableCredential) -> SecureItemSource? {
        switch credential {
        case let .creditCard(card):
            return SecureItemSource(kind: .creditCard, fields: present([
                ("number", card.number), ("fullName", card.fullName), ("cardType", card.cardType),
                ("verificationNumber", card.verificationNumber), ("pin", card.pin), ("expiryDate", card.expiryDate),
                ("validFrom", card.validFrom),
            ]))
        case let .address(address):
            return SecureItemSource(kind: .address, fields: present([
                ("streetAddress", address.streetAddress), ("postalCode", address.postalCode), ("city", address.city),
                ("territory", address.territory), ("country", address.country), ("telephone", address.telephone),
            ]))
        case let .personName(name):
            return SecureItemSource(kind: .personName, fields: present([
                ("title", name.title), ("given", name.given), ("givenInformal", name.givenInformal), ("given2", name.given2),
                ("surnamePrefix", name.surnamePrefix), ("surname", name.surname), ("surname2", name.surname2),
                ("credentials", name.credentials), ("generation", name.generation),
            ]))
        case let .wifi(network):
            return SecureItemSource(kind: .wifi, fields: present([
                ("ssid", network.ssid), ("networkSecurityType", network.networkSecurityType), ("passphrase", network.passphrase),
                ("hidden", network.hidden),
            ]))
        case let .apiKey(key):
            return SecureItemSource(kind: .apiKey, fields: present([
                ("key", key.key), ("userName", key.userName), ("keyType", key.keyType), ("url", key.url),
                ("validFrom", key.validFrom), ("expiryDate", key.expiryDate),
            ]))
        case let .sshKey(key):
            // The private key is bytes: it is kept as base64url text (no padding), which `SecureItem.validate` checks.
            return SecureItemSource(
                kind: .sshKey,
                plain: [("keyType", key.keyType), ("privateKey", WebAuthnWire.base64URL(key.privateKey)), ("keyComment", key.keyComment ?? "")],
                fields: present([
                    ("creationDate", key.creationDate), ("expiryDate", key.expiryDate), ("keyGenerationSource", key.keyGenerationSource),
                ])
            )
        case let .driversLicense(license):
            return SecureItemSource(kind: .driversLicense, fields: present([
                ("fullName", license.fullName), ("birthDate", license.birthDate), ("issueDate", license.issueDate),
                ("expiryDate", license.expiryDate), ("issuingAuthority", license.issuingAuthority), ("territory", license.territory),
                ("country", license.country), ("licenseNumber", license.licenseNumber), ("licenseClass", license.licenseClass),
            ]))
        case let .passport(passport):
            return SecureItemSource(kind: .passport, fields: present([
                ("issuingCountry", passport.issuingCountry), ("passportType", passport.passportType),
                ("passportNumber", passport.passportNumber), ("nationalIdentificationNumber", passport.nationalIdentificationNumber),
                ("nationality", passport.nationality), ("fullName", passport.fullName), ("birthDate", passport.birthDate),
                ("birthPlace", passport.birthPlace), ("sex", passport.sex), ("issueDate", passport.issueDate),
                ("expiryDate", passport.expiryDate), ("issuingAuthority", passport.issuingAuthority),
            ]))
        case let .identityDocument(document):
            return SecureItemSource(kind: .identityDocument, fields: present([
                ("issuingCountry", document.issuingCountry), ("documentNumber", document.documentNumber),
                ("identificationNumber", document.identificationNumber), ("nationality", document.nationality),
                ("fullName", document.fullName), ("birthDate", document.birthDate), ("birthPlace", document.birthPlace),
                ("sex", document.sex), ("issueDate", document.issueDate), ("expiryDate", document.expiryDate),
                ("issuingAuthority", document.issuingAuthority),
            ]))
        case let .customFields(custom):
            return SecureItemSource(kind: .customFields, id: custom.id, label: custom.label, fields: custom.fields.map { (name: "", field: $0) })
        default:
            return nil
        }
    }

    private static func present(_ members: [(String, ASImportableEditableField?)]) -> [(name: String, field: ASImportableEditableField)] {
        members.compactMap { name, field in field.map { (name: name, field: $0) } }
    }

    /// The Credential Exchange credential `item` goes out as: `secureItemSource` read backwards, member by member. Every value keeps
    /// the field type, id and label it is stored with (`exchangeType`, never a raw value), so a hidden value goes out hidden and an
    /// import of the result gives back the same item.
    static func exportSecureItem(_ item: SecureItem) throws -> ASImportableCredential {
        func exported(_ stored: SecureItemField) -> ASImportableEditableField {
            let fieldType = item.kind.member(stored.name)?.type ?? .string
            return makeField(stored.value, metadata: stored.field ?? CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: fieldType))
        }
        func field(_ name: String) -> ASImportableEditableField? {
            item.fields.first { $0.name == name }.map(exported)
        }
        switch item.kind {
        case .creditCard:
            return .creditCard(.init(
                number: field("number"), fullName: field("fullName"), cardType: field("cardType"),
                verificationNumber: field("verificationNumber"), pin: field("pin"), expiryDate: field("expiryDate"),
                validFrom: field("validFrom")
            ))
        case .address:
            return .address(.init(
                streetAddress: field("streetAddress"), postalCode: field("postalCode"), city: field("city"),
                territory: field("territory"), country: field("country"), telephone: field("telephone")
            ))
        case .personName:
            return .personName(.init(
                title: field("title"), given: field("given"), givenInformal: field("givenInformal"), given2: field("given2"),
                surnamePrefix: field("surnamePrefix"), surname: field("surname"), surname2: field("surname2"),
                credentials: field("credentials"), generation: field("generation")
            ))
        case .wifi:
            return .wifi(.init(
                ssid: field("ssid"), networkSecurityType: field("networkSecurityType"), passphrase: field("passphrase"),
                hidden: field("hidden")
            ))
        case .apiKey:
            return .apiKey(.init(
                key: field("key"), userName: field("userName"), keyType: field("keyType"), url: field("url"),
                validFrom: field("validFrom"), expiryDate: field("expiryDate")
            ))
        case .sshKey:
            // The SDK requires a key type and key bytes. One the item lacks goes out empty, which an import reads as absent again.
            let privateKey = try item.value("privateKey").map { try WebAuthnWire.base64URLDecode($0, maximum: CredentialVaultLimits.payloadBytes) }
            return .sshKey(.init(
                keyType: item.value("keyType") ?? "", privateKey: privateKey ?? Data(), keyComment: item.value("keyComment"),
                creationDate: field("creationDate"), expiryDate: field("expiryDate"), keyGenerationSource: field("keyGenerationSource")
            ))
        case .driversLicense:
            return .driversLicense(.init(
                fullName: field("fullName"), birthDate: field("birthDate"), issueDate: field("issueDate"), expiryDate: field("expiryDate"),
                issuingAuthority: field("issuingAuthority"), territory: field("territory"), country: field("country"),
                licenseNumber: field("licenseNumber"), licenseClass: field("licenseClass")
            ))
        case .passport:
            return .passport(.init(
                issuingCountry: field("issuingCountry"), passportType: field("passportType"), passportNumber: field("passportNumber"),
                nationalIdentificationNumber: field("nationalIdentificationNumber"), nationality: field("nationality"),
                fullName: field("fullName"), birthDate: field("birthDate"), birthPlace: field("birthPlace"), sex: field("sex"),
                issueDate: field("issueDate"), expiryDate: field("expiryDate"), issuingAuthority: field("issuingAuthority")
            ))
        case .identityDocument:
            return .identityDocument(.init(
                issuingCountry: field("issuingCountry"), documentNumber: field("documentNumber"),
                identificationNumber: field("identificationNumber"), nationality: field("nationality"), fullName: field("fullName"),
                birthDate: field("birthDate"), birthPlace: field("birthPlace"), sex: field("sex"), issueDate: field("issueDate"),
                expiryDate: field("expiryDate"), issuingAuthority: field("issuingAuthority")
            ))
        case .customFields:
            return .customFields(.init(id: item.id, label: item.label, fields: item.fields.map(exported)))
        }
    }

    /// Whether every item `incoming` brings is already one of `local`'s, as the same bytes: the other app sent nothing that isn't
    /// saved here.
    static func secureItemsAreHeld(_ incoming: CredentialAccount, by local: CredentialAccount) -> Bool {
        guard let held = try? Set((local.secureItems ?? []).map { try CredentialContent.canonicalJSON($0) }) else { return false }
        return (incoming.secureItems ?? []).allSatisfy { item in (try? CredentialContent.canonicalJSON(item)).map(held.contains) ?? false }
    }
}

nonisolated extension CredentialIdentity {
    /// Notes and items go where their item's login goes when nobody decided them (`CredentialExchangeCodec.leadIdentity`).
    var followsLogin: Bool {
        switch self {
        case .note, .secureItems:
            true
        case .password, .passkey, .totp:
            false
        }
    }
}
