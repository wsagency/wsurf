// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An account an action replaced, and the stamp of the account as the action left it. The stamp is what an undo requires to still
/// hold: an account changed since is not put back over.
nonisolated struct CredentialReplaced: Sendable {
    let before: CredentialAccount
    let after: AccountStamp
}

/// One action of the Credentials page that Undo can take back. It lives only in the unlocked session, secrets included like the open
/// draft, and goes with it: a lock, another vault or leaving the page ends it. Nothing here is ever logged.
nonisolated struct CredentialUndoStep: Sendable {
    enum Kind: Equatable, Sendable {
        case moveToTrash, merge, edit, add, restore, markForDeletion
    }

    /// Tells this step from the others while a replay is under way, so the step that ran is the one that is taken off its stack.
    let id = UUID()
    var kind: Kind
    /// Accounts to put back as they were.
    var accounts: [CredentialReplaced] = []
    /// What the action moved to the Trash; it comes back.
    var returning: [RemovalScope] = []
    /// What the action added or restored; it goes to the Trash.
    var removing: [UUID: AccountStamp] = [:]
    /// Trash entries only marked for deletion in this session: there is no vault write to take back.
    var marked: [UUID] = []
    /// The stamps the accounts it touches had just before it ran (those that existed). The step behind it in its stack is the action
    /// before this one when it expects those very stamps; only then does it follow the accounts to their new stamps.
    var starting: [UUID: AccountStamp] = [:]
}

nonisolated extension RemovalScope {
    /// The account the removal belongs to.
    var ownerID: UUID {
        switch self {
        case .account(let id):
            id
        case .credential(let owner, _, _):
            owner
        }
    }
}

nonisolated extension CredentialUndoStep {
    /// The accounts this step writes, returns or moves: the ones whose stored rows change when it runs.
    var touchedAccounts: Set<UUID> {
        var ids = Set(accounts.map { $0.before.id })
        ids.formUnion(returning.map(\.ownerID))
        ids.formUnion(removing.keys)
        return ids
    }

    /// This step, bound to the stamps the accounts have now after `replayed` ran in front of it. This step expects an account as its own
    /// action left it. When `replayed` rewrote that account, the content is what this step expects but the stamp is new, so the step
    /// follows it, provided nothing else changed the account in between: that is so when the stamp this step expects is the very stamp
    /// `replayed` started from. An account anything else changed keeps its old stamp, and the replay of this step refuses it.
    func rebound(behind replayed: CredentialUndoStep, to stamps: [UUID: AccountStamp]) -> CredentialUndoStep {
        var step = self
        step.accounts = accounts.map { replaced in
            guard replayed.starting[replaced.before.id] == replaced.after, let stamp = stamps[replaced.before.id] else { return replaced }
            return CredentialReplaced(before: replaced.before, after: stamp)
        }
        for (id, expected) in removing where replayed.starting[id] == expected {
            if let stamp = stamps[id] {
                step.removing[id] = stamp
            }
        }
        return step
    }
}

nonisolated extension CredentialUndoStep.Kind {
    /// The Edit menu's title for Undo.
    var undoTitle: LocalizedStringResource {
        switch self {
        case .moveToTrash:
            "Undo Move to Trash"
        case .merge:
            "Undo Merge"
        case .edit:
            "Undo Edit"
        case .add:
            "Undo Add Credential"
        case .restore:
            "Undo Restore"
        case .markForDeletion:
            "Undo Delete"
        }
    }

    /// The Edit menu's title for Redo.
    var redoTitle: LocalizedStringResource {
        switch self {
        case .moveToTrash:
            "Redo Move to Trash"
        case .merge:
            "Redo Merge"
        case .edit:
            "Redo Edit"
        case .add:
            "Redo Add Credential"
        case .restore:
            "Redo Restore"
        case .markForDeletion:
            "Redo Delete"
        }
    }

    /// What the page says once the action is repeated.
    var redoneNotice: LocalizedStringResource {
        switch self {
        case .moveToTrash:
            "Redid Move to Trash."
        case .merge:
            "Redid Merge."
        case .edit:
            "Redid Edit."
        case .add:
            "Redid Add Credential."
        case .restore:
            "Redid Restore."
        case .markForDeletion:
            "Redid Delete."
        }
    }

    /// What the page says once the action is taken back.
    var undoneNotice: LocalizedStringResource {
        switch self {
        case .moveToTrash:
            "Undid Move to Trash."
        case .merge:
            "Undid Merge."
        case .edit:
            "Undid Edit."
        case .add:
            "Undid Add Credential."
        case .restore:
            "Undid Restore."
        case .markForDeletion:
            "Undid Delete."
        }
    }
}

/// Which way a step is replayed: Undo takes the newest action back, Redo repeats the newest one that was taken back.
nonisolated enum CredentialReplay: Sendable {
    case undo, redo
}
