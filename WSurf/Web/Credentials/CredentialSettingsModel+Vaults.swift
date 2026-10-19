// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension CredentialSettingsModel {
    /// Reads the vault listing again and changes nothing else. A vault's name is sealed in its head and listed only while that
    /// vault is unlocked, so the list changes whenever one unlocks or locks. A read that fails, is cancelled or straddles a lock or
    /// an unlock of the selected vault is dropped: the lock or unlock that changed the epoch reads again.
    func refreshListing() async {
        guard let store else { return }
        let epoch = authorizationEpoch
        guard let listing = try? await store.listing(), !Task.isCancelled, authorizationEpoch == epoch else { return }
        vaults = listing
    }

    /// The name the store gives a new vault when none is typed, so a default-named vault reads the same locked and unlocked.
    var suggestedVaultName: String {
        String(localized: "Vault \((vaults.map(\.ordinal).max() ?? 0) + 1)")
    }

    /// When the selected vault locks after its next unlock; the lease in force is told by `setAutoLock`.
    var autoLock: CredentialAutoLock {
        manager?.autoLock ?? .standard
    }

    /// Applies at once when it is shorter than the running lease, else from the next unlock. A locked vault is refused.
    func setAutoLock(_ choice: CredentialAutoLock) {
        error = nil
        do {
            try manager?.setAutoLock(choice)
        } catch {
            self.error = Self.message(for: error)
        }
    }

    /// Renames the selected vault. Only an unlocked vault has a name to change; a locked one is refused and nothing is written.
    func renameVault(_ name: String) async {
        guard let epoch = authorizationEpoch else {
            error = Self.message(for: CredentialVaultError.unauthorized)
            return
        }
        let renamed = await perform(epoch: epoch) { manager in
            _ = try await manager.renameVault(name, authorizedEpoch: epoch)
            // The rename is a new revision of the vault: the open session reads it, or its next write would be stale.
            try await self.reloadAfterWrite(epoch: epoch)
        }
        if renamed {
            await refreshListing()
        }
    }
}
