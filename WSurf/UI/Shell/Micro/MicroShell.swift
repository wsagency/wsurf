// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation
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

/// Whether the micro bar is down. It is down while the pointer is at the top, for `hostFlash` after the page moves to another
/// site, and while something needs reading or answering; it goes up `hideDelay` after the last of those ends. The traffic
/// lights follow it. Durations are inputs so a test does not wait seconds.
@MainActor
@Observable
final class MicroReveal {
    private(set) var isRevealed = false
    private(set) var isFlashing = false
    @ObservationIgnored private(set) var pointerInZone = false
    /// What keeps the bar down whatever the pointer does. The editing part of it cannot be observed, so it is asked again
    /// every `hideDelay` while the bar waits to go up.
    @ObservationIgnored var keeps: () -> Bool
    @ObservationIgnored let hideDelay: Duration
    @ObservationIgnored let hostFlash: Duration
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var flash: Task<Void, Never>?

    init(
        hideDelay: Duration = MicroShell.hideDelay,
        hostFlash: Duration = MicroShell.hostFlash,
        keeps: @escaping () -> Bool = { false }
    ) {
        self.hideDelay = hideDelay
        self.hostFlash = hostFlash
        self.keeps = keeps
    }

    private var holds: Bool {
        pointerInZone || isFlashing || keeps()
    }

    func pointer(inZone: Bool) {
        pointerInZone = inZone
        update()
    }

    /// Something that keeps the bar changed: bring it down if it now holds, and look again later if it does not.
    func update() {
        if holds {
            isRevealed = true
        }
        if isRevealed {
            scheduleCheck()
        }
    }

    /// Brings the bar down for a moment, as the address command does before the address has the keyboard.
    func show() {
        isRevealed = true
        scheduleCheck()
    }

    /// The page moved to another site: the address shows for `hostFlash`, so a page never has the window to itself.
    func siteChanged() {
        isFlashing = true
        isRevealed = true
        flash?.cancel()
        flash = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hostFlash)
            guard !Task.isCancelled else { return }
            isFlashing = false
            flash = nil
            if holds {
                scheduleCheck()
            } else {
                hide()
            }
        }
        update()
    }

    func stop() {
        check?.cancel()
        flash?.cancel()
        check = nil
        flash = nil
    }

    private func hide() {
        check?.cancel()
        check = nil
        isRevealed = false
    }

    // ponytail: polls every hideDelay while the bar is down and held, because the address having the keyboard is not
    // observable. A notification from the field editor would replace it.
    private func scheduleCheck() {
        check?.cancel()
        check = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hideDelay)
            guard !Task.isCancelled else { return }
            check = nil
            if holds {
                scheduleCheck()
            } else {
                hide()
            }
        }
    }
}

/// The chrome of the micro window, drawn over the page `MicroWindowView` lays out: a bar that slides down from the top edge
/// with the window buttons while the pointer is at the top (or while there is something to read or answer), and nothing else.
struct MicroShell: View {
    let browser: BrowserModel
    let coordinator: AppCoordinator

    @State private var reveal = MicroReveal()
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

    /// `keepsBar` for a live window. `isEditing` is left out of what SwiftUI watches (see `MicroReveal.keeps`).
    static func keepsBar(browser: BrowserModel, coordinator: AppCoordinator, isEditing: Bool, voiceOver: Bool) -> Bool {
        let tab = browser.activeTab
        var isAsking = false
        if let badge = tab?.permissions.badge, case .asking = badge {
            isAsking = true
        }
        return keepsBar(
            hasPage: !(tab?.urlString.isEmpty ?? true),
            isEditing: isEditing,
            // The same as the Minimal bar's `chromeIsBusy`.
            isBusy: coordinator.state == .listening
                || coordinator.statusMessage != nil
                || coordinator.notice != nil
                || coordinator.agentReply.message(inAnchor: browser.activeAnchorID) != nil
                || coordinator.pendingAgentQuestion(inChrome: true) != nil,
            isAsking: isAsking,
            hasSaveOffer: tab.map { $0.autofillSave.current != nil || $0.autofillSave.websiteOffer != nil } ?? false,
            voiceOver: voiceOver
        )
    }

    // ponytail: a text view as first responder means the address (or another chrome field) is being edited; a page's own
    // fields live inside the web view, which is not a text view. The popover is found by its private class name.
    /// The address field has the keyboard, or a sheet or a popover from the bar is open: the bar stays.
    static func isEditing(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.firstResponder is NSTextView
            || window.attachedSheet != nil
            || window.childWindows?.contains { $0.className.contains("Popover") } == true
    }

    /// The host of an address, nil for none: what "another site" is measured on.
    static func host(of address: String?) -> String? {
        address.flatMap { URL(string: $0)?.host()?.lowercased() }
    }

    private var motion: Animation? {
        reduceMotion ? nil : Theme.Motion.settle
    }

    private var currentHost: String? {
        Self.host(of: browser.activeTab?.urlString)
    }

    /// What SwiftUI can watch of what keeps the bar.
    private var keepsObserved: Bool {
        Self.keepsBar(browser: browser, coordinator: coordinator, isEditing: false, voiceOver: voiceOver)
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
        .onAppear {
            reveal.keeps = { [weak browser, weak coordinator] in
                guard let browser, let coordinator else { return false }
                return Self.keepsBar(
                    browser: browser,
                    coordinator: coordinator,
                    isEditing: Self.isEditing(in: coordinator.nativeWindow),
                    voiceOver: NSWorkspace.shared.isVoiceOverEnabled
                )
            }
            // A window that opens on a page shows where it is for a moment; one with no page waits for its address.
            if browser.activeTab?.urlString.isEmpty ?? true {
                reveal.update()
            } else {
                reveal.siteChanged()
            }
        }
        .onChange(of: currentHost) { _, _ in reveal.siteChanged() }
        .onChange(of: keepsObserved) { _, _ in reveal.update() }
        .onChange(of: coordinator.addressBarFocusToken) { _, _ in reveal.show() }
        .onDisappear { reveal.stop() }
    }
}
