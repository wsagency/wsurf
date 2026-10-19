// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Chooses the Dock icon. The choice is the app's, not a theme's.
struct AppearanceDockIconSection: View {
    @Bindable var settings: BrowserSettings

    var body: some View {
        SettingsSection(
            title: "Dock icon", symbol: "dock.rectangle",
            footnote: "Finder and Applications keep the standard icon. Only Default follows your Mac’s icon and widget style."
        ) {
            DetailRow(caption: "Changes the Dock icon while WSurf is running.", layout: .stacked) {
                LazyVGrid(columns: AppearanceThumbnailMetrics.columns, spacing: AppearanceThumbnailMetrics.spacing) {
                    ForEach(DockIconChoice.allCases, id: \.self) { choice in
                        PreviewChoiceCard(label: choice.label, isSelected: settings.dockIcon == choice) {
                            settings.dockIcon = choice
                        } thumbnail: {
                            DockIconThumbnail(choice: choice)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .settingsAnchor("appearance.dockIcon")
        }
    }
}

private struct DockIconThumbnail: View {
    let choice: DockIconChoice

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.Wash.faint)
            Image(nsImage: choice.image ?? AppIcon.bundle)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(6)
                .accessibilityHidden(true)
        }
    }
}
