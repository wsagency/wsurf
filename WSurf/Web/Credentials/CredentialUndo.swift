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

    var kind: Kind
    /// Accounts to put back as they were.
    var accounts: [CredentialReplaced] = []
    /// What the action moved to the Trash; it comes back.
    var returning: [RemovalScope] = []
    /// What the action added or restored; it goes to the Trash.
    var removing: [UUID: AccountStamp] = [:]
    /// Trash entries only marked for deletion in this session (U5): there is no vault write to take back.
    var marked: [UUID] = []
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

    /// This step with the stamps of `ids` taken from `stamps`. A step expects the accounts as its own action left them. When a later
    /// step is undone, the accounts it rewrote have the content this step expects but a new stamp, so this step is bound to it. An
    /// account anything else changed keeps its old stamp, and the undo of this step refuses it.
    func rebound(_ ids: Set<UUID>, to stamps: [UUID: AccountStamp]) -> CredentialUndoStep {
        var step = self
        step.accounts = accounts.map { replaced in
            guard ids.contains(replaced.before.id), let stamp = stamps[replaced.before.id] else { return replaced }
            return CredentialReplaced(before: replaced.before, after: stamp)
        }
        for id in removing.keys where ids.contains(id) {
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
