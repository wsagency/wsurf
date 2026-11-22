// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension AutofillSaveSession {
    /// Retire the page's previous vault grants, queued submissions and native pickers together.
    func invalidateVaultContext(in page: BrowserPage) {
        page.invalidateCredentialContexts()
        clear()
        AutofillSuggestions.shared.dismiss(in: page)
        CredentialPickerSheet.dismiss(page: page)
    }
}

extension AutofillSaveCoordinator {
    func selectedVaultLocked(_ manager: CredentialManager) {
        for session in registeredSessions {
            guard let page = session.page, page.vaultScope.isRestricted, page.vaultScope.contains(manager) else { continue }
            session.invalidateVaultContext(in: page)
        }
    }

    /// Leaving the browsing profile can keep the selected vault's owner unlocked. The old page still loses its authority.
    func vaultAccessEnded(profileID: UUID) {
        AutofillSuggestions.shared.vaultAccessEnded(profileID: profileID)
        CredentialPicker.shared.vaultAccessEnded(profileID: profileID)
        CredentialPickerSheet.dismiss(profileID: profileID)
        for session in registeredSessions {
            guard let page = session.page, page.profileID == profileID || page.vaultScope.owner?.id == profileID else { continue }
            if page.vaultScope.isRestricted {
                session.invalidateVaultContext(in: page)
            } else {
                session.vaultAccessEnded()
            }
        }
    }
}
