// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

extension BrowserTab {
    /// Whether nothing about the tab needs its page shown while another tab is in front: the page is then hidden on the shelf,
    /// as a background tab is in any browser. The tab is left shown for every reason it is not unloaded, bar a download, which
    /// goes on whatever the page shows: it plays or is the media dock's, has its video in a picture, uses the camera or
    /// microphone, shares the screen, holds an edited form, is driven by the assistant or a connected app, is private, or is
    /// on a site kept active.
    var hidesInBackground: Bool {
        intrinsicProtectionReason == nil && !isPictureOut && !keepsSiteActive
    }

    private var keepsSiteActive: Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return sitePermissions.keepsActive(SitePermissions.origin(for: url))
    }

    /// Keeps `view.hidesWhileParked` in step with `hidesInBackground` for as long as `view` is the tab's page, so a page that
    /// starts to play or is taken over while it waits on the shelf is shown at once, and hidden again when that ends.
    func followBackgroundHiding(of view: BrowserPage) {
        view.hidesWhileParked = hidesInBackground
        withObservationTracking {
            _ = hidesInBackground
        } onChange: { [weak self, weak view] in
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, !isClosed, liveView === view else { return }
                followBackgroundHiding(of: view)
            }
        }
    }
}
