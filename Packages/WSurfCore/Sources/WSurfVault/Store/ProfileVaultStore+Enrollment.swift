// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension ProfileVaultStore {
    /// Every passkey enrolled in any listed vault, lowest-numbered vault first.
    func enrolledPasskeys(of listing: [VaultListing]) async throws -> [(vault: VaultListing, unlock: VaultUnlock)] {
        var found: [(vault: VaultListing, unlock: VaultUnlock)] = []
        for vault in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            for unlock in try await discovery(vaultID: vault.vaultID).unlocks {
                found.append((vault, unlock))
            }
        }
        return found
    }

    /// What creating a vault may do with the user's `choice`, read from the store as it is now. The first vault is created
    /// only from a confirmed first run; a further one is authorized by `authorizer` (an unlocked vault) or by an enrolled
    /// passkey of a listed vault. An existing passkey that is no longer enrolled is refused, never swapped for another.
    func creationChoice(
        for choice: NewVaultChoice,
        authorizer: @MainActor ([VaultListing]) -> CredentialManager?
    ) async throws -> NewVaultChoice {
        switch openState() {
        case .firstRun:
            guard case .newPasskey = choice else { throw CredentialStoreError.noAuthority }
            return .newPasskey(authorizedBy: nil)
        case .provisional:
            let vaults = try await listing()
            guard vaults.count < StoreFormat.activeVaultLimit else { throw CredentialStoreError.tooManyVaults }
            switch choice {
            case .newPasskey:
                guard let source = await authorizer(vaults) else { throw CredentialStoreError.noAuthority }
                return .newPasskey(authorizedBy: source)
            case .existing(let sourceVaultID, let credentialID, let prfInput):
                guard vaults.contains(where: { $0.vaultID == sourceVaultID }),
                    try await discovery(vaultID: sourceVaultID).unlocks.contains(where: {
                        $0.credentialID == credentialID && $0.prfInput == prfInput
                    })
                else { throw CredentialStoreError.passkeyUnusable }
                return choice
            }
        case .legacy, .resumeMigration:
            throw CredentialStoreError.noAuthority
        case .failClosed(let closed):
            throw CredentialStoreError.failClosed(closed)
        }
    }
}
