// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Observation
import SwiftUI

/// What the panel's view reads and the controller sets: which way Ask opens, and whether it has extras to show.
@Observable
final class FloatingBarModel {
    /// Frozen while Ask has extras, so the bar never jumps under the person.
    var opensUpward = true
    var hasExtras = false
}

/// The panel's content: the Minimal bar, in the same environment as the window's own views.
struct FloatingBarView: View {
    let coordinator: AppCoordinator
    let model: FloatingBarModel
    let onExtras: (Bool) -> Void

    var body: some View {
        IslandBar(
            browser: coordinator.browser,
            coordinator: coordinator,
            // The bar's edge decides which way Ask, audio and downloads open: a bar low on its screen opens upward.
            edge: model.opensUpward ? .bottom : .top
        )
        .padding(FloatingBarMetrics.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.opensUpward ? .bottom : .top)
        .onPreferenceChange(AskExtrasKey.self) { onExtras($0) }
        .browserWindowEnvironment(coordinator)
    }
}

/// Owns the floating toolbar panel of one browser window: it exists exactly while `AppCoordinator.barFloats`, as a child of the
/// window. Nothing runs per frame or per navigation: the panel is made and removed when the placement or the full-screen state
/// changes, moved once when a drag ends, and resized once when Ask opens or closes its extras. It is the delegate of the panel
/// alone; the window's own delegate is `BrowserHost`, which tells this of the window's key changes.
@MainActor
final class FloatingBarController: NSObject, NSWindowDelegate {
    private weak var coordinator: AppCoordinator?
    private weak var window: NSWindow?
    private(set) var panel: FloatingBarPanel?
    private var keyUnit = KeyUnit()
    let model = FloatingBarModel()
    private var isStarted = false
    private var isStopped = false

    /// Whether the panel follows what Ask reports. A test with no Ask results on screen turns it off to drive `extrasChanged`
    /// itself: laying the panel out again would report none and shrink it back.
    var listensToAsk = true

    /// Whether a window is key. A test host in the background has no key window and sets what it needs here.
    var isKey: (NSWindow) -> Bool = { $0.isKeyWindow }

    init(coordinator: AppCoordinator, window: NSWindow) {
        self.coordinator = coordinator
        self.window = window
    }

    private func keyed(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return isKey(window)
    }

    // MARK: - Panel

    /// The window is on screen: start watching what decides the panel, and bring it up if the bar floats.
    func windowDidShow() {
        if !isStarted {
            isStarted = true
            observe()
        }
        sync()
    }

    /// The window is closing: the panel goes with it.
    func stop() {
        isStopped = true
        hide()
    }

    /// The panel exists exactly when the bar floats. Idempotent.
    func sync() {
        guard isStarted, !isStopped, let coordinator, let window else { return }
        if coordinator.barFloats {
            show(in: window, for: coordinator)
        } else {
            hide()
        }
    }

    private func observe() {
        guard !isStopped else { return }
        withObservationTracking {
            _ = coordinator?.barFloats
            _ = coordinator?.settings.minimalBarFloatOffset
            _ = coordinator?.settings.showsFullAddress
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !isStopped else { return }
                observe()
                sync()
            }
        }
    }

    private static var visibleFrames: [CGRect] {
        NSScreen.screens.map(\.visibleFrame)
    }

    private func barSize(_ coordinator: AppCoordinator, _ window: NSWindow) -> CGSize {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? 1_000
        // The full address (or a developer-mode page) makes the in-window bar wider; the panel follows the setting only, so
        // that a navigation never resizes it.
        let width = FloatingBarMetrics.barWidth(fullAddress: coordinator.settings.showsFullAddress, visibleWidth: visible)
        return CGSize(width: width, height: IslandBar.height)
    }

    /// Where the bar belongs: its saved place, else the window's bar edge, kept on a screen.
    private func savedRow(_ coordinator: AppCoordinator, _ window: NSWindow, size: CGSize) -> CGRect {
        let settings = coordinator.settings
        let wanted = settings.minimalBarFloatOffset.map { FloatingBarMetrics.row(at: $0, size: size, in: window.frame) }
            ?? FloatingBarMetrics.defaultRow(
                parent: window.frame, width: size.width, edge: settings.minimalBarEdge,
                gap: IslandBar.edgeGap(pageSpacing: settings.chromeShape.pageSpacing)
            )
        return FloatingBarMetrics.clamped(row: wanted, in: Self.visibleFrames)
    }

    private func show(in window: NSWindow, for coordinator: AppCoordinator) {
        let size = barSize(coordinator, window)
        if let panel {
            // Another window's drag saved a place, or the width changed. Without a saved place the bar stays where it is.
            var row = currentRow(of: panel)
            row.size = size
            if coordinator.settings.minimalBarFloatOffset != nil {
                row = savedRow(coordinator, window, size: size)
            }
            apply(row, to: panel)
            return
        }
        let row = savedRow(coordinator, window, size: size)
        model.hasExtras = false
        model.opensUpward = FloatingBarMetrics.opensUpward(row: row, in: Self.visibleFrames)

        let panel = FloatingBarPanel(frame: FloatingBarMetrics.panelFrame(row: row, opensUpward: model.opensUpward, hasExtras: false))
        panel.delegate = self
        panel.onDragEnd = { [weak self] in self?.dragEnded() }
        panel.appearance = window.appearance
        panel.level = window.level
        let hosting = NSHostingView(rootView: FloatingBarView(
            coordinator: coordinator, model: model,
            onExtras: { [weak self] in
                if self?.listensToAsk == true {
                    self?.extrasChanged($0)
                }
            }
        ))
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
        keyUnit.seed(isKey: keyed(window))
        window.addChildWindow(panel, ordered: .above)
        if window.isVisible {
            panel.orderFront(nil)
        }
    }

    private func hide() {
        guard let panel else { return }
        let wasKey = keyed(panel)
        panel.delegate = nil
        panel.onDragEnd = nil
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        model.hasExtras = false
        keyUnit.seed(isKey: wasKey || keyed(window))
        if wasKey, !isStopped {
            window?.makeKey()
        }
    }

    private func currentRow(of panel: FloatingBarPanel) -> CGRect {
        FloatingBarMetrics.row(inPanel: panel.frame, opensUpward: model.opensUpward, hasExtras: model.hasExtras)
    }

    private func apply(_ row: CGRect, to panel: FloatingBarPanel) {
        let frame = FloatingBarMetrics.panelFrame(row: row, opensUpward: model.opensUpward, hasExtras: model.hasExtras)
        if !panel.frame.equalTo(frame) {
            panel.setFrame(frame, display: false)
        }
        if let level = window?.level, panel.level != level {
            panel.level = level
        }
    }

    // MARK: - Moving and Ask

    /// A drag ended: keep the bar on a screen, say which way Ask opens from here, and save the place, once.
    private func dragEnded() {
        guard let panel, let window, let coordinator else { return }
        let screens = Self.visibleFrames
        let row = FloatingBarMetrics.clamped(row: currentRow(of: panel), in: screens)
        if !model.hasExtras {
            model.opensUpward = FloatingBarMetrics.opensUpward(row: row, in: screens)
        }
        apply(row, to: panel)
        coordinator.settings.minimalBarFloatOffset = FloatingBarMetrics.offset(of: row, in: window.frame)
    }

    /// The window moved to another display, or opened at its final size: the bar stays inside a screen, at its saved place.
    func windowDidSettle() {
        guard let panel, let coordinator, let window else { return }
        let row = savedRow(coordinator, window, size: barSize(coordinator, window))
        if !model.hasExtras {
            model.opensUpward = FloatingBarMetrics.opensUpward(row: row, in: Self.visibleFrames)
        }
        apply(row, to: panel)
    }

    /// Ask opened or closed its extras: the panel grows toward the middle of the screen, or shrinks back, with the row's own
    /// edge fixed. One resize each time; the direction is worked out again once the extras are gone.
    func extrasChanged(_ hasExtras: Bool) {
        guard let panel, hasExtras != model.hasExtras else { return }
        let row = currentRow(of: panel)
        model.hasExtras = hasExtras
        if !hasExtras {
            model.opensUpward = FloatingBarMetrics.opensUpward(row: row, in: Self.visibleFrames)
        }
        apply(row, to: panel)
    }

    /// For ⌘L: the address is in the panel, which has to be key to take what is typed.
    func makeKey() {
        panel?.makeKey()
    }

    // MARK: - The window and its panel are one key unit

    /// The window or the panel became key. The app hears of it when the unit was not key already: the keyboard moving between
    /// the two is not news. Without a panel it always hears, as before.
    func memberBecameKey() {
        let news = keyUnit.becameKey()
        if panel == nil || news {
            coordinator?.windowDidBecomeKey()
        }
    }

    /// The window or the panel resigned key. Without a panel the app hears now, as before. With one, a run-loop turn later and
    /// only if neither has the keyboard by then: it may only have moved from the window to the panel, and hearing of that would
    /// suspend hold-to-talk while the address is typed.
    func memberResignedKey() {
        guard panel != nil else {
            keyUnit.seed(isKey: false)
            coordinator?.windowDidResignKey()
            return
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.settleKey() }
        }
    }

    private func settleKey() {
        guard keyUnit.resigned(windowIsKey: keyed(window), panelIsKey: keyed(panel)) else { return }
        coordinator?.windowDidResignKey()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        memberBecameKey()
    }

    func windowDidResignKey(_ notification: Notification) {
        memberResignedKey()
    }
}

/// The environment every view of a browser window is drawn in, shared by the window's root view and the floating toolbar.
struct BrowserWindowEnvironment: ViewModifier {
    let coordinator: AppCoordinator

    func body(content: Content) -> some View {
        content
            .disclosureGroupStyle(ClickableDisclosureStyle())
            .writingToolsAffordanceVisibility(.hidden)
            .environment(\.windowControlsInset, coordinator.windowControlsInset)
            .environment(\.titleStripInset, coordinator.titleStripInset)
            .environment(\.profileFavicons, coordinator.browser.context.favicons)
            .environment(\.assistantProviderID, coordinator.selectedProvider.id)
    }
}

extension View {
    func browserWindowEnvironment(_ coordinator: AppCoordinator) -> some View {
        modifier(BrowserWindowEnvironment(coordinator: coordinator))
    }
}
