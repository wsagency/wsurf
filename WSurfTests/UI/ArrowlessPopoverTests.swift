// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import Testing

@testable import WSurf

/// `ArrowlessPopover` sets two private AppKit settings, each behind `responds(to:)`. When AppKit stops answering to
/// either, the popover must still open its content and behave as a normal popover.
@MainActor
struct ArrowlessPopoverTests {
    /// An `NSPopover` that does not know the private anchor-hiding setting.
    private final class PopoverWithoutPrivateSettings: NSPopover {
        nonisolated override func responds(to aSelector: Selector!) -> Bool {
            if aSelector == Selector(("setShouldHideAnchor:")) {
                return false
            }
            return super.responds(to: aSelector)
        }
    }

    private func makeWindow() -> (NSWindow, NSView) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let anchor = NSView(frame: NSRect(x: 100, y: 100, width: 28, height: 28))
        content.addSubview(anchor)
        window.contentView = content
        window.orderFront(nil)
        return (window, anchor)
    }

    @Test func thePopoverOpensItsContentWithoutThePrivateSettings() async throws {
        let (window, anchor) = makeWindow()
        defer { window.close() }
        let popover = PopoverWithoutPrivateSettings()
        #expect(!popover.responds(to: Selector(("setShouldHideAnchor:"))))
        let coordinator = ArrowlessPopoverAnchor<Text>.Coordinator(popover: popover)
        coordinator.alignment = .leading(width: 280)
        coordinator.hosting.rootView = AnyView(Text(verbatim: "Attach").frame(width: 280, height: 40))

        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)

        #expect(await waitUntil { popover.isShown })
        #expect(coordinator.hosting.view.window != nil, "the content is presented")
        popover.close()
        #expect(await waitUntil { !popover.isShown })
    }

    @Test func aWindowThatDoesNotKnowTheAnchorPointIsLeftAlone() {
        let plain = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        plain.isReleasedWhenClosed = false
        #expect(!plain.responds(to: Selector(("setAnchorPoint:"))), "the premise: an ordinary window")
        let coordinator = ArrowlessPopoverAnchor<Text>.Coordinator()
        coordinator.alignment = .leading(width: 280)

        coordinator.pinGrowOrigin(in: plain)
        coordinator.pinGrowOrigin(in: nil)
    }
}
