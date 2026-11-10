// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import IOSurface
import os
import QuartzCore

/// Where the frames of out-of-process Chromium browsers land (D4, `plans/d4-phase2-plan.md` §1 item 4). The service sends one
/// IOSurface per frame; the frames connection's queue hands it here and it becomes a layer's `contents`. WSurf's main thread
/// does no frame work.
///
/// Two sides, and they never write the same property:
/// - **The frames queue** (`framesQueue`, serial, `userInteractive`) sets `contents` on the page layer and `contents`, `frame` and
///   `isHidden` on the popup layer, each call inside an explicit `CATransaction` with actions disabled. It never adds or removes
///   a layer. A layer changed on a GCD thread outside an explicit transaction opens an implicit one that is never committed in
///   time, and the explicit ones after it nest inside it: a popup then reaches the screen late or not at all (spike b17-b18).
///   The only reads of main-owned state are the page layer's `bounds` and `contentsAreFlipped()`, to place a popup.
/// - **The main thread** makes the popup layer (hidden, at registration, so no layer is ever made on the frames queue), puts it in
///   the tree, owns the page layer's frame, and removes both layers.
///
/// The registry between them is lock-protected. The frames queue changes a layer only while it holds that lock, and `unregister`
/// takes the entry out under it, so once `unregister` has taken the entry no frame can write to either layer again. The lock is
/// never held across a commit.
///
/// Typed API only: decoding the XPC messages belongs to the connection (D4-5).
nonisolated final class ChromiumFrameSink: @unchecked Sendable {
    /// The browser's id on the wire (the spike's `Int64`).
    typealias Browser = Int64

    private nonisolated struct Entry: @unchecked Sendable {
        let page: CALayer
        let popup: CALayer
    }

    private nonisolated struct State: @unchecked Sendable {
        var entries: [Browser: Entry] = [:]
        var framesShown = 0
        var popupFramesShown = 0
        var framesDropped = 0
    }

    /// The queue the frames connection targets, and the only queue `apply` and `applyPopup` may run on.
    let framesQueue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(label: String = "io.wsagency.wsurf.chromium-frames") {
        framesQueue = DispatchQueue(label: label, qos: .userInteractive)
    }

    // MARK: Counters

    /// Page frames applied to a registered browser.
    var framesShown: Int {
        state.withLock { $0.framesShown }
    }
    /// Popup frames applied to a registered browser.
    var popupFramesShown: Int {
        state.withLock { $0.popupFramesShown }
    }
    /// Frames and popup events for a browser that is not registered (closed, or not yet registered).
    var framesDropped: Int {
        state.withLock { $0.framesDropped }
    }

    func isRegistered(browser: Browser) -> Bool {
        state.withLock { $0.entries[browser] != nil }
    }

    /// The browser's popup layer, for tests and for the page's layout code.
    func popupLayer(for browser: Browser) -> CALayer? {
        state.withLockUnchecked { $0.entries[browser]?.popup }
    }

    // MARK: Main thread

    /// Registers the page's layer and gives it its popup layer: made here, hidden, and added as the page layer's sublayer.
    /// Registering a browser again replaces its entry: the old popup layer goes, and the old page layer too unless it is the same one.
    /// The popup's `contentsScale` is the page layer's at this point; later scale changes are the page's to forward (D4-9).
    @MainActor
    func register(browser: Browser, pageLayer: CALayer) {
        let popup = CALayer()
        popup.anchorPoint = .zero
        popup.contentsGravity = .resize
        popup.contentsScale = pageLayer.contentsScale
        popup.zPosition = 1
        popup.isHidden = true
        Self.withoutActions { pageLayer.addSublayer(popup) }
        let old = state.withLockUnchecked { $0.entries.updateValue(Entry(page: pageLayer, popup: popup), forKey: browser) }
        if let old {
            Self.detach(old, keepingPage: old.page === pageLayer)
        }
    }

    /// Removes the browser's page and popup layers from the tree and drops their contents. Frames that arrive afterwards are dropped.
    @MainActor
    func unregister(browser: Browser) {
        guard let entry = state.withLockUnchecked({ $0.entries.removeValue(forKey: browser) }) else { return }
        Self.detach(entry)
    }

    @MainActor
    private static func detach(_ entry: Entry, keepingPage: Bool = false) {
        withoutActions {
            entry.popup.removeFromSuperlayer()
            entry.popup.contents = nil
            if !keepingPage {
                entry.page.removeFromSuperlayer()
                entry.page.contents = nil
            }
        }
    }

    @MainActor
    private static func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Frames queue

    /// A frame: the surface becomes the page layer's `contents`, or the popup layer's when `popup` is set. Frames queue only.
    func apply(surface: IOSurface, browser: Browser, popup: Bool) {
        inTransaction {
            state.withLockUnchecked { state in
                guard let entry = state.entries[browser] else {
                    state.framesDropped += 1
                    return
                }
                if popup {
                    entry.popup.contents = surface
                    state.popupFramesShown += 1
                } else {
                    entry.page.contents = surface
                    state.framesShown += 1
                }
            }
        }
    }

    /// A popup widget (a `<select>` list) was shown, moved or hidden. `rect` is CEF's rectangle in view points with a top-left
    /// origin; it is flipped unless the page layer's contents already are. Frames queue only.
    func applyPopup(browser: Browser, visible: Bool, rect: CGRect) {
        inTransaction {
            state.withLockUnchecked { state in
                guard let entry = state.entries[browser] else {
                    state.framesDropped += 1
                    return
                }
                var frame = rect
                if !entry.page.contentsAreFlipped() {
                    frame.origin.y = entry.page.bounds.height - rect.maxY
                }
                entry.popup.frame = frame
                entry.popup.isHidden = !visible
                if !visible {
                    entry.popup.contents = nil
                }
            }
        }
    }

    private func inTransaction(_ body: () -> Void) {
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(framesQueue))
        #endif
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
