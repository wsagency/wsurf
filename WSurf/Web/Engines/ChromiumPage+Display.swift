// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CefKit
import Foundation
import QuartzCore

// D4 (out-of-process Chromium), phase 2, PR D4-9: what a page in the Chromium service needs to be seen. Its frames are IOSurfaces
// that the service sends and `ChromiumFrameSink` sets as the `contents` of a layer of this view; this file makes and places that
// layer (main thread only), and tells the service the page's size, backing scale, screen and visibility.
//
// Nothing here waits on the service, and nothing in WSurf's shelf code (`WebViewRepresentable`) is involved: the page is asked
// where it is (window, ancestors), not told. A page in process never gets here (`remote` is nil: every entry point returns).

extension ChromiumPage {
    // MARK: The frame layer

    /// Makes the layer the frames go to and registers it with the sink. The layer is a sublayer of the view's own, at the view's
    /// size; it keeps its last frame while the page is hidden, parked or between two frames, so the person sees the page as it
    /// was until the first new frame arrives. The surface carries its colour-space tag (CEF's, copied by the service) and the
    /// layer sets none of its own, so the compositor matches it as it does any tagged IOSurface.
    func attachRemoteFrameLayer(to browser: ChromiumRemoteBrowser) {
        // What the browser is made with is what the service has been told so far (`browser.create`'s size, scale and `hidden`).
        browser.sentSize = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        browser.sentScale = max(1, window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        // `browser.create` carries no screen: it goes with the first resize, which the attach (or this page's first window) sends.
        browser.sentScreen = .zero
        browser.sentHidden = remoteVisibility().hidden
        browser.sentParked = false
        wantsLayer = true
        guard let host = layer else { return }
        // A page that waited for this browser has its last frame in the layer it kept: the first frame of the new browser replaces it.
        let frames = retainedPreview ?? CALayer()
        retainedPreview = nil
        frames.anchorPoint = .zero
        frames.contentsGravity = .resize
        frames.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frames.frame = bounds
        host.addSublayer(frames)
        CATransaction.commit()
        browser.attachFrameLayer(frames)
        // Over the frames, at the page's size (it follows the page's bounds): the first responder of this page (`BrowserPage`).
        let content = ChromiumRemoteContentView(frame: bounds)
        content.browser = browser
        addSubview(content)
        browser.contentView = content
        // A page that was focused when its browser went (or before it came) holds the keys in `BrowserPage`: they go to the new view
        // (F1 of the D4-11 review). Any other first responder (the address bar, a find field) is not taken from.
        if let window, window.firstResponder === owner || window.firstResponder === self {
            window.makeFirstResponder(content)
        }
    }

    // MARK: The preview that waits for a relaunch

    /// Whether this page keeps its last frame when the service ends (asked by the browser, before it lets go of its layer): any page
    /// that will load again, shown or waiting for its person (a hidden page keeps its preview as it does while its service lives, and
    /// comes back with it), and has a frame to keep. A crash loop shows no frame of a page that is not coming.
    func keepsPreviewWhenServiceEnds(_ browser: ChromiumRemoteBrowser) -> Bool {
        remote === browser && !closing && !isClosed && !remoteConnection.isGivenUp && browser.pageLayer?.contents != nil
    }

    /// The page's last frame is let go of: it was not wanted after all (the tab did not load the page again, or the page closed).
    func dropRetainedPreview() {
        guard let preview = retainedPreview else { return }
        retainedPreview = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.removeFromSuperlayer()
        preview.contents = nil
        CATransaction.commit()
    }

    // MARK: Geometry

    /// Size, scale and screen. The layer follows at once; the service is told when one of them changed since it was last told, at
    /// the end of the run-loop turn (like visibility: a drag or a layout pass calls this many times in one), with the final values.
    /// A live resize is still one message per turn: the service limits what it allocates for the sizes of a drag
    /// (`FramePresenter`: a new size waits for its frame until it is stable, and a drag is painted ten times a second at most).
    /// Called from the view's size and backing-property callbacks and when the page joins a window.
    func updateRemoteGeometry() {
        guard let remote, !isClosed else {
            if let preview = retainedPreview, preview.frame != bounds {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                preview.frame = bounds
                CATransaction.commit()
            }
            return
        }
        let (size, scale, screen) = remoteGeometry(of: remote)
        if let frames = remote.pageLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if frames.frame != bounds {
                frames.frame = bounds
            }
            frames.contentsScale = scale
            // The sink made the pop-up layer at the scale the page layer had then: later changes are the page's (the frames queue
            // never writes this property).
            remote.connection.sink.popupLayer(for: remote.id)?.contentsScale = scale
            CATransaction.commit()
        }
        guard size != remote.sentSize || scale != remote.sentScale || screen != remote.sentScreen, !remote.geometryUpdatePending else { return }
        remote.geometryUpdatePending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self, weak remote] in
            MainActor.assumeIsolated {
                remote?.geometryUpdatePending = false
                self?.sendRemoteGeometry()
            }
        }
    }

    private func remoteGeometry(of remote: ChromiumRemoteBrowser) -> (size: CGSize, scale: CGFloat, screen: CGSize) {
        (CGSize(width: max(1, bounds.width), height: max(1, bounds.height)), max(1, window?.backingScaleFactor ?? remote.sentScale),
         window?.screen?.frame.size ?? remote.sentScreen)
    }

    private func sendRemoteGeometry() {
        guard let remote, !isClosed else { return }
        let (size, scale, screen) = remoteGeometry(of: remote)
        guard size != remote.sentSize || scale != remote.sentScale || screen != remote.sentScreen else { return }
        remote.sentSize = size
        remote.sentScale = scale
        remote.sentScreen = screen
        remote.countResize()
        remote.send(CefRemote.Op.resize) {
            $0.set(CefRemote.Key.width, Double(size.width))
            $0.set(CefRemote.Key.height, Double(size.height))
            $0.set(CefRemote.Key.scale, Double(scale))
            if screen != .zero {
                $0.set(CefRemote.Key.screenX, 0.0)
                $0.set(CefRemote.Key.screenY, 0.0)
                $0.set(CefRemote.Key.screenWidth, Double(screen.width))
                $0.set(CefRemote.Key.screenHeight, Double(screen.height))
            }
        }
    }

    /// The window changed screens: the screen's size and scale are the service's to know. One observer, for the window the page is in.
    func observeScreenChanges() {
        guard let remote else { return }
        remote.stopObservingScreen()
        guard let window else { return }
        remote.screenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRemoteGeometry() }
        }
    }

    // MARK: Visibility

    /// Hidden: not in a window, or the view or one of its ancestors is hidden. Parked: the page waits on its window's shelf, unseen
    /// but not hidden, so it keeps running as it does in process; the service drops its frames until it comes back.
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

    /// Coalesced to the end of the run-loop turn, whatever calls it: a tab switch takes a page out of its window and puts it back
    /// (or on the shelf) in one turn, and only where it ends up is the service's business. A `was_hidden` flap would make the
    /// renderer hide and redraw.
    func updateRemoteVisibility() {
        resumeRecoveryWhenShown()
        guard let remote, !isClosed, !remote.visibilityUpdatePending else { return }
        remote.visibilityUpdatePending = true
        RunLoop.main.perform(inModes: [.common]) { [weak self, weak remote] in
            MainActor.assumeIsolated {
                remote?.visibilityUpdatePending = false
                self?.sendRemoteVisibility()
            }
        }
    }

    private func sendRemoteVisibility() {
        guard let remote, !isClosed else { return }
        let visibility = remoteVisibility()
        guard visibility.hidden != remote.sentHidden || visibility.parked != remote.sentParked else { return }
        remote.sentHidden = visibility.hidden
        remote.sentParked = visibility.parked
        remote.countVisibility()
        remote.send(CefRemote.Op.visibility) {
            $0.set(CefRemote.Key.hidden, visibility.hidden)
            $0.set(CefRemote.Key.parked, visibility.parked)
        }
    }
}
