// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Value types

/// What to do with one incoming credential. Conflicts (the exporter's item or passkey already exists here)
/// must be decided; every other record is imported automatically unless a choice is made for it.
nonisolated enum CredentialImportChoice: Sendable, Equatable {
    case skip
    /// Conflicts only: overwrite the stored credential the exporter's identifiers match.
    case replace
    /// Creates a new account for the credential.
    case addSeparately
    /// Puts the credential into an account the user picked. It takes that account's websites, which the review
    /// states in full (`CredentialImportReview.Target.allowedOrigins`).
    case merge(into: UUID)
}

/// What an import does, or did, to the vault. `added` and `updated` count accounts; `results` says what became of every
/// incoming credential. Display metadata only (kind, title, website): never a password, seed or key.
nonisolated struct CredentialImportOutcome: Equatable, Sendable {
    struct Result: Equatable, Sendable, Identifiable {
        enum Action: Equatable, Sendable { case added, updated, unchanged, skipped }
        let id: CredentialIdentity
        let kind: CredentialImportReview.Record.Kind
        let title: String
        let relyingParty: String?
        let action: Action
    }

    let added: Int
    let updated: Int
    var results: [Result] = []
}

/// What `cancelImport(for:)` ended. Cancelling a running commit only asks the vault not to write: a write that
/// already started may still land, so only `.reviewCancelled` means that nothing was written.
nonisolated enum CredentialImportCancellation: Equatable, Sendable {
    case nothingOwned
    /// A claim or review was dropped and no commit was running.
    case reviewCancelled
    case commitCancellationRequested
}

/// What an export attempt can say about itself. The system never reports whether the destination app received
/// anything, so `.transferred` means only that the system accepted the hand-off without an error.
nonisolated enum CredentialExportOutcome: Equatable, Sendable {
    /// The system's hand-off call completed without an error.
    case transferred
    /// The user backed out before any credential data was passed to the system.
    case cancelled
    /// The hand-off call had started and then failed or was cancelled. The data may or may not have left.
    case uncertain

    /// What the user is told for this outcome; a user cancel says nothing.
    var message: CredentialTransferMessage? {
        switch self {
        case .transferred:
            .handedToSystem()
        case .uncertain:
            .exportUncertain()
        case .cancelled:
            nil
        }
    }
}

nonisolated enum CredentialExchangeCoordinatorError: Error, Equatable, Sendable {
    case tokenMismatch
    case wrongTarget
    case busy
    case unresolvedConflicts
    case unknownConflict
    /// The choice is not offered for that record, or it would make the import inconsistent.
    case invalidChoice
    /// Another incoming credential already replaces that stored credential.
    case replaceTaken
    case noStagedImport
    case emptySelection
    /// Domain and code only: the system's own text can name what was being transferred.
    case systemRejected(domain: String, code: Int)
}

nonisolated struct CredentialImportReview: Sendable {
    /// An existing account an incoming credential could be merged into.
    struct Target: Identifiable, Sendable {
        let accountID: UUID
        let title: String
        /// Every website the credential works on once merged: the target's own, which the credential inherits.
        /// Nothing is added to the target, and the credential's own scope is not carried over.
        let allowedOrigins: [String]
        var id: UUID {
            accountID
        }
    }

    struct Record: Identifiable, Sendable {
        enum Kind: Sendable { case password, passkey, totp }

        /// Where the record ends up under its current choice, from the plan's own account data.
        enum Destination: Sendable, Equatable {
            case skipped
            /// A new account of its own, which works on the exporter's websites for the item (possibly none).
            case newAccount(origins: [String])
            /// A stored account. It keeps exactly its own websites: `ignoredOrigins` are the ones the exporter sent
            /// for this item that it does not already approve, and none of them are added.
            case existing(accountID: UUID, title: String, origins: [String], ignoredOrigins: [String])
        }

        let incoming: CredentialIdentity
        /// The stored credential the exporter's identifiers match. Non-nil makes this record a conflict.
        let existing: CredentialIdentity?
        let kind: Kind
        let title: String
        let existingTitle: String?
        /// A passkey's own website, which it keeps wherever it is saved. `nil` for other kinds.
        let relyingParty: String?
        /// `nil` while an unresolved conflict has no decision.
        let destination: Destination?
        /// `false` for a passkey whose credential ID a stored passkey already holds: the vault keeps those unique,
        /// so a second copy can't be added, and the choice is neither offered nor accepted.
        let canAddSeparately: Bool
        /// `true` for a login conflict whose stored account has a password but whose incoming login has none. Replacing
        /// takes the exporter's username and password as sent, so it removes the stored password; the review says so
        /// before the user chooses, and `.addSeparately` or `.skip` keep it.
        let removesStoredPasswordOnReplace: Bool
        /// What the vault already says about this credential: new, unchanged, changed on either side, previously removed,
        /// ambiguous, or a passkey with a conflicting key (never replaced).
        let classification: CredentialImportClass
        /// `true` until the user decides it: a conflict with a stored credential, or (CSV) a row that shares its website and
        /// username with another row of the file or with several stored logins, each with a different password. Nothing
        /// is imported or dropped for such a record by default.
        let needsChoice: Bool
        /// The line of the CSV file the record came from; `nil` for a system import.
        let csvLine: Int?
        /// `nil` for an unresolved conflict, or an automatic import for any other record.
        var choice: CredentialImportChoice?
        var isConflict: Bool {
            existing != nil
        }
        var id: CredentialIdentity {
            incoming
        }
    }

    struct Candidate: Identifiable, Sendable {
        let summary: CredentialSummary
        /// Holds a login or TOTP seed but no approved website, so autofill never offers it until the user adds one.
        let needsManualAssociation: Bool
        let records: [Record]
        var id: UUID {
            summary.id
        }
    }

    /// Whose vault the credentials go into: the profile, and the vault when its name is readable.
    let profileName: String
    let vaultName: String?
    let candidates: [Candidate]
    let revision: UInt64
    /// `nil` until every conflict has a decision.
    let outcome: CredentialImportOutcome?
    /// What a CSV file held beyond what will be imported; `nil` for a system import. Counts the file as read (staged), not what is saved.
    var csvReport: CredentialCSVReport?

    var conflicts: [Record] {
        candidates.flatMap(\.records).filter(\.isConflict)
    }
    var isResolved: Bool {
        candidates.allSatisfy { $0.records.allSatisfy { !$0.needsChoice || $0.choice != nil } }
    }
}
