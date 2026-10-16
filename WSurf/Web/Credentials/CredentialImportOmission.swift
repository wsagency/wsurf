// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A part of a transfer that WSurf did not keep, shown in the review before anything is saved. Only the position, the item's
/// title, the kind of credential and a fixed reason: never a value, so the list can be shown and logged safely. Everything else in
/// the transfer is still imported; only the checks that protect the vault refuse a whole transfer.
nonisolated struct CredentialImportOmission: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// A kind of credential WSurf has no place for yet.
        case unsupportedKind
        /// A passkey that is not ES256, cannot be read, or belongs to a website the vault will not serve.
        case passkeyNotKept
        /// A verification code whose settings WSurf cannot use.
        case codeNotKept
        /// A second login in one item: the first is kept.
        case extraLogin
        /// A second verification code in one item: the first is kept.
        case extraCode
        /// A login with neither a username nor a password.
        case emptyLogin
        /// A website that is not an HTTPS address.
        case websitesNotKept
        case androidAppsNotKept
        /// Who the item is shared with.
        case sharingNotKept
        /// A field kept as plain text, or without its id or label.
        case fieldDetailsSimplified
        /// The whole item: it held nothing WSurf can keep.
        case nothingToKeep
    }

    let record: CredentialExchangeError.Record
    let title: String
    let kind: CredentialExchangeError.CredentialKind?
    let reason: Reason

    /// Fixed wording, built from the kind and the reason only.
    var text: String {
        let name = title.isEmpty ? String(localized: "Untitled item") : title
        return "\(name): \(detail)"
    }

    private var detail: String {
        switch reason {
        case .unsupportedKind:
            let label = kind?.label ?? String(localized: "This item")
            return String(localized: "\(label) isn’t supported yet, so it wasn’t imported.")
        case .passkeyNotKept:
            return String(localized: "A passkey can’t be stored, so it wasn’t imported.")
        case .codeNotKept:
            return String(localized: "A verification code has settings WSurf can’t use, so it wasn’t imported.")
        case .extraLogin:
            return String(localized: "It has more than one login. Only the first was imported.")
        case .extraCode:
            return String(localized: "It has more than one verification code. Only the first was imported.")
        case .emptyLogin:
            return String(localized: "A login has no username and no password, so it wasn’t imported.")
        case .websitesNotKept:
            return String(localized: "Some websites aren’t secure HTTPS addresses, so they weren’t imported.")
        case .androidAppsNotKept:
            return String(localized: "Android apps can’t be used here, so they weren’t imported.")
        case .sharingNotKept:
            return String(localized: "Who it is shared with isn’t imported.")
        case .fieldDetailsSimplified:
            return String(localized: "A field was saved as plain text without its original details.")
        case .nothingToKeep:
            return String(localized: "It has nothing WSurf can store yet, so it wasn’t imported.")
        }
    }
}

nonisolated extension CredentialExchangeError.CredentialKind {
    /// What the kind is called where the user reads it.
    var label: String {
        switch self {
        case .address:
            String(localized: "An address")
        case .apiKey:
            String(localized: "An API key")
        case .basicAuthentication:
            String(localized: "A login")
        case .creditCard:
            String(localized: "A payment card")
        case .customFields:
            String(localized: "Custom fields")
        case .driversLicense:
            String(localized: "A driver’s license")
        case .generatedPassword:
            String(localized: "A generated password")
        case .identityDocument:
            String(localized: "An identity document")
        case .itemReference:
            String(localized: "A link to another item")
        case .note:
            String(localized: "A note")
        case .passkey:
            String(localized: "A passkey")
        case .passport:
            String(localized: "A passport")
        case .personName:
            String(localized: "A name")
        case .sshKey:
            String(localized: "An SSH key")
        case .totp:
            String(localized: "A verification code")
        case .wifi:
            String(localized: "A Wi-Fi network")
        case .unknown:
            String(localized: "A kind of item WSurf doesn’t know")
        }
    }
}
