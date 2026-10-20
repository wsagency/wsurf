// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The shape a theme gives the chrome: how the page and marked rows are edged, how round corners are, and whether
/// loaded tabs keep their favicon colors. Rows and the page observe only this value, so a color or brightness change
/// does not redraw their shapes, and a theme switch reassigns it only when it differs.
struct ThemeShape: Equatable {
    var pageFrame = FrameStyle.standard
    var rowFrame = FrameStyle.standard
    var cornerScale: CGFloat = 1
    var colorsFavicons = false

    init() {}

    init(_ adjustment: ThemeAdjustment) {
        pageFrame = adjustment.pageFrame
        rowFrame = adjustment.rowFrame
        cornerScale = CGFloat(adjustment.cornerScale)
        colorsFavicons = adjustment.loadedFavicons == .color
    }

    /// Half the shortest sidebar row. A larger radius would leave a row no straight edge on its ends.
    static let rowRadiusLimit: CGFloat = 12

    /// The radius of sidebar rows, their highlights and folder outlines, from the unscaled `base`.
    func rowRadius(_ base: CGFloat) -> CGFloat {
        min(base * cornerScale, Self.rowRadiusLimit)
    }

    /// The radius of the page, the side panel and split panes. It never rounds more than the window's own corner.
    func pageRadius(_ base: CGFloat, window: CGFloat) -> CGFloat {
        min(base * cornerScale, window)
    }

    /// The page edge that is drawn. Increase Contrast asks for firm edges, so a page without a frame gets the thin one.
    func pageFrame(contrast: ColorSchemeContrast) -> FrameStyle {
        contrast == .increased && pageFrame == .none ? .hairline : pageFrame
    }
}
