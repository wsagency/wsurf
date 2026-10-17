// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// One card per theme: built-in themes in catalog order, then the saved ones. In System mode a card shows the
/// light and dark appearance side by side.
struct ThemeGallery: View {
    let themes: [ThemeDefinition]
    let selection: String
    let mode: AppearanceMode
    let adjustments: [String: ThemeAdjustment]
    let onSelect: (String) -> Void

    var body: some View {
        LazyVGrid(columns: AppearanceThumbnailMetrics.columns, spacing: AppearanceThumbnailMetrics.spacing) {
            ForEach(themes) { theme in
                ThemeCard(
                    theme: theme,
                    adjustment: adjustments[theme.id] ?? ThemeAdjustment(),
                    mode: mode,
                    isSelected: theme.id == selection
                ) {
                    onSelect(theme.id)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ThemeCard: View {
    let theme: ThemeDefinition
    let adjustment: ThemeAdjustment
    let mode: AppearanceMode
    let isSelected: Bool
    let action: () -> Void

    private var schemes: [ColorScheme] {
        switch mode {
        case .system:
            [.light, .dark]
        case .light:
            [.light]
        case .dark:
            [.dark]
        }
    }

    var body: some View {
        PreviewChoiceCard(verbatim: theme.name, isSelected: isSelected, action: action) {
            ZStack(alignment: .leading) {
                ForEach(Array(schemes.enumerated()), id: \.offset) { index, scheme in
                    ThemeThumbnailWindow(palette: ThemeThumbnailPalette(theme, adjustment: adjustment, scheme: scheme))
                        .frame(
                            width: AppearanceThumbnailMetrics.width,
                            height: AppearanceThumbnailMetrics.height
                        )
                        .clipShape(
                            Slice(
                                start: CGFloat(index) / CGFloat(schemes.count),
                                end: CGFloat(index + 1) / CGFloat(schemes.count)
                            )
                        )
                }
            }
        }
        .accessibilityLabel(mode == .system ? Text("\(theme.name), light and dark") : Text(verbatim: theme.name))
    }
}
