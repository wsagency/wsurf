// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation

/// The Trash tab: listing, restoring and deleting permanently. Everything it shows lives in the authorization session, so a lock, a
/// re-unlock or another vault starts again from nothing.
extension CredentialSettingsModel {
    /// The first page of the vault's Trash and its verified counts.
    func loadTrash() async throws {
        guard let live else { throw CredentialVaultError.unauthorized }
        try await fetchTrash(epoch: live.epoch)
    }

    func loadMoreTrash() async throws {
        guard let live, let after = live.trashNext, let manager else { return }
        let page = try await manager.trashPage(after: after)
        try Task.checkCancellation()
        try update(live.epoch) {
            guard $0.trashNext == after else { return }
            let known = Set($0.trash.map(\.id))
            $0.trash += page.items.filter { !known.contains($0.id) }
            $0.trashNext = page.next
        }
    }

    /// Restores a removed credential, or one removed password, code or passkey, as it was. The vault checks what the copy would
    /// collide with; a refusal writes nothing and is shown on the entry, which offers the same copy again or dismissing it.
    func restore(entryID: UUID) async {
        guard let live, let manager else { return }
        _ = await guarded {
            let (epoch, snapshot) = try await authorizedSnapshot(epoch: live.epoch)
            @MainActor func refuse(_ block: UndeleteBlock) throws {
                try update(epoch) { $0.restoreBlocked = RestoreBlocked(entryID: entryID, block: block) }
            }
            if let block = try await manager.previewUndelete(entryID: entryID).block {
                try refuse(block)
                return
            }
            let receipt: VaultCommitReceipt
            do {
                receipt = try await manager.undelete(entryID: entryID, expectedRevision: snapshot.revision, authorizedEpoch: epoch)
            } catch CredentialStoreError.undeleteBlocked(let block) {
                try refuse(block)
                return
            }
            try update(epoch) { $0.restoreBlocked = nil }
            try await reloadAfterWrite(epoch: epoch)
            let item = live.trash.first { $0.id == entryID }
            let owner = snapshot.accounts.first { $0.id == item?.ownerID }
            recordRestore(of: item, owner: owner, started: item.flatMap { snapshot.stamps[$0.ownerID] }, receipt: receipt, epoch: epoch)
        }
    }

    func dismissRestoreBlock() {
        if let live {
            try? update(live.epoch) { $0.restoreBlocked = nil }
        }
    }

    /// `entryIDs` are Trash entries already listed; `emptyAll` ignores them and purges everything the Trash holds when the
    /// write happens. Nothing is deleted until `confirmPurge`, which asks for a fresh passkey assertion.
    func requestPurge(entryIDs: [UUID], emptyAll: Bool) {
        guard let live, let manager, let counts = live.counts else { return }
        let total = counts.trash.trashEntry
        let ids = emptyAll ? [] : entryIDs
        guard emptyAll ? total > 0 : !ids.isEmpty && ids.allSatisfy({ id in live.trash.contains { $0.id == id } }) else { return }
        let pending = PendingPurge(
            entryIDs: ids, emptyAll: emptyAll, count: emptyAll ? total : ids.count, vaultID: manager.vaultID, epoch: live.epoch,
            warning: PendingPurge.Warning(logicalOnly: true, preMigrationBackup: manager.preMigrationBackup)
        )
        try? update(live.epoch) { $0.pendingPurge = pending }
    }

    func cancelPurge() {
        if let live {
            try? update(live.epoch) { $0.pendingPurge = nil }
        }
    }

    /// The confirmation stays until the purge has actually run: a declined, cancelled or failed passkey assertion leaves it
    /// shown so the same purge can be confirmed again or cancelled. A tap while the purge is in flight does nothing, a success
    /// consumes the confirmation, and a lock, re-unlock or another vault drops it with the session.
    func confirmPurge(in anchor: @autoclosure () -> ASPresentationAnchor) async {
        guard !isBusy else { return }
        guard let live, let pending = live.pendingPurge, pending.epoch == live.epoch, pending.vaultID == manager?.vaultID else {
            if let live {
                try? update(live.epoch) { $0.pendingPurge = nil }
            }
            error = Self.message(for: CredentialVaultError.unauthorized)
            return
        }
        let purged = await perform(epoch: pending.epoch) {
            _ = try await $0.purge(entryIDs: pending.entryIDs, emptyAll: pending.emptyAll, in: anchor())
        }
        guard purged else { return }
        if let current = self.live {
            try? update(current.epoch) {
                if current.pendingPurge == pending {
                    $0.pendingPurge = nil
                }
                // Entries that are gone cannot be deleted again: the marks on them end, with their steps.
                $0.dropMarks(pending.emptyAll ? nil : Set(pending.entryIDs))
            }
        }
        _ = await guarded { _ = try await reloadAfterWrite(epoch: pending.epoch) }
    }

    // MARK: Deleting with X

    /// X in the Trash: hides the entries and counts them out. Nothing is deleted until the Trash is left (`commitMarked`), and Undo
    /// shows them again, up to five steps back. Entries the Trash does not list are ignored.
    func markForDeletion(entryIDs: [UUID]) {
        guard !isBusy, let live else { return }
        let listed = Set(live.trash.map(\.id)).subtracting(live.markedForDeletion)
        let fresh = entryIDs.filter { listed.contains($0) }
        guard !fresh.isEmpty else { return }
        try? update(live.epoch) {
            $0.markedForDeletion += fresh
            $0.record(CredentialUndoStep(kind: .markForDeletion, marked: fresh))
        }
        let text: LocalizedStringResource = fresh.count == 1
            ? "1 item will be deleted permanently when you leave Trash."
            : "\(fresh.count) items will be deleted permanently when you leave Trash."
        showNotice(text, undo: true)
    }

    /// Leaving the Trash, or Delete Now: deletes everything marked, in one purge with ONE fresh passkey or Touch ID assertion and no
    /// dialog of the app. A declined or failed assertion deletes nothing; the marks end either way, so the entries show again.
    func commitMarked(in anchor: @autoclosure () -> ASPresentationAnchor) async {
        guard !isBusy, let live, !live.markedForDeletion.isEmpty else { return }
        let ids = live.markedForDeletion
        let epoch = live.epoch
        let purged = await perform(epoch: epoch) { _ = try await $0.purge(entryIDs: ids, emptyAll: false, in: anchor()) }
        try? update(epoch) { $0.dropMarks(nil) }
        guard purged else {
            showNotice("Nothing was deleted.")
            return
        }
        _ = await guarded { _ = try await reloadAfterWrite(epoch: epoch) }
        let text: LocalizedStringResource = ids.count == 1 ? "Deleted 1 item permanently." : "Deleted \(ids.count) items permanently."
        showNotice(text)
    }

    func fetchTrash(epoch: UInt64) async throws {
        guard let manager, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let page = try await manager.trashPage(after: nil)
        let counts = try await manager.historyCounts()
        try Task.checkCancellation()
        try update(epoch) {
            $0.trash = page.items
            $0.trashNext = page.next
            $0.counts = counts
            $0.restoreBlocked = nil
            $0.pendingPurge = nil
        }
    }

    /// After a write this page made: the accounts as stored (returned), and the Trash from its first page when it is open. Internal for the model's extensions.
    @discardableResult
    func reloadAfterWrite(epoch: UInt64) async throws -> StoreSnapshot {
        let (_, snapshot) = try await authorizedSnapshot(epoch: epoch)
        try update(epoch) { $0.refresh(snapshot) }
        if live?.counts != nil {
            try await fetchTrash(epoch: epoch)
        }
        return snapshot
    }
}
