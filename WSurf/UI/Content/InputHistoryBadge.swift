// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Beside the key: opens Settings > Autofill > Input History. It appears only while Input History is on.
struct InputHistoryBadge: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    static let title: LocalizedStringResource = "Input History"
    /// The `SettingsIndex` entry of the Input History sub-page.
    static let anchor = "autofill.inputHistory"

    /// A private profile keeps no Input History and its Settings row is disabled, so it never offers the shortcut. The key hides on
    /// internal pages too.
    static func isShown(settings: BrowserSettings, isPrivate: Bool, isWebPage: Bool) -> Bool {
        settings.recordsInputHistory && !isPrivate && isWebPage
    }

    var body: some View {
        if let tab = browser.activeTab,
           Self.isShown(
               settings: coordinator.context.settings,
               isPrivate: coordinator.context.profile.isPrivate,
               isWebPage: tab.internalPage == nil
           ) {
            ChromeIcon(symbol: "list.clipboard", weight: .semibold, help: String(localized: Self.title)) {
                coordinator.openSettings(revealing: Self.anchor)
            }
            .accessibilityLabel(Text(Self.title))
        }
    }
}
