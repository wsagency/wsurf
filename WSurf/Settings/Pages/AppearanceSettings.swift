// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct AppearanceSettings: View {
    let coordinator: AppCoordinator

    @Bindable var settings: BrowserSettings

    private var sidebar: SidebarLayout {
        coordinator.sidebar
    }

    private static let sizes: [Double] = [0.5, 0.75, 0.85, 1, 1.15, 1.25, 1.5, 1.75, 2]

    private static let sidebarFontOptions: [SettingsMenu<String>.Option] = {
        [
            .init(value: "", label: String(localized: "System Default")),
        ] + NSFontManager.shared.availableFontFamilies
            .sorted()
            .map { .init(value: $0, label: $0) }
    }()

    var body: some View {
        SettingsPageHeader(title: "Appearance")

        SettingsCard {
            DetailRow(title: "Theme", layout: .stacked) {
                ThemePicker(selection: settings.appearance) { settings.appearance = $0 }
            }
            .settingsAnchor("appearance.theme")

            RowSeparator()

            DetailRow(
                title: "Page zoom",
                caption: "Set the default zoom for websites. You can also zoom individual tabs."
            ) {
                SettingsMenu(
                    options: Self.sizes.map {
                        .init(
                            value: $0,
                            label: $0.formatted(
                                .percent.precision(.fractionLength(0))
                            )
                        )
                    },
                    selection: $settings.pageZoom
                )
            }
            .settingsAnchor("appearance.zoom")
        }

        WindowStyleSettingsSection(settings: settings)

        SettingsSection(title: "Sidebar", symbol: "sidebar.left") {
            DetailRow(title: "Show sidebar") {
                SettingsToggle(Binding(
                    get: { sidebar.isVisible },
                    set: { sidebar.setVisible($0) }
                ))
            }
            .settingsAnchor("appearance.sidebar")

            RowSeparator()

            DetailRow(title: "Icons only") {
                SettingsToggle(Binding(
                    get: { sidebar.style == .icons },
                    set: { sidebar.setStyle($0 ? .icons : .full) }
                ))
            }
            .settingsAnchor("appearance.sidebarStyle")

            RowSeparator()

            DetailRow(
                title: "Sidebar font",
                caption: "Choose an installed font family for tab and folder names."
            ) {
                SettingsMenu(
                    options: Self.sidebarFontOptions,
                    selection: $settings.sidebarFontFamily,
                    placeholder: "System Default"
                )
            }
            .settingsAnchor("appearance.sidebarFont")

            RowSeparator()

            DetailRow(title: "Font weight") {
                SettingsMenu(
                    options: SidebarFontWeight.allCases.map {
                        .init(value: $0, label: $0.label)
                    },
                    selection: $settings.sidebarFontWeight
                )
            }
            .settingsAnchor("appearance.sidebarFontWeight")

            RowSeparator()

            DetailRow(
                title: "Font size",
                caption: "Adjust the text size without reducing the row’s usable target."
            ) {
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

            DetailRow(
                title: "Row spacing",
                caption: "Add vertical breathing room between sidebar rows."
            ) {
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

            DetailRow(
                title: "Folder tint",
                caption: "Set the background tint for expanded folders, including none."
            ) {
                HStack(spacing: 8) {
                    Slider(value: $settings.sidebarFolderTint, in: 0...1, step: 0.05)
                        .frame(width: 140)
                        .accessibilityLabel("Folder tint")
                    Text(settings.sidebarFolderTint == 0
                        ? "None"
                        : settings.sidebarFolderTint.formatted(.percent.precision(.fractionLength(0))))
                        .frame(width: 46, alignment: .trailing)
                }
            }
            .settingsAnchor("appearance.sidebarFolderTint")
        }
    }
}

private struct WindowStyleSettingsSection: View {
    @Bindable var settings: BrowserSettings

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
            SettingsCard {
                DetailRow(title: "Window style", layout: .stacked) {
                    LoomStylePicker(
                        selection: settings.loomStyle,
                        usesWebsiteTint: settings.matchesWebsiteColor,
                        tintsSelectedTab: settings.refractsTabColor
                    ) {
                        settings.loomStyle = $0
                    }
                }
                .settingsAnchor("appearance.windowStyle")

                RowSeparator()

                DetailRow(
                    title: "Website tint",
                    caption: "Use the current website’s color in the toolbar and sidebar."
                ) {
                    SettingsToggle($settings.matchesWebsiteColor)
                }
                .settingsAnchor("appearance.websiteTint")

                RowSeparator()

                DetailRow(
                    title: "Tint selected tab",
                    caption: "Color the selected tab using the website icon."
                ) {
                    SettingsToggle($settings.refractsTabColor)
                }
                .settingsAnchor("appearance.refraction")

                if settings.loomStyle == .transparent {
                    RowSeparator()

                    DetailRow(
                        title: "Transparency",
                        caption: "Move left for more transparency or right for more contrast.",
                        layout: .stacked
                    ) {
                        LoomTransparencyControl(opacity: $settings.transparency)
                    }
                    .settingsAnchor("appearance.transparency")
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            Text("Choose Standard or Transparent.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
        .animation(Theme.Motion.settle, value: settings.loomStyle)
    }
}
