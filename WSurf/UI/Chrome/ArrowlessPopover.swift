// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import SwiftUI

/// Where the popover grows from. Linen also has a trailing alignment, which WSurf has no caller for.
enum ArrowlessPopoverAlignment {
    case center
    case leading(width: CGFloat)
}

extension View {
    func arrowlessPopover<Content: View>(
        isPresented: Binding<Bool>,
        alignment: ArrowlessPopoverAlignment = .center,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(ArrowlessPopoverAnchor(isPresented: isPresented, alignment: alignment, content: content))
    }
}

struct ArrowlessPopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let alignment: ArrowlessPopoverAlignment
    let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        let environment = context.environment
        coordinator.dismiss = { if isPresented { isPresented = false } }
        coordinator.alignment = alignment
        coordinator.hosting.rootView = AnyView(
            content().transformEnvironment(\.self) { $0 = environment }
        )
        let popover = coordinator.popover
        if isPresented, !popover.isShown, view.window != nil {
            popover.appearance = NSAppearance(named: environment.chromeIsLight ? .aqua : .darkAqua)
            let anchor = positioningView(in: view, coordinator: coordinator)
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if !isPresented, popover.isShown {
            popover.close()
        }
    }

    private func positioningView(in view: NSView, coordinator: Coordinator) -> NSView {
        let originX: CGFloat
        let width: CGFloat
        switch alignment {
        case .center:
            return view
        case .leading(let menuWidth):
            originX = 0
            width = menuWidth
        }
        let anchor = coordinator.alignedAnchor
        anchor.frame = CGRect(x: originX, y: 0, width: width, height: view.bounds.height)
        if anchor.superview !== view {
            view.addSubview(anchor)
        }
        return anchor
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.popover.close()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        let popover: NSPopover
        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        let alignedAnchor = NSView()
        var dismiss: () -> Void = {}
        var alignment = ArrowlessPopoverAlignment.center

        /// A test passes a popover that answers to neither private selector.
        init(popover: NSPopover = NSPopover()) {
            self.popover = popover
            super.init()
            hosting.sizingOptions = .preferredContentSize
            popover.contentViewController = hosting
            popover.behavior = .transient
            popover.delegate = self
            let hidesAnchor = Selector(("setShouldHideAnchor:"))
            if popover.responds(to: hidesAnchor) {
                popover.setValue(true, forKey: "shouldHideAnchor")
            }
        }

        func popoverWillShow(_ notification: Notification) {
            pinGrowOrigin(in: hosting.view.window)
        }

        func popoverWillClose(_ notification: Notification) {
            pinGrowOrigin(in: hosting.view.window)
        }

        func popoverDidClose(_ notification: Notification) {
            dismiss()
        }

        func pinGrowOrigin(in window: NSWindow?) {
            guard let window,
                  window.responds(to: Selector(("setAnchorPoint:")))
            else { return }
            let frame = hosting.view.convert(hosting.view.bounds, to: nil)
            let originX: CGFloat
            switch alignment {
            case .center:
                return
            case .leading:
                originX = frame.minX
            }
            window.setValue(NSPoint(x: originX, y: 0), forKey: "anchorPoint")
        }
    }
}
