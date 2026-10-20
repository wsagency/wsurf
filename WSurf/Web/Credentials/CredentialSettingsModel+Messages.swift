// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import Foundation

/// What the page says for an error, by cause: the vault and its passkeys, then the store, then the exchange. `nil` is a
/// user cancel, which says nothing.
extension CredentialSettingsModel {
    static func importMessage(
        for error: any Error, tokenSpent: Bool, origin: CredentialTransferMessage.Origin = .system
    ) -> String? {
        guard tokenSpent else { return message(for: error) }
        let reason: String
        switch error {
        case is CancellationError:
            reason = String(localized: "it was cancelled")
        case CredentialVaultError.staleRevision:
            reason = String(localized: "your credentials changed while it was open")
        case CredentialVaultError.unauthorized, CredentialVaultError.expired:
            reason = String(localized: "your credentials were locked")
        case let error as CredentialExchangeError:
            reason = String(localized: "the credentials couldn’t be read (\(error.description))")
        case CredentialExchangeCoordinatorError.systemRejected:
            reason = String(localized: "the system couldn’t deliver the credentials")
        case CredentialExchangeCoordinatorError.tokenMismatch, CredentialExchangeCoordinatorError.wrongTarget,
             CredentialExchangeCoordinatorError.noStagedImport:
            reason = String(localized: "it was no longer open")
        default:
            reason = String(localized: "something went wrong")
        }
        switch origin {
        case .system:
            return String(localized: "The import ended because \(reason), and nothing was saved. To import these credentials, send them again from the other app.")
        case .csvFile:
            return String(localized: "The import ended because \(reason), and nothing was saved. To import the file, choose it again.")
        case .legacyPasswords:
            return String(localized: "The import ended because \(reason), and nothing was saved. Your saved passwords are still in the old list. To import them, choose Review again.")
        }
    }

    static func message(for error: any Error) -> String? {
        switch error {
        case CredentialVaultError.staleRevision:
            return String(localized: "Your credentials changed elsewhere. Reload and try again.")
        case CredentialVaultError.unauthorized, CredentialVaultError.expired:
            return String(localized: "Credentials are locked.")
        case CredentialVaultError.missingVault:
            return String(localized: "No credential vault exists for this profile yet. Create one to continue.")
        case CredentialVaultError.alreadyExists:
            return String(localized: "A credential vault already exists for this profile. Unlock it instead.")
        case CredentialVaultError.noUnlocks:
            return String(localized: "The vault needs at least one unlock passkey.")
        case CredentialVaultError.invalidData:
            return String(localized: "Check the details and try again.")
        case CredentialVaultError.corruptVault:
            return String(localized: "The credential vault couldn’t be read. It may be damaged.")
        case CredentialVaultError.authenticationFailed, CredentialVaultError.wrongProfile:
            return String(localized: "That passkey can’t unlock this vault.")
        case CredentialManagerError.externalPasskeyRemains:
            return String(localized: "The passkey was created but setup didn’t finish. It still exists in your passkey provider; remove it there if you don’t want it.")
        case CredentialManagerError.registrationOutcomeUnknown:
            return String(localized: "Passkey registration was cancelled, but the provider may have created it. Check your passkey provider before trying again.")
        case PasskeyUnlockError.appCancelled:
            return nil
        case PasskeyUnlockError.failed(let domain, let code)
            where domain == ASAuthorizationError.errorDomain && code == ASAuthorizationError.Code.canceled.rawValue:
            return nil
        case PasskeyUnlockError.unsupportedPRF:
            return String(localized: "That passkey can’t protect the vault. Choose a passkey provider that supports the PRF extension.")
        case is CancellationError:
            return nil
        default:
            return storeMessage(for: error)
        }
    }

    private static func storeMessage(for error: any Error) -> String? {
        switch error {
        case CredentialStoreError.migrationNeedsConfirmation:
            return String(localized: "This vault was saved by an older version of WSurf. Unlocking it upgrades it to the new format. Confirm to continue.")
        case CredentialStoreError.tooManyVaults:
            return String(localized: "This profile already has the most vaults it can hold.")
        case CredentialStoreError.noAuthority:
            return String(localized: "Unlock one of your vaults first. A new vault is created with the approval of a vault that is already open.")
        case CredentialStoreError.invalidVaultName:
            return String(localized: "Use a name of 1 to \(StoreFormat.nameLimit) characters.")
        case CredentialStoreError.passkeyUnusable:
            return String(localized: "That passkey is no longer enrolled in that vault. Choose a passkey again.")
        case CredentialStoreError.stateChanged:
            return String(localized: "Your credential files changed while WSurf was reading them. Check again.")
        case CredentialStoreError.noSuchVault:
            return String(localized: "That vault is no longer listed. Check again.")
        case CredentialStoreError.lastVault:
            return String(localized: "A profile keeps at least one vault. Nothing was deleted.")
        case CredentialStoreError.vaultNotEmpty:
            return String(localized: "This vault isn’t empty. Nothing was deleted.")
        default:
            return exchangeMessage(for: error)
        }
    }

    private static func exchangeMessage(for error: any Error) -> String? {
        switch error {
        case let error as CredentialExchangeError:
            return String(localized: "The file couldn’t be imported (\(error.description)). Nothing was changed.")
        case CredentialExchangeCoordinatorError.tokenMismatch:
            return String(localized: "That import is no longer waiting. Start the transfer again from the other app.")
        case CredentialExchangeCoordinatorError.wrongTarget, CredentialExchangeCoordinatorError.noStagedImport:
            return String(localized: "The import is no longer open. To import these credentials, send them again from the other app.")
        case CredentialExchangeCoordinatorError.busy:
            return String(localized: "Another import is already in progress.")
        case CredentialExchangeCoordinatorError.unresolvedConflicts, CredentialExchangeCoordinatorError.unknownConflict:
            return String(localized: "Choose what to do with every conflict first.")
        case CredentialExchangeCoordinatorError.invalidChoice:
            return String(localized: "That choice isn’t available, or it doesn’t fit with the other choices. Change it, or skip the credential, and try again.")
        case CredentialExchangeCoordinatorError.replaceTaken:
            return String(localized: "Another row already replaces that saved login. Change that one first.")
        case CredentialExchangeCoordinatorError.emptySelection:
            return String(localized: "Select at least one credential to export.")
        case CredentialExchangeCoordinatorError.systemRejected:
            return String(localized: "The system couldn’t complete the transfer.")
        default:
            return String(localized: "Couldn’t access credentials.")
        }
    }
}
