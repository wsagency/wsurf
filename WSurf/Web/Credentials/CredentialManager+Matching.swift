// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// The reads that answer a question about every credential of the vault without a secret leaving it: which passkeys it holds, for
/// routing, and which credentials hold a password, for saving one. Each is read like `snapshot`: under the current lease, and
/// discarded if a lock lands while it is in flight.
extension CredentialManager {
    /// Each passkey's relying party, algorithm and credential ID, never its key (`ProfileVaultStore.passkeyRoutes`): what the passkey
    /// route asks of every unlocked vault (`CredentialRouting.route(profile:origin:passkeyRPID:allowed:)`).
    func passkeyRoutes() async throws -> PasskeyRoutes {
        try await reading { access in
            Self.noteRead(.passkeys, profile: profileID)
            return try await store.passkeyRoutes(vaultID: vaultID, using: access)
        }
    }

    /// The candidates and the ids of `login`'s username's credentials that hold its password (`ProfileVaultStore.passwordMatches`),
    /// never a stored password. It tells whether a login is saved, so only the save offer (`AutofillSaveCoordinator`:
    /// `siblingAccount`, `managedPlan`) and the Input History save (`InputHistoryCredentialSave`) may call it, with the login a person
    /// just submitted or typed. `AutofillListingTests` counts every reference to it and fails on any other.
    func passwordMatches(_ login: SavedPassword) async throws -> AutofillPasswordMatches {
        try await reading { access in
            Self.noteRead(.passwordMatches, profile: profileID)
            return try await store.passwordMatches(vaultID: vaultID, username: login.username, password: login.password, using: access)
        }
    }
}
