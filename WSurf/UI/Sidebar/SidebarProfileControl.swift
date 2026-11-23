// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import SwiftUI

struct SidebarProfileControl: View {
    let coordinator: AppCoordinator

    private var profiles: ProfileStore {
        coordinator.profiles
    }

    private var profile: Profile {
        profiles.current
    }

    private var isPlain: Bool {
        !profiles.isPrivate && profile.id == profiles.profiles.first?.id
    }

    private var tint: Color? {
        isPlain ? nil : profile.color.tint
    }

    private var name: String {
        profiles.isPrivate ? profiles.privateBrowsing.name : ProfileSummary.displayName(for: profile)
    }

    private var isShared: Bool {
        !profiles.isPrivate && ProfileSummary.isShared(profile)
    }

    var body: some View {
        QuietIconButton(
            symbol: profiles.isPrivate ? profiles.privateBrowsing.symbol : profile.symbol,
            isOn: coordinator.isProfileSwitcherOpen,
            tint: tint,
            badge: isShared ? "icloud.fill" : nil,
            help: isShared ? String(localized: "Shared profile — \(name)") : String(localized: "Profile — \(name)")
        ) {
            coordinator.isProfileSwitcherOpen.toggle()
        }
        .accessibilityLabel(isShared ? Text("Shared profile — \(name)") : Text("Profile — \(name)"))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
            coordinator.profileButtonFrame = $0
        }
    }
}
