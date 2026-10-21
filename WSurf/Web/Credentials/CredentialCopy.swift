// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - What can be copied

/// A part of a credential that a Credentials view can put on the clipboard. A view names the part; the model reads the value
/// itself under the current unlock, so no view ever passes a string to the clipboard.
nonisolated enum CredentialCopyPart: Equatable, Sendable {
    case name
    case username
    case password
    /// The nth website the editor lists: the login addresses first, then the other HTTPS origins.
    case website(Int)
    case note(Int)
    /// The verification code valid now.
    case code
    /// The issuer and account a verification code is for. The setup key is never a part.
    case codeLabel
    case passkeyUser(UUID)
    case passkeyWebsite(UUID)
    /// One value of one of the credential's cards, addresses or other items, by position.
    case secureField(item: Int, field: Int)

    /// The brief confirmation after the copy landed. Title Case, like the app's other short notices.
    var copiedNotice: LocalizedStringResource {
        switch self {
        case .name:
            "Name Copied"
        case .username, .passkeyUser:
            "Username Copied"
        case .password:
            "Password Copied"
        case .website, .passkeyWebsite:
            "Website Copied"
        case .note:
            "Note Copied"
        case .code:
            "Verification Code Copied"
        case .codeLabel, .secureField:
            "Copied"
        }
    }
}

/// Where a copy reads from.
nonisolated enum CredentialCopySource: Equatable, Sendable {
    /// The credential as stored in the vault.
    case stored(UUID)
    /// The open editor, unsaved text included.
    case draft
    /// The earlier version History shows. It never yields a verification code.
    case version
}

/// One value ready for the clipboard. A secret also carries the concealed marker, so clipboard managers skip it.
nonisolated struct CredentialCopyValue: Equatable, Sendable {
    let text: String
    let isSecret: Bool
}

nonisolated extension TOTPGenerator {
    /// The issuer and account a code is for, as the editor and History show them; empty when neither is known.
    var accountLabel: String {
        [issuer, userName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Parts

/// The copyable strings of one credential state: as stored, as the editor holds it, or as an earlier version had it.
struct CredentialCopyParts {
    private let name: String?
    private let username: String
    private let usernameIsConcealed: Bool
    private let password: String?
    private let websites: [String]
    private let notes: [String]
    /// Only a source that may produce a code keeps its generator; an earlier version never does.
    private let generator: TOTPGenerator?
    private let codeLabel: String
    private let passkeys: [PasskeySummary]
    private let items: [SecureItem]

    init(_ account: CredentialAccount, allowsCode: Bool = true) {
        name = account.displayName
        username = account.username
        usernameIsConcealed = account.basicAuthenticationMetadata?.username?.fieldType == .concealedString
        password = account.password
        websites = CredentialHistory.websites(of: account).map(\.text)
        notes = account.notes?.map(\.text) ?? []
        generator = allowsCode ? account.totp : nil
        codeLabel = account.totp?.accountLabel ?? ""
        passkeys = account.passkeys.map { PasskeySummary($0) }
        items = account.secureItems ?? []
    }

    init(_ draft: CredentialDraft) {
        name = draft.displayName
        username = draft.username
        usernameIsConcealed = draft.usernameIsConcealed
        password = draft.password
        websites = Self.websiteLines(of: draft)
        notes = draft.notes.map(\.text)
        generator = draft.totp
        codeLabel = draft.totp?.accountLabel ?? ""
        passkeys = draft.passkeySummaries
        items = draft.secureItems
    }

    /// Whether `part` is a hidden value of a card or an identity document, which needs Touch ID before it leaves the vault.
    func isSensitive(_ part: CredentialCopyPart) -> Bool {
        guard case let .secureField(index, position) = part, items.indices.contains(index),
              items[index].fields.indices.contains(position) else { return false }
        let item = items[index]
        return item.kind.isSensitive && item.isConcealed(item.fields[position])
    }

    /// The editor's website lines in the order `CredentialCopyPart.website` counts them.
    static func websiteLines(of draft: CredentialDraft) -> [String] {
        [draft.websites, draft.extraOrigins].flatMap { text in
            text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }

    /// Throws `invalidData` when the credential has nothing for `part`. `now` is read only for a code.
    func value(of part: CredentialCopyPart, now: @MainActor () -> TimeInterval) throws -> CredentialCopyValue {
        switch part {
        case .name:
            return try value(name)
        case .username:
            return try value(username, secret: usernameIsConcealed)
        case .password:
            guard let password else { throw CredentialVaultError.invalidData }
            return CredentialCopyValue(text: password, isSecret: true)
        case .website(let index):
            return try value(websites.indices.contains(index) ? websites[index] : nil)
        case .note(let index):
            return try value(notes.indices.contains(index) ? notes[index] : nil, secret: true)
        case .code:
            guard let generator else { throw CredentialVaultError.invalidData }
            return CredentialCopyValue(text: try TOTP.code(generator, at: now()).value, isSecret: true)
        case .codeLabel:
            return try value(codeLabel)
        case .passkeyUser(let id):
            return try value(passkeys.first { $0.id == id }?.userName)
        case .passkeyWebsite(let id):
            return try value(passkeys.first { $0.id == id }?.rpID)
        case let .secureField(index, position):
            guard items.indices.contains(index), items[index].fields.indices.contains(position) else { throw CredentialVaultError.invalidData }
            let item = items[index]
            return try value(item.fields[position].value, secret: item.isConcealed(item.fields[position]))
        }
    }

    private func value(_ text: String?, secret: Bool = false) throws -> CredentialCopyValue {
        guard let text, !text.isEmpty else { throw CredentialVaultError.invalidData }
        return CredentialCopyValue(text: text, isSecret: secret)
    }
}
