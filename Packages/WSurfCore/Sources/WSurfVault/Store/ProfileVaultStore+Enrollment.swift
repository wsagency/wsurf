// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension ProfileVaultStore {
    /// Every passkey enrolled in any listed vault, lowest-numbered vault first.
    public func enrolledPasskeys(of listing: [VaultListing]) async throws -> [(vault: VaultListing, unlock: VaultUnlock)] {
        var found: [(vault: VaultListing, unlock: VaultUnlock)] = []
        for vault in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            for unlock in try await discovery(vaultID: vault.vaultID).unlocks {
                found.append((vault, unlock))
            }
        }
        return found
    }
}
