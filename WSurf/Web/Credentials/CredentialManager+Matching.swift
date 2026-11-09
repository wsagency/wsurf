// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// The reads that answer a question about every credential of the vault without a secret leaving it: which passkeys it holds, for
/// routing. Each is read like `snapshot`: under the current lease, and discarded if a lock lands while it is in flight.
extension CredentialManager {
    /// Each passkey's relying party, algorithm and credential ID, never its key (`ProfileVaultStore.passkeyRoutes`): what the passkey
    /// route asks of every unlocked vault (`CredentialRouting.route(profile:origin:passkeyRPID:allowed:)`).
    func passkeyRoutes() async throws -> PasskeyRoutes {
        try await reading { access in
            Self.noteRead(.passkeys, profile: profileID)
            return try await store.passkeyRoutes(vaultID: vaultID, using: access)
        }
    }
}
