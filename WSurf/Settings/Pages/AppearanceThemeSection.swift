// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AppearanceThemeSection: View {
    @Bindable var settings: BrowserSettings
    let scheme: ColorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isEditing = false

    private var themes: [ThemeDefinition] {
        let selected = settings.previewedTheme
        return settings.allThemes.map { $0.id == selected.id ? selected : $0 }
    }

    private var adjustments: [String: ThemeAdjustment] {
        var values = settings.themeAdjustments
        values[settings.selectedTheme.id] = settings.themeAdjustment
        return values
    }

    private var materialCaption: LocalizedStringResource {
        GlassPolicy.fallsBack(reduceTransparency: reduceTransparency, contrast: contrast)
            ? "Reduce transparency or increase contrast is on in System Settings, so WSurf uses Plain."
            : "Glass shows your desktop through the window. It uses more GPU."
    }

    var body: some View {
        SettingsSection(title: "Theme", symbol: "paintpalette") {
            DetailRow(title: "Appearance") {
                SegmentedControl(
                    items: AppearanceMode.allCases.map { .init(value: $0, label: $0.label) },
                    selection: settings.colorMode,
                    onSelect: { settings.colorMode = $0 }
                )
            }
            .settingsAnchor("appearance.mode")
            RowSeparator()
            DetailRow(title: "Theme", layout: .stacked) {
                ThemeGallery(
                    themes: themes, selection: settings.selectedTheme.id,
                    mode: settings.colorMode, adjustments: adjustments
                ) { settings.themeID = $0 }
            }
            .settingsAnchor("appearance.theme")
            RowSeparator()
            DetailRow(title: "Material", caption: materialCaption) {
                SegmentedControl(
                    items: [
                        .init(value: ThemeMaterial.plain, label: "Plain"),
                        .init(value: ThemeMaterial.glass, label: "Glass"),
                    ],
                    selection: settings.themeMaterial,
                    onSelect: { settings.themeMaterial = $0 }
                )
            }
            .settingsAnchor("appearance.material")
            if settings.themeMaterial == .glass {
                RowSeparator()
                DetailRow(title: "Transparency", layout: .stacked) {
                    LoomTransparencyControl(
                        opacity: adjustmentBinding(\.glassOpacity), onEditingChanged: editingChanged
                    )
                }
                .settingsAnchor("appearance.transparency")
            }
            RowSeparator()
            DetailRow(
                title: "Brightness",
                caption: scheme == .dark
                    ? "Makes this theme’s dark colors darker or lighter."
                    : "Makes this theme’s light colors darker or lighter."
            ) {
                HStack(spacing: 8) {
                    Slider(value: brightness, in: -0.5...0.5, onEditingChanged: editingChanged)
                        .frame(width: 140)
                        .accessibilityLabel("Theme brightness")
                        .accessibilityValue(Text(brightness.wrappedValue, format: .percent))
                    Text(brightness.wrappedValue, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            .settingsAnchor("appearance.brightness")
            RowSeparator()
            DetailRow(
                title: "Website tint",
                caption: "Use the current website’s color in the toolbar and sidebar. Off while a theme’s colors or brightness are changed."
            ) {
                SettingsToggle($settings.matchesWebsiteColor)
            }
            .settingsAnchor("appearance.websiteTint")
            RowSeparator()
            DetailRow(title: "Tint selected tab", caption: "Color tabs you select together using the website icon.") {
                SettingsToggle($settings.refractsTabColor)
            }
            .settingsAnchor("appearance.refraction")
        }
        .onDisappear { settings.commitThemePreview() }
        .onChange(of: scheme) { _, _ in
            settings.commitThemePreview()
            isEditing = false
        }
    }

    private var brightness: Binding<Double> {
        Binding(
            get: { settings.themeAdjustment.brightness(scheme) },
            set: { value in
                var adjustment = settings.themeAdjustment
                adjustment.setBrightness(value, for: scheme)
                store(adjustment)
            }
        )
    }

    private func adjustmentBinding(_ keyPath: WritableKeyPath<ThemeAdjustment, Double>) -> Binding<Double> {
        Binding(
            get: { settings.themeAdjustment[keyPath: keyPath] },
            set: { value in
                var adjustment = settings.themeAdjustment
                adjustment[keyPath: keyPath] = value
                store(adjustment)
            }
        )
    }

    private func store(_ adjustment: ThemeAdjustment) {
        if isEditing {
            settings.previewThemeAdjustment(adjustment)
        } else {
            settings.themeAdjustment = adjustment
        }
    }

    private func editingChanged(_ editing: Bool) {
        isEditing = editing
        if editing {
            settings.beginThemePreview()
        } else {
            settings.commitThemePreview()
        }
    }
}
