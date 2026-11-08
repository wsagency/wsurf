// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4 spike: a ChromiumPage whose browser lives in the out-of-process service. The page stays the NSView every caller holds;
// it hosts the service's remote layer, tells the service its size and visibility, and turns the service's events into the
// same calls CEF's callbacks make in process (`willNavigate`, `didStartLoad`, `didFinishLoad`, ...).

import AppKit
import CefKit
import QuartzCore
import os

extension ChromiumPage {
    var isRemote: Bool {
        ChromiumOOP.isEnabled
    }

    /// Asks the service for this page's browser. Nothing here waits: the browser comes later, and every command sent before it
    /// exists waits in the service.
    func materializeRemote() throws {
        guard !isClosing, !isClosed else { throw ChromiumError.closed }
        guard remote == nil else { return }
        ChromiumRemote.shared.ensureContext(for: context)
        let browser = ChromiumRemote.shared.makeBrowser(for: self)
        remote = browser
        wantsLayer = true
        let visibility = remoteVisibility()
        browser.send(CefRemote.Op.createBrowser) { message in
            message.set(CefRemote.Key.context, context.contextID.uuidString)
            message.set(CefRemote.Key.url, "about:blank")
            message.set(CefRemote.Key.javaScript, context.settings.javaScriptEnabled)
            fillGeometry(message, browser: browser)
            message.set(CefRemote.Key.hidden, visibility.hidden)
            message.set(CefRemote.Key.parked, visibility.parked)
        }
        browser.sentHidden = visibility.hidden
        browser.sentParked = visibility.parked
        if ChromiumRemote.shared.wantsAccessibility {
            browser.send(CefRemote.Op.accessibility) { $0.set(CefRemote.Key.flag, true) }
        }
        try adoptRemote(browser)
    }

    /// A click at `point` (view points, top-left origin), as VoiceOver's Press on an element of the mirror.
    func remoteClick(at point: CGPoint) {
        guard let remote else { return }
        for kind in ["move", "down", "up"] {
            let message = remote.message(CefRemote.Op.mouse)
            message.set(CefRemote.Key.kind, kind)
            message.set(CefRemote.Key.x, Double(point.x))
            message.set(CefRemote.Key.y, Double(point.y))
            message.set(CefRemote.Key.button, Int64(0))
            message.set(CefRemote.Key.clickCount, Int64(1))
            remote.sendInput(message)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard remote != nil else { return super.accessibilityChildren() }
        return accessibilityMirror?.rootElement.map { [$0] } ?? []
    }

    override func isAccessibilityElement() -> Bool {
        remote != nil ? false : super.isAccessibilityElement()
    }

    /// Geometry for the service: the view's size in points, the scale, the screen and the view's top-left on it.
    func fillGeometry(_ message: CefRemoteMessage, browser: ChromiumRemoteBrowser) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var origin = CGPoint.zero
        var screenRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let window, let screen = window.screen ?? NSScreen.main {
            let onScreen = window.convertToScreen(convert(bounds, to: nil))
            origin = CGPoint(x: onScreen.minX, y: screen.frame.maxY - onScreen.maxY)
            screenRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
        }
        let size = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        message.set(CefRemote.Key.width, Double(size.width))
        message.set(CefRemote.Key.height, Double(size.height))
        message.set(CefRemote.Key.scale, Double(scale))
        message.set(CefRemote.Key.screenX, Double(screenRect.minX))
        message.set(CefRemote.Key.screenY, Double(screenRect.minY))
        message.set(CefRemote.Key.screenWidth, Double(screenRect.width))
        message.set(CefRemote.Key.screenHeight, Double(screenRect.height))
        message.set(CefRemote.Key.originX, Double(origin.x))
        message.set(CefRemote.Key.originY, Double(origin.y))
        browser.sentSize = size
        browser.sentScale = scale
    }

    /// The service published the browser's layer tree: show it here.
    func attachRemoteLayer(_ clientID: UInt32) {
        wantsLayer = true
        remoteLayer?.removeFromSuperlayer()
        let hosted = CALayer(remoteClientId: clientID)
        hosted.anchorPoint = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        layer?.addSublayer(hosted)
        CATransaction.commit()
        remoteLayer = hosted
    }

    /// Size, scale and visibility: re-sent when they changed. Called from layout and from the view's visibility callbacks.
    func updateRemoteGeometry() {
        guard let remote, !isClosed else { return }
        if let remoteLayer, remoteLayer.frame != bounds {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            remoteLayer.frame = bounds
            CATransaction.commit()
        }
        let scale = window?.backingScaleFactor ?? remote.sentScale
        let size = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        if size != remote.sentSize || scale != remote.sentScale {
            remote.send(CefRemote.Op.resize) { fillGeometry($0, browser: remote) }
        }
        updateRemoteVisibility()
    }

    /// Hidden: not in a window, or the view or one of its ancestors is hidden (the page is hidden to itself). Parked: the page
    /// waits on its window's shelf, unseen but not hidden, so it keeps running as it does in process; the service drops its
    /// frames until it comes back.
    func remoteVisibility() -> (hidden: Bool, parked: Bool) {
        let hidden = window == nil || isHiddenOrHasHiddenAncestor
        var parked = false
        var ancestor = superview
        while let view = ancestor {
            if view is WebViewParkingShelf {
                parked = true
                break
            }
            ancestor = view.superview
        }
        return (hidden, !hidden && parked)
    }

    /// Coalesced to the end of the turn: a switch takes a page out of its window and puts it back (or on the shelf) in one
    /// turn, and only where it ends up is the service's business. A `was_hidden` flap would make the renderer hide and redraw.
    func updateRemoteVisibility() {
        guard remote != nil, !isClosed, !remoteInput.visibilityUpdatePending else { return }
        remoteInput.visibilityUpdatePending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remoteInput.visibilityUpdatePending = false
                self.sendRemoteVisibility()
            }
        }
    }

    private func sendRemoteVisibility() {
        guard let remote, !isClosed else { return }
        let visibility = remoteVisibility()
        guard visibility.hidden != remote.sentHidden || visibility.parked != remote.sentParked else { return }
        remote.sentHidden = visibility.hidden
        remote.sentParked = visibility.parked
        remote.send(CefRemote.Op.visibility) {
            $0.set(CefRemote.Key.hidden, visibility.hidden)
            $0.set(CefRemote.Key.parked, visibility.parked)
        }
    }

    /// An event of this page's browser: the same calls CEF's callbacks make in process.
    func receiveRemote(_ message: CefRemoteMessage) {
        switch message.op {
        case CefRemote.Event.loadingState:
            didChangeLoading(message.bool(CefRemote.Key.loading), canGoBack: message.bool(CefRemote.Key.canGoBack),
                             canGoForward: message.bool(CefRemote.Key.canGoForward))
        case CefRemote.Event.loadStart:
            didStartLoad()
        case CefRemote.Event.loadEnd:
            didFinishLoad(status: Int(message.int(CefRemote.Key.status)))
        case CefRemote.Event.loadError:
            didFailLoad(code: Int(message.int(CefRemote.Key.code)), text: message.string(CefRemote.Key.text),
                        url: message.string(CefRemote.Key.url))
        case CefRemote.Event.beforeBrowse:
            if let url = URL(string: message.string(CefRemote.Key.url)) {
                willNavigate(URLRequest(url: url), isRedirect: message.bool(CefRemote.Key.isRedirect))
            }
        case CefRemote.Event.address:
            didChangeURL(URL(string: message.string(CefRemote.Key.url)))
        case CefRemote.Event.title:
            didChangeTitle()
        case CefRemote.Event.progress:
            didChangeProgress(message.double(CefRemote.Key.progress))
        case CefRemote.Event.statusMessage:
            didHoverLink(URL(string: message.string(CefRemote.Key.text)))
        case CefRemote.Event.fullscreen:
            didChangeFullscreen(message.bool(CefRemote.Key.flag))
        case CefRemote.Event.cursor:
            remoteCursor = CefCursorType.fromRemote(message.int(CefRemote.Key.cursor)).nsCursor ?? .arrow
            remoteCursor.set()
            window?.invalidateCursorRects(for: self)
        case CefRemote.Event.renderTerminated:
            didTerminate()
        case CefRemote.Event.devToolsMessage, CefRemote.Event.devToolsResult, CefRemote.Event.devToolsEvent,
             CefRemote.Event.devToolsDetached:
            devTools.receiveRemote(message)
        case CefRemote.Event.findResult:
            find.receive(identifier: Int(message.int(CefRemote.Key.identifier)), count: Int(message.int(CefRemote.Key.count)),
                         active: Int(message.int(CefRemote.Key.active)), isFinal: message.bool(CefRemote.Key.final))
        case CefRemote.Event.accessibilityTree:
            if accessibilityMirror == nil {
                accessibilityMirror = ChromiumAccessibilityMirror(page: self)
            }
            accessibilityMirror?.applyTree(message.data(CefRemote.Key.data))
        case CefRemote.Event.accessibilityLocation:
            accessibilityMirror?.applyLocations(message.data(CefRemote.Key.data))
        case CefRemote.Event.popupBlocked:
            ChromiumOOP.log.notice("spike: pop-up or new-tab link refused (out of scope)")
        default:
            receiveRemoteInput(message)
        }
    }

    /// The service closed the browser (`on_before_close` in process).
    func remoteBrowserClosed() {
        remoteLayer?.removeFromSuperlayer()
        remoteLayer = nil
        browserDidClose()
    }

    /// The service ended with this page's browser in it: the page is left with no browser, as after a renderer crash, and
    /// the tab's crash handling reloads it, which asks a new service for a new browser.
    func remoteServiceEnded() {
        remoteLayer?.removeFromSuperlayer()
        remoteLayer = nil
        resetAfterServiceEnd()
    }
}
