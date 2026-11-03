// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// Opening a credential's website from the list or the editor.
extension CredentialSettingsModel {
    /// Opens `url` in a new tab after the one showing this page, in the same window, so in the same profile. Only an HTTPS address,
    /// and never from a private profile (which keeps no vault). Nothing is read from the vault: the address is one the page shows.
    /// Returns whether a tab was asked for.
    @discardableResult
    func openWebsite(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.host?.isEmpty == false, !profile.isPrivate, let websiteOpener else {
            return false
        }
        websiteOpener(url)
        return true
    }
}
