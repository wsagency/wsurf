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
    /// The saved credentials the other app no longer holds that the user chose to move to Trash.
    var movedToTrash = 0
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
        enum Kind: Sendable { case password, passkey, totp, note }

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
        /// `true` for a conflict with a stored credential, or (CSV) a row that shares its website and username with another row
        /// of the file or with several stored logins, each with a different password. Such a record is imported or dropped only
        /// by a choice: the defaults (`CredentialImportDefaults`) make it for what the vault can settle (unchanged, changed in
        /// one place only, removed before), and the user makes it for the rest.
        let needsChoice: Bool
        /// The line of the CSV file the record came from; `nil` for a system import.
        let csvLine: Int?
        /// `nil` for an undecided conflict, or the automatic placement for any other record.
        var choice: CredentialImportChoice?
        var isConflict: Bool {
            existing != nil
        }
        var id: CredentialIdentity {
            incoming
        }
    }

    /// Where an item sits in the review, most urgent first. The group is assigned once, when the review is staged, from what the vault
    /// says about the item's parts and the defaults (`CredentialImportDefaults`), so a decision never moves a row.
    enum Group: Int, CaseIterable, Sendable, Comparable {
        /// A part that only the user can settle: both sides changed, no common base, or an unmatched link.
        case decide
        /// A saved credential already holds this item's login, or its passkey, and the item adds something to it: a note, a passkey, a
        /// verification code or a website (`Duplicate`).
        case merge
        /// Nothing is saved for it yet.
        case new
        /// Changed in the other app only.
        case update
        /// Already saved, or changed only here.
        case saved
        /// Left out by default: removed here before, or a passkey whose key conflicts with the saved one.
        case skipped

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// What an item will do under the choices made so far. One item has one effect, the most active of its parts.
    enum Effect: Sendable {
        case undecided, new, update, merge, unchanged, skipped
        /// Already saved, and Import records that the other app's item is that credential, so the next import finds it unchanged. The
        /// credential's own content does not change.
        case linked
    }

    /// The whole item decided in one step (`CredentialExchangeCoordinator.chooseItem`). Each maps to a choice for every part it applies to.
    enum ItemAction: Sendable, Equatable {
        /// Imports what is not saved yet. Parts that conflict with a saved one are added as separate credentials.
        case importNew
        /// Keeps the saved version of every part that conflicts with a saved one.
        case keepSaved
        /// Replaces the saved version of every part that conflicts with the other app's.
        case useIncoming
        /// Adds the other app's version of every conflicting part next to the saved one.
        case keepBoth
        /// Imports nothing of this item.
        case skip
        /// Adds what the item brings (a note, a passkey, a code, websites) to the saved credential that already holds its login, and
        /// links the two. Only for an item with a `Duplicate`.
        case mergeIntoSaved
    }

    /// How many items fall under each effect: the review's footer, without a pass over the review.
    struct Tally: Equatable, Sendable {
        var undecided = 0
        var new = 0
        var updates = 0
        var merges = 0
        var unchanged = 0
        var skipped = 0
        var linked = 0

        /// Items that write to the vault. A linked item writes the link, nothing else.
        var writes: Int {
            new + updates + merges + linked
        }

        mutating func add(_ effect: Effect, _ count: Int = 1) {
            switch effect {
            case .undecided:
                undecided += count
            case .new:
                new += count
            case .update:
                updates += count
            case .merge:
                merges += count
            case .unchanged:
                unchanged += count
            case .skipped:
                skipped += count
            case .linked:
                linked += count
            }
        }
    }

    struct Candidate: Identifiable, Sendable {
        let summary: CredentialSummary
        /// Holds a login or TOTP seed but no approved website, so autofill never offers it until the user adds one.
        let needsManualAssociation: Bool
        var records: [Record]
        /// Where the row sits (see `Group`); fixed when the review is staged.
        let group: Group
        /// What a search matches: the lower-cased title, username (unless concealed) and websites. Never a password, seed or note.
        let searchKey: String
        /// The stored credential that already holds this item of the other app, if there is one.
        let linkedAccountID: UUID?
        /// The parts of this item that were not kept, with fixed wording.
        let omissions: [CredentialImportOmission]
        /// What the item does under the current choices.
        var effect: Effect
        /// The last choice made for the whole item; `nil` after a choice for one of its parts, and before any.
        var action: ItemAction?
        /// The saved credential that already holds this item's login or passkey, if there is one. Fixed when the review is staged.
        var duplicate: Duplicate?
        var id: UUID {
            summary.id
        }

        /// Items with a conflict have a saved credential to keep or replace.
        var hasConflict: Bool {
            records.contains(where: \.isConflict)
        }

        /// What can be done with the item as a whole, as `CredentialExchangeCoordinator.chooseItem` accepts it.
        var availableActions: [ItemAction] {
            CredentialImportReview.availableActions(for: records, duplicate: duplicate)
        }
    }

    /// The actions that apply to an item with these records. An action that would replace a saved password with a login that has
    /// none, that has no saved version to keep, replace or keep alongside, or that would add an identical copy of what is saved, is
    /// not offered. Import is offered for an item with no conflict, and Add Separately for a part that needs a choice.
    static func availableActions(for records: [Record], duplicate: Duplicate? = nil) -> [ItemAction] {
        if let duplicate {
            // The saved credential is what the item is compared with, so there is nothing to keep, replace or keep alongside.
            return (duplicate.isMergeable ? [.mergeIntoSaved] : []) + [.importNew, .skip]
        }
        let conflicts = records.filter(\.isConflict)
        var actions: [ItemAction] = []
        if conflicts.isEmpty {
            actions.append(.importNew)
        } else {
            actions.append(.keepSaved)
            let replaceable = conflicts.filter { $0.kind != .passkey && !keepsSavedWhenUsingIncoming($0) }
            if !replaceable.isEmpty, replaceable.allSatisfy({ !$0.removesStoredPasswordOnReplace }) {
                actions.append(.useIncoming)
            }
            if conflicts.contains(where: { $0.kind != .passkey && $0.classification != .unchanged && $0.canAddSeparately }) {
                actions.append(.keepBoth)
            }
        }
        actions.append(.skip)
        return actions
    }

    /// Whether Use Incoming leaves this conflicting part as it is saved: it is the same, or it changed only here (the other app's copy
    /// is the old one, and replacing would undo the user's edit).
    static func keepsSavedWhenUsingIncoming(_ record: Record) -> Bool {
        record.classification == .unchanged || record.classification == .localChanged
    }

    /// Whose vault the credentials go into: the profile, and the vault when its name is readable.
    let profileName: String
    let vaultName: String?
    var candidates: [Candidate]
    let revision: UInt64
    /// Candidate positions by group, in transfer order; built once.
    let sections: [Group: [Int]]
    /// What the choices made so far add up to.
    var tally: Tally
    /// What a CSV file held beyond what will be imported; `nil` for a system import. Counts the file as read (staged), not what is saved.
    var csvReport: CredentialCSVReport?
    /// Where the credentials came from, which decides the wording of the review.
    var origin = CredentialTransferMessage.Origin.system
    /// What the transfer held that WSurf will not import, shown before Import. Empty for a CSV file.
    var omitted: [CredentialImportOmission] = []
    /// The omissions that belong to no kept item (an item with nothing storable, say).
    var unattachedOmissions: [CredentialImportOmission] = []
    /// What was changed in WSurf since the last import and stays as it is (`CredentialImportReport`). Fixed when the review is staged.
    var keptChanges: [KeptChange] = []
    /// The saved credentials the other app brought earlier and the transfer no longer holds. Each is kept unless the user moves it to Trash.
    var missing: [Missing] = []
    /// The user's word that the transfer holds everything the other app has: a transfer does not say whether it is whole, so nothing
    /// moves to Trash before this is set.
    var transferIsComplete = false

    var conflicts: [Record] {
        candidates.flatMap(\.records).filter(\.isConflict)
    }
    /// `true` once nothing needs the user's decision.
    var isResolved: Bool {
        tally.undecided == 0
    }
}

/// What the review asks about every candidate, indexed once: a review of thousands of credentials must not search the preview or
/// the stored accounts again for each of them.
nonisolated struct ReviewLookup {
    private let linkedIDs: [CredentialExchangeCodec.ExternalItemID: UUID]
    private let candidatesByID: [UUID: CredentialAccount]
    private let storedCredentialIDs: Set<Data>

    init(_ preview: CredentialImportPreview) {
        linkedIDs = CredentialExchangeCodec.linkedAccountIDs(in: preview.base.accounts)
        candidatesByID = Dictionary(preview.candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        storedCredentialIDs = Set(preview.base.accounts.flatMap { $0.passkeys.map(\.credentialID) })
    }

    /// The stored account that already holds `candidate`'s exporter item, if there is one.
    func linkedAccountID(for candidate: CredentialAccount) -> UUID? {
        (try? CredentialExchangeCodec.externalItemID(for: candidate)).flatMap { linkedIDs[$0] }
    }

    /// Whether `incoming` is a passkey whose credential ID is already held by a stored passkey.
    func holdsStoredCredentialID(_ incoming: CredentialIdentity) -> Bool {
        guard case let .passkey(accountID, passkeyID) = incoming,
              let value = candidatesByID[accountID]?.passkeys.first(where: { $0.id == passkeyID }) else { return false }
        return storedCredentialIDs.contains(value.credentialID)
    }
}
