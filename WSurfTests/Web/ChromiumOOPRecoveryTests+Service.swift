// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Darwin
import Foundation
import Testing
import WebKit

@testable import CefKit
@testable import WSurf

/// The second group of `ChromiumOOPRecoveryTests`: the real service, killed and left idle, with real pages and fixtures on 127.0.0.1
/// (the OOP lane: `Tools/run-chromium-oop-tests.sh ChromiumOOPRecoveryTests`), each test gated on `ChromiumServiceBundle.isPresent`.
///
/// launchd starts a service no sooner than 10 s after the spawn of the one before it, and a replacement of a service that died
/// younger than that waits for the difference (D4-4a, D4-5). A test that times a relaunch therefore lets the service run 11 s from
/// its hello first. Each test has a connection of its own (`Env`) and ends it, and the service with it, before the next starts.
extension ChromiumOOPRecoveryTests {
    /// How long the visible page may take to be loaded again after the kill.
    static let reloadBudget: TimeInterval = 3
    /// The longest the main thread may be busy between two ticks of the 2 ms timer while the service is killed and replaced.
    static let mainGapBudgetMs = 100.0

    struct Env {
        let server: HTTPFixtureServer
        let connection: ChromiumRemote
        /// When the first hello was answered (system uptime).
        let up: TimeInterval
        let pid: pid_t

        func url(_ path: String) throws -> URL {
            try server.url(path)
        }
    }

    /// A page of the environment: its own context, window and browser, on the environment's connection, with the tab's reaction to a
    /// lost browser (`BrowserTab.contentProcessDidTerminate`: load the committed address again).
    @MainActor
    final class Tab {
        let native: ChromiumPage
        let page: BrowserPage
        let window: NSWindow
        let context: BrowserProfileContext
        /// Finished loads (`onNavigationFinished`), and the browser each was made by.
        private(set) var finished = 0
        private(set) var failures: [Error] = []

        init(_ env: Env) {
            context = BrowserProfileContext(profile: .privateBrowsing())
            native = ChromiumPage(context: context)
            native.remoteConnection = env.connection
            page = BrowserPage(chromium: native)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            window.orderBack(nil)
            page.onNavigationFinished = { [weak self] _ in self?.finished += 1 }
            page.onNavigationFailed = { [weak self] _, error in self?.failures.append(error) }
            page.onContentProcessTerminated = { [weak page] in
                guard let page, let url = page.url else { return }
                page.load(URLRequest(url: url))
            }
        }

        func load(_ url: URL) async throws {
            let before = finished
            page.load(URLRequest(url: url))
            try #require(await waitUntil { finished > before && !page.isLoading && page.url == url }, "\(url) did not load: \(failures)")
        }

        func finish() async {
            page.onContentProcessTerminated = nil
            window.contentView = nil
            window.close()
            await page.close()
            await context.endPrivateSession()
        }
    }

    static let routes: [String: HTTPFixtureServer.Response] = [
        "/one": .html("<!doctype html><title>One</title><body style='margin:0;background:#ff0000'><p>one</p>"),
        "/two": .html("<!doctype html><title>Two</title><body style='margin:0;background:#0000ff'><p>two</p>"),
    ]

    /// A connection of its own to the service (`linger` seconds of idleness before it leaves; nil is the service's 60), with its first
    /// hello answered. Nil when there is no service or no answer.
    func env(linger: Double? = nil) async throws -> Env? {
        let server = try await HTTPFixtureServer.start(routes: Self.routes)
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let canonical = try ChromiumRemote.prepareRoot(root)
        let connection = ChromiumRemote(
            sink: ChromiumFrameSink(), root: { canonical }, linger: linger, helloTimeout: 30,
            clock: { ProcessInfo.processInfo.systemUptime }, latch: ChromiumOOP.Latch(), isEnabled: { true })
        _ = connection.connect()
        guard await waitUntil(timeout: .seconds(45), { connection.isRunning }), case let .running(pid) = connection.state else {
            Issue.record("no hello: \(connection.state): \(connection.lastRefusalText)")
            connection.disconnect()
            return nil
        }
        return Env(server: server, connection: connection, up: ProcessInfo.processInfo.systemUptime, pid: pid)
    }

    /// Ends the environment so that no service outlives it (the next test needs a fresh one).
    func end(_ env: Env) async {
        env.connection.disconnect()
        let gone = await waitUntil(timeout: .seconds(10)) { kill(env.pid, 0) == -1 && errno == ESRCH }
        #expect(gone, "the service \(env.pid) did not leave after its connection closed")
    }

    // MARK: The kill

    /// The plan's test: a service killed with a shown page and a hidden one in it. The shown one is loaded again within 3 s (the
    /// service had run 11 s, so launchd holds the replacement back no longer), the hidden one not until it is shown, and the main
    /// thread is never busy for 100 ms on the way.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func aKilledServiceLoadsTheShownPageAgainWithinThreeSecondsAndTheHiddenPageOnlyWhenItIsShown() async throws {
        guard let env = try await env() else { return }
        let shown = Tab(env), hidden = Tab(env)
        let one = try env.url("/one"), two = try env.url("/two")
        try await shown.load(one)
        try await hidden.load(two)
        hidden.page.isHidden = true
        #expect(await waitUntil { hidden.native.remote?.sentHidden == true }, "the service was told the page is hidden")
        let old = (shown: try #require(shown.native.remote), hidden: try #require(hidden.native.remote))
        // The first instance has to be 11 s old: launchd spawns no replacement before 10 s after the spawn that died.
        let wait = 11 - (ProcessInfo.processInfo.systemUptime - env.up)
        if wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }
        let watch = HitchWatch()
        let finishedBefore = shown.finished
        watch.start()
        let killed = ProcessInfo.processInfo.systemUptime
        env.connection.abortService()
        let reloaded = await waitUntil(timeout: .seconds(Self.reloadBudget + 10)) { shown.finished > finishedBefore && !shown.page.isLoading }
        let took = ProcessInfo.processInfo.systemUptime - killed
        watch.stop()
        #expect(reloaded, "the shown page was not loaded again: remote \(String(describing: shown.native.remote)), state \(env.connection.state)")
        #expect(took <= Self.reloadBudget, "the shown page was loaded again \(took) s after the kill")
        #expect(shown.page.url == one && shown.native.remote !== old.shown)
        #expect(watch.longestMs < Self.mainGapBudgetMs, "the main thread was busy for \(watch.longestMs) ms")
        print("ChromiumOOPRecoveryTests observed: kill after 11 s, the shown page loaded again after \(took) s, main thread longest gap \(watch.longestMs) ms over \(watch.gaps.count) ticks")
        // The hidden page waits: its browser is not made, and the service holds only the shown page's.
        try await Task.sleep(for: .seconds(1))
        #expect(hidden.native.remote == nil && hidden.native.recovery == .waitingForActivation, "hidden: \(String(describing: hidden.native.remote))")
        #expect(env.connection.browserCount == 1)
        // Shown, it comes back.
        let hiddenBefore = hidden.finished
        hidden.page.isHidden = false
        #expect(await waitUntil(timeout: .seconds(Self.reloadBudget + 10)) { hidden.finished > hiddenBefore && !hidden.page.isLoading })
        #expect(hidden.page.url == two && hidden.native.remote !== old.hidden)
        #expect(env.connection.browserCount == 2)
        await shown.finish()
        await hidden.finish()
        await end(env)
    }

    // MARK: The screen the page sees

    /// What the page reads of the screen (`screen.width`, `screen.height`, `devicePixelRatio`), through DevTools, once it has the
    /// window's: the service tells CEF with `notify_screen_info_changed`, and a browser made again after a relaunch is told as
    /// soon as it exists (review of #129, F1 and F2). Waits for the values to settle: the notification is asynchronous.
    private func pageScreen(_ tab: Tab, matching screen: NSScreen) async -> [Double] {
        let want = [Double(screen.frame.width), Double(screen.frame.height), Double(screen.backingScaleFactor)]
        var seen: [Double] = []
        _ = await waitUntil(timeout: .seconds(8)) {
            let value = try? await tab.page.evaluateJavaScript("[screen.width, screen.height, devicePixelRatio]") as? [NSNumber]
            seen = value?.map(\.doubleValue) ?? []
            return seen == want
        }
        return seen
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func theScreenThePageReadsIsTheWindowsScreenAfterTheCreateAndAfterARelaunchReload() async throws {
        guard let env = try await env() else { return }
        let tab = Tab(env)
        guard let screen = tab.window.screen else {
            await end(env)
            return
        }
        let want = [Double(screen.frame.width), Double(screen.frame.height), Double(screen.backingScaleFactor)]
        let one = try env.url("/one")
        try await tab.load(one)
        #expect(await pageScreen(tab, matching: screen) == want, "after the create")
        let wait = 11 - (ProcessInfo.processInfo.systemUptime - env.up)
        if wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        }
        let before = tab.finished
        env.connection.abortService()
        #expect(await waitUntil(timeout: .seconds(Self.reloadBudget + 10)) { tab.finished > before && !tab.page.isLoading }, "reloaded")
        #expect(await pageScreen(tab, matching: screen) == want, "after the relaunch reload")
        // A screen that changes with no change of size: CEF is told by `notify_screen_info_changed` and nothing else.
        let remote = try #require(tab.native.remote)
        remote.send(CefRemote.Op.resize) {
            $0.set(CefRemote.Key.width, Double(remote.sentSize.width))
            $0.set(CefRemote.Key.height, Double(remote.sentSize.height))
            $0.set(CefRemote.Key.scale, Double(remote.sentScale))
            $0.set(CefRemote.Key.screenX, 0.0)
            $0.set(CefRemote.Key.screenY, 0.0)
            $0.set(CefRemote.Key.screenWidth, 1111.0)
            $0.set(CefRemote.Key.screenHeight, 777.0)
        }
        var changed: [Double] = []
        let followed = await waitUntil(timeout: .seconds(8)) {
            let value = try? await tab.page.evaluateJavaScript("[screen.width, screen.height]") as? [NSNumber]
            changed = value?.map(\.doubleValue) ?? []
            return changed == [1111, 777]
        }
        #expect(followed, "a screen that changed with no change of size reaches the page: \(changed)")
        print("ChromiumOOPRecoveryTests observed: screen \(want), the page reads it after the create and after the relaunch, and follows a change of screen alone")
        await tab.finish()
        await end(env)
    }

    // MARK: The idle exit

    /// The last tab closed: the service leaves after its linger (1 s here) and is not relaunched; the next new tab launches it again
    /// and loads.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent), .boundedWebViews)
    func closingTheLastTabLetsTheServiceLeaveAfterItsLingerAndTheNextTabLaunchesItAgain() async throws {
        guard let env = try await env(linger: 1) else { return }
        let first = Tab(env)
        try await first.load(try env.url("/one"))
        // The environment's own hello may have been preceded by one that found the last test's service leaving: count from here.
        let hellos = env.connection.helloCount
        await first.finish()
        let closed = ProcessInfo.processInfo.systemUptime
        let gone = await waitUntil(timeout: .seconds(3)) { kill(env.pid, 0) == -1 && errno == ESRCH }
        let took = ProcessInfo.processInfo.systemUptime - closed
        #expect(gone, "the service \(env.pid) was still there 3 s after the last tab closed")
        print("ChromiumOOPRecoveryTests observed: last tab closed, linger 1 s, the service was gone after \(took) s")
        #expect(await waitUntil(timeout: .seconds(3)) { env.connection.state == .stopped }, "an idle exit is not relaunched: \(env.connection.state)")
        #expect(env.connection.helloCount == hellos && env.connection.browserCount == 0, "no relaunch: hello \(env.connection.helloCount) after \(hellos)")
        // The next tab asks for the service again (launchd may hold the spawn back until 10 s after the first one).
        let second = Tab(env)
        try await second.load(try env.url("/two"))
        #expect(env.connection.helloCount == hellos + 1, "a new hello")
        guard case let .running(pid) = env.connection.state else {
            Issue.record("the service is not running: \(env.connection.state)")
            await second.finish()
            env.connection.disconnect()
            return
        }
        #expect(pid != env.pid)
        #expect(second.page.url == (try env.url("/two")))
        await second.finish()
        env.connection.disconnect()
        #expect(await waitUntil(timeout: .seconds(10)) { kill(pid, 0) == -1 && errno == ESRCH })
    }

    /// Prewarm in this mode launches the service and nothing else: no browser, no context.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anEarlyStartLaunchesTheServiceAndMakesNoBrowser() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
        let canonical = try ChromiumRemote.prepareRoot(root)
        let connection = ChromiumRemote(
            sink: ChromiumFrameSink(), root: { canonical }, helloTimeout: 30,
            clock: { ProcessInfo.processInfo.systemUptime }, latch: ChromiumOOP.Latch(), isEnabled: { true })
        // `ChromiumRuntime.startEarly` is this one call on the process's connection.
        #expect(connection.connect() == .starting)
        guard await waitUntil(timeout: .seconds(45), { connection.isRunning }), case let .running(pid) = connection.state else {
            Issue.record("no hello: \(connection.state)")
            connection.disconnect()
            return
        }
        #expect(connection.browserCount == 0)
        let stats = await connection.statistics()
        #expect(stats?.int(CefRemote.Key.pid) == Int64(pid))
        connection.disconnect()
        #expect(await waitUntil(timeout: .seconds(10)) { kill(pid, 0) == -1 && errno == ESRCH })
    }
}
