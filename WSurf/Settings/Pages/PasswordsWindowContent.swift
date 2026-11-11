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

    /// The browser window a link of this window opens in: one that shows this window's profile (the external-link window if it
    /// does, else the last regular one), otherwise a new window of that profile. Never a private window, which keeps no vault,
    /// and never another profile's window, whose cookies and history are not this vault's profile.
    static func linkTarget(in app: BrowserApplication, for profile: Profile) -> AppCoordinator {
        app.externalLinkTarget(for: profile) ?? app.newWindow(profile: profile)
    }

    private func openInBrowser(_ action: (AppCoordinator) -> Void) {
        let target = Self.linkTarget(in: BrowserApplication.shared, for: profile)
        action(target)
        target.showBrowser()
    }
}
