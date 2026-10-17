// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct AppearanceSettings: View {
    let coordinator: AppCoordinator

    @Bindable var settings: BrowserSettings
    @Environment(\.colorScheme) private var windowColorScheme

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
            DetailRow(title: "Appearance") {
                SettingsMenu(
                    options: AppearanceMode.allCases.map { .init(value: $0, label: String(localized: $0.label)) },
                    selection: $settings.colorMode
                )
            }
            .settingsAnchor("appearance.mode")

            RowSeparator()

            DetailRow(title: "Theme") {
                SettingsMenu(
                    options: settings.allThemes.map { .init(value: $0.id, label: $0.name) },
                    selection: Binding(get: { settings.selectedTheme.id }, set: { settings.themeID = $0 })
                )
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

        themeCustomizationSection
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
                title: "Loaded tab color",
                caption: "Text and icon color and opacity are saved with the theme."
            ) {
                sidebarColorControls(isDeferred: false)
            }
            .settingsAnchor("appearance.sidebarLoadedColor")

            RowSeparator()

            DetailRow(
                title: "Unloaded tab color",
                caption: "Text and icon color and opacity are saved with the theme."
            ) {
                sidebarColorControls(isDeferred: true)
            }
            .settingsAnchor("appearance.sidebarUnloadedColor")

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

    /// The appearance whose colors the rows below edit: the one the window shows, or the one chosen in System mode.
    private var shownScheme: ColorScheme {
        switch settings.colorMode {
        case .system:
            windowColorScheme
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private var shownVariant: ThemeVariant {
        settings.selectedTheme.variant(shownScheme)
    }

    /// Reads a color of the shown variant. Writing edits the theme, and edits a copy when it is a built-in one.
    private func colorBinding<Value>(_ keyPath: WritableKeyPath<ThemeVariant, Value>) -> Binding<Value> {
        let scheme = shownScheme
        return Binding(
            get: { settings.selectedTheme.variant(scheme)[keyPath: keyPath] },
            set: { value in settings.editColors(scheme: scheme) { $0[keyPath: keyPath] = value } }
        )
    }

    private var brightnessBinding: Binding<Double> {
        let scheme = shownScheme
        return Binding(
            get: { settings.themeAdjustment.brightness(scheme) },
            set: {
                var adjustment = settings.themeAdjustment
                adjustment.setBrightness($0, for: scheme)
                settings.themeAdjustment = adjustment
            }
        )
    }

    private var themeCustomizationSection: some View {
        SettingsSection(title: "Theme customization", symbol: "paintpalette") {
            DetailRow(
                title: "Customize current theme",
                caption: """
                Changes preview live. Changing a built-in theme’s colors saves them as a copy; brightness stays with \
                the theme. Custom palette colors take precedence over website tint.
                """
            ) {
                Text("\(settings.selectedTheme.name), \(shownScheme == .dark ? String(localized: "dark") : String(localized: "light"))")
                    .foregroundStyle(.secondary)
            }
            RowSeparator()
            DetailRow(title: "Brightness") {
                Slider(value: brightnessBinding, in: -0.5...0.5)
                    .frame(width: 160)
                    .accessibilityLabel("Theme brightness")
            }
            RowSeparator()
            DetailRow(title: "Hue") {
                Slider(value: colorBinding(\.hue), in: -0.5...0.5)
                    .frame(width: 160)
                    .accessibilityLabel("Theme hue")
            }
            RowSeparator()
            DetailRow(title: "Primary color", caption: "Derives the background, surface, and accent palette without changing website content.") {
                primaryColorPicker
            }
            RowSeparator()
            DetailRow(title: "Control icons") {
                themeColorControls(\.icons, label: "Control icons", opacityLabel: "Control icons opacity")
            }
            RowSeparator()
            DetailRow(title: "URL text") {
                themeColorControls(\.url, label: "URL text", opacityLabel: "URL text opacity")
            }
            RowSeparator()
            DetailRow(title: "Reset theme", caption: "Restore this theme’s original palette and chrome colors.") {
                Button("Reset") { settings.resetColors(scheme: shownScheme) }
            }
        }
        .settingsAnchor("appearance.themeCustomization")
    }

    private var primaryColorPicker: some View {
        let scheme = shownScheme
        return ColorPicker(
            String(localized: "Primary color"),
            selection: Binding(
                get: { settings.selectedTheme.variant(scheme).primary.map(Color.init(hex:)) ?? Theme.accent },
                set: { color in
                    guard let rgb = SidebarTextStyle.rgb(of: color) else { return }
                    settings.editColors(scheme: scheme) { $0.primary = rgb }
                }
            ),
            supportsOpacity: false
        )
        .labelsHidden()
        .accessibilityLabel("Primary color")
    }

    private func themeColorControls(
        _ keyPath: WritableKeyPath<ThemeVariant, SidebarTextStyle>,
        label: LocalizedStringResource,
        opacityLabel: LocalizedStringResource? = nil
    ) -> some View {
        let binding = colorBinding(keyPath)
        return HStack(spacing: 8) {
            ColorPicker(String(localized: label), selection: Binding(
                get: { binding.wrappedValue.color ?? Color.primary },
                set: {
                    var style = binding.wrappedValue
                    style.setColor($0)
                    binding.wrappedValue = style
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .accessibilityLabel(Text(label))
            if let opacityLabel {
                Slider(value: Binding(
                    get: { binding.wrappedValue.opacity },
                    set: {
                        var style = binding.wrappedValue
                        style.opacity = $0
                        binding.wrappedValue = style
                    }
                ), in: 0...1, step: 0.05)
                .frame(width: 110)
                .accessibilityLabel(Text(opacityLabel))
                Text(binding.wrappedValue.opacity, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
        }
    }

    private func sidebarColorControls(isDeferred: Bool) -> some View {
        let keyPath: WritableKeyPath<ThemeVariant, SidebarTextStyle> = isDeferred ? \.unloadedText : \.sidebarText
        let style = colorBinding(keyPath)
        let label: LocalizedStringResource = isDeferred ? "Unloaded tab color" : "Loaded tab color"
        let opacityLabel: LocalizedStringResource = isDeferred ? "Unloaded tab opacity" : "Loaded tab opacity"
        let scheme = shownScheme
        return HStack(spacing: 8) {
            ColorPicker(
                String(localized: label),
                selection: Binding(
                    get: {
                        style.wrappedValue.color ?? shownVariant.text.map(Color.init(hex:))
                            ?? (scheme == .dark ? .white : .black)
                    },
                    set: {
                        var updated = style.wrappedValue
                        updated.setColor($0)
                        style.wrappedValue = updated
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .accessibilityLabel(Text(label))
            Slider(
                value: Binding(
                    get: { style.wrappedValue.opacity },
                    set: {
                        var updated = style.wrappedValue
                        updated.opacity = $0
                        style.wrappedValue = updated
                    }
                ),
                in: 0...1,
                step: 0.05
            )
            .frame(width: 110)
            .accessibilityLabel(Text(opacityLabel))
            Text(style.wrappedValue.opacity, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
    }
}

private struct WindowStyleSettingsSection: View {
    @Bindable var settings: BrowserSettings

    /// A theme with solid colors paints its own ground, so the window style and the website tint have no effect.
    private var drawsSolid: Bool {
        settings.selectedTheme.ground == .solid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.headerGap) {
            SettingsCard {
                if !drawsSolid {
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
                }

                DetailRow(
                    title: "Tint selected tab",
                    caption: "Color tabs you select together using the website icon."
                ) {
                    SettingsToggle($settings.refractsTabColor)
                }
                .settingsAnchor("appearance.refraction")

                if !drawsSolid, settings.loomStyle == .transparent {
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

            if !drawsSolid {
                Text("Choose Standard or Transparent.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
        .animation(Theme.Motion.settle, value: settings.loomStyle)
    }
}
