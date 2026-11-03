// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import SwiftUI

struct InternalPageSurface: View {
    let page: BrowserTab.InternalPage
    let browser: BrowserModel
    let coordinator: AppCoordinator
    let settingsWorkspace: SettingsWorkspace

    var body: some View {
        switch page {
        case .settings:
            SettingsView(coordinator: coordinator, workspace: settingsWorkspace)
        case .history:
            HistoryView(browser: browser, coordinator: coordinator)
        case .downloads:
            DownloadsView(browser: browser)
        case .releaseNotes:
            ReleaseNotesView(browser: browser, notes: coordinator.releaseNotes)
        }
    }
}
