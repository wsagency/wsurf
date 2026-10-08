// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

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
        if !origin.isEmpty, let recorded = store.popups(for: origin) {
            return recorded
        }
        return settings.blocksPopups ? .blockAndNotify : .allow
    }

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
        guard popups.pageChanged(url: page.url) else { return }
        refreshPopupPolicy()
    }

    func refreshPopupPolicy() {
        guard isMaterialised else { return }
        page.webKit?.configuration.preferences.javaScriptCanOpenWindowsAutomatically = !popups.effective.blocks
    }
}
