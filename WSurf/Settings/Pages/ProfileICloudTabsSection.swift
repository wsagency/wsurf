// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfCore

/// The switch that shares a profile's open tabs through iCloud. There is no section unless sync exists: with the hidden flag off,
/// or in a build without the iCloud entitlements, `CloudTabs.shared` is nil.
struct ProfileICloudTabsSection: View {
    let profile: Profile

    var body: some View {
        if let cloudTabs = CloudTabs.shared, CloudTabs.canShare(profile) {
            SettingsSection(title: "iCloud", symbol: "icloud", footnote: footnote(cloudTabs)) {
                DetailRow(
                    title: "Share tabs through iCloud",
                    caption: "Tabs open in this profile appear on your other devices, and theirs appear in the sidebar here. Private windows are never shared."
                ) {
                    SettingsToggle(Binding(
                        get: { cloudTabs.isOptedIn(profile.id) },
                        set: { cloudTabs.setOptIn($0, for: profile) }
                    ))
                }
            }
        }
    }

    private func footnote(_ cloudTabs: CloudTabs) -> LocalizedStringResource? {
        guard cloudTabs.sync.accountAvailable == false else { return nil }
        return "Sign in with your Apple Account in System Settings to share tabs."
    }
}
