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
        /// A passkey whose key is well formed but not ES256 (P-256).
        case passkeyAlgorithmNotSupported
        /// A passkey whose key is not a PKCS#8 P-256 key WSurf can read.
        case passkeyKeyUnreadable
        /// A passkey with no credential ID, or one over `WebsitePasskey.credentialIDLimit` bytes.
        case passkeyCredentialIDInvalid
        case passkeyUserHandleMissing
        /// A user handle over `WebsitePasskey.userHandleLimit` bytes.
        case passkeyUserHandleTooLong
        /// A user name or display name over `WebsitePasskey.nameLimit` bytes.
        case passkeyNameTooLong
        /// FIDO2 extension data over the size of one stored field.
        case passkeyExtensionsTooLarge
        /// A website that is not a valid name or is a public suffix such as "com".
        case passkeyWebsiteNotAllowed
        /// The list of public suffixes could not be loaded, so no passkey website can be checked.
        case passkeyWebsiteNotChecked
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
        /// Websites past the first 64 of one item: the first 64 are kept.
        case extraWebsites
        case androidAppsNotKept
        /// Who the item is shared with.
        case sharingNotKept
        /// A field kept as plain text, or without its id or label.
        case fieldDetailsSimplified
        /// Items past the first `SecureItem.itemLimit` of one item: the first ones are kept.
        case extraItems
        /// Values past the first `SecureItem.fieldLimit` of one card, address or other item: the first ones are kept.
        case extraFields
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
        case .passkeyAlgorithmNotSupported:
            return String(localized: "A passkey uses a signature type other than ES256, which WSurf doesn’t support, so it wasn’t imported.")
        case .passkeyKeyUnreadable:
            return String(localized: "A passkey’s private key isn’t in a format WSurf can read, so it wasn’t imported.")
        case .passkeyCredentialIDInvalid:
            return String(localized: "A passkey’s credential ID is empty or longer than \(WebsitePasskey.credentialIDLimit) bytes, so it wasn’t imported.")
        case .passkeyUserHandleMissing:
            return String(localized: "A passkey has no user handle, so it wasn’t imported.")
        case .passkeyUserHandleTooLong:
            return String(localized: "A passkey’s user handle is longer than \(WebsitePasskey.userHandleLimit) bytes, so it wasn’t imported.")
        case .passkeyNameTooLong:
            return String(localized: "A passkey’s user name or display name is longer than \(WebsitePasskey.nameLimit) bytes, so it wasn’t imported.")
        case .passkeyExtensionsTooLarge:
            return String(localized: "A passkey’s extension data is too large, so it wasn’t imported.")
        case .passkeyWebsiteNotAllowed:
            return String(localized: "A passkey’s website isn’t a valid name or is a domain suffix such as “com”, so it wasn’t imported.")
        case .passkeyWebsiteNotChecked:
            return String(localized: "A passkey’s website couldn’t be checked because WSurf’s list of domain suffixes isn’t available, so it wasn’t imported.")
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
        case .extraWebsites:
            return String(localized: "It has more than \(CredentialAccount.websiteLimit) websites. Only the first \(CredentialAccount.websiteLimit) were imported.")
        case .androidAppsNotKept:
            return String(localized: "Android apps can’t be used here, so they weren’t imported.")
        case .sharingNotKept:
            return String(localized: "Who it is shared with isn’t imported.")
        case .fieldDetailsSimplified:
            return String(localized: "A field was saved as plain text without its original details.")
        case .extraItems:
            return String(localized: "It has more than \(SecureItem.itemLimit) cards and other items. Only the first \(SecureItem.itemLimit) were imported.")
        case .extraFields:
            return String(localized: "An item has more than \(SecureItem.fieldLimit) values. Only the first \(SecureItem.fieldLimit) were imported.")
        case .nothingToKeep:
            return String(localized: "It has nothing WSurf can store yet, so it wasn’t imported.")
        }
    }
}

nonisolated extension CredentialImportOmission.Reason {
    /// The reason for a passkey field `WebsitePasskey.validate` refuses.
    static func passkey(_ problem: WebsitePasskey.Problem) -> Self {
        switch problem {
        case .credentialID:
            .passkeyCredentialIDInvalid
        case .userHandleMissing:
            .passkeyUserHandleMissing
        case .userHandleTooLong:
            .passkeyUserHandleTooLong
        case .relyingParty:
            .passkeyWebsiteNotAllowed
        case .name:
            .passkeyNameTooLong
        case .key:
            .passkeyKeyUnreadable
        case .extensions:
            .passkeyExtensionsTooLarge
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
