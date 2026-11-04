// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class TabPopupPolicy {
    private let store: SitePermissions
    private let settings: BrowserSettings

    init(store: SitePermissions, settings: BrowserSettings) {
        self.store = store
        self.settings = settings
    }

    private(set) var origin = ""

    private(set) var blocked: URL?

    var effective: PopupPolicy {
        Self.policy(for: origin, store: store, settings: settings)
    }

    /// The pop-up answer for pages of `origin`: the website's own, or the setting every other website is under.
    static func policy(for origin: String, store: SitePermissions, settings: BrowserSettings) -> PopupPolicy {
        if !origin.isEmpty, let recorded = store.popups(for: origin) {
            return recorded
        }
        return settings.blocksPopups ? .blockAndNotify : .allow
    }

    @discardableResult
    func pageChanged(url: URL?) -> Bool {
        let next = SystemPages.isSystem(url) ? "" : SitePermissions.origin(for: url)
        guard next != origin else { return false }
        origin = next
        blocked = nil
        return true
    }

    func note(_ url: URL?) {
        guard effective == .blockAndNotify else { return }
        blocked = url
    }

    func clear() {
        blocked = nil
    }
}

extension BrowserTab {
    func applySitePopups() {
        popups.pageChanged(url: page.url)
    }
}
