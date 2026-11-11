// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import IOSurface
import os
import QuartzCore
import Testing

@testable import WSurf

/// Records every implicit action a layer asks its delegate for. With actions disabled in the transaction a layer never asks, so
/// the list stays empty; `animationKeys()` alone could stay empty for a layer outside a window and prove nothing.
private nonisolated final class ActionRecorder: NSObject, CALayerDelegate, @unchecked Sendable {
    private let keys = OSAllocatedUnfairLock(initialState: [String]())

    var asked: [String] {
        keys.withLock { $0 }
    }

    func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
        keys.withLock { $0.append(event) }
        return nil
    }
}

/// The frame sink of out-of-process Chromium (D4-3): what the frames queue may change, what it must not, and what happens to
/// frames that outlive their browser. No service and no CEF: the surfaces are made here.
@MainActor
@Suite
struct ChromiumFrameSinkTests {
    private let browser: ChromiumFrameSink.Browser = 7

    private static func makeSurface(width: Int = 16, height: Int = 16) throws -> IOSurface {
        try #require(IOSurface(properties: [
            .width: width, .height: height, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,  // 'BGRA'
        ]))
    }

    private static func makePage() -> CALayer {
        let page = CALayer()
        page.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        return page
    }

    /// The frames queue's work, run the way the frames connection runs it.
    private static func onFramesQueue(_ sink: ChromiumFrameSink, _ body: () -> Void) {
        sink.framesQueue.sync(execute: body)
    }

    @Test
    func aSurfaceBecomesThePageLayersContents() throws {
        let sink = ChromiumFrameSink()
        let page = Self.makePage()
        let surface = try Self.makeSurface()
        sink.register(browser: browser, pageLayer: page)
        #expect(page.contents == nil)

        Self.onFramesQueue(sink) { sink.apply(surface: surface, browser: browser, popup: false) }

        #expect((page.contents as AnyObject?) === surface)
        #expect(sink.framesShown == 1)
        #expect(sink.popupFramesShown == 0)
        #expect(sink.popupLayer(for: browser)?.contents == nil)
    }

    @Test
    func noImplicitActionIsEverAskedFor() throws {
        let sink = ChromiumFrameSink()
        let page = Self.makePage()
        let surface = try Self.makeSurface()
        sink.register(browser: browser, pageLayer: page)
        let popup = try #require(sink.popupLayer(for: browser))
        let recorder = ActionRecorder()
        page.delegate = recorder
        popup.delegate = recorder

        Self.onFramesQueue(sink) {
            sink.apply(surface: surface, browser: browser, popup: false)
            sink.applyPopup(browser: browser, visible: true, rect: CGRect(x: 10, y: 20, width: 100, height: 50))
            sink.apply(surface: surface, browser: browser, popup: true)
            sink.applyPopup(browser: browser, visible: true, rect: CGRect(x: 30, y: 40, width: 120, height: 60))
            sink.applyPopup(browser: browser, visible: false, rect: .zero)
        }

        #expect(page.contents != nil)
        #expect(recorder.asked.isEmpty, "the frames queue asked for implicit actions: \(recorder.asked)")
        withExtendedLifetime(recorder) {}
    }

    /// The control for the test above: the same property changes, without the transaction, do reach the delegate. A recorder
    /// that never hears anything would let the test above pass for the wrong reason.
    @Test
    func theRecorderHearsAnUnguardedChange() throws {
        let page = Self.makePage()
        let recorder = ActionRecorder()
        page.delegate = recorder
        CATransaction.begin()
        page.contents = try Self.makeSurface()
        page.frame = CGRect(x: 1, y: 1, width: 10, height: 10)
        CATransaction.commit()
        #expect(recorder.asked.contains("contents"))
    }

    @Test
    func aPopupIsShownMovedAndHidden() throws {
        let sink = ChromiumFrameSink()
        let page = Self.makePage()
        let surface = try Self.makeSurface()
        sink.register(browser: browser, pageLayer: page)
        let popup = try #require(sink.popupLayer(for: browser))
        #expect(popup.isHidden)

        Self.onFramesQueue(sink) {
            sink.applyPopup(browser: browser, visible: true, rect: CGRect(x: 10, y: 20, width: 100, height: 50))
            sink.apply(surface: surface, browser: browser, popup: true)
        }
        // CEF's rectangle has a top-left origin and this page layer is not flipped: 300 - (20 + 50) = 230.
        #expect(!popup.isHidden)
        #expect(popup.frame == CGRect(x: 10, y: 230, width: 100, height: 50))
        #expect((popup.contents as AnyObject?) === surface)
        #expect(sink.popupFramesShown == 1)
        #expect(sink.framesShown == 0)

        Self.onFramesQueue(sink) {
            sink.applyPopup(browser: browser, visible: true, rect: CGRect(x: 40, y: 0, width: 80, height: 30))
        }
        #expect(!popup.isHidden)
        #expect(popup.frame == CGRect(x: 40, y: 270, width: 80, height: 30))

        Self.onFramesQueue(sink) { sink.applyPopup(browser: browser, visible: false, rect: .zero) }
        #expect(popup.isHidden)
        #expect(popup.contents == nil)
    }

    @Test
    func framesForAnUnregisteredBrowserAreDropped() throws {
        let sink = ChromiumFrameSink()
        let page = Self.makePage()
        let surface = try Self.makeSurface()
        Self.onFramesQueue(sink) {
            sink.apply(surface: surface, browser: browser, popup: false)
            sink.apply(surface: surface, browser: browser, popup: true)
            sink.applyPopup(browser: browser, visible: true, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        #expect(sink.framesDropped == 3)
        #expect(sink.framesShown == 0)
        #expect(sink.popupFramesShown == 0)

        // Another browser's registration does not catch them.
        sink.register(browser: browser + 1, pageLayer: page)
        Self.onFramesQueue(sink) { sink.apply(surface: surface, browser: browser, popup: false) }
        #expect(page.contents == nil)
        #expect(sink.framesDropped == 4)
    }

    @Test
    func unregisterRemovesBothLayersAndLaterFramesAreDropped() throws {
        let sink = ChromiumFrameSink()
        let host = CALayer()
        let page = Self.makePage()
        host.addSublayer(page)
        let surface = try Self.makeSurface()
        sink.register(browser: browser, pageLayer: page)
        let popup = try #require(sink.popupLayer(for: browser))
        Self.onFramesQueue(sink) {
            sink.apply(surface: surface, browser: browser, popup: false)
            sink.applyPopup(browser: browser, visible: true, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
            sink.apply(surface: surface, browser: browser, popup: true)
        }
        #expect(page.superlayer === host)
        #expect(popup.superlayer === page)

        sink.unregister(browser: browser)
        #expect(page.superlayer == nil)
        #expect(popup.superlayer == nil)
        #expect(page.contents == nil)
        #expect(popup.contents == nil)
        #expect(!sink.isRegistered(browser: browser))
        #expect(sink.popupLayer(for: browser) == nil)

        Self.onFramesQueue(sink) {
            sink.apply(surface: surface, browser: browser, popup: false)
            sink.applyPopup(browser: browser, visible: true, rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        #expect(page.contents == nil)
        #expect(popup.contents == nil)
        #expect(sink.framesDropped == 2)
        sink.unregister(browser: browser)  // twice is harmless
    }

    @Test
    func unregisteringWhileFramesArriveLeavesNoContentsOnARemovedLayer() throws {
        let sink = ChromiumFrameSink()
        let surface = try Self.makeSurface()
        let id = browser
        for iteration in 0..<100 {
            let page = Self.makePage()
            sink.register(browser: id, pageLayer: page)
            let popup = try #require(sink.popupLayer(for: id))
            sink.framesQueue.async {
                for _ in 0..<50 {
                    sink.apply(surface: surface, browser: id, popup: false)
                    sink.apply(surface: surface, browser: id, popup: true)
                    sink.applyPopup(browser: id, visible: true, rect: CGRect(x: 1, y: 1, width: 5, height: 5))
                }
            }
            if iteration % 2 == 0 {
                Thread.sleep(forTimeInterval: 0.0002)
            }
            sink.unregister(browser: id)
            Self.onFramesQueue(sink) {}  // everything queued has run
            #expect(page.contents == nil, "iteration \(iteration)")
            #expect(popup.contents == nil, "iteration \(iteration)")
            #expect(page.superlayer == nil && popup.superlayer == nil)
        }
        #expect(sink.framesShown + sink.popupFramesShown + sink.framesDropped > 0)
    }

    @Test
    func theFramesQueueNeverChangesSublayers() throws {
        let sink = ChromiumFrameSink()
        let page = Self.makePage()
        let surface = try Self.makeSurface()
        sink.register(browser: browser, pageLayer: page)
        // The popup layer exists, hidden and in the tree, before any frame or popup event: it was made on this thread.
        let popup = try #require(sink.popupLayer(for: browser))
        #expect(page.sublayers?.count == 1)
        #expect(page.sublayers?.first === popup)
        #expect(popup.isHidden)

        Self.onFramesQueue(sink) {
            for index in 0..<20 {
                sink.apply(surface: surface, browser: browser, popup: false)
                sink.applyPopup(browser: browser, visible: index % 2 == 0, rect: CGRect(x: 5, y: 5, width: 50, height: 20))
                sink.apply(surface: surface, browser: browser, popup: true)
            }
        }
        #expect(page.sublayers?.count == 1)
        #expect(page.sublayers?.first === popup)
        #expect(popup.superlayer === page)
    }

    @Test
    func registeringAgainReplacesThePopupAndKeepsASharedPageLayer() throws {
        let sink = ChromiumFrameSink()
        let host = CALayer()
        let page = Self.makePage()
        host.addSublayer(page)
        sink.register(browser: browser, pageLayer: page)
        let first = try #require(sink.popupLayer(for: browser))

        sink.register(browser: browser, pageLayer: page)
        let second = try #require(sink.popupLayer(for: browser))
        #expect(first !== second)
        #expect(first.superlayer == nil)
        #expect(page.superlayer === host)
        #expect(page.sublayers?.count == 1)

        let other = Self.makePage()
        host.addSublayer(other)
        sink.register(browser: browser, pageLayer: other)
        #expect(page.superlayer == nil)
        #expect(second.superlayer == nil)
        #expect(other.sublayers?.count == 1)
    }
}
