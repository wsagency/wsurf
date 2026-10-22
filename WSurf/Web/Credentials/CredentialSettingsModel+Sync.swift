// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation
import WSurfCore
import WSurfVault

/// Why adding a vault that another Mac synced did not work, where the card explains it. (A missing authority is not kept: the card
/// reads it from the page again every time, so it goes as soon as a vault is unlocked.)
enum SyncAddFailure: Equatable {
    /// The passkey gave a key that opens no copy of this vault on this Mac. `keyCheck` is the non-secret value to compare.
    case keyDiffers(vaultID: UUID, keyCheck: String)
}

// The page's side of iCloud vault sync. All of it is gone, and every control with it, unless `CloudSync.shared?.vaults` exists: the
// hidden flag and the signed entitlements both have to allow it. The private profile has none of it.
extension CredentialSettingsModel {
    var vaultSync: VaultSync? {
        profile.isPrivate ? nil : CloudSync.shared?.vaults
    }

    var syncStatus: VaultSyncStatus? {
        guard let sync = vaultSync, let id = selectedVaultID else { return nil }
        return sync.status(profileID: profile.id, vaultID: id)
    }

    /// Vaults other devices synced for this profile that this Mac does not hold yet.
    var addableSyncedVaults: [RemoteVault] {
        guard let sync = vaultSync else { return [] }
        let held = Set(vaults.map(\.vaultID))
        return sync.remoteVaults(profileID: profile.id).filter { !held.contains($0.vaultID) }
    }

    /// Whether adding `remote` can start: a first run needs nothing; later an unlocked vault of the profile, or a vault that enrolls the
    /// passkey, must approve it. Asked before any prompt, so the card says what is missing instead of asking for a passkey in vain.
    func canAddSyncedVault(_ remote: RemoteVault) -> Bool {
        if case .firstRun = openState {
            return true
        }
        guard openState?.isProvisional == true else { return false }
        if CredentialManager.unlockedAuthorizer(in: vaults, selected: manager, profile: profile) != nil {
            return true
        }
        guard let wrappers = try? VaultWrapperList.decode(remote.payload.wrappers) else { return false }
        return existingPasskeys.contains { item in
            wrappers.contains { $0.credentialID == item.unlock.credentialID && $0.prfInput == item.unlock.prfInput }
        }
    }

    func vaultIsSyncedHere(_ vaultID: UUID) -> Bool {
        vaultSync?.isSyncing(profileID: profile.id, vaultID: vaultID) == true
    }

    // MARK: Turning sync on and off

    /// Turns sync on for the selected, unlocked vault: creates its zone or joins the one another Mac made.
    func enableSync() async {
        guard let sync = vaultSync, let id = selectedVaultID else { return }
        _ = await guarded { try await sync.enable(profileID: profile.id, vaultID: id) }
    }

    /// This Mac stops syncing the vault. iCloud and the other Macs are untouched.
    func disableSync() {
        guard let id = selectedVaultID else { return }
        vaultSync?.disable(profileID: profile.id, vaultID: id)
    }

    /// Deletes the vault's zone in iCloud. Every Mac keeps its copy.
    func removeSelectedVaultFromICloud() {
        guard let id = selectedVaultID else { return }
        vaultSync?.removeFromICloud(profileID: profile.id, vaultID: id)
    }

    // MARK: Adding a vault from another Mac

    /// Opens the synced passkey (one user-verified prompt), adds the vault to this profile's store, locked, and starts syncing it. Its
    /// entries arrive at its first unlock. A key that differs is told on the card and changes nothing; no authority is told there too, before any prompt.
    func addSyncedVault(_ remote: RemoteVault, in anchor: @autoclosure () -> ASPresentationAnchor) async {
        guard let sync = vaultSync else { return }
        syncAddFailure = nil
        var added: UUID?
        let finished = await guarded {
            do {
                added = try await CredentialManager.adoptSyncedVault(profile: profile, remote: remote, in: anchor(), native: native)
            } catch CredentialManagerError.syncKeyDiffers(let keyCheck) {
                syncAddFailure = .keyDiffers(vaultID: remote.vaultID, keyCheck: keyCheck)
            }
        }
        guard finished, let added else { return }
        await sync.adopted(profileID: profile.id, vaultID: added)
        await retry()
    }

    // MARK: Review

    /// Opens the entries that changed here and on another device, both versions each. Needs the vault unlocked.
    func openSyncReview() async {
        guard let sync = vaultSync, let id = selectedVaultID else { return }
        _ = await guarded { syncReview = try await sync.conflicts(profileID: profile.id, vaultID: id) }
    }

    func closeSyncReview() {
        syncReview = nil
    }

    /// `keepLocal` keeps this Mac's version (or, for a deleted entry, leaves it deleted); otherwise iCloud's version is taken. The
    /// version not kept stays in that entry's History or Trash.
    func resolveSync(_ accountIDs: [UUID], keepLocal: Bool) async {
        guard let sync = vaultSync, let id = selectedVaultID, !accountIDs.isEmpty else { return }
        let resolved = await guarded {
            try await sync.resolve(profileID: profile.id, vaultID: id, accountIDs: accountIDs, keepLocal: keepLocal)
        }
        if resolved {
            await reloadAfterSync()
        }
        syncReview = nil
        await openSyncReview()
        if syncReview?.isEmpty == true {
            syncReview = nil
        }
    }

    // MARK: Writes from another device

    /// Sync wrote to the open vault: the page reads it again, unless an editor or an import review is open. Those keep their revision, so
    /// a save made after a synced change fails as "changed elsewhere" instead of overwriting; the page reads again when they close.
    func reloadAfterSync() async {
        guard isLoaded else { return }
        if draft != nil || importReview != nil {
            syncReloadPending = true
            return
        }
        syncReloadPending = false
        await load()
    }

    /// Called when the editor or the import review closes.
    func reloadIfSyncWaited() async {
        guard syncReloadPending, draft == nil, importReview == nil else { return }
        await reloadAfterSync()
    }
}
