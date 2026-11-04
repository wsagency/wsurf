// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// The root of a micro window: the page, and the bar over it that slides down at the top. There is no sidebar, side panel,
/// palette, tab list or onboarding. It never reads `titleStripInset`: a micro window does not enter full screen.
struct MicroWindowView: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    /// `ContentArea` shows internal pages through one. A micro window never holds such a page, but it asks for a workspace.
    @State private var lazySettingsWorkspace = LazySettingsWorkspace()
    @Environment(\.colorScheme) private var scheme

    private var settingsWorkspace: SettingsWorkspace {
        lazySettingsWorkspace.workspace(for: coordinator)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ContentArea(
                browser: browser,
                coordinator: coordinator,
                settingsWorkspace: settingsWorkspace,
                canvasTrailingInset: 0,
                isFullHeight: true,
                findBarTop: MicroShell.findBarTop
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            MicroShell(browser: browser, coordinator: coordinator)
        }
        .background {
            LoomAmbientBackdrop(
                sampledPageColor: ChromeBand.pageColor(browser: browser, coordinator: coordinator),
                settings: BrowserSettings.application
            )
        }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .global)
        } action: { frame in
            coordinator.noteShellFrame(frame)
        }
        .modifier(TranslationDownloadHost(downloads: coordinator.translationDownloads))
        .tint(Theme.systemAccent)
        .environment(\.profileFavicons, coordinator.context.favicons)
        .environment(\.assistantProviderID, coordinator.selectedProvider.id)
        .environment(\.chromeIsLight, scheme == .light)
        .environment(\.chromeWash, .of(nil, isLight: scheme == .light))
        .environment(\.windowColorScheme, scheme)
    }
}
