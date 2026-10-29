// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The window border (`WindowBorder`): a 1 pt line on the outermost points of the window, above everything in it. It takes
/// the continuous corner that `BrowserHost` clips the content to, so the line follows that corner exactly. It never takes
/// a click. `BrowserHost` adds it last to the content view; anything added after it would cover the line.
final class WindowOutlineView: NSView {
    /// The line drawn now. None hides the view.
    private(set) var border = WindowBorder.none
    private var customRGB = WindowBorder.defaultColor
    private var increasesContrast = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerCurve = .continuous
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    /// Draws `border` with `cornerRadius`. `customRGB` is the colour of Custom; `increasesContrast` makes Subtle firmer.
    func apply(border: WindowBorder, customRGB: UInt32, increasesContrast: Bool, cornerRadius: CGFloat) {
        self.border = border
        self.customRGB = customRGB
        self.increasesContrast = increasesContrast
        layer?.cornerRadius = cornerRadius
        isHidden = border == .none
        refreshColor()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColor()
    }

    /// A layer's border colour is a fixed value, so a colour that follows light and dark is resolved in this view's own
    /// appearance, now and again whenever that appearance changes.
    private func refreshColor() {
        guard border != .none else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = lineColor.cgColor
        }
    }

    /// Subtle is the page's Thin edge colour. Accent is the theme's accent in this appearance.
    private var lineColor: NSColor {
        switch border {
        case .none:
            .clear
        case .subtle:
            NSColor(Theme.chrome(GlassPolicy.borderOpacity(contrast: increasesContrast ? .increased : .standard)))
        case .accent:
            NSColor(Theme.accent)
        case .custom:
            NSColor(Color(hex: customRGB))
        }
    }
}
