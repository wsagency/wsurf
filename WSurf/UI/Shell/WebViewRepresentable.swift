// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

struct WebViewRepresentable: NSViewRepresentable {
    let page: BrowserPage
    var parksWhenIdle = false
    var onReady: (() -> Void)?

    func makeNSView(context: Context) -> WebViewContainer {
        let container = WebViewContainer(page: page, onReady: onReady)
        container.parksWhenIdle = parksWhenIdle
        return container
    }

    func updateNSView(_ nsView: WebViewContainer, context: Context) {
        nsView.parksWhenIdle = parksWhenIdle
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
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
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
    static func park(_ page: BrowserPage) {
        guard let shelf = page.window?.contentView?.subviews
            .first(where: { $0 is WebViewParkingShelf })
        else {
            page.removeFromSuperview()
            return
        }
        let size = page.bounds.size
        page.removeFromSuperview()
        page.autoresizingMask = []
        page.frame = NSRect(x: 0, y: 0, width: max(size.width, 1), height: max(size.height, 1))
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
    var onReady: (() -> Void)?

    private weak var installedPage: BrowserPage?
    private var didReportReady = false

    override var preservesContentDuringLiveResize: Bool {
        true
    }

    init(page: BrowserPage, onReady: (() -> Void)? = nil) {
        self.onReady = onReady
        super.init(frame: .zero)
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
            if parksWhenIdle {
                WebViewParking.park(installedPage)
            } else {
                installedPage.removeFromSuperview()
            }
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
        addSubview(page)
        reportReadyIfPossible()
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
        WebViewParking.park(installedPage)
    }

    func uninstall() {
        guard let installedPage else { return }
        if installedPage.superview === self {
            if parksWhenIdle {
                WebViewParking.park(installedPage)
            } else {
                installedPage.removeFromSuperview()
            }
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
