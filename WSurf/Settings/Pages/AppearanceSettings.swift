// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct AppearanceSettings: View {
    let coordinator: AppCoordinator
    @Bindable var settings: BrowserSettings
    @Environment(\.colorScheme) private var windowColorScheme

    private var shownScheme: ColorScheme {
        if coordinator.profiles.isPrivate {
            return .dark
        }
        switch settings.colorMode {
        case .system:
            return windowColorScheme
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    var body: some View {
        SettingsPageHeader(title: "Appearance")
        AppearanceThemeSection(settings: settings, scheme: shownScheme)
        AppearanceColorsSection(settings: settings, scheme: shownScheme)
        AppearanceDockIconSection(settings: settings)
        AppearanceSidebarSection(settings: settings, sidebar: coordinator.sidebar)
        AppearanceZoomSection(settings: settings)
    }
}

private struct AppearanceSidebarSection: View {
    @Bindable var settings: BrowserSettings
    let sidebar: SidebarLayout

    private static let fontOptions: [SettingsMenu<String>.Option] = {
        [.init(value: "", label: String(localized: "System Default"))]
            + NSFontManager.shared.availableFontFamilies.sorted().map { .init(value: $0, label: $0) }
    }()

    var body: some View {
        SettingsSection(title: "Sidebar", symbol: "sidebar.left") {
            DetailRow(title: "Show sidebar") {
                SettingsToggle(Binding(get: { sidebar.isVisible }, set: { sidebar.setVisible($0) }))
            }
            .settingsAnchor("appearance.sidebar")

            RowSeparator()
            DetailRow(title: "Icons only") {
                SettingsToggle(Binding(
                    get: { sidebar.style == .icons }, set: { sidebar.setStyle($0 ? .icons : .full) }
                ))
            }
            .settingsAnchor("appearance.sidebarStyle")

            RowSeparator()
            DetailRow(title: "Sidebar font", caption: "Choose an installed font family for tab and folder names.") {
                SettingsMenu(options: Self.fontOptions, selection: $settings.sidebarFontFamily, placeholder: "System Default")
            }
            .settingsAnchor("appearance.sidebarFont")

            RowSeparator()
            DetailRow(title: "Font weight") {
                SettingsMenu(
                    options: SidebarFontWeight.allCases.map { .init(value: $0, label: $0.label) },
                    selection: $settings.sidebarFontWeight
                )
            }
            .settingsAnchor("appearance.sidebarFontWeight")

            RowSeparator()
            DetailRow(title: "Font size", caption: "Adjust the text size without reducing the row’s usable target.") {
                HStack(spacing: 8) {
                    Slider(value: $settings.sidebarFontSize, in: 10...20, step: 0.5)
                        .frame(width: 140)
                        .accessibilityLabel("Sidebar font size")
                    Text(settings.sidebarFontSize, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .settingsAnchor("appearance.sidebarFontSize")

            RowSeparator()
            DetailRow(title: "Row spacing", caption: "Add vertical breathing room between sidebar rows.") {
                HStack(spacing: 8) {
                    Slider(value: $settings.sidebarRowSpacing, in: 0...8, step: 0.5)
                        .frame(width: 140)
                        .accessibilityLabel("Sidebar row spacing")
                    Text(settings.sidebarRowSpacing, format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .settingsAnchor("appearance.sidebarRowSpacing")

            RowSeparator()
            DetailRow(title: "Folder tint", caption: "Set the background tint for expanded folders, including none.") {
                HStack(spacing: 8) {
                    Slider(value: $settings.sidebarFolderTint, in: 0...1, step: 0.05)
                        .frame(width: 140)
                        .accessibilityLabel("Folder tint")
                    Text(settings.sidebarFolderTint == 0
                        ? "None" : settings.sidebarFolderTint.formatted(.percent.precision(.fractionLength(0))))
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .settingsAnchor("appearance.sidebarFolderTint")
        }
    }
}

private struct AppearanceZoomSection: View {
    @Bindable var settings: BrowserSettings
    private static let sizes: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2]

    var body: some View {
        SettingsCard {
            DetailRow(title: "Page zoom", caption: "Set the default zoom for websites. You can also zoom individual tabs.") {
                SettingsMenu(options: Self.sizes.map {
                    .init(value: $0, label: $0.formatted(.percent.precision(.fractionLength(0))))
                }, selection: $settings.pageZoom)
            }
            .settingsAnchor("appearance.zoom")
        }
    }
}
