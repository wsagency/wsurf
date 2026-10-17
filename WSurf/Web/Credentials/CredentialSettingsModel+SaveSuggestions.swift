// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The websites the user excluded from save suggestions ("Never for This Site") belong to the vault that was asked: each vault
/// keeps its own list, and so this page resets the selected vault's list and no other.
extension CredentialSettingsModel {
    /// How many sites the selected vault excludes; zero while it is locked.
    var blockedSiteCount: Int {
        live?.blockedSiteCount ?? 0
    }

    /// Empties the selected vault's list of excluded sites, so pages offer to save passwords there again, and forgets the "Not
    /// Now" answers pages of this profile were holding. The write is bound to the revision and unlock the page is looking at: a
    /// vault that changed or locked meanwhile is left as it is.
    func resetSaveSuggestions() async {
        guard let epoch = authorizationEpoch else { return }
        let profileID = profile.id
        let reset = await perform(epoch: epoch) { manager in
            let snapshot = try await manager.snapshot()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            _ = try await manager.updatePasswordSavePolicy([], expectedRevision: snapshot.revision, authorizedEpoch: epoch)
        }
        guard reset else { return }
        AutofillSaveCoordinator.shared.resetDismissals(kind: .password, profileID: profileID)
        await load()
    }
}
