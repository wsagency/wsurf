// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import CefKit
@testable import WSurf

/// D4-10: what a `ChromiumPage` in the Chromium service does when its browser is gone. The service ends (a crash, a kill, its own
/// exit): every page resets through `didTerminate`, which the tab answers by loading its committed address again. A page that is
/// shown does that at once (the load waits, in order, for the relaunched service's hello); a hidden one waits until it is shown; a
/// service that keeps dying leaves the tab in its crash state until the person reloads. The last tab closed lets the service
/// leave after its linger, and the next one launches it again.
///
/// The tests that make a page load again need `WSurf Chromium.xpc` (the OOP lane: `Tools/run-chromium-oop-tests.sh
/// ChromiumOOPRecoveryTests`) and are skipped without it: a page that lost its browser asks the process's latch where its next one is
/// made, which must never be "in process" in the default lane. The first group (this file) drives a page with a recorded browser
/// and a connection that has no service; the second (`+Service`) kills and idles the real one.
@MainActor
@Suite(.serialized)
struct ChromiumOOPRecoveryTests {
    init() {
        #if DEBUG
        // Before any Chromium start of this host, as `ChromiumOOPPageTests`.
        ChromiumOOP.testOverride = true
        #endif
    }

    static let address = URL(string: "https://recovery.example/page")!

    final class Recorder {
        var messages: [CefRemoteMessage] = []

        func sent(_ op: String) -> [CefRemoteMessage] {
            messages.filter { $0.op == op }
        }
    }

    final class Flag {
        var raised = false
    }

    struct Rig {
        let native: ChromiumPage
        let page: BrowserPage
        let remote: ChromiumRemoteBrowser
        let recorder: Recorder
        let connection: ChromiumRemote
        let window: NSWindow

        /// What the tab does when its page's content is gone (`BrowserTab.contentProcessDidTerminate`): it loads the address again.
        func reloadLikeTheTab() {
            page.onContentProcessTerminated = { [weak page] in
                page?.load(URLRequest(url: ChromiumOOPRecoveryTests.address))
            }
        }

        func end() async {
            page.onContentProcessTerminated = nil
            window.contentView = nil
            window.close()
            connection.disconnect()
            await page.close()
        }
    }

    /// A page with a made browser whose messages go to a recorder, in a window of its own, on a connection that has no service.
    func makeRig() async -> Rig {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let native = ChromiumPage(context: context)
        let page = BrowserPage(chromium: native)
        let connection = ChromiumRemote(
            serviceName: ChromiumRemoteClientTests.noSuchService, sink: ChromiumFrameSink(),
            root: { FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-recovery-\(UUID().uuidString)", directoryHint: .isDirectory) },
            latch: ChromiumOOP.Latch(), isEnabled: { true })
        native.remoteConnection = connection
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        let rig = Rig(native: native, page: page, remote: remote, recorder: recorder, connection: connection, window: window)
        await settle()
        return rig
    }

    /// Long enough for the end of a run-loop turn (where visibility and the recovery check are made) to have come.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    // MARK: Which pages load again, and when

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aPageThatIsShownLoadsItsAddressAgainAsSoonAsTheServiceEnds() async {
        let rig = await makeRig()
        rig.reloadLikeTheTab()
        rig.remote.remoteServiceEnded()
        #expect(rig.native.recovery == .none)
        #expect(await waitUntil { rig.native.remote != nil && rig.native.remote !== rig.remote }, "a new browser was asked for")
        #expect(rig.native.requestedURL == Self.address)
        await rig.end()
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHiddenPageLoadsItsAddressAgainOnlyWhenItIsShown() async {
        let rig = await makeRig()
        rig.page.isHidden = true
        await settle()
        rig.reloadLikeTheTab()
        rig.remote.remoteServiceEnded()
        #expect(rig.native.recovery == .waitingForActivation)
        #expect(rig.native.heldReload?.url == Self.address, "the tab's reload is held, not dropped")
        await settle()
        #expect(rig.native.remote == nil, "no browser is made for a page nobody sees")
        rig.page.isHidden = false
        #expect(await waitUntil { rig.native.remote != nil }, "shown: its browser is asked for")
        #expect(rig.native.recovery == .none && rig.native.heldReload == nil)
        #expect(rig.native.requestedURL == Self.address)
        await rig.end()
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aServiceThatKeepsDyingLeavesTheCrashStateUntilThePersonReloads() async {
        let rig = await makeRig()
        var failures: [Error] = []
        rig.page.onNavigationFailed = { _, error in failures.append(error) }
        let connection = rig.connection
        // Three deaths in a row, with no await between them: the third trips the cap, and the page hears of it after the state is
        // set. The tab (its stand-in) reloads when the page says its content is gone, as it does at the third.
        for death in 0..<3 {
            if rig.native.remote == nil {
                rig.native.remote = ChromiumRemoteBrowser(page: rig.native, connection: connection)
            }
            if death == 2 {
                rig.reloadLikeTheTab()
            }
            connection.receive(.interrupted, generation: connection.generation)
        }
        #expect(connection.state == .crashLooping)
        #expect(rig.native.recovery == .waitingForPerson)
        let hellos = connection.helloCount
        #expect(await waitUntil { !failures.isEmpty }, "the tab's own reload fails, and that is the crash state it shows")
        #expect(!rig.page.isLoading)
        #expect(connection.helloCount == hellos && connection.state == .crashLooping, "nothing launched the service again")
        // The person reloads: the loop is given up, the service is asked for, and the page loads.
        rig.page.reload()
        #expect(rig.native.recovery == .none)
        #expect(connection.state != .crashLooping)
        #expect(connection.helloCount == hellos + 1)
        await rig.end()
    }

    /// Review of #129, F1: a browser made again for a page that is already in its window is told the screen it is on.
    @Test
    func aBrowserMadeAgainForAPageInItsWindowIsToldTheScreen() async throws {
        let rig = await makeRig()
        guard rig.window.screen != nil else { await rig.end(); return }
        rig.remote.remoteServiceEnded()
        #expect(rig.native.remote == nil)
        try rig.native.materializeRemote()
        let made = try #require(rig.native.remote)
        #expect(made.sentScreen == rig.window.screen?.frame.size, "the screen is sent (held until the browser is made), not left unknown")
        #expect(made.sentScreen != .zero)
        await rig.end()
    }

    // MARK: A cancelled load does not leave the tab loading (carried from the D4-8 delta review)

    /// The tab does not reload a page that died twice in five seconds ("leaving the tab alone"): nothing else ends its loading.
    @Test
    func aLoadCancelledByTheServiceEndingLeavesNoLoadingWhenTheTabLeavesThePageAlone() async {
        let rig = await makeRig()
        rig.page.load(URLRequest(url: Self.address))
        #expect(await waitUntil { !rig.recorder.sent(CefRemote.Op.load).isEmpty })
        #expect(rig.page.isLoading)
        rig.remote.remoteServiceEnded()
        #expect(!rig.page.isLoading, "the cancelled load is not left loading")
        await rig.end()
    }

    @Test
    func aLoadCancelledByTheBrowserClosingLeavesNoLoadingWhenTheTabLeavesThePageAlone() async {
        let rig = await makeRig()
        rig.page.load(URLRequest(url: Self.address))
        #expect(await waitUntil { !rig.recorder.sent(CefRemote.Op.load).isEmpty })
        #expect(rig.page.isLoading)
        rig.remote.remoteEvent(CefRemoteMessage(CefRemote.Event.browserClosed, browser: rig.remote.id))
        #expect(!rig.page.isLoading)
        await rig.end()
    }

    // MARK: Late events of a browser the page let go of

    /// A browser's events after the page made a new one are not the page's (carried from the same review).
    @Test
    func anEventOfABrowserThePageLetGoOfDoesNotReachThePage() async throws {
        let rig = await makeRig()
        var terminated = 0
        rig.page.onContentProcessTerminated = { terminated += 1 }
        let old = rig.remote
        old.remoteServiceEnded()
        #expect(terminated == 1)
        let next = ChromiumRemoteBrowser(page: rig.native, connection: rig.connection)
        rig.native.remote = next
        old.remoteEvent(CefRemoteMessage(CefRemote.Event.renderTerminated, browser: old.id))
        #expect(terminated == 1, "the late event of the old browser is dropped")
        next.remoteEvent(CefRemoteMessage(CefRemote.Event.renderTerminated, browser: next.id))
        #expect(terminated == 2, "the page's own browser still reaches it")
        await rig.end()
    }

    /// The case that mattered: command ids restart in the page's next DevTools, so a late reply of the old browser could answer a
    /// command of the new one.
    @Test
    func aLateReplyOfAnAbandonedBrowserDoesNotAnswerACommandOfTheNewOne() async throws {
        let rig = await makeRig()
        let old = rig.remote
        old.remoteServiceEnded()
        let next = ChromiumRemoteBrowser(page: rig.native, connection: rig.connection)
        let recorder = Recorder()
        next.outgoing = { message in
            recorder.messages.append(message)
            return true
        }
        rig.native.remote = next
        try rig.native.devTools.attach(remote: next)
        next.markCreated()
        let answered = Flag()
        let command = Task { [native = rig.native] in
            _ = try? await native.devTools.command("Browser.getVersion")
            answered.raised = true
        }
        #expect(await waitUntil { !recorder.sent(CefRemote.Op.devTools).isEmpty })
        let sent = try #require(recorder.sent(CefRemote.Op.devTools).first)
        var id = -1
        sent.withBytes(CefRemote.Key.data) { pointer, size in
            guard let pointer else { return }
            let object = try? JSONSerialization.jsonObject(with: Data(bytes: pointer, count: size)) as? [String: Any]
            id = (object?["id"] as? Int) ?? -1
        }
        #expect(id > 0)
        func reply(from browser: ChromiumRemoteBrowser) -> CefRemoteMessage {
            let message = CefRemoteMessage(CefRemote.Event.devToolsResult, browser: browser.id)
            message.set(CefRemote.Key.identifier, id)
            message.set(CefRemote.Key.success, true)
            message.set(CefRemote.Key.data, data: Data("{}".utf8))
            return message
        }
        old.remoteEvent(reply(from: old))
        await settle()
        #expect(!answered.raised, "the old browser's reply does not match the new browser's command")
        next.remoteEvent(reply(from: next))
        #expect(await waitUntil { answered.raised })
        _ = await command.value
        await rig.end()
    }
}
