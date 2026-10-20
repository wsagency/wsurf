// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The shape knobs of the selected theme: page edge, row edges, corner rounding and tab icons. Like brightness,
/// they belong to the theme, travel with a saved copy and never make one.
struct AppearanceLayoutSection: View {
    @Bindable var settings: BrowserSettings
    @Environment(\.settingsHighlight) private var highlight
    @State private var isExpanded = false
    @State private var isEditing = false

    private static let edges: [SegmentedControl<FrameStyle>.Item] = [
        .init(value: .standard, label: "Standard"),
        .init(value: .hairline, label: "Thin edge"),
        .init(value: FrameStyle.none, label: "None"),
    ]

    private static let favicons: [SegmentedControl<FaviconStyle>.Item] = [
        .init(value: .mono, label: "Monochrome"),
        .init(value: .color, label: "Color"),
    ]

    var body: some View {
        let adjustment = settings.themeAdjustment
        SettingsCard {
            DisclosureGroup("Layout", isExpanded: $isExpanded) {
                Text("Saved with this theme. Changing it never makes a copy.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                DetailRow(title: "Page edge") {
                    SegmentedControl(items: Self.edges, selection: adjustment.pageFrame, onSelect: { update(\.pageFrame, $0) })
                }
                RowSeparator()
                DetailRow(title: "Tab and folder edges", caption: "Thin edge and None draw selected tabs without glass.") {
                    SegmentedControl(items: Self.edges, selection: adjustment.rowFrame, onSelect: { update(\.rowFrame, $0) })
                }
                RowSeparator()
                DetailRow(title: "Corner rounding", caption: "Rounds tabs, folders and the page.") {
                    HStack(spacing: 8) {
                        Slider(value: cornerScale, in: 0...1.5, step: 0.1, onEditingChanged: editingChanged)
                            .frame(width: 140)
                            .accessibilityLabel("Corner rounding")
                            .accessibilityValue(cornerLabel)
                        cornerLabel
                            .monospacedDigit()
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                RowSeparator()
                DetailRow(title: "Tab icons", caption: "Unloaded tabs stay monochrome.") {
                    SegmentedControl(items: Self.favicons, selection: adjustment.loadedFavicons, onSelect: { update(\.loadedFavicons, $0) })
                }
            }
            .disclosureGroupStyle(ClickableDisclosureStyle())
            .padding(SettingsMetrics.cardInset)
        }
        .settingsAnchor("appearance.layout")
        .onChange(of: highlight, initial: true) { _, value in
            if value == "appearance.layout" {
                isExpanded = true
            }
        }
        .onDisappear { settings.commitThemePreview() }
    }

    private var cornerLabel: Text {
        let scale = settings.themeAdjustment.cornerScale
        return scale == 0 ? Text("Square") : Text(scale, format: .percent.precision(.fractionLength(0)))
    }

    private var cornerScale: Binding<Double> {
        Binding(get: { settings.themeAdjustment.cornerScale }, set: { update(\.cornerScale, $0) })
    }

    /// A drag previews in memory and writes once when it ends; a tap or a keyboard step writes at once.
    private func update<Value>(_ keyPath: WritableKeyPath<ThemeAdjustment, Value>, _ value: Value) {
        var adjustment = settings.themeAdjustment
        adjustment[keyPath: keyPath] = value
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
