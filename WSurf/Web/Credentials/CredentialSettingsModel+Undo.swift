// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Undo for the Credentials page: the last five actions it made (Move to Trash, Merge, Edit, Add, Restore), kept in the unlocked
/// session. Taking one back is a new ordinary commit with the cause "undo" (`ProfileVaultStore.undo`); nothing in history is rewritten.
extension CredentialSettingsModel {
    // MARK: Recording

    /// Keeps `make`'s step, but only if the vault is exactly as the write behind `receipt` left it: the page has read it again
    /// (`reloadAfterWrite`) and its revision is that write's. A foreign write that landed in between would make the stamps in the step
    /// describe somebody else's change, so no step is kept and the notice offers no Undo.
    @discardableResult
    func recordUndo(receipt: VaultCommitReceipt, epoch: UInt64, _ make: (CredentialVaultSession) -> CredentialUndoStep?) -> Bool {
        guard let live, live.epoch == epoch, live.revision == receipt.revision, let step = make(live) else { return false }
        return (try? update(epoch) { $0.record(step) }) != nil
    }

    /// After a save of the editor: reads the vault again, keeps a step that takes the save back, and says so.
    func recordSave(of saved: CredentialAccount, from before: CredentialAccount?, receipt: VaultCommitReceipt, epoch: UInt64) async {
        try? await reloadAfterWrite(epoch: epoch)
        let recorded = recordUndo(receipt: receipt, epoch: epoch) { session in
            guard let stamp = session.stamps[saved.id] else { return nil }
            guard let before else { return CredentialUndoStep(kind: .add, removing: [saved.id: stamp]) }
            // What the edit moved to the Trash (a cleared password, a removed code or passkey) comes back with the old values.
            let removed = (try? CredentialDiff.plan(old: [before], new: [saved]).removals) ?? []
            return CredentialUndoStep(kind: .edit, accounts: [CredentialReplaced(before: before, after: stamp)], returning: removed)
        }
        showNotice(before == nil ? "Credential added." : "Changes saved.", undo: recorded)
    }

    /// After a merge: `survivors` as they were before it, and the credentials it moved to the Trash.
    func recordMerge(
        _ survivors: [CredentialAccount], absorbed: [UUID], receipt: VaultCommitReceipt, epoch: UInt64, notice: LocalizedStringResource
    ) {
        let recorded = recordUndo(receipt: receipt, epoch: epoch) { session in
            var replaced: [CredentialReplaced] = []
            for survivor in survivors {
                guard let stamp = session.stamps[survivor.id] else { return nil }
                replaced.append(CredentialReplaced(before: survivor, after: stamp))
            }
            return CredentialUndoStep(kind: .merge, accounts: replaced, returning: absorbed.map(RemovalScope.account))
        }
        showNotice(notice, undo: recorded)
    }

    /// After a restore from the Trash. `before` is the owner as it was, for a restored password, code, note or passkey.
    func recordRestore(of item: TrashItem?, owner before: CredentialAccount?, receipt: VaultCommitReceipt, epoch: UInt64) {
        let recorded = recordUndo(receipt: receipt, epoch: epoch) { session in
            guard let item, let stamp = session.stamps[item.ownerID] else { return nil }
            if item.scope == .account {
                return CredentialUndoStep(kind: .restore, removing: [item.ownerID: stamp])
            }
            guard let before else { return nil }
            return CredentialUndoStep(kind: .restore, accounts: [CredentialReplaced(before: before, after: stamp)])
        }
        showNotice("Restored from Trash.", undo: recorded)
    }

    // MARK: Undo

    /// Whether Undo has something to take back right now: not while the page is busy, and not while an editor is open (its draft
    /// would be written over a vault that moved).
    var canUndo: Bool {
        !isBusy && draft == nil && live?.undoSteps.isEmpty == false
    }

    /// The Edit menu's title, "Undo Move to Trash"; `nil` when there is nothing to take back.
    var undoMenuTitle: String? {
        guard canUndo, let step = live?.undoSteps.last else { return nil }
        return String(localized: step.kind.undoTitle)
    }

    /// Takes the last action back, in one commit. A refusal that will not change (the credential changed since, its copy in the Trash is
    /// gone, a passkey is live again) drops that step, writes nothing and says why; the next Undo tries the step before it.
    func undo() async {
        guard canUndo, let live, let step = live.undoSteps.last else { return }
        let epoch = live.epoch
        if step.kind == .markForDeletion {
            // Nothing was written: the entries show in the Trash again.
            try? update(epoch) {
                $0.markedForDeletion.removeAll { step.marked.contains($0) }
                $0.undoSteps.removeLast()
            }
            showNotice(step.kind.undoneNotice)
            return
        }
        let undone = await guarded(describe: { Self.undoMessage(for: $0) }) {
            do {
                _ = try await applyUndo(step, epoch: epoch)
            } catch let failure where Self.endsUndo(failure) {
                try? update(epoch) { $0.undoSteps.removeLast() }
                throw failure
            }
            try await reloadAfterWrite(epoch: epoch)
            // The accounts it rewrote have new stamps; the steps before it expect exactly this content under them.
            let touched = step.touchedAccounts
            try update(epoch) {
                $0.undoSteps.removeLast()
                $0.rebindUndoSteps(touched)
            }
        }
        if undone {
            showNotice(step.kind.undoneNotice)
        }
    }

    private func applyUndo(_ step: CredentialUndoStep, epoch: UInt64) async throws -> VaultCommitReceipt {
        guard let manager, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let writes = step.accounts.map { AccountWrite(accountID: $0.before.id, expected: .stamp($0.after), replacement: $0.before) }
        // Last point before the durable write: a cancelled task or a changed authorization never commits.
        try Task.checkCancellation()
        return try await manager.undo(writes: writes, returning: step.returning, removing: step.removing, authorizedEpoch: epoch)
    }

    /// A refusal that a second try would not change: the vault no longer matches the step.
    private static func endsUndo(_ error: any Error) -> Bool {
        switch error {
        case CredentialVaultError.staleRevision, CredentialVaultError.invalidData, CredentialStoreError.undeleteBlocked:
            true
        default:
            false
        }
    }

    /// What the page says: the reason, then that nothing was changed. No title, username, site or secret.
    static func undoMessage(for error: any Error) -> String? {
        guard endsUndo(error) else { return message(for: error) }
        var text = String(localized: "This can’t be undone: the credential changed since, or its copy in Trash is gone. Nothing was changed.")
        if case CredentialStoreError.undeleteBlocked(let block) = error {
            text += " " + String(localized: block.explanation)
        }
        return text
    }
}
