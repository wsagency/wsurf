// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The root of a micro window: the page, and the bar over it that slides down at the top. There is no sidebar, side panel,
/// palette, tab list or onboarding. It never reads `titleStripInset`: a micro window does not enter full screen.
struct MicroWindowView: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @State private var settingsWorkspace: SettingsWorkspace
    @Environment(\.colorScheme) private var scheme

    init(browser: BrowserModel, coordinator: AppCoordinator) {
        self.browser = browser
        self.coordinator = coordinator
        // `ContentArea` shows internal pages through one. A micro window never holds such a page, but it asks for a workspace.
        let workspace = SettingsWorkspace(coordinator: coordinator)
        workspace.onRoute = { [weak coordinator] category in
            coordinator?.routeSettings(to: category)
        }
        _settingsWorkspace = State(initialValue: workspace)
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
