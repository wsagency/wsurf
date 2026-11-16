// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import IOSurface
import QuartzCore
import Testing

@testable import CefKit
@testable import WSurf

/// The first group of `ChromiumOOPDisplayTests`: a page whose messages go to a recorder, in a window, and the frame sink that is the
/// connection's own. No service: it runs in the default lane too, and what it shows is WSurf's half (what the page sends when its
/// size, scale or place change, and where its frames land). The live half is in `ChromiumOOPDisplayTests`.
extension ChromiumOOPDisplayTests {
    final class Recorder {
        var messages: [CefRemoteMessage] = []

        func sent(_ op: String) -> [CefRemoteMessage] {
            messages.filter { $0.op == op }
        }
    }

    struct Rig {
        let native: ChromiumPage
        let page: BrowserPage
        let remote: ChromiumRemoteBrowser
        let recorder: Recorder
        let connection: ChromiumRemote
        let window: NSWindow

        var sink: ChromiumFrameSink {
            connection.sink
        }

        func end() async {
            window.contentView = nil
            window.close()
            connection.disconnect()
            await page.close()
        }
    }

    /// A page with a made browser (as `ChromiumOOPPageTests.makeRig`), whose frame layer is registered and which is in a window of
    /// its own. The browser is given to the page before the page joins the window, so that nothing asks the process's latch.
    func makeRig() async -> Rig {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-display-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
        let remote = ChromiumRemoteBrowser(page: native, connection: connection)
        let recorder = Recorder()
        remote.outgoing = { message in
            recorder.messages.append(message)
            return true
        }
        native.remote = remote
        native.preparation = Task<Void, Error> {}
        native.hasAppliedInitialSettings = true
        remote.markCreated()
        native.attachRemoteFrameLayer(to: remote)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        let rig = Rig(native: native, page: page, remote: remote, recorder: recorder, connection: connection, window: window)
        await settle()
        recorder.messages.removeAll()
        return rig
    }

    /// Long enough for the end of a run-loop turn (where visibility is sent) to have come, whatever the machine is doing.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    private func surface() throws -> IOSurface {
        try #require(IOSurface(properties: [.width: 16, .height: 16, .bytesPerElement: 4, .pixelFormat: 0x4247_5241]))
    }

    // MARK: Geometry

    @Test func aPageSendsItsSizeAndScaleWhenTheyChangeAndNothingWhenTheyDoNot() async {
        let rig = await makeRig()
        let scale = rig.window.backingScaleFactor
        for size in [CGSize(width: 900, height: 640), CGSize(width: 1300, height: 860)] {
            rig.native.setFrameSize(size)
            #expect(rig.remote.pageLayer?.frame.size == size, "the frame layer follows the view at once")
            await settle()
            let last = rig.recorder.sent(CefRemote.Op.resize).last
            #expect(last?.double(CefRemote.Key.width) == Double(size.width))
            #expect(last?.double(CefRemote.Key.height) == Double(size.height))
            #expect(last?.double(CefRemote.Key.scale) == Double(scale))
            if rig.window.screen != nil {
                #expect(last?.double(CefRemote.Key.screenWidth) ?? 0 >= 1, "the screen goes with it")
            }
        }
        #expect(rig.recorder.sent(CefRemote.Op.resize).count == 2)
        rig.native.setFrameSize(CGSize(width: 1300, height: 860))
        rig.native.viewDidChangeBackingProperties()
        rig.native.updateRemoteGeometry()
        await settle()
        #expect(rig.recorder.sent(CefRemote.Op.resize).count == 2, "a size and scale the service already has are not sent again")
        #expect(rig.remote.pageLayer?.contentsScale == scale)
        await rig.end()
    }

    /// The exit gate's F4: a drag (or a layout pass) changes the size many times in one turn; the service is told once, with the last.
    @Test func manySizeChangesInOneTurnSendExactlyOneResizeWithTheFinalSize() async {
        let rig = await makeRig()
        let final = CGSize(width: 1111, height: 777)
        for step in 0..<120 {
            rig.native.setFrameSize(CGSize(width: 900 + CGFloat(step), height: 640))
        }
        rig.native.setFrameSize(final)
        #expect(rig.recorder.sent(CefRemote.Op.resize).isEmpty, "nothing is sent inside the turn")
        #expect(rig.remote.pageLayer?.frame.size == final, "the layer is the view's size, whatever was sent")
        await settle()
        let messages = rig.recorder.sent(CefRemote.Op.resize)
        #expect(messages.count == 1, "one message for the turn, not one for each size: \(messages.count)")
        #expect(messages.first?.double(CefRemote.Key.width) == Double(final.width))
        #expect(messages.first?.double(CefRemote.Key.height) == Double(final.height))
        #expect(rig.remote.resizesSent == 1)
        await rig.end()
    }

    /// The exit gate's second F4 point: a browser that does not exist yet holds what is sent to it. Resizes while it is made are one.
    @Test func resizesSentBeforeTheBrowserExistsAreHeldAsOneWithTheLastSize() {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory }, latch: ChromiumOOP.Latch(), isEnabled: { true })
        let remote = ChromiumRemoteBrowser(page: native, connection: connection)
        let recorder = Recorder()
        remote.outgoing = { message in
            recorder.messages.append(message)
            return true
        }
        for width in 1...200 {
            remote.send(CefRemote.Op.resize) {
                $0.set(CefRemote.Key.width, Double(width))
                $0.set(CefRemote.Key.height, 600.0)
            }
            remote.send(CefRemote.Op.mute) { $0.set(CefRemote.Key.flag, width.isMultiple(of: 2)) }
        }
        remote.markCreated()
        let resizes = recorder.sent(CefRemote.Op.resize)
        #expect(resizes.count == 1 && resizes.first?.double(CefRemote.Key.width) == 200, "one resize, the last: \(resizes.count)")
        #expect(recorder.sent(CefRemote.Op.mute).count == 200, "the other messages are all kept, in order")
        connection.disconnect()
    }

    @Test func aTurnThatEndsAtTheSizeItBeganAtSendsNoResize() async {
        let rig = await makeRig()
        let size = rig.native.bounds.size
        rig.native.setFrameSize(CGSize(width: size.width + 40, height: size.height + 40))
        rig.native.setFrameSize(size)
        await settle()
        #expect(rig.recorder.sent(CefRemote.Op.resize).isEmpty)
        await rig.end()
    }

    @Test func theFrameLayerIsASublayerOfTheViewsLayerAtItsSize() async {
        let rig = await makeRig()
        #expect(rig.remote.pageLayer?.superlayer === rig.native.layer)
        #expect(rig.remote.pageLayer?.frame.size == rig.native.bounds.size)
        #expect(rig.sink.popupLayer(for: rig.remote.id)?.superlayer === rig.remote.pageLayer, "the sink made the pop-up layer on main")
        let host = rig.native.layer?.contentsAreFlipped() ?? false, frames = rig.remote.pageLayer?.contentsAreFlipped() ?? false
        print("ChromiumOOPDisplayTests observed: view flipped \(rig.native.isFlipped), host layer flipped \(host), frame layer flipped \(frames)")
        await rig.end()
    }

    // MARK: Visibility

    @Test func threeWindowMovesInOneTurnSendExactlyOneVisibilityMessageWithTheFinalState() async {
        let rig = await makeRig()
        rig.window.contentView = nil
        rig.window.contentView = rig.page
        rig.window.contentView = nil
        #expect(rig.recorder.sent(CefRemote.Op.visibility).isEmpty, "nothing is sent inside the turn")
        await settle()
        let messages = rig.recorder.sent(CefRemote.Op.visibility)
        #expect(messages.count == 1, "one message for the turn, not one for each move: \(messages.count)")
        #expect(messages.first?.bool(CefRemote.Key.hidden) == true)
        #expect(messages.first?.bool(CefRemote.Key.parked) == false)
        await rig.end()
    }

    @Test func aPageThatEndsTheTurnWhereItBeganSendsNothing() async {
        let rig = await makeRig()
        rig.window.contentView = nil
        rig.window.contentView = rig.page
        rig.page.isHidden = true
        rig.page.isHidden = false
        await settle()
        #expect(rig.recorder.sent(CefRemote.Op.visibility).isEmpty)
        // One that is hidden, and shown in a later turn, sends both.
        rig.page.isHidden = true
        await settle()
        rig.page.isHidden = false
        await settle()
        let messages = rig.recorder.sent(CefRemote.Op.visibility)
        #expect(messages.map { $0.bool(CefRemote.Key.hidden) } == [true, false])
        await rig.end()
    }

    @Test func aPageOnTheShelfIsParkedNotHidden() async {
        let rig = await makeRig()
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        root.addSubview(WebViewParkingShelf(frame: .zero))
        rig.window.contentView = root
        WebViewParking.park(rig.page, in: rig.window)
        await settle()
        let messages = rig.recorder.sent(CefRemote.Op.visibility)
        #expect(messages.count == 1, "the window move and the parking are one turn")
        #expect(messages.first?.bool(CefRemote.Key.hidden) == false)
        #expect(messages.first?.bool(CefRemote.Key.parked) == true)
        // A page that hides while parked is hidden, not parked.
        rig.page.isHidden = true
        await settle()
        #expect(rig.recorder.sent(CefRemote.Op.visibility).last?.bool(CefRemote.Key.hidden) == true)
        #expect(rig.recorder.sent(CefRemote.Op.visibility).last?.bool(CefRemote.Key.parked) == false)
        await rig.end()
    }

    // MARK: Frames in the layer

    @Test func aFrameReachesThePageLayerAndStaysThereWhileThePageIsHiddenUntilANewOneArrives() async throws {
        let rig = await makeRig()
        let first = try surface()
        rig.sink.framesQueue.sync { rig.sink.apply(surface: first, browser: rig.remote.id, popup: false) }
        #expect(rig.remote.pageLayer?.contents as AnyObject? === first)
        #expect(rig.sink.framesShown == 1)
        // Hidden: the service frees its ring and sends no frames; the layer keeps the last one, which the person sees on return.
        rig.window.contentView = nil
        await settle()
        #expect(rig.remote.pageLayer?.contents as AnyObject? === first, "the tab's last preview stays")
        let second = try surface()
        rig.window.contentView = rig.page
        await settle()
        #expect(rig.remote.pageLayer?.contents as AnyObject? === first, "and stays until the first frame")
        rig.sink.framesQueue.sync { rig.sink.apply(surface: second, browser: rig.remote.id, popup: false) }
        #expect(rig.remote.pageLayer?.contents as AnyObject? === second)
        await rig.end()
    }

    @Test func theFrameLayerLeavesTheTreeWhenTheBrowserEndsAndAnyFrameAfterwardsIsDropped() async throws {
        let rig = await makeRig()
        let layer = try #require(rig.remote.pageLayer)
        #expect(rig.sink.isRegistered(browser: rig.remote.id) && layer.superlayer != nil)
        rig.remote.remoteServiceEnded()
        #expect(!rig.sink.isRegistered(browser: rig.remote.id))
        #expect(layer.superlayer == nil && layer.contents == nil)
        let late = try surface()
        rig.sink.framesQueue.sync { rig.sink.apply(surface: late, browser: rig.remote.id, popup: false) }
        #expect(layer.contents == nil)
        #expect(rig.sink.framesDropped == 1)
        await rig.end()
    }

    // MARK: Memory that no process footprint shows (exit gate F5)

    @Test func aHiddenPagesPreviewAndBrowserAreCountedWhereNoProcessFootprintSeesThem() async throws {
        let rig = await makeRig()
        ChromiumRuntime.shared.register(rig.native)
        let frame = try surface()
        rig.sink.framesQueue.sync { rig.sink.apply(surface: frame, browser: rig.remote.id, popup: false) }
        let shown = ChromiumRuntime.shared.remoteMemory
        #expect(shown.previews >= 1 && shown.browsers >= 1)
        #expect(rig.native.previewBytes == frame.allocationSize && frame.allocationSize > 0)
        let hiddenBefore = shown.hiddenBrowsers
        rig.window.contentView = nil
        await settle()
        let hidden = ChromiumRuntime.shared.remoteMemory
        #expect(hidden.hiddenBrowsers >= hiddenBefore + 1, "the hidden browser is counted")
        #expect(hidden.previewBytes >= frame.allocationSize, "and its preview stays in the count: hiding frees nothing in WSurf")
        #expect(rig.native.previewBytes == frame.allocationSize)
        await rig.end()
        #expect(!ChromiumRuntime.shared.livePages.contains { $0 === rig.native }, "a closed page leaves the count")
    }
}
