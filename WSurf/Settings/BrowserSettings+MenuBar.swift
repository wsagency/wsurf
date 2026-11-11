// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension BrowserSettings {
    // MARK: - Menu bar

    /// Whether WSurf shows its Passwords item in the macOS menu bar. One choice for the whole app, on by default.
    /// `onPasswordsMenuBarChanged` is where the item is shown or hidden: `PasswordsStatusItem.install` sets it.
    var showsPasswordsInMenuBar: Bool {
        get { globalValue(\.showsPasswordsInMenuBar, storage: storedShowsPasswordsInMenuBar) }
        set {
            setGlobal(\BrowserSettings.showsPasswordsInMenuBar, storage: \BrowserSettings.storedShowsPasswordsInMenuBar,
                      value: newValue, key: Key.passwordsMenuBar, didChange: { $0.onPasswordsMenuBarChanged?(newValue) })
        }
    }
}
