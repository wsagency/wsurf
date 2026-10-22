// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The shape a theme gives the chrome: how the page and marked rows are edged, how round corners are, whether
/// loaded tabs keep their favicon colors, how far the page and the sidebar sit from the window, and how roomy rows are. Rows and the page observe only this value, so a color or brightness change
/// does not redraw their shapes, and a theme switch reassigns it only when it differs.
struct ThemeShape: Equatable {
    var pageFrame = FrameStyle.standard
    var rowFrame = FrameStyle.standard
    var cornerScale: CGFloat = 1
    var colorsFavicons = false
    var pageSpacing = LoomChrome.canvasInset
    var sidebarMargin = LoomChrome.canvasInset
    var rowPadding: CGFloat = 9
    var tabIconSize: CGFloat = 16

    init() {}

    init(_ adjustment: ThemeAdjustment) {
        pageFrame = adjustment.pageFrame
        rowFrame = adjustment.rowFrame
        cornerScale = CGFloat(adjustment.cornerScale)
        colorsFavicons = adjustment.loadedFavicons == .color
        pageSpacing = CGFloat(adjustment.pageSpacing)
        sidebarMargin = CGFloat(adjustment.sidebarMargin)
        rowPadding = CGFloat(adjustment.rowPadding)
        tabIconSize = CGFloat(adjustment.tabIconSize)
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

    /// The corner of the page, the side panel and split panes in a window of corner `window`. A page flush with the
    /// window is square: the window's own corner rounds it where the two meet.
    func canvasRadius(window: CGFloat) -> CGFloat {
        pageSpacing == 0 ? 0 : pageRadius(Theme.Radius.nested(in: window, inset: pageSpacing), window: window)
    }

    /// The page edge that is drawn. Increase Contrast asks for firm edges, so a page without a frame gets the thin one.
    func pageFrame(contrast: ColorSchemeContrast) -> FrameStyle {
        contrast == .increased && pageFrame == .none ? .hairline : pageFrame
    }
}
