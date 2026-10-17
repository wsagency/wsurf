// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension AppCoordinator {
    /// Unloads every background tab in every window and says how many went. Without an application, only this window.
    func freeMemory() {
        let count = application?.freeMemory() ?? browser.freeMemory()
        let message: String
        switch count {
        case 0:
            message = String(localized: "No background tabs to unload.")
        case 1:
            message = String(localized: "Unloaded 1 tab.")
        default:
            message = String(localized: "Unloaded \(count) tabs.")
        }
        show(notice: message)
    }
}
