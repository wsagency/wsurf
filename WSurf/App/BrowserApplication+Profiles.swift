// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserApplication {
    /// Release every window before removing a profile's website and disk data.
    func prepareToRemove(profile: Profile) async {
        guard !profile.isOriginal else { return }
        let affected = windows.filter { $0.profiles.current.id == profile.id }
        for coordinator in affected {
            coordinator.closeWindow()
            if windows.contains(where: { $0 === coordinator }) {
                coordinator.windowDidClose()
            }
        }
        forgetProfile(profile.id)
    }

    /// A watch notification opens its page in a new tab of a regular window of the watch's profile, never a private window.
    func openWatchedPage(_ url: URL, profileID: UUID) {
        guard let profile = ProfileStore.shared.profiles.first(where: { $0.id == profileID }) else { return }
        let window = windows.last {
            !$0.isClosed && !$0.profiles.isPrivate && !$0.isSwitchingProfile && $0.context.profile.id == profileID
        } ?? newWindow(profile: profile)
        window.openNewTab(url: url)
        window.showBrowser()
    }
}
