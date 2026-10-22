// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI
import Testing

@testable import WSurf

@MainActor
struct AppearancePickerFitTests {
    private func widthTaken(_ view: some View, proposing width: CGFloat) -> CGFloat {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: 900)
        renderer.scale = 1
        return renderer.nsImage?.size.width ?? 0
    }

    @Test func theMaterialPickerFitsIntoANarrowPage() {
        let narrow = AppearanceThumbnailMetrics.width + 20
        let picker = SegmentedControl(
            items: [
                .init(value: ThemeMaterial.plain, label: "Plain"),
                .init(value: ThemeMaterial.glass, label: "Glass"),
            ],
            selection: .plain,
            onSelect: { _ in }
        )

        #expect(widthTaken(picker, proposing: narrow) <= narrow)
    }

    private func sizeTaken(_ view: some View, proposing width: CGFloat) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: 2000)
        renderer.scale = 1
        return renderer.nsImage?.size ?? .zero
    }

    private func gallery(mode: AppearanceMode = .system) -> ThemeGallery {
        ThemeGallery(
            themes: ThemeCatalog.builtIn + [ThemeDefinition(id: "mine", name: "Mine", basedOn: "nord", ground: .solid)],
            selection: "standard", mode: mode, adjustments: [:], onSelect: { _ in }
        )
    }

    @Test(arguments: [AppearanceMode.system, .light, .dark])
    func theThemeCardsWrapIntoANarrowPage(mode: AppearanceMode) {
        let narrow = AppearanceThumbnailMetrics.width + 20

        #expect(sizeTaken(gallery(mode: mode), proposing: narrow).width <= narrow)
    }

    @Test func theThemeCardsShareRowsWhenThereIsRoom() {
        let narrow = AppearanceThumbnailMetrics.width + 20
        let roomy = AppearanceThumbnailMetrics.width * 4 + AppearanceThumbnailMetrics.spacing * 3

        let wide = sizeTaken(gallery(), proposing: roomy)
        #expect(wide.width <= roomy)
        #expect(wide.height < sizeTaken(gallery(), proposing: narrow).height / 2)
    }
}
