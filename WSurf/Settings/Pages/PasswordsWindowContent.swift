// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

/// What the Passwords window shows: the credentials page of Settings › Autofill without its header, in a scroll view of its own.
struct PasswordsWindowContent: View {
    let profile: Profile
    private let context: BrowserProfileContext

    init(profile: Profile) {
        self.profile = profile
        context = BrowserProfileContext.shared(for: profile)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    CredentialSettings(context: context, highlight: nil, showsHeader: false) { url in
                        openInBrowser { $0.browser.newTab(url: url, activate: true, after: $0.browser.activeTab) }
                    }
                }
                .frame(maxWidth: SettingsMetrics.detailWidth, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.compactPageInset)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .environment(\.settingsScrollProxy, proxy)
            .environment(\.settingsIsCompact, true)
            .environment(\.settingsDescriptionLineLimit, 1)
            .environment(\.profileFavicons, context.favicons)
            // A link to a setting that lives on a Settings page (the autofill switches, Input History) opens Settings.
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == SettingsIndex.linkScheme, let anchor = url.host() else { return .systemAction }
                openInBrowser { $0.openSettings(revealing: anchor) }
                return .handled
            })
        }
        .id(context.contextID)
    }

    /// Runs `action` in the window external links go to, or a new one: never a private window, which keeps no vault, and the
    /// profile of this window, not the current one.
    private func openInBrowser(_ action: (AppCoordinator) -> Void) {
        let app = BrowserApplication.shared
        let target = app.externalLinkTarget ?? app.newWindow(profile: profile)
        action(target)
        target.showBrowser()
    }
}
