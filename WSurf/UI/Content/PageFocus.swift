// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

extension View {
    /// A click on this native page moves keyboard focus off the toolbar. A click inside the control that
    /// already has focus leaves it alone, so editing and search fields keep their caret.
    func takesFocusOnClick() -> some View {
        modifier(TakesFocusOnClick())
    }
}

private struct TakesFocusOnClick: ViewModifier {
    @State private var anchor = PageFocusAnchor()

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { anchor.view?.takeFocus(at: $0.location) })
            .background(PageFocusView(anchor: anchor))
    }
}

private final class PageFocusAnchor {
    weak var view: PageFocusNSView?
}

private struct PageFocusView: NSViewRepresentable {
    let anchor: PageFocusAnchor

    func makeNSView(context: Context) -> PageFocusNSView {
        let view = PageFocusNSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: PageFocusNSView, context: Context) {
        anchor.view = nsView
    }
}

/// Takes focus in the window that holds the page, never the key window: a second window may be key.
final class PageFocusNSView: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }

    /// Click focus is programmatic; the anchor has no focus ring, so Tab must not stop on it.
    override var canBecomeKeyView: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func takeFocus(at location: CGPoint) {
        guard let window else { return }
        if var responder = window.firstResponder as? NSView, responder !== self {
            if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
                responder = field
            }
            let point = convert(CGPoint(x: location.x, y: isFlipped ? location.y : bounds.height - location.y), to: nil)
            if responder.convert(responder.bounds, to: nil).contains(point) {
                return
            }
        }
        window.makeFirstResponder(self)
    }
}
