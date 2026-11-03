// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation

extension BrowserTab {
    /// Whether nothing about the tab needs its page shown while another tab is in front: the page is then hidden, as a background
    /// tab is in any browser. The tab is left shown for every reason it is not unloaded, bar a download, which goes on whatever
    /// the page shows: it plays or is the media dock's, has its video in a picture, uses the camera or microphone, shares the
    /// screen, holds an edited form, is driven by the assistant or a connected app, is private, or is on a site kept active.
    var hidesInBackground: Bool {
        intrinsicProtectionReason == nil && !isPictureOut && !keepsSiteActive
    }

    private var keepsSiteActive: Bool {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        return sitePermissions.keepsActive(SitePermissions.origin(for: url))
    }

    /// Hides the page of a tab in the background once `backgroundHidingGrace` has passed since the tab left the front, and shows
    /// it the moment the tab is in front again or something needs it. Until then the page stays as it was, so switching straight
    /// back is as quick as it always was: a page that has been hidden takes a few frames to draw again. A tab that was never in
    /// front (a favorite loading at launch) has no one to switch back to it and hides at once.
    func reconsiderBackgroundHiding() {
        guard liveView != nil else { return }
        guard !isInFront, hidesInBackground else {
            backgroundHidingTask?.cancel()
            backgroundHidingTask = nil
            setHidesPageInBackground(false)
            return
        }
        guard !hidesPageInBackground, backgroundHidingTask == nil else { return }
        if hasBeenInFront, backgroundHidingGrace > .zero {
            backgroundHidingTask = Task { [weak self, backgroundClock, backgroundHidingGrace] in
                try? await backgroundClock.sleep(for: backgroundHidingGrace)
                guard !Task.isCancelled, let self else { return }
                backgroundHidingTask = nil
                if !isInFront, hidesInBackground {
                    setHidesPageInBackground(true)
                }
            }
        } else {
            setHidesPageInBackground(true)
        }
    }

    private func setHidesPageInBackground(_ hides: Bool) {
        if hidesPageInBackground != hides {
            hidesPageInBackground = hides
        }
        liveView?.hidesWhileParked = hides
    }

    /// Keeps the page's hiding in step with the tab for as long as `view` is its page: the wait starts and ends with the tab's
    /// place (`isInFront`), and a page that starts to play or is taken over while it waits is shown at once, and waits again
    /// when that ends.
    func followBackgroundHiding(of view: BrowserPage) {
        view.hidesWhileParked = hidesPageInBackground
        reconsiderBackgroundHiding()
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
