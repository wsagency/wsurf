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

    func revealSecureItems(accountID: UUID) async throws {
        let (epoch, snapshot) = try await authorizedSnapshot()
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }), let items = account.secureItems else {
            throw CredentialVaultError.invalidData
        }
        try await verifySensitiveItems(of: account)
        try update(epoch) { $0.revealedItems = (accountID, items) }
    }

    /// Asks for Touch ID or the Mac password when `account` holds a sensitive item (`SecureItem.isSensitive`); returns at once otherwise. Throws
    /// when the person cancels or fails, and nothing is then shown, copied or opened.
    func verifySensitiveItems(of account: CredentialAccount) async throws {
        guard account.secureItems?.contains(where: \.isSensitive) == true else { return }
        try await verifyUser(String(localized: "show saved cards, documents and hidden fields"))
        try Task.checkCancellation()
    }
}
