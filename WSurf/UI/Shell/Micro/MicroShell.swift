// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// How a micro window is sized, placed and stacked. The numbers are tuning knobs.
nonisolated enum MicroWindowMetrics {
    static let minSize = NSSize(width: 420, height: 240)
    static let defaultSize = NSSize(width: 560, height: 420)
    /// Each new window opens this far right of and below the last one, and this far from the corner of the screen.
    static let cascade: CGFloat = 24
    /// Where the last micro window was, as `NSStringFromRect`, so the next one opens beside it.
    static let lastFrameKey = "wsurf.browser.micro.lastFrame"

    /// A micro window never enters full screen (the green button zooms). While it floats it also joins every desktop and
    /// stays over full-screen apps, like a picture-in-picture window.
    static func collectionBehavior(floating: Bool) -> NSWindow.CollectionBehavior {
        floating ? [.fullScreenAuxiliary, .canJoinAllSpaces] : [.fullScreenNone]
    }

    /// Where a new micro window opens inside `visible`: below and right of `last` by `cascade`, else in the top right corner.
    /// Always fits `visible`.
    static func openingFrame(visible: NSRect, last: NSRect?) -> NSRect {
        let size = NSSize(
            width: min(last?.width ?? defaultSize.width, visible.width),
            height: min(last?.height ?? defaultSize.height, visible.height)
        )
        var origin = NSPoint(x: visible.maxX - size.width - cascade, y: visible.maxY - size.height - cascade)
        if let last {
            origin = NSPoint(x: last.minX + cascade, y: last.maxY - size.height - cascade)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }
}

/// The chrome of the micro window, drawn over the page `MicroWindowView` lays out: a bar that slides down from the top edge
/// with the window buttons while the pointer is at the top (or while there is something to read or answer), and nothing else.
/// When it is down is `MicroReveal`'s to say; this only draws it.
struct MicroShell: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    /// How tall the strip at the top is, while the bar is up, in which the pointer reveals it.
    static let revealBand: CGFloat = 16
    static let hideDelay: Duration = .milliseconds(600)
    static let hostFlash: Duration = .seconds(2)
    /// Where the find bar sits, below the bar's place at the top.
    static let findBarTop = IslandBar.height + 10
    private static let hiddenOffset = IslandBar.height + 8

    /// The truth table of what keeps the bar down. With no address showing, a page can draw a fake browser around itself,
    /// so the real address stays while a prompt asks, a save is offered, or a question waits for an answer.
    static func keepsBar(
        hasPage: Bool, isEditing: Bool, isBusy: Bool, isAsking: Bool, hasSaveOffer: Bool, voiceOver: Bool
    ) -> Bool {
        !hasPage || isEditing || isBusy || isAsking || hasSaveOffer || voiceOver
    }

    /// `keepsBar` for a live window. A page that has no host to show (nothing yet, `about:`, `data:`, a file) counts as no
    /// page: what cannot be told is a reason to keep the bar, never to drop it.
    static func keepsBar(browser: BrowserModel, coordinator: AppCoordinator, isEditing: Bool, voiceOver: Bool) -> Bool {
        let tab = browser.activeTab
        return keepsBar(
            hasPage: host(of: tab?.urlString) != nil,
            isEditing: isEditing,
            // The same as the Minimal bar's `chromeIsBusy`.
            isBusy: coordinator.state == .listening
                || coordinator.statusMessage != nil
                || coordinator.notice != nil
                || coordinator.agentReply.message(inAnchor: browser.activeAnchorID) != nil
                || coordinator.pendingAgentQuestion(inChrome: true) != nil,
            isAsking: coordinator.hasPendingPagePrompt,
            hasSaveOffer: tab.map { $0.autofillSave.current != nil || $0.autofillSave.websiteOffer != nil } ?? false,
            voiceOver: voiceOver
        )
    }

    // ponytail: a text view as first responder means the address (or another chrome field) is being edited; a page's own
    // fields live inside the web view, which is not a text view. The panel (the autofill suggestions, which name the site
    // themselves) is found by what it is, since it says nothing; only a bar that is already down is held by it.
    /// The address field has the keyboard, or a sheet or a panel hangs from the window: the bar stays. No window is a
    /// reason to stay too.
    static func isEditing(in window: NSWindow?) -> Bool {
        guard let window else { return true }
        return window.firstResponder is NSTextView
            || window.attachedSheet != nil
            || window.childWindows?.contains { $0.isVisible && ($0 is NSPanel || $0.className.contains("Popover")) } == true
    }

    /// The host of an address, nil for none: what "another site" is measured on.
    static func host(of address: String?) -> String? {
        address.flatMap { URL(string: $0)?.host()?.lowercased() }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private var reveal: MicroReveal {
        coordinator.microReveal
    }

    private var motion: Animation? {
        reduceMotion ? nil : Theme.Motion.settle
    }

    var body: some View {
        let spacing = BrowserSettings.application.chromeShape.pageSpacing
        ZStack(alignment: .top) {
            MicroRevealSensor(
                zoneHeight: reveal.isRevealed ? IslandBar.height + 8 : Self.revealBand,
                showsWindowControls: reveal.isRevealed,
                onPointerInZone: { reveal.pointer(inZone: $0) }
            )
            .allowsHitTesting(false)

            // The gutter above the page moves the window while the bar is up out of the way, like the Minimal window's.
            WindowDragArea()
                .frame(height: max(spacing, 6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            MicroBar(browser: browser, coordinator: coordinator)
                .offset(y: reveal.isRevealed ? 0 : -Self.hiddenOffset)
                .allowsHitTesting(reveal.isRevealed)
                .accessibilityHidden(!reveal.isRevealed)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(motion, value: reveal.isRevealed)
        .onAppear { reveal.update() }
        .onChange(of: voiceOver) { _, _ in reveal.update() }
    }
}
