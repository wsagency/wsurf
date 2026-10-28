// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

struct WebViewRepresentable: NSViewRepresentable {
    let page: BrowserPage
    var parksWhenIdle = false
    /// The page stays loaded in its window but is not shown (`WebViewContainer.hidesPage`).
    var hidesPage = false
    var onReady: (() -> Void)?

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer(page: page, onReady: onReady)
        container.parksWhenIdle = parksWhenIdle
        container.hidesPage = hidesPage
        return container
    }

    func updateNSView(_ nsView: WebViewContainer, context: Context) {
        nsView.parksWhenIdle = parksWhenIdle
        nsView.hidesPage = hidesPage
        nsView.onReady = onReady
        nsView.install(page)
    }

    static func dismantleNSView(_ nsView: WebViewContainer, coordinator: ()) {
        nsView.uninstall()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: WebViewContainer,
        context: Context
    ) -> CGSize? {
        proposal.webViewSize
    }
}

extension ProposedViewSize {
    var webViewSize: CGSize? {
        guard let width, let height, width.isFinite, height.isFinite else { return nil }
        // Padding can leave a negative proposal during minimum-size layout passes.
        return CGSize(width: max(0, width), height: max(0, height))
    }
}

@MainActor
enum WebKeyEcho {
    static func shouldSilenceUnhandledKey(from responder: NSResponder?) -> Bool {
        var view = responder as? NSView
        while let current = view {
            if current is BrowserPage {
                return true
            }
            view = current.superview
        }
        return false
    }
}

@MainActor
enum WebViewParking {
    /// Keeps `page` attached to `window` (its own window when nil) without showing it, so it keeps loading and, unless the page
    /// hides while parked (`BrowserPage.hidesWhileParked`), rendering. `size` replaces the page's current size. Without a shelf
    /// in that window the page is only removed.
    static func park(_ page: BrowserPage, in window: NSWindow? = nil, size: CGSize? = nil) {
        guard let shelf = (window ?? page.window)?.contentView?.subviews
            .first(where: { $0 is WebViewParkingShelf })
        else {
            page.isHidden = false
            page.removeFromSuperview()
            return
        }
        let size = size ?? page.bounds.size
        page.removeFromSuperview()
        page.autoresizingMask = []
        page.frame = NSRect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1))
        // Before it joins the shelf, so the engine never sees the page shown there for a moment.
        page.isHidden = page.hidesWhileParked
        shelf.addSubview(page)
    }
}

final class WebViewParkingShelf: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

final class WebViewContainer: NSView {
    var parksWhenIdle = false
    /// Hides the page while this view holds it. Both engines report the document of a hidden view as hidden, run no animation
    /// frames and paint nothing for it; loading and sound go on, and timers are throttled as in any background tab. The page
    /// must stay in its window all the same: Chromium builds its browser there, and a page out of the window stops playing.
    var hidesPage = false {
        didSet {
            guard hidesPage != oldValue, let installedPage, installedPage.superview === self else { return }
            installedPage.isHidden = hidesPage
        }
    }
    var onReady: (() -> Void)?

    private weak var installedPage: BrowserPage?
    private var didReportReady = false

    override var preservesContentDuringLiveResize: Bool {
        true
    }

    init(page: BrowserPage, onReady: (() -> Void)? = nil) {
        self.onReady = onReady
        super.init(frame: .zero)
        // A development viewport can be larger than the host; the overflow is clipped, never squeezed.
        wantsLayer = true
        layer?.masksToBounds = true
        install(page)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func install(_ page: BrowserPage) {
        if installedPage !== page {
            didReportReady = false
        }
        if let installedPage, installedPage !== page, installedPage.superview === self {
            release(installedPage)
        }
        installedPage = page
        attachIfHosted()
        reportReadyIfPossible()
    }

    private func attachIfHosted() {
        guard window != nil, let page = installedPage, page.superview !== self else { return }
        page.removeFromSuperview()
        page.autoresizingMask = [.width, .height]
        if bounds.width > 0, bounds.height > 0 {
            page.frame = page.frameInViewport(bounds)
        }
        // A page that waited hidden on the shelf is shown before it joins this view, so it is drawing from the moment it is in
        // the window and no frame shows it blank. A host that hides hides it once it is in: Chromium builds its browser as the
        // page first reaches a window, and a browser built in a hidden view counts itself shown for good.
        if !hidesPage {
            page.isHidden = false
        }
        addSubview(page)
        if hidesPage {
            page.isHidden = true
        }
        reportReadyIfPossible()
    }

    /// Lets go of `page`: it waits on the shelf, hidden or not as it says, or leaves the window shown.
    private func release(_ page: BrowserPage) {
        if parksWhenIdle {
            WebViewParking.park(page)
        } else {
            page.isHidden = false
            page.removeFromSuperview()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfHosted()
        reportReadyIfPossible()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        guard newWindow == nil, parksWhenIdle,
              let installedPage, installedPage.superview === self else { return }
        release(installedPage)
    }

    func uninstall() {
        guard let installedPage else { return }
        if installedPage.superview === self {
            release(installedPage)
        }
        self.installedPage = nil
        didReportReady = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard let installedPage, installedPage.superview === self else { return }
        let frame = installedPage.frameInViewport(bounds)
        if installedPage.frame != frame {
            installedPage.frame = frame
        }
        reportReadyIfPossible()
    }

    func layoutPage() {
        guard let installedPage, installedPage.superview === self else { return }
        installedPage.frame = installedPage.frameInViewport(bounds)
    }

    private func reportReadyIfPossible() {
        guard !didReportReady, window != nil, bounds.width > 0, bounds.height > 0,
              installedPage?.superview === self, let onReady
        else { return }
        didReportReady = true
        onReady()
    }
}
