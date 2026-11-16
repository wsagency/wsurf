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
        browser.sentScreen = window?.screen?.frame.size ?? .zero
        browser.sentHidden = remoteVisibility().hidden
        browser.sentParked = false
        wantsLayer = true
        guard let host = layer else { return }
        let frames = CALayer()
        frames.anchorPoint = .zero
        frames.contentsGravity = .resize
        frames.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        frames.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.addSublayer(frames)
        CATransaction.commit()
        browser.attachFrameLayer(frames)
    }

    // MARK: Geometry

    /// Size, scale and screen, sent when one of them changed since the service was last told. Called from the view's size and
    /// backing-property callbacks and when the page joins a window.
    func updateRemoteGeometry() {
        guard let remote, !isClosed else { return }
        let size = CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        let scale = max(1, window?.backingScaleFactor ?? remote.sentScale)
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
        let screen = window?.screen?.frame.size ?? remote.sentScreen
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
