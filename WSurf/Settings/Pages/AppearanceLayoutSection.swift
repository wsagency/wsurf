// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The shape knobs of the selected theme: page edge and spacing, row edges, corner rounding, sidebar margin, tab
/// padding and tab icons. Like brightness, they belong to the theme, travel with a saved copy and never make one.
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
                pointSlider(
                    "Page spacing", caption: "None puts the page against the window and the sidebar.",
                    \.pageSpacing, in: ThemeAdjustment.pageSpacingRange, zero: "None"
                )
                RowSeparator()
                pointSlider("Sidebar margin", caption: "The room between the tabs and the window edge.",
                            \.sidebarMargin, in: ThemeAdjustment.sidebarMarginRange)
                RowSeparator()
                pointSlider("Tab padding", caption: "The room between a tab’s edge and its icon.",
                            \.rowPadding, in: ThemeAdjustment.rowPaddingRange)
                RowSeparator()
                DetailRow(title: "Tab icons", caption: "Unloaded tabs stay monochrome.") {
                    SegmentedControl(items: Self.favicons, selection: adjustment.loadedFavicons, onSelect: { update(\.loadedFavicons, $0) })
                }
                RowSeparator()
                pointSlider("Tab icon size", caption: "Rows grow with the icon.",
                            \.tabIconSize, in: ThemeAdjustment.tabIconSizeRange)
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
        binding(\.cornerScale)
    }

    private func binding(_ keyPath: WritableKeyPath<ThemeAdjustment, Double>) -> Binding<Double> {
        Binding(get: { settings.themeAdjustment[keyPath: keyPath] }, set: { update(keyPath, $0) })
    }

    /// A whole-point slider. Like corner rounding, a drag previews and writes once when it ends.
    private func pointSlider(
        _ title: LocalizedStringResource,
        caption: LocalizedStringResource,
        _ keyPath: WritableKeyPath<ThemeAdjustment, Double>,
        in range: ClosedRange<Double>,
        zero: LocalizedStringResource? = nil
    ) -> some View {
        let points = settings.themeAdjustment[keyPath: keyPath]
        let label = if let zero, points == 0 {
            Text(zero)
        } else {
            Text("\(Int(points)) pt")
        }
        return DetailRow(title: title, caption: caption) {
            HStack(spacing: 8) {
                Slider(value: binding(keyPath), in: range, step: 1, onEditingChanged: editingChanged)
                    .frame(width: 140)
                    .accessibilityLabel(Text(title))
                    .accessibilityValue(label)
                label
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
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
