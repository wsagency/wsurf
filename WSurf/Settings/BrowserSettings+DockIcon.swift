// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

extension BrowserSettings {
    /// The Dock icon while WSurf runs. It belongs to the app, not to a theme, so it does not change with the theme
    /// or travel with a saved one.
    var dockIcon: DockIconChoice {
        get { globalValue(\.dockIcon, storage: storedDockIcon) }
        set {
            setGlobal(\BrowserSettings.dockIcon, storage: \BrowserSettings.storedDockIcon, value: newValue,
                      key: Key.dockIcon, encode: { $0.rawValue }) { $0.applyDockIcon() }
        }
    }

    /// Shows the stored choice in the Dock; Default clears the override. Only the app-wide settings do this, once at
    /// launch and again whenever the choice changes.
    func applyDockIcon() {
        guard appliesAppearanceGlobally else { return }
        showsDockIcon(dockIcon.image)
    }
}
