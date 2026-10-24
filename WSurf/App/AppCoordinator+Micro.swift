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

    /// Float on Top, set from the bar and the Window menu. Off is a normal window that can zoom but never enter full screen.
    func applyFloatOnTop() {
        guard isMicro, let window = nativeWindow else { return }
        window.level = floatsOnTop ? .floating : .normal
        window.collectionBehavior = MicroWindowMetrics.collectionBehavior(floating: floatsOnTop)
    }

    /// The window the commands that open app pages (a new tab, the palette, Settings, History, Downloads, release notes) act
    /// in. A micro window holds one page, so those go to the regular window of its profile used last, or to a new one.
    func mainWindowForCommands() -> AppCoordinator {
        guard isMicro, !isClosed else { return self }
        let app = application ?? BrowserApplication.shared
        return app.browsingWindow(for: self)
            ?? app.newWindow(profile: profiles.isPrivate ? profiles.profileToReturnTo : profiles.current)
    }
}
