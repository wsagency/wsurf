// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The micro window's bar: full width and flush with the top edge, as tall as the band the traffic lights are centred in, so
/// the native window buttons sit on it. The middle is the same Ask surface as the toolbar's, so it carries the address, the
/// assistant, and the badges, among them the one that moves the page back to the main window.
struct MicroBar: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.windowControlsInset) private var windowControlsInset

    private var ground: NSColor {
        LoomChrome.sampledColor(
            ChromeBand.measuredColor(browser: browser, coordinator: coordinator),
            scheme: scheme,
            isFloating: true
        )
    }

    private var floatHelp: LocalizedStringResource {
        coordinator.floatsOnTop ? "Stop Floating on Top" : "Float on Top"
    }

    var body: some View {
        let isLight = PageInk.isLight(ground, scheme: scheme)

        HStack(spacing: 4) {
            // The window buttons are drawn by the window, over this space.
            Color.clear.frame(width: windowControlsInset - 4)

            ToolbarNavigationControls(browser: browser, coordinator: coordinator)

            AskSurface(placement: .toolbar, browser: browser, coordinator: coordinator)
                .holdsWindowStillOnHover()

            AudioIndicatorButton(coordinator: coordinator, style: .bar, listEdge: .bottom)

            ToolbarButton(
                symbol: coordinator.floatsOnTop ? "square.3.layers.3d.top.filled" : "square.3.layers.3d",
                enabled: true,
                isOn: coordinator.floatsOnTop,
                help: String(localized: floatHelp)
            ) {
                coordinator.floatsOnTop.toggle()
            }
            .accessibilityLabel(Text(floatHelp))
        }
        .padding(.horizontal, 4)
        .frame(height: IslandBar.height)
        .background {
            // The theme's floating ground, opaque under Reduce Transparency and Increase Contrast. Dragging it moves the window.
            ZStack {
                LoomFloatingFill(
                    sampledPageColor: ChromeBand.pageColor(browser: browser, coordinator: coordinator),
                    settings: BrowserSettings.application
                )
                WindowDragArea()
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Theme.chrome(GlassPolicy.borderOpacity(contrast: contrast)))
                    .frame(height: contrast == .increased ? 1 : 0.5)
            }
        }
        .environment(\.chromeIsLight, isLight)
        .environment(\.chromeWash, .of(ground, isLight: isLight))
        .environment(\.windowColorScheme, scheme)
        .environment(\.colorScheme, isLight ? .light : .dark)
        .animation(nil, value: isLight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Toolbar"))
    }
}
