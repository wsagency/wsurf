// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// What the Add menu starts a new entry from. A template fills only the new draft with empty values; nothing is stored before Save,
/// and empty values are dropped then, as for any new entry.
nonisolated enum CredentialTemplate: CaseIterable, Sendable {
    case login
    /// A person with no sign-in: a name, an ID document and custom fields (a child's OIB, date of baptism and medical notes).
    case identity
    case card
    case address
    case note

    /// What the Add menu calls it.
    var title: String {
        switch self {
        case .login:
            String(localized: "Login")
        case .identity:
            String(localized: "Identity")
        case .card:
            String(localized: "Payment Card")
        case .address:
            String(localized: "Address")
        case .note:
            String(localized: "Secure Note")
        }
    }

    var symbol: String {
        switch self {
        case .login:
            "key"
        case .identity:
            "person.text.rectangle"
        case .card:
            "creditcard"
        case .address:
            "house"
        case .note:
            "note.text"
        }
    }

    /// Puts the template's empty items (or note) into a new draft.
    func apply(to draft: inout CredentialDraft) {
        switch self {
        case .login:
            break
        case .identity:
            func custom(_ label: String, _ type: CredentialEditableFieldType) -> SecureItemField {
                SecureItemField(name: "", value: "", field: CredentialEditableFieldMetadata(id: nil, label: label, fieldType: type))
            }
            draft.secureItems = [
                .empty(.personName),
                .empty(.identityDocument),
                SecureItem(kind: .customFields, label: "", fields: [
                    custom(String(localized: "OIB"), .concealedString),
                    custom(String(localized: "Date of baptism"), .date),
                    custom(String(localized: "Medical"), .string),
                ]),
            ]
        case .card:
            draft.secureItems = [.empty(.creditCard)]
        case .address:
            draft.secureItems = [.empty(.address)]
        case .note:
            draft.addNote()
        }
    }
}
