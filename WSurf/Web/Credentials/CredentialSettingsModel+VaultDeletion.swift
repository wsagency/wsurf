// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation

/// A vault deletion the user was shown. It lives in the authorization session, so a lock, a re-unlock or a change of vault drops
/// it: a confirmation shown for one vault can never delete another. The counts are only what the vault held when it was shown.
nonisolated struct PendingVaultDeletion: Equatable, Sendable {
    struct Counts: Equatable, Sendable {
        let credentials: Int
        let passkeys: Int
        let codes: Int
        let inTrash: Int
        let earlierVersions: Int
    }

    let vaultID: UUID
    let epoch: UInt64
    let ordinal: Int
    let name: String
    let counts: Counts
    /// The vault autofill and saving use instead, when this one is the default.
    let fallback: String?
    /// The copy made before this vault was upgraded. WSurf never deletes it, and it still holds the old contents.
    let preMigrationBackup: URL?
    /// At least one of this vault's unlock passkeys is enrolled in no other vault, so it is left over in the passkey provider.
    let hasOwnUnlockPasskey: Bool

    /// The vault's name, typed exactly (surrounding spaces aside): the first of the two confirmations.
    func accepts(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines) == name
    }
}

/// What the page tells after a vault was deleted: its number only, never its name.
nonisolated struct DeletedVault: Equatable, Sendable {
    let ordinal: Int
    let leavesUnlockPasskey: Bool
}

/// Why Delete Vault is not offered for the selected vault, in the order the page says it.
nonisolated enum VaultDeletionBlock: Equatable, Sendable {
    case locked, onlyVault, importOpen
}

extension CredentialSettingsModel {
    var pendingVaultDeletion: PendingVaultDeletion? {
        live?.pendingVaultDeletion
    }

    /// Whether the sheet is on screen. It comes down while the deletion runs and comes back if the deletion did not happen (a declined
    /// prompt keeps the confirmation). The system's passkey prompt is a sheet of the same window, and a window that already has a
    /// sheet does not show a second one: with this sheet up, the prompt would wait for the sheet and the sheet for the prompt, and
    /// the page would spin until the user cancelled the sheet. The purge and unlock-removal dialogs do the same.
    var showsVaultDeletionSheet: Bool {
        pendingVaultDeletion != nil && !isBusy
    }

    var vaultDeletionBlock: VaultDeletionBlock? {
        guard let manager, manager.isUnlocked else { return .locked }
        if vaults.count < 2 {
            return .onlyVault
        }
        return exchange.hasStagedImport(for: manager, owner: owner) ? .importOpen : nil
    }

    /// Deletes the selected vault at once when it holds nothing at all (the store decides, inside the deleting transaction; nothing
    /// can be lost, so no sheet and no passkey). Otherwise shows what deleting it would remove, and deletes nothing: the vault must
    /// be open, not the last one, and have no import of this window under review.
    func requestVaultDeletion() async {
        guard vaultDeletionBlock == nil, !isBusy, let epoch = authorizationEpoch else { return }
        deletedVault = nil
        var outgoing: (id: UUID, notice: DeletedVault)?
        var emptied = false
        let ran = await perform(epoch: epoch) { manager in
            guard let name = try await manager.displayNames().vault, let listing = self.vaults.first(where: { $0.vaultID == manager.vaultID })
            else { throw CredentialVaultError.unauthorized }
            let enrolled = try await self.store?.enrolledPasskeys(of: self.vaults) ?? []
            let elsewhere = Set(enrolled.filter { $0.vault.vaultID != manager.vaultID }.map { $0.unlock.credentialID })
            let ownPasskey = manager.unlockCredentials.contains { !elsewhere.contains($0.credentialID) }
            outgoing = (manager.vaultID, DeletedVault(ordinal: listing.ordinal, leavesUnlockPasskey: ownPasskey))
            do {
                try await manager.deleteEmptyVault(authorizedEpoch: epoch)
                emptied = true
                return
            } catch CredentialStoreError.vaultNotEmpty {
                // Something is in it: the two confirmations below.
            }
            let counts = try await manager.historyCounts()
            let others = self.vaults.filter { $0.vaultID != manager.vaultID }
            let fallback = self.defaultVaultID == manager.vaultID ? others.min(by: { $0.ordinal < $1.ordinal })?.displayName : nil
            let summaries = self.summaries
            let pending = PendingVaultDeletion(
                vaultID: manager.vaultID,
                epoch: epoch,
                ordinal: listing.ordinal,
                name: name,
                counts: PendingVaultDeletion.Counts(
                    credentials: summaries.count,
                    passkeys: summaries.reduce(0) { $0 + $1.passkeys.count },
                    codes: summaries.filter(\.hasTOTP).count,
                    inTrash: counts.trash.trashEntry,
                    earlierVersions: counts.live.revision + counts.trash.revision
                ),
                fallback: fallback,
                preMigrationBackup: listing.ordinal == 1 ? manager.preMigrationBackup : nil,
                hasOwnUnlockPasskey: ownPasskey
            )
            try self.update(epoch) { $0.pendingVaultDeletion = pending }
        }
        guard let outgoing else { return }
        var gone = emptied
        if !gone, !ran {
            gone = await isGone(outgoing.id)
        }
        if gone {
            await finishVaultDeletion(outgoing.notice)
        }
    }

    func cancelVaultDeletion() {
        guard let epoch = live?.epoch else { return }
        try? update(epoch) { $0.pendingVaultDeletion = nil }
    }

    func dismissDeletedVault() {
        deletedVault = nil
    }

    /// The second confirmation: a fresh assertion of this vault's own passkey, after the name was typed. The confirmation stays
    /// until the deletion has actually run, so a declined or failed assertion deletes nothing and the same deletion can be
    /// confirmed again or cancelled. A lock or a re-unlock since the sheet was shown deletes nothing. On success the page lists
    /// the remaining vaults again and opens the default one (still locked, if it is).
    @discardableResult
    func confirmVaultDeletion(typedName: String, in anchor: ASPresentationAnchor) async -> Bool {
        guard !isBusy else { return false }
        guard let live, let pending = live.pendingVaultDeletion, pending.epoch == live.epoch, pending.vaultID == manager?.vaultID else {
            error = Self.message(for: CredentialVaultError.unauthorized)
            return false
        }
        guard pending.accepts(typedName) else { return false }
        guard vaultDeletionBlock == nil else {
            cancelVaultDeletion()
            return false
        }
        var deleted = await perform(epoch: pending.epoch) { try await $0.deleteVault(authorizedEpoch: pending.epoch, in: anchor) }
        if !deleted {
            deleted = await isGone(pending.vaultID)
        }
        guard deleted else { return false }
        await finishVaultDeletion(DeletedVault(ordinal: pending.ordinal, leavesUnlockPasskey: pending.hasOwnUnlockPasskey))
        return true
    }

    /// The vault is no longer listed: its deletion committed and then reported a failure (closing the database, say), which is still
    /// a deletion.
    private func isGone(_ vaultID: UUID) async -> Bool {
        guard let store, let listing = try? await store.listing() else { return false }
        return !listing.contains { $0.vaultID == vaultID }
    }

    /// Lists what is left, opens the default vault (still locked, if it is) and tells which vault went.
    private func finishVaultDeletion(_ notice: DeletedVault) async {
        await retry()
        deletedVault = notice
    }
}
