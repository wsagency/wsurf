// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfCore

/// The same choice is available from Sync and from the Personal profile settings.
struct ProfileICloudTabsSection: View {
    let profile: Profile
    @State private var keychainUnavailable = false

    var body: some View {
        if let cloud = CloudSync.shared, cloud.settingsSync != nil || cloud.tabs != nil, CloudTabs.canShare(profile) {
            SettingsSection(title: "Tabs on other devices", symbol: "macbook", footnote: footnote(cloud.tabs)) {
                DetailRow(
                    title: "Share tabs through iCloud",
                    caption: "See tabs from your other devices in the sidebar and open independent copies. To keep the same tabs in sync, join a Shared Space."
                ) {
                    SettingsToggle(Binding(
                        get: { cloud.tabs?.isOptedIn(profile.id) == true },
                        set: { keychainUnavailable = !cloud.setOtherDeviceSharing($0, for: profile) }
                    ))
                }
            }
        }
    }

    private func footnote(_ tabs: CloudTabs?) -> LocalizedStringResource? {
        if keychainUnavailable {
            return "Couldn’t read this Mac’s device identifier from Keychain. Try again."
        }
        guard tabs?.sync.accountAvailable == false else { return nil }
        return "Sign in with your Apple Account in System Settings to share tabs."
    }
}
