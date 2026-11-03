// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Observation

nonisolated enum TabFolderColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case gray
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal

    var id: Self {
        self
    }
}

/// How large a folder's own row is drawn: its name, icon and disclosure arrow scale together. Rows inside it are
/// not affected. The raw value is the factor, and it is what is stored.
nonisolated enum TabFolderSize: Double, CaseIterable, Sendable {
    case normal = 1
    case large = 1.5
    case larger = 2
    case largest = 2.5

    var factor: CGFloat {
        CGFloat(rawValue)
    }

    /// Normal, or the factor in the reader's number format: 1.5×, 2×, 2.5×.
    var menuTitle: String {
        self == .normal ? String(localized: "Normal") : rawValue.formatted(.number) + "×"
    }

    /// A stored factor that is missing, or that no size has, reads as normal.
    static func stored(_ factor: Double?) -> Self {
        factor.flatMap(Self.init(rawValue:)) ?? .normal
    }

    /// What a row of the stored form holds: nil for normal, so rows saved before sizes existed read the same.
    var storedFactor: Double? {
        self == .normal ? nil : rawValue
    }
}

@MainActor
@Observable
final class TabFolder: Identifiable {
    let id: UUID
    var name: String
    var nameRevision = 0
    var color = TabFolderColor.gray
    var isExpanded = true
    var isPinned = false
    var size = TabFolderSize.normal
    /// Draws the icons of the tabs inside the folder in the folder's color, and those of the folders inside it that
    /// do not tint on their own. Off by default.
    var tintsIcons = false
    /// A color a person chose with the color panel. It takes the place of `color` while it is set; nil is the preset.
    var customColor: CustomFolderColor?
    /// The SF Symbol a person chose to stand for the folder; nil is the plain folder icon, which opens and shuts.
    var symbol: String?
    /// The space the folder and everything in it belong to; nil while the folder is pinned or inside a pinned folder.
    var spaceID: UUID?

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

extension TabFolder: Equatable {
    nonisolated static func == (lhs: TabFolder, rhs: TabFolder) -> Bool {
        lhs === rhs
    }
}

nonisolated enum SidebarItem: Hashable, Identifiable, Sendable {
    case folder(UUID)
    case tab(UUID)

    var id: Self {
        self
    }
}
