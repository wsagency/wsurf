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
}
