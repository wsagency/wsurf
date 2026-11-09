// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Showing a credential's cards, addresses and other items. Like every Show, it reads the vault under the current unlock. A card or an
/// identity document also needs a fresh device-owner authentication each time, before anything is read into the page.
extension CredentialSettingsModel {
    var revealedItems: (accountID: UUID, items: [SecureItem])? {
        live?.revealedItems
    }

    /// Show Details on a row. A card or an identity document asks first, as the list's summary says, and the vault is read only after
    /// the answer, so a refusal reads nothing. One that arrived since the list was read is not shown unasked: the list catches up
    /// and nothing shows, so the next Show Details asks.
    func revealSecureItems(accountID: UUID) async throws {
        guard let live else { throw CredentialVaultError.unauthorized }
        guard let summary = live.summaries.first(where: { $0.id == accountID }) else { throw CredentialVaultError.invalidData }
        let asks = summary.hasSensitiveItems
        if asks {
            guard try await verifyOwner(String(localized: "show saved cards, documents and hidden fields")) == live.epoch else {
                throw CredentialVaultError.unauthorized
            }
        }
        let (epoch, snapshot) = try await authorizedSnapshot(epoch: live.epoch)
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }), let items = account.secureItems else {
            throw CredentialVaultError.invalidData
        }
        if !asks, items.contains(where: \.isSensitive) {
            try update(epoch) { $0.refresh(snapshot) }
            throw CredentialPromptError.listChanged
        }
        try update(epoch) { $0.revealedItems = (accountID, items) }
    }

    /// Asks for Touch ID or the Mac password when `account` holds a sensitive item (`SecureItem.isSensitive`); returns at once otherwise. Throws
    /// when the person cancels or fails, and nothing is then shown, copied or opened. Returns whether it asked. `reason` replaces the
    /// prompt's usual words where the answer covers more than the items.
    @discardableResult
    func verifySensitiveItems(of account: CredentialAccount, reason: String? = nil) async throws -> Bool {
        guard account.secureItems?.contains(where: \.isSensitive) == true else { return false }
        try await verifyUser(reason ?? String(localized: "show saved cards, documents and hidden fields"))
        try Task.checkCancellation()
        return true
    }
}
