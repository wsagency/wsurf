// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import os

// D4-41 (out-of-process Chromium, phase 5): what a client of the accessibility API (VoiceOver, or any other) finds in a page that runs
// in the Chromium service. The view is not an element itself (a plain NSView is ignored, and its children are promoted): it answers
// `accessibilityChildren` and `accessibilityHitTest` from the browser's mirror, whose root is an AXWebArea. (The page's own focus is not
// mirrored before D4-42, so the focused element is AppKit's default.) Nothing is added to `ChromiumPage` (plan C1a), so the accessibility of a page in process is what it was.
//
// The first query by any client turns Chromium's tree on (`ChromiumRemote.noteAccessibilityQuery`, plan Q12), and the tree arrives a
// moment later: until then the view has no children, and a layout-changed notification tells the client to ask again.

/// The part of the content view that knows its page's browser: where the mirror is, what a point or a press means in view points, and
/// when to note a query.
@MainActor
final class ChromiumRemoteAccessibilityHost {
    weak var view: ChromiumRemoteContentView?
    weak var page: ChromiumPage?
    private weak var browser: ChromiumRemoteBrowser?
    private var found: ChromiumAccessibilityMirror?

    init(view: ChromiumRemoteContentView, page: ChromiumPage, browser: ChromiumRemoteBrowser) {
        self.view = view
        self.page = page
        self.browser = browser
    }

    /// The browser's mirror: nil until the service has the browser (and after it closed).
    var mirror: ChromiumAccessibilityMirror? {
        if found == nil, let browser {
            found = browser.connection.browserAccessibility(browser.id)?.mirror
        }
        return found
    }

    /// How many of Chromium's units (physical pixels) make a point of this view: the backing scale the service was told, which is the
    /// scale its frames are painted at. Not the ratio of the root's width to the view's, which is wrong for as long as a resize has not
    /// reached the tree.
    var unitsPerPoint: CGFloat {
        max(1, browser?.sentScale ?? 1)
    }

    /// The page's main-frame generation: it moves with every navigation (see `press`).
    var generation: UInt64 {
        page?.mainFrameGeneration ?? 0
    }

    func noteQuery() {
        browser?.connection.noteAccessibilityQuery()
    }

    func rootElement() -> ChromiumAccessibilityElement? {
        mirror?.rootElement(host: self)
    }

    func parentOfRoot() -> Any? {
        view.flatMap { NSAccessibility.unignoredAncestor(of: $0) }
    }

    /// A rectangle in the view's points (top-left origin, the view is flipped) on the screen.
    func screenFrame(of rect: CGRect) -> NSRect {
        guard let view, let window = view.window else { return .zero }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    func element(atScreenPoint point: NSPoint) -> ChromiumAccessibilityElement? {
        guard let view, let window = view.window, let mirror else { return nil }
        let inView = view.convert(window.convertFromScreen(NSRect(origin: point, size: .zero)).origin, from: nil)
        return mirror.elementKey(at: inView, unitsPerPoint: unitsPerPoint).flatMap { mirror.element(for: $0, host: self) }
    }

    #if DEBUG
    /// Runs after a press is made and before it is sent (DEBUG: a test navigates the page in this gap, which a real press meets as
    /// a slow DevTools round trip or `ensureReady`), and, when the press ended without reaching the page, with what stopped it.
    var pressGate: (@MainActor () async -> Void)?
    var pressRefused: (@MainActor (Error) -> Void)?
    #endif

    /// A trusted click at the middle of an element, through DevTools (`Input.dispatchMouseEvent`): it needs neither the app to be
    /// active nor the window to be key, and no input connection. False for an element that is gone or not in view. The view's points
    /// are CSS pixels times the page's zoom.
    ///
    /// The click goes out some time after the press is made (`ensureReady`, a DevTools round trip), and a page that navigates in
    /// between would take it at a point of the next document. So it is bound to the document it was aimed at, the way an agent's
    /// pointer is (`PageAutomationGuard`): `generation` is the page's main-frame generation (`ChromiumPage.mainFrameGeneration`, which
    /// every navigation moves, a reload to the same address included) when the element was made. A press of an element from an
    /// earlier document returns false, and one whose navigation lands while it is on its way is not sent; both need the node to be
    /// in the mirror still. (An element first made after a navigation committed and before the new tree arrived, about a tenth of a
    /// second, is not told apart.)
    func press(_ key: ChromiumAccessibilityKey, in mirror: ChromiumAccessibilityMirror, generation: UInt64) -> Bool {
        guard mirror.exists(key), page?.mainFrameGeneration == generation else { return false }
        let rect = mirror.rectInPoints(key, unitsPerPoint: unitsPerPoint)
        guard let page, let view, rect.width > 0, rect.height > 0, view.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) else { return false }
        let zoom = max(0.1, page.zoom)
        let point = CGPoint(x: rect.midX / zoom, y: rect.midY / zoom)
        let stillThere: @MainActor @Sendable () -> Bool = { [weak page, weak mirror] in
            page?.mainFrameGeneration == generation && mirror?.exists(key) == true
        }
        Task { @MainActor [weak page, weak self] in
            #if DEBUG
            await self?.pressGate?()
            #endif
            do {
                try await page?.dragPointer(path: [point, point], allowed: stillThere)
            } catch {
                ChromiumOOP.log.error("an accessibility press did not reach the page: \(String(describing: error), privacy: .public)")
                #if DEBUG
                self?.pressRefused?(error)
                #endif
            }
        }
        return true
    }

    /// The tree changed: what the client knows of the structure is stale.
    func treeChanged() {
        if let view {
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
        if let root = rootElement() {
            NSAccessibility.post(element: root, notification: .layoutChanged)
        }
    }
}

extension ChromiumRemoteContentView {
    /// The host of this view's accessibility, made with the first query. Nil for a view that is not its page's current one (its browser
    /// is gone), which then answers as any plain view does.
    var accessibilityHost: ChromiumRemoteAccessibilityHost? {
        guard let page = superview as? ChromiumPage, let browser = page.remote, browser.contentView === self else { return nil }
        if browser.accessibilityHost == nil {
            browser.accessibilityHost = ChromiumRemoteAccessibilityHost(view: self, page: page, browser: browser)
        }
        return browser.accessibilityHost
    }

    /// The browser's tree changed (`ChromiumBrowserAccessibility.onTreeChanged`).
    func accessibilityTreeChanged() {
        accessibilityHost?.treeChanged()
    }

    /// The root web area, when the browser's tree is in.
    override func accessibilityChildren() -> [Any]? {
        guard let host = accessibilityHost else { return super.accessibilityChildren() }
        host.noteQuery()
        let children: [ChromiumAccessibilityElement] = host.rootElement().map { [$0] } ?? []
        return children
    }

    /// AppKit declares the hit test `nonisolated`; it asks on the main thread, like every other accessibility query.
    nonisolated override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        nonisolated(unsafe) var hit: Any?
        MainActor.assumeIsolated {
            if let host = accessibilityHost {
                host.noteQuery()
                hit = host.element(atScreenPoint: point)
            }
        }
        return hit ?? super.accessibilityHitTest(point)
    }
}
