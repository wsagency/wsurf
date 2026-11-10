// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Password health: which saved passwords are weak or reused, as flags (`PasswordHealthReport`). Like the autofill projections, it runs
/// the verified read (`snapshot(vaultID:using:)`) on this actor, compares the passwords here, and checks once more, right before it
/// returns, that `access` still holds its grant: a lock whose revocation lands during the read or the comparison returns nothing. No
/// password, digest or length leaves the actor, and nothing is written.
extension ProfileVaultStore {
    /// `expectedRevision` is the revision the caller asks about, such as the one its page shows. A vault at any other revision is
    /// `staleRevision`, refused right after the read and before any password is compared: a report the caller did not ask for, such
    /// as one of a write that landed while it waited, never leaves the actor.
    public func passwordHealth(vaultID: UUID, expectedRevision: UInt64, using access: VaultAccess) async throws -> PasswordHealthReport {
        let snapshot = try await snapshot(vaultID: vaultID, using: access)
        guard snapshot.revision == expectedRevision else { throw CredentialVaultError.staleRevision }
        let report = PasswordHealth.report(vaultID: vaultID, revision: snapshot.revision, accounts: snapshot.accounts)
        _ = try authorizedGrant(vaultID, access)
        return report
    }
}
