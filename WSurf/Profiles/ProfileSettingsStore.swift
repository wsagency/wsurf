// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

enum ProfileSettingsStore {
    static func suiteName(for id: UUID) -> String {
        "io.wsagency.wsurf.profile.\(id.uuidString)"
    }

    @MainActor
    static func defaults(for profile: Profile) -> UserDefaults {
        #if DEBUG
        if StageMode.isActive {
            return StageMode.defaults
        }
        #endif
        guard !profile.isOriginal else { return .standard }
        return UserDefaults(suiteName: suiteName(for: profile.id)) ?? .standard
    }

    static func forget(_ id: UUID) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName(for: id))
    }
}
