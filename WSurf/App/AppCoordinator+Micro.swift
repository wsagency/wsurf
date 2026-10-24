// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// The micro window: one page, no chrome until the pointer reaches the top. It is an ordinary window (coordinator, model
/// and host) with `WindowKind.micro`, so everything that owns a page (permissions, dialogs, downloads, media, extensions)
/// still has its owner.
extension AppCoordinator {
    var isMicro: Bool {
        browser.windowKind == .micro
    }

    /// Opens an empty micro window with the address focused. From a private window it opens a regular one, as New Window does.
    @discardableResult
    func requestNewMicroWindow(show: Bool = true) -> AppCoordinator? {
        guard !isClosed else { return nil }
        let app = application ?? BrowserApplication.shared
        let owner = profiles.isPrivate ? profiles.profileToReturnTo : profiles.current
        let micro = app.newWindow(profile: owner, settingsOwner: owner, show: show, kind: .micro)
        micro.focusAddressBar()
        return micro
    }
}
