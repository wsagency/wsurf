// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Why a value was replaced

/// The `cause` a writer records on the revisions its commit creates (spec §11.1). Only the writers named here pass one; any other
/// token is shown exactly as written.
nonisolated enum CredentialChangeCause {
    static let `import` = "import"
    /// Written by the merge of two saved credentials (Credential Manager v3, PR E).
    static let merge = "merge"

    /// What the History panel says, `nil` when the writer said nothing.
    static func text(for cause: String?) -> String? {
        guard let cause, !cause.isEmpty else { return nil }
        return switch cause {
        case Self.import:
            String(localized: "Changed by an import")
        case Self.merge:
            String(localized: "Changed by a merge")
        default:
            cause
        }
    }
}

// MARK: - Versions

/// One whole-credential state, rebuilt from the credential as stored now and the values later changes replaced.
nonisolated struct CredentialVersion: Identifiable, Equatable, Sendable {
    /// The newest revision row this version was rebuilt from; `nil` for the credential as stored now.
    let id: UUID?
    let account: CredentialAccount
    /// When the next change replaced this version; `nil` for the credential as stored now.
    let replacedAt: Date?
    /// The parts that change replaced (empty for the current one).
    let changed: Set<RecordSubject>
    let cause: String?

    var isCurrent: Bool {
        id == nil
    }
}

/// One website line of a credential: a login address, or an HTTPS origin no login address covers.
nonisolated struct HistoryWebsite: Equatable, Sendable {
    let text: String
    let isOtherOrigin: Bool

    /// What `CredentialDraft.take` adds for this line; `nil` for an address that is not a URL.
    var field: CredentialHistoryField? {
        isOtherOrigin ? .origin(text) : URL(string: text).map(CredentialHistoryField.website)
    }
}

nonisolated enum CredentialHistory {
    /// The login addresses, then the other origins, as the editor lists them.
    static func websites(of account: CredentialAccount) -> [HistoryWebsite] {
        let covered = Set(account.loginURLs.compactMap { CredentialAccount.origin(for: $0) })
        return account.loginURLs.map { HistoryWebsite(text: $0.absoluteString, isOtherOrigin: false) }
            + account.origins.filter { !covered.contains($0) }.map { HistoryWebsite(text: $0, isOtherOrigin: true) }
    }

    /// The credential and every earlier state of it, newest first, rebuilt by putting each replaced value back. `revisions` are the
    /// account's revision rows newest first, as the store pages them. Rows written by one commit share their time and cause and name
    /// different parts, so they make one version: a state in the middle of a commit never existed.
    ///
    /// A part that was added (nothing replaced) or removed to Trash wrote no revision, and a passkey never has one. Those parts
    /// are shown as they are now in every earlier version.
    /// ponytail: a commit whose rows straddle two pages shows its last loaded row as a version until the next page completes it.
    static func versions(current: CredentialAccount, revisions: [RevisionValue]) throws -> [CredentialVersion] {
        var versions = [CredentialVersion(id: nil, account: current, replacedAt: nil, changed: [], cause: nil)]
        var state = current
        var index = revisions.startIndex
        while index < revisions.endIndex {
            let first = revisions[index].item
            var subjects = Set<RecordSubject>()
            while index < revisions.endIndex {
                let item = revisions[index].item
                guard item.recordedAt == first.recordedAt, item.cause == first.cause, subjects.insert(item.subject).inserted else { break }
                try ProfileVaultStore.applying(item.subject, value: revisions[index].value, to: &state)
                index = revisions.index(after: index)
            }
            versions.append(CredentialVersion(id: first.id, account: state, replacedAt: first.recordedAt, changed: subjects, cause: first.cause))
        }
        return versions
    }
}

/// One credential's earlier values and the versions rebuilt from them, as the open editor shows them. It holds secrets, so it lives
/// in the authorization session only: a lock drops it, and `revealsSecrets` keeps them masked until the user shows them.
nonisolated struct HistoryState: Sendable {
    let accountID: UUID
    /// The vault revision the draft and these versions were both read at.
    let revision: UInt64
    /// Every page read so far, newest first.
    var values: [RevisionValue]
    /// The cursor of the next page of older values; only meaningful inside this session.
    var next: Int?
    /// `versions[0]` is the credential as stored when History opened.
    var versions: [CredentialVersion]
    /// The version shown against the draft; `nil` is the current one.
    var selected: UUID?
    var revealsSecrets = false

    init(accountID: UUID, revision: UInt64, values: [RevisionValue], next: Int?, versions: [CredentialVersion]) {
        self.accountID = accountID
        self.revision = revision
        self.values = values
        self.next = next
        self.versions = versions
        selected = versions.dropFirst().first?.id
    }

    var shown: CredentialVersion? {
        versions.first { $0.id == selected }
    }
}

/// The part of an earlier version that "Use This" or "Add" puts into the draft (`CredentialDraft.take`).
nonisolated enum CredentialHistoryField: Equatable, Sendable {
    case name
    /// Username and password together.
    case login
    /// The whole website list and the other HTTPS origins.
    case websites
    /// One website address.
    case website(URL)
    /// One other HTTPS origin.
    case origin(String)
    case code
    /// The whole notes list.
    case notes
    /// One note, added after the draft's own.
    case note(Int)
}
