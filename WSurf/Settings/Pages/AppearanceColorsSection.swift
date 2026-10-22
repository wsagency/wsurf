// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AppearanceColorsSection: View {
    @Bindable var settings: BrowserSettings
    let scheme: ColorScheme
    @Environment(\.settingsHighlight) private var highlight
    @State private var isExpanded = false
    @State private var isEditing = false

    private var introduction: LocalizedStringResource {
        ThemeCatalog.isBuiltIn(settings.selectedTheme.id)
            ? "Built-in themes don’t change. Your first edit makes a copy you can rename."
            : "Changes are saved to this theme as you make them."
    }

    var body: some View {
        SettingsCard {
            DisclosureGroup("Colors", isExpanded: $isExpanded) {
                Text(introduction)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DetailRow(title: "Accent color") {
                    paletteColor(\.accent, label: "Accent color")
                }
                RowSeparator()
                DetailRow(title: "Assistant color", caption: "Marks assistant activity. Follows the accent color until you choose one.") {
                    paletteColor(\.assistant, label: "Assistant color")
                }
                RowSeparator()
                DetailRow(title: "Tab text") {
                    inkControls(\.sidebarText, label: "Tab text", opacityLabel: "Tab text opacity")
                }
                RowSeparator()
                DetailRow(title: "Unloaded tab text") {
                    inkControls(\.unloadedText, label: "Unloaded tab text", opacityLabel: "Unloaded tab text opacity")
                }
                RowSeparator()
                DetailRow(title: "Icons") {
                    inkControls(\.icons, label: "Icons", opacityLabel: "Icons opacity")
                }
                RowSeparator()
                DetailRow(title: "URL text") {
                    inkControls(\.url, label: "URL text", opacityLabel: "URL text opacity")
                }
                RowSeparator()
                DetailRow(
                    title: "Primary color",
                    caption: "Derives the background, surface, and accent palette without changing website content."
                ) {
                    paletteColor(\.primary, label: "Primary color")
                }
                RowSeparator()
                DetailRow(title: "Hue") {
                    Slider(value: colorBinding(\.hue), in: -0.5...0.5, onEditingChanged: editingChanged)
                        .frame(width: 160)
                        .accessibilityLabel("Theme hue")
                }
                if settings.selectedTheme.basedOn.flatMap(ThemeCatalog.builtIn) != nil {
                    RowSeparator()
                    DetailRow(title: "Reset colors", caption: "Restore the original colors of this theme’s shown variant.") {
                        SettingsButton(title: "Reset Colors") { settings.resetColors(scheme: scheme) }
                    }
                }
            }
            .disclosureGroupStyle(ClickableDisclosureStyle())
            .padding(SettingsMetrics.cardInset)
        }
        .settingsAnchor("appearance.colors")
        .onChange(of: highlight, initial: true) { _, value in
            if value == "appearance.colors" {
                isExpanded = true
            }
        }
        .onChange(of: scheme) { _, _ in
            settings.commitThemePreview()
            isEditing = false
        }
        .onDisappear { settings.commitThemePreview() }
    }

    private func colorBinding<Value>(_ keyPath: WritableKeyPath<ThemeVariant, Value>) -> Binding<Value> {
        Binding(
            get: { settings.previewedTheme.variant(scheme)[keyPath: keyPath] },
            set: { value in
                if isEditing {
                    settings.previewThemeColors(scheme: scheme) { $0[keyPath: keyPath] = value }
                } else {
                    settings.editColors(scheme: scheme) { $0[keyPath: keyPath] = value }
                }
            }
        )
    }

    private func paletteColor(
        _ keyPath: WritableKeyPath<ThemeVariant, UInt32?>, label: LocalizedStringResource
    ) -> some View {
        let binding = colorBinding(keyPath)
        return ColorPicker(String(localized: label), selection: Binding(
            get: { binding.wrappedValue.map(Color.init(hex:)) ?? Theme.accent },
            set: { color in
                guard let rgb = SidebarTextStyle.rgb(of: color) else { return }
                binding.wrappedValue = rgb
            }
        ), supportsOpacity: false)
        .labelsHidden()
        .accessibilityLabel(Text(label))
    }

    private func inkControls(
        _ keyPath: WritableKeyPath<ThemeVariant, SidebarTextStyle>,
        label: LocalizedStringResource, opacityLabel: LocalizedStringResource
    ) -> some View {
        let style = colorBinding(keyPath)
        return HStack(spacing: 8) {
            ColorPicker(String(localized: label), selection: Binding(
                get: {
                    style.wrappedValue.color ?? settings.previewedTheme.variant(scheme).text.map(Color.init(hex:))
                        ?? (scheme == .dark ? .white : .black)
                },
                set: {
                    var updated = style.wrappedValue
                    updated.setColor($0)
                    style.wrappedValue = updated
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .accessibilityLabel(Text(label))
            Slider(value: Binding(
                get: { style.wrappedValue.opacity },
                set: {
                    var updated = style.wrappedValue
                    updated.opacity = $0
                    style.wrappedValue = updated
                }
            ), in: 0...1, step: 0.05, onEditingChanged: editingChanged)
            .frame(width: 110)
            .accessibilityLabel(Text(opacityLabel))
            Text(style.wrappedValue.opacity, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
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
