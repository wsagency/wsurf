// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
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
                Text(scheme == .dark
                    ? "These colors are for the dark appearance, which is showing now."
                    : "These colors are for the light appearance, which is showing now.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DetailRow(title: "Accent color", caption: "Buttons, highlights, drop targets and the new-tab dot.") {
                    paletteColor(\.accent, label: "Accent color")
                }
                RowSeparator()
                DetailRow(
                    title: "Assistant color",
                    caption: "The assistant’s activity, questions and buttons. A theme without one uses the accent color."
                ) {
                    paletteColor(\.assistant, label: "Assistant color")
                }
                RowSeparator()
                DetailRow(title: "Tab text", caption: "The title of tabs and folders that are loaded.") {
                    inkControls(
                        \.sidebarText, label: "Tab text", opacityLabel: "Tab text opacity",
                        drawn: { $0.loadedInk }
                    )
                }
                RowSeparator()
                DetailRow(title: "Unloaded tab text", caption: "The title of tabs that are asleep (unloaded).") {
                    inkControls(
                        \.unloadedText, label: "Unloaded tab text", opacityLabel: "Unloaded tab text opacity",
                        drawn: { $0.unloadedInk }
                    )
                }
                RowSeparator()
                DetailRow(title: "Icons", caption: "The icons on the toolbar and on controls.") {
                    inkControls(
                        \.icons, label: "Icons", opacityLabel: "Icons opacity",
                        drawn: { $0.controlInk }
                    )
                }
                RowSeparator()
                DetailRow(title: "URL text", caption: "The address in the toolbar.") {
                    inkControls(\.url, label: "URL text", opacityLabel: "URL text opacity", drawn: { _ in nil })
                }
                RowSeparator()
                DetailRow(
                    title: "Primary color",
                    caption: "Derives the background, surface, and accent palette without changing website content."
                ) {
                    paletteColor(\.primary, label: "Primary color")
                }
                RowSeparator()
                DetailRow(title: "Hue", caption: "Turns the colors derived from the primary color around the color wheel.") {
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
            .padding(.vertical, SettingsMetrics.rowPaddingV)
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
        label: LocalizedStringResource, opacityLabel: LocalizedStringResource,
        drawn: (ResolvedVariant) -> Color?
    ) -> some View {
        let style = colorBinding(keyPath)
        let note = readabilityNote(style.wrappedValue, drawn: drawn(settings.resolvedTheme.variant(scheme)))
        return VStack(alignment: .trailing, spacing: 4) {
            inkRow(style: style, label: label, opacityLabel: opacityLabel)
            if let note {
                note
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Says so when the text is drawn differently from the choice: a color or an opacity too faint for the
    /// background to read at 4.5:1 is moved by the least that reads, keeping its hue.
    private func readabilityNote(_ style: SidebarTextStyle, drawn: Color?) -> Text? {
        guard let drawn, let ink = NSColor(drawn).usingColorSpace(.sRGB) else { return nil }
        if ink.alphaComponent > style.opacity + 0.005 {
            return Text("Shown at \(Double(ink.alphaComponent), format: .percent.precision(.fractionLength(0))) so it stays readable.")
        }
        guard let chosen = style.colorRGB,
              let wanted = NSColor(Color(hex: chosen)).usingColorSpace(.sRGB),
              abs(wanted.redComponent - ink.redComponent) + abs(wanted.greenComponent - ink.greenComponent)
                  + abs(wanted.blueComponent - ink.blueComponent) > 0.02
        else { return nil }
        return Text("Adjusted a little so it stays readable.")
    }

    private func inkRow(
        style: Binding<SidebarTextStyle>, label: LocalizedStringResource, opacityLabel: LocalizedStringResource
    ) -> some View {
        HStack(spacing: 8) {
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
            .frame(width: 90)
            .accessibilityLabel(Text(opacityLabel))
            Text("Opacity \(style.wrappedValue.opacity, format: .percent.precision(.fractionLength(0)))")
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
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
