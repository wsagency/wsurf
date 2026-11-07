// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

struct AppearanceColorsSection: View {
    @Bindable var settings: BrowserSettings
    let scheme: ColorScheme
    /// Owned by the page, so that Customize can open the card.
    @Binding var isExpanded: Bool
    @Environment(\.settingsHighlight) private var highlight
    @State private var isEditing = false

    private var isDark: Bool {
        scheme == .dark
    }

    private var introduction: LocalizedStringResource {
        ThemeCatalog.isBuiltIn(settings.selectedTheme.id)
            ? "Built-in themes don’t change. Your first edit makes a copy named “\(settings.selectedTheme.name) Custom” that you can rename."
            : "Changes are saved to this theme as you make them."
    }

    private var appearanceNote: LocalizedStringResource {
        isDark
            ? "These colors are for the dark appearance, which is showing now."
            : "These colors are for the light appearance, which is showing now."
    }

    /// Standard and Calm take their look from the page. Their copies draw their own base colors as a solid ground.
    private var groundNote: LocalizedStringResource? {
        let theme = settings.previewedTheme
        guard theme.ground != .solid else { return nil }
        let note: LocalizedStringResource = theme.drawnGround == .solid
            ? "This theme draws its window, sidebar and surface colors as a solid ground, without the website tint."
            : "Changing the window, sidebar or surface color draws this theme as a solid ground, without the website tint."
        return note
    }

    private var paletteChangeNote: LocalizedStringResource? {
        let variant = settings.previewedTheme.variant(scheme)
        guard variant.hue != 0 || variant.primary != nil || settings.themeAdjustment.brightness(scheme) != 0 else { return nil }
        let note: LocalizedStringResource =
            "Hue, primary color and brightness are applied on top of these colors, so what you see can differ from what you pick."
        return note
    }

    private func shortfall(_ role: ThemeContrast.Role) -> ThemeContrast.Shortfall? {
        let theme = settings.previewedTheme
        return ThemeContrast.shortfall(
            role, in: theme.variant(scheme), isDark: isDark,
            brightness: settings.themeAdjustment.brightness(scheme), ground: theme.drawnGround
        )
    }

    private func caption(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(Theme.Font.label)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        let live = settings.liveResolvedVariant(scheme)
        return SettingsCard {
            DisclosureGroup("Colors", isExpanded: $isExpanded) {
                caption(introduction)
                caption(appearanceNote)
                if let groundNote {
                    caption(groundNote)
                }
                if let paletteChangeNote {
                    caption(paletteChangeNote)
                }
                DetailRow(title: "Window background", caption: "Behind the tabs and the page, and under the side panel.") {
                    paletteColor(\.window, label: "Window background", fallback: Color(nsColor: StandardPalette.window(isDark: isDark)))
                }
                RowSeparator()
                DetailRow(
                    title: "Sidebar",
                    caption: "The floating sidebar and the Minimal bar. The docked sidebar uses the window color."
                ) {
                    paletteColor(\.sidebar, label: "Sidebar", fallback: Color(nsColor: StandardPalette.sidebar(isDark: isDark)))
                }
                RowSeparator()
                DetailRow(title: "Surface", caption: "Toolbar controls, buttons and the highlight of the selected tab.") {
                    paletteColor(\.surface, label: "Surface", fallback: Color(nsColor: StandardPalette.surface(isDark: isDark)))
                }
                RowSeparator()
                DetailRow(
                    title: "Primary text", caption: "Tab titles, icons and the address, unless one is colored below."
                ) {
                    warned(paletteColor(\.text, label: "Primary text", fallback: isDark ? .white : .black), .primary)
                }
                RowSeparator()
                DetailRow(title: "Secondary text", caption: "The titles of tabs that are asleep (unloaded), dimmer than primary text.") {
                    inkControls(
                        live: live,
                        \.unloadedText, label: "Secondary text", opacityLabel: "Secondary text opacity",
                        drawn: { $0.unloadedInk }, role: .secondary
                    )
                }
                RowSeparator()
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
                DetailRow(
                    title: "Folder color opacity",
                    caption: "How strongly folder colors draw: folder icons, outlines and the icons a folder tints."
                ) {
                    folderOpacityControls
                }
                RowSeparator()
                DetailRow(title: "Tab text", caption: "The title of tabs and folders that are loaded.") {
                    inkControls(
                        live: live,
                        \.sidebarText, label: "Tab text", opacityLabel: "Tab text opacity",
                        drawn: { $0.loadedInk }
                    )
                }
                RowSeparator()
                DetailRow(title: "Icons", caption: "The icons on the toolbar and on controls.") {
                    inkControls(
                        live: live,
                        \.icons, label: "Icons", opacityLabel: "Icons opacity",
                        drawn: { $0.controlInk }
                    )
                }
                RowSeparator()
                DetailRow(title: "URL text", caption: "The address in the toolbar.") {
                    inkControls(live: live, \.url, label: "URL text", opacityLabel: "URL text opacity", drawn: { _ in nil })
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

    /// A color well for a color the theme may leave unset: it shows `fallback` (the accent when there is none), the
    /// color drawn without it, before the hue, primary color and brightness are laid over it.
    private func paletteColor(
        _ keyPath: WritableKeyPath<ThemeVariant, UInt32?>, label: LocalizedStringResource, fallback: Color? = nil
    ) -> some View {
        let binding = colorBinding(keyPath)
        return ColorPicker(String(localized: label), selection: Binding(
            get: { binding.wrappedValue.map(Color.init(hex:)) ?? fallback ?? Theme.accent },
            set: { color in
                guard let rgb = SidebarTextStyle.rgb(of: color) else { return }
                binding.wrappedValue = rgb
            }
        ), supportsOpacity: false)
        .labelsHidden()
        .accessibilityLabel(Text(label))
    }

    /// `control` with a warning under it when `role`'s text is under 4.5:1 on a ground it is drawn on. The warning
    /// only says so: the picked color is neither blocked nor changed.
    private func warned(_ control: some View, _ role: ThemeContrast.Role) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            control
            if let shortfall = shortfall(role) {
                ContrastWarning(shortfall: shortfall)
            }
        }
    }

    private func inkControls(
        live: ResolvedVariant,
        _ keyPath: WritableKeyPath<ThemeVariant, SidebarTextStyle>,
        label: LocalizedStringResource, opacityLabel: LocalizedStringResource,
        drawn: (ResolvedVariant) -> Color?, role: ThemeContrast.Role? = nil
    ) -> some View {
        let style = colorBinding(keyPath)
        let note = readabilityNote(style.wrappedValue, drawn: drawn(live))
        return VStack(alignment: .trailing, spacing: 4) {
            inkRow(style: style, label: label, opacityLabel: opacityLabel)
            if let role, let shortfall = shortfall(role) {
                ContrastWarning(shortfall: shortfall)
            }
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

    /// A knob of the theme, not a color: like the Layout sliders it never makes a copy, a drag previews in memory and
    /// writes once when it ends, and Reset Theme to Default puts it back.
    private var folderOpacityControls: some View {
        let opacity = Binding(
            get: { settings.themeAdjustment.folderColorOpacity },
            set: { value in
                var adjustment = settings.themeAdjustment
                adjustment.folderColorOpacity = value
                if isEditing {
                    settings.previewThemeAdjustment(adjustment)
                } else {
                    settings.themeAdjustment = adjustment
                }
            }
        )
        return HStack(spacing: 8) {
            Slider(
                value: opacity, in: ThemeAdjustment.folderColorOpacityRange,
                step: ThemeAdjustment.folderColorOpacityStep, onEditingChanged: editingChanged
            )
            .frame(width: 90)
            .accessibilityLabel("Folder color opacity")
            Text("Opacity \(opacity.wrappedValue, format: .percent.precision(.fractionLength(0)))")
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

/// The inline warning of a text color that reads under 4.5:1 on one of its grounds.
private struct ContrastWarning: View {
    let shortfall: ThemeContrast.Shortfall

    private var message: LocalizedStringResource {
        let ratio = shortfall.shownRatio.formatted(.number.precision(.fractionLength(1)))
        switch shortfall.ground {
        case .window:
            return "Low contrast: \(ratio):1 on the window color. Aim for 4.5:1 or more."
        case .sidebar:
            return "Low contrast: \(ratio):1 on the sidebar color. Aim for 4.5:1 or more."
        case .surface:
            return "Low contrast: \(ratio):1 on the surface color. Aim for 4.5:1 or more."
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(Theme.Font.label)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
