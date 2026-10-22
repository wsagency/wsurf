// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Undo for the Credentials page: the last five actions it made (Move to Trash, Merge, Edit, Add, Restore), kept in the unlocked
/// session. Taking one back is a new ordinary commit with the cause "undo" (`ProfileVaultStore.undo`); nothing in history is rewritten.
extension CredentialSettingsModel {
    // MARK: Recording

    /// Keeps `make`'s step, but only if the vault is exactly as the write behind `receipt` left it: the page has read it again
    /// (`reloadAfterWrite`) and its revision, and the stamps it read, are that write's. A foreign write that landed in between would make the stamps in the step
    /// describe somebody else's change, so no step is kept and the notice offers no Undo.
    @discardableResult
    func recordUndo(receipt: VaultCommitReceipt, epoch: UInt64, _ make: (CredentialVaultSession) -> CredentialUndoStep?) -> Bool {
        guard let live, live.epoch == epoch, live.revision == receipt.revision, live.stampsRevision == receipt.revision,
              let step = make(live) else { return false }
        return (try? update(epoch) { $0.record(step) }) != nil
    }

    /// After a save of the editor: reads the vault again, keeps a step that takes the save back, and says so.
    /// `started` is the stamp the credential had when the editor saved it.
    func recordSave(
        of saved: CredentialAccount, from before: CredentialAccount?, started: AccountStamp?, receipt: VaultCommitReceipt, epoch: UInt64
    ) async {
        _ = try? await reloadAfterWrite(epoch: epoch)
        let recorded = recordUndo(receipt: receipt, epoch: epoch) { session in
            guard let stamp = session.stamps[saved.id] else { return nil }
            guard let before else { return CredentialUndoStep(kind: .add, removing: [saved.id: stamp]) }
            // What the edit moved to the Trash (a cleared password, a removed code or passkey) comes back with the old values.
            let removed = (try? CredentialDiff.plan(old: [before], new: [saved]).removals) ?? []
            return CredentialUndoStep(
                kind: .edit, accounts: [CredentialReplaced(before: before, after: stamp)], returning: removed,
                starting: started.map { [saved.id: $0] } ?? [:]
            )
        }
        showNotice(before == nil ? "Credential added." : "Changes saved.", undo: recorded)
    }

    /// After a merge: `survivors` as they were before it, and the credentials it moved to the Trash.
    func recordMerge(
        _ survivors: [CredentialAccount], absorbed: [UUID], starting: [UUID: AccountStamp], receipt: VaultCommitReceipt, epoch: UInt64,
        notice: LocalizedStringResource
    ) {
        let recorded = recordUndo(receipt: receipt, epoch: epoch) { session in
            var replaced: [CredentialReplaced] = []
            for survivor in survivors {
                guard let stamp = session.stamps[survivor.id] else { return nil }
                replaced.append(CredentialReplaced(before: survivor, after: stamp))
            }
            return CredentialUndoStep(kind: .merge, accounts: replaced, returning: absorbed.map(RemovalScope.account), starting: starting)
        }
        showNotice(notice, undo: recorded)
    }

    /// After a restore from the Trash. `before` is the owner as it was, for a restored password, code, note or passkey.
    func recordRestore(
        of item: TrashItem?, owner before: CredentialAccount?, started: AccountStamp?, receipt: VaultCommitReceipt, epoch: UInt64
    ) {
        let recorded = recordUndo(receipt: receipt, epoch: epoch) { session in
            guard let item, let stamp = session.stamps[item.ownerID] else { return nil }
            if item.scope == .account {
                return CredentialUndoStep(kind: .restore, removing: [item.ownerID: stamp])
            }
            guard let before else { return nil }
            return CredentialUndoStep(
                kind: .restore, accounts: [CredentialReplaced(before: before, after: stamp)],
                starting: started.map { [item.ownerID: $0] } ?? [:]
            )
        }
        showNotice("Restored from Trash.", undo: recorded)
    }

    // MARK: Undo and Redo

    /// Whether Undo has something to take back right now: not while the page is busy, and not while an editor is open (its draft
    /// would be written over a vault that moved).
    var canUndo: Bool {
        !isBusy && draft == nil && live?.undoSteps.isEmpty == false
    }

    /// Whether Redo has something to repeat, on the same conditions.
    var canRedo: Bool {
        !isBusy && draft == nil && live?.redoSteps.isEmpty == false
    }

    /// The Edit menu's title, "Undo Move to Trash"; `nil` when there is nothing to take back.
    var undoMenuTitle: String? {
        guard canUndo, let step = live?.undoSteps.last else { return nil }
        return String(localized: step.kind.undoTitle)
    }

    /// The Edit menu's title, "Redo Move to Trash"; `nil` when there is nothing to repeat.
    var redoMenuTitle: String? {
        guard canRedo, let step = live?.redoSteps.last else { return nil }
        return String(localized: step.kind.redoTitle)
    }

    /// Takes the last action back, in one commit. A refusal that will not change (the credential changed since, its copy in the Trash is
    /// gone, a passkey is live again) drops that step, writes nothing and says why; the next Undo tries the step before it.
    func undo() async {
        await replay(.undo)
    }

    /// Repeats the last action that Undo took back, the same way. Any new action ends what could be redone.
    func redo() async {
        await replay(.redo)
    }

    private func replay(_ direction: CredentialReplay) async {
        guard direction == .undo ? canUndo : canRedo, let live else { return }
        guard let step = direction == .undo ? live.undoSteps.last : live.redoSteps.last else { return }
        let epoch = live.epoch
        let done = direction == .undo ? step.kind.undoneNotice : step.kind.redoneNotice
        if step.kind == .markForDeletion {
            // Nothing was written: the entries show in the Trash again, or are hidden again.
            var applied = false
            try? update(epoch) { applied = $0.replayMark(step, direction) }
            if applied {
                showNotice(done)
            }
            return
        }
        let replayed = await guarded(describe: { Self.undoMessage(for: $0, direction: direction) }) {
            let before = try await authorizedSnapshot(epoch: epoch).snapshot
            let receipt: VaultCommitReceipt
            do {
                receipt = try await applyUndo(step, epoch: epoch)
            } catch let failure where Self.endsUndo(failure) {
                try? update(epoch) { $0.discard(step, from: direction) }
                throw failure
            }
            // The write is done. What follows describes the vault only if the reload shows exactly what this write made; if it does
            // not, the step is spent and nothing is bound to stamps that may be somebody else's.
            let after = try? await reloadAfterWrite(epoch: epoch)
            let exact = after.map { $0.revision == receipt.revision } ?? false
            let inverse = exact ? after.flatMap { Self.inverse(of: step, before: before, after: $0) } : nil
            try update(epoch) { $0.completed(direction, step: step, inverse: inverse, rebinding: exact) }
        }
        if replayed {
            showNotice(done)
        }
    }

    /// The step that puts back what `step` just changed, for Redo after an Undo and for Undo after a Redo. The accounts it rewrote
    /// are written back as they were before, bound to the stamps they have now; what it returned from the Trash goes there again;
    /// what it moved to the Trash returns; and a part of an account that it moved to the Trash returns to the account. It starts from
    /// the stamps the accounts had before `step` ran.
    private static func inverse(of step: CredentialUndoStep, before: StoreSnapshot, after: StoreSnapshot) -> CredentialUndoStep? {
        var inverse = CredentialUndoStep(kind: step.kind)
        var owners = step.accounts.map { $0.before.id }
        var restored: [CredentialAccount] = []
        for scope in step.returning {
            switch scope {
            case .account(let id):
                guard let stamp = after.stamps[id] else { return nil }
                inverse.removing[id] = stamp
                restored += after.accounts.filter { $0.id == id }
            case .credential(let owner, _, _):
                if !owners.contains(owner) {
                    owners.append(owner)
                }
            }
        }
        for id in owners {
            guard let was = before.accounts.first(where: { $0.id == id }), let stamp = after.stamps[id] else { return nil }
            inverse.accounts.append(CredentialReplaced(before: was, after: stamp))
            if let now = after.accounts.first(where: { $0.id == id }) {
                inverse.returning += (try? CredentialDiff.plan(old: [was], new: [now], returning: restored).removals) ?? []
            }
        }
        inverse.returning += step.removing.keys.map(RemovalScope.account)
        let touched = inverse.touchedAccounts
        inverse.starting = before.stamps.filter { touched.contains($0.key) }
        return inverse
    }

    private func applyUndo(_ step: CredentialUndoStep, epoch: UInt64) async throws -> VaultCommitReceipt {
        guard let manager, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let writes = step.accounts.map { AccountWrite(accountID: $0.before.id, expected: .stamp($0.after), replacement: $0.before) }
        // Last point before the durable write: a cancelled task or a changed authorization never commits.
        try Task.checkCancellation()
        return try await manager.undo(writes: writes, returning: step.returning, removing: step.removing, authorizedEpoch: epoch)
    }

    /// A refusal that a second try would not change: the vault no longer matches the step, or what the step asks is not valid. A lock,
    /// a cancelled task or a busy or full disk is not one; the step stays for another try.
    private static func endsUndo(_ error: any Error) -> Bool {
        switch error {
        case CredentialVaultError.staleRevision, CredentialVaultError.invalidData, CredentialVaultError.duplicateIdentifier,
             CredentialVaultError.oversized, CredentialStoreError.undeleteBlocked, CredentialStoreError.malformed,
             CredentialStoreError.limit:
            true
        default:
            false
        }
    }

    /// What the page says: the reason, then that nothing was changed. No title, username, site or secret.
    static func undoMessage(for error: any Error, direction: CredentialReplay = .undo) -> String? {
        guard endsUndo(error) else { return message(for: error) }
        var text = direction == .undo
            ? String(localized: "This can’t be undone: the credential changed since, or its copy in Trash is gone. Nothing was changed.")
            : String(localized: "This can’t be redone: the credential changed since, or its copy in Trash is gone. Nothing was changed.")
        if case CredentialStoreError.undeleteBlocked(let block) = error {
            text += " " + String(localized: block.explanation)
        }
        return text
    }
}
