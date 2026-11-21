// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

extension BrowserApplication {
    /// Regular windows keep their place and adopt the first surviving profile. A micro window belongs to the page it is showing.
    func prepareToRemove(profile: Profile) async {
        guard !profile.isOriginal, !profile.isPrivate else { return }
        for coordinator in windows where !coordinator.isClosed && coordinator.context.profile.id == profile.id {
            if !coordinator.isMicro {
                await coordinator.leaveErasedProfile(profile)
                continue
            }
            let tabs = coordinator.browser.tabs
            coordinator.closeWindow()
            if !coordinator.isClosed {
                coordinator.windowDidClose()
            }
            for tab in tabs {
                await tab.waitForRetirement()
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
