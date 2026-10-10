// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .system:
            "Auto"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}

enum LoomStyle: String, CaseIterable, Identifiable {
    case standard
    case transparent

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .standard:
            "Standard"
        case .transparent:
            "Transparent"
        }
    }
}

enum SidebarFontWeight: String, CaseIterable, Identifiable {
    case regular
    case medium
    case semibold
    case bold

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .regular:
            String(localized: "Regular")
        case .medium:
            String(localized: "Medium")
        case .semibold:
            String(localized: "Semibold")
        case .bold:
            String(localized: "Bold")
        }
    }

    var nativeWeight: NSFont.Weight {
        switch self {
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        }
    }

    var appKitWeight: Int {
        switch self {
        case .regular:
            5
        case .medium:
            6
        case .semibold:
            8
        case .bold:
            9
        }
    }
}
