// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// Chooses the window style, where the Minimal bar floats, and the shadow and border of every window. Those are app-wide, not
/// part of a theme; the Layout disclosure at the end holds the theme's knobs for the page.
struct AppearanceWindowSection: View {
    @Bindable var settings: BrowserSettings

    private static let edges: [SegmentedControl<MinimalBarEdge>.Item] = MinimalBarEdge.allCases.map {
        .init(value: $0, label: $0.label)
    }

    private static let hidingChoices: [SettingsMenu<MinimalBarHiding>.Option] = MinimalBarHiding.allCases.map {
        .init(value: $0, label: String(localized: $0.label))
    }

    private static let borderChoices: [SettingsMenu<WindowBorder>.Option] = WindowBorder.allCases.map {
        .init(value: $0, label: String(localized: $0.label))
    }

    private var borderColor: Binding<Color> {
        Binding(
            get: { Color(hex: settings.windowBorderColor) },
            set: { color in
                guard let rgb = SidebarTextStyle.rgb(of: color) else { return }
                settings.windowBorderColor = rgb
            }
        )
    }

    var body: some View {
        SettingsSection(title: "Window", symbol: "macwindow") {
            DetailRow(
                caption: "Minimal hides the sidebar and the toolbar. Its bar carries the address and the page controls.",
                layout: .stacked
            ) {
                LazyVGrid(columns: AppearanceThumbnailMetrics.columns, spacing: AppearanceThumbnailMetrics.spacing) {
                    ForEach(BrowserWindowStyle.allCases) { style in
                        PreviewChoiceCard(label: style.label, isSelected: settings.windowStyle == style) {
                            settings.windowStyle = style
                        } thumbnail: {
                            WindowStyleThumbnail(style: style)
                        }
                        .help(Text(style.caption))
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .settingsAnchor("appearance.window")

            // Always listed, so search finds them; they apply to the Minimal window only.
            Group {
                RowSeparator()
                DetailRow(title: "Bar position", caption: "Where the Minimal window’s bar floats.") {
                    SegmentedControl(items: Self.edges, selection: settings.minimalBarEdge) {
                        settings.minimalBarEdge = $0
                    }
                }
                .settingsAnchor("appearance.minimalBar")

                RowSeparator()
                DetailRow(
                    title: "Hide bar",
                    caption: "Move the pointer to the edge of the window to show the bar."
                ) {
                    SettingsMenu(options: Self.hidingChoices, selection: $settings.minimalBarHiding)
                }
                .settingsAnchor("appearance.minimalBarAutoHide")
            }
            .disabled(settings.windowStyle != .minimal)

            RowSeparator()
            DetailRow(
                title: "Shadow",
                caption: "Turning it off also removes the thin outline macOS draws around the window."
            ) {
                SettingsToggle($settings.windowShadow)
            }
            .settingsAnchor("appearance.windowShadow")

            RowSeparator()
            DetailRow(title: "Border", caption: "A line around the edge of the window. It follows the corners.") {
                HStack(spacing: 8) {
                    if settings.windowBorder == .custom {
                        ColorPicker(String(localized: "Border color"), selection: borderColor, supportsOpacity: false)
                            .labelsHidden()
                            .accessibilityLabel(Text("Border color"))
                    }
                    SettingsMenu(options: Self.borderChoices, selection: $settings.windowBorder)
                }
            }
            .settingsAnchor("appearance.windowBorder")

            RowSeparator()
            AppearanceLayoutSection(settings: settings, part: .window)
        }
    }
}

/// A drawn miniature of a window style: a sidebar and toolbar beside the page, or the page with a floating bar.
struct WindowStyleThumbnail: View {
    let style: BrowserWindowStyle

    var body: some View {
        let page = RoundedRectangle(cornerRadius: 4, style: .continuous)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.Wash.faint)
            switch style {
            case .standard:
                HStack(spacing: 4) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<4, id: \.self) { _ in
                            Capsule().fill(Theme.Wash.emphasis).frame(width: 22, height: 4)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.leading, 6)
                    VStack(spacing: 4) {
                        Capsule().fill(Theme.Wash.emphasis).frame(width: 40, height: 6)
                            .frame(maxWidth: .infinity)
                        page.fill(Theme.windowBackground)
                    }
                    .padding(.top, 4)
                    .padding([.trailing, .bottom], 4)
                }
            case .minimal:
                page.fill(Theme.windowBackground)
                    .padding(4)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(Theme.Wash.emphasis).frame(width: 52, height: 8).padding(.bottom, 9)
                    }
            }
        }
        .accessibilityHidden(true)
    }
}
