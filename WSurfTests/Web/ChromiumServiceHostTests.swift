// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import os
import Testing
import XPC

@testable import CefKit
@testable import WSurf

/// D4-4a: the Chromium service's host, driven over raw XPC with `CefRemoteMessage`. No WSurf client code is involved (that is
/// D4-5), and no browser is created (D4-4b): the lifecycle is exercised with the service's DEBUG stub browsers.
///
/// Every test needs `WSurf Chromium.xpc`, which only a build with `WSURF_CHROMIUM_OOP_BUILD=YES` has
/// (`Tools/run-chromium-oop-tests.sh ChromiumServiceHostTests`), so each is gated on `ChromiumServiceBundle.isPresent`. All the
/// connections of this host reach one service instance (JoinExistingSession), so the suite is serialized and each test ends
/// by waiting for that instance to leave, which gives the next test a fresh one. Each test gets its own temporary root, and
/// CEF runs there with the service's mock keychain; in-process CEF is never started in this host.
@Suite(.serialized)
struct ChromiumServiceHostTests {
    private static let helloTimeout: TimeInterval = 30

    // MARK: Hello

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func helloStartsCEFAndTheReplyCarriesThePidAndTheStartTime() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        let reply = try client.hello()
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        #expect(reply.int(CefRemote.Key.protocolVersion) == CefRemote.protocolVersion)
        let pid = try #require(client.pid)
        #expect(pid > 1 && pid != getpid())
        #expect(reply.double(CefRemote.Key.startMs) > 0, "CEF's start time")
        let stats = try client.stats()
        #expect(stats.bool(CefRemote.Key.started))
        #expect(stats.int(CefRemote.Key.pid) == Int64(pid))
        #expect(stats.int(CefRemote.Key.count) == 0)
        // Plan §1.8 and D4-S: the mock keychain always, and CEF's log nowhere unless WSurf names a file.
        #expect(stats.bool(CefRemote.Key.mockKeychain))
        #expect(stats.string(CefRemote.Key.logFile) == "/dev/null")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHelloWithAnotherProtocolVersionIsRefusedAndStartsNothing() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        for version in [CefRemote.protocolVersion + 1, 0] {
            let hello = CefRemoteMessage.hello(protocolVersion: version)
            hello.set(CefRemote.Key.rootPath, client.root.path)
            let reply = try client.call(hello, timeout: Self.helloTimeout)
            #expect(!reply.bool(CefRemote.Key.success), "version \(version) must be refused")
            #expect(reply.int(CefRemote.Key.protocolVersion) == CefRemote.protocolVersion, "the refusal names the service's version")
            #expect(!reply.string(CefRemote.Key.error).isEmpty)
        }
        let stats = try client.stats()
        #expect(!stats.bool(CefRemote.Key.started), "a refused hello starts no CEF")
        // A hello with no version at all (an old or foreign sender) is a mismatch too.
        let bare = CefRemoteMessage(CefRemote.Op.hello)
        bare.set(CefRemote.Key.rootPath, client.root.path)
        #expect(!(try client.call(bare, timeout: Self.helloTimeout)).bool(CefRemote.Key.success))
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aSecondHostIsRefusedWhileTheFirstIsConnected() throws {
        let first = try ChromiumServiceClient()
        defer { first.finish() }
        #expect(try first.hello().bool(CefRemote.Key.success))
        let second = try ChromiumServiceClient(root: first.root)
        defer { second.close() }
        let hello = CefRemoteMessage.hello()
        hello.set(CefRemote.Key.rootPath, first.root.path)
        let reply = try second.call(hello)
        #expect(!reply.bool(CefRemote.Key.success))
        // The first host is untouched.
        #expect(try first.stats().int(CefRemote.Key.pid) == Int64(try #require(first.pid)))
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aSecondConnectionCannotActOnTheFirstHostsBrowsersOrContexts() throws {
        let first = try ChromiumServiceClient()
        defer { first.finish() }
        #expect(try first.hello().bool(CefRemote.Key.success))
        try first.stubBrowser(1)
        let second = try ChromiumServiceClient(root: first.root)
        defer { second.close() }
        // The second connection never says hello (or its hello is refused: both leave it no host), and sends what only the host may.
        let hello = CefRemoteMessage.hello()
        hello.set(CefRemote.Key.rootPath, first.root.path)
        #expect(!(try second.call(hello)).bool(CefRemote.Key.success))
        second.send(CefRemoteMessage(CefRemote.Op.close, browser: 1))
        let context = CefRemoteMessage(CefRemote.Op.createContext)
        context.set(CefRemote.Key.context, "intruder")
        context.set(CefRemote.Key.cachePath, first.root.appending(path: "intruder").path)
        // Messages of one connection are served in order: the answer to this one means the `browser.close` before it was served.
        let refused = try second.call(context)
        #expect(!refused.bool(CefRemote.Key.success), "a context asked for by a connection that is not the host")
        #expect(!refused.string(CefRemote.Key.error).isEmpty)
        let stats = try first.stats()
        #expect(stats.int(CefRemote.Key.count) == 1, "the first host's browser is still open")
        #expect(stats.int(CefRemote.Key.contexts) == 0, "no context was created for the second connection")
        #expect(!first.expectEvent(CefRemote.Event.browserClosed), "nothing was closed under the first host")
    }

    // MARK: Paths

    /// The path the way Foundation gives a temporary folder (`/var/folders/…`), which is a link to the canonical
    /// `/private/var/folders/…`. Nil when the folder is not under such an alias.
    private static func aliased(_ canonical: URL) -> URL? {
        guard canonical.path.hasPrefix("/private/var/") else { return nil }
        return URL(filePath: String(canonical.path.dropFirst("/private".count)), directoryHint: .isDirectory)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aRootWithAnAliasInItIsRefusedByTheServiceAndStartsNothing() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        let alias = try #require(Self.aliased(client.root), "the temporary folder is not under /var: \(client.root.path)")
        #expect(FileManager.default.fileExists(atPath: alias.path), "the alias names the same folder")
        let hello = CefRemoteMessage.hello()
        hello.set(CefRemote.Key.rootPath, alias.path)
        hello.set(CefRemote.Key.cachePath, alias.appending(path: "default").path)
        let reply = try client.call(hello, timeout: Self.helloTimeout)
        #expect(!reply.bool(CefRemote.Key.success), "a root that is not canonical must be refused")
        #expect(reply.string(CefRemote.Key.error).contains("canonical"), "\(reply.string(CefRemote.Key.error))")
        #expect(!(try client.stats()).bool(CefRemote.Key.started), "a refused root starts no CEF")
    }

    /// The bug of D4-5's first lane run: a canonical root and a cache folder that does not exist yet looked "outside the root" to
    /// the service, because only an existing path lost its `/private`. The hello's cache folder (`root/default`) is such a folder.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aCacheFolderThatDoesNotExistYetIsInsideACanonicalRootAndTheServiceMakesIt() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        let alias = try #require(Self.aliased(client.root), "the temporary folder is not under /var: \(client.root.path)")
        let reply = try client.hello()
        #expect(reply.bool(CefRemote.Key.success), "a cache folder that is not made yet: \(reply.string(CefRemote.Key.error))")
        // A context whose folder is below the root and not made: by its canonical path, and by one with the alias in it.
        let canonicalFresh = client.root.appending(path: "profiles/one", directoryHint: .isDirectory)
        let viaAlias = alias.appending(path: "profiles/two", directoryHint: .isDirectory)
        for (name, folder) in [("one", canonicalFresh), ("two", viaAlias)] {
            #expect(!FileManager.default.fileExists(atPath: folder.path))
            let message = CefRemoteMessage(CefRemote.Op.createContext)
            message.set(CefRemote.Key.context, name)
            message.set(CefRemote.Key.cachePath, folder.path)
            let answer = try client.call(message)
            #expect(answer.bool(CefRemote.Key.success), "\(folder.path): \(answer.string(CefRemote.Key.error))")
            #expect(FileManager.default.fileExists(atPath: folder.path), "the service made the folder after it checked the path")
        }
        #expect(try client.stats().int(CefRemote.Key.contexts) == 2)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aContextFolderOutsideTheRootIsRefusedAndNothingIsMadeThere() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        #expect(try client.hello().bool(CefRemote.Key.success))
        let outside = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        let target = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-link-target-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: client.root.appending(path: "link"), withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: target)
        }
        let escapes = [
            ("sibling", outside.appending(path: "a", directoryHint: .isDirectory)),
            ("dotdot", client.root.appending(path: "../wsurf-d4-escape-\(UUID().uuidString)", directoryHint: .isDirectory)),
            ("twin", URL(filePath: client.root.path + "-twin/a", directoryHint: .isDirectory)),
            ("link", client.root.appending(path: "link/child", directoryHint: .isDirectory)),
        ]
        for (name, folder) in escapes {
            let message = CefRemoteMessage(CefRemote.Op.createContext)
            message.set(CefRemote.Key.context, name)
            message.set(CefRemote.Key.cachePath, folder.path)
            let answer = try client.call(message)
            #expect(!answer.bool(CefRemote.Key.success), "\(name): \(folder.path)")
            #expect(!FileManager.default.fileExists(atPath: folder.path), "\(name): nothing is made outside the root")
        }
        #expect(!FileManager.default.fileExists(atPath: target.appending(path: "child").path), "nothing was made through the link")
        #expect(try client.stats().int(CefRemote.Key.contexts) == 0)
    }

    // MARK: Lifecycle

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aLingerOfOneSecondWithNoBrowserEndsTheServiceWithinThreeSeconds() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello(linger: 1)
        let pid = try #require(client.pid)
        let took = try #require(ChromiumServiceClient.secondsUntilGone(pid, within: 3), "the service outlived its 1 s linger by more than 3 s")
        print("ChromiumServiceHostTests observed: linger 1 s, service gone after \(took) s")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserHoldsTheServiceUpPastItsLingerAndTheLastCloseStartsItAgain() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        // The linger starts with the hello, so the stub has to be registered before it ends: 2 s leave a loaded machine room for
        // that (a lost race would make the service leave under the test and fail it for the wrong reason). The window of the
        // first wait ends 1.5 s after the linger would have, as it did at 1 s, and the second leaves 3 s for the exit.
        _ = try client.hello(linger: 2)
        let pid = try #require(client.pid)
        try client.stubBrowser(1)
        #expect(ChromiumServiceClient.secondsUntilGone(pid, within: 3.5) == nil, "a browser is open: the linger must not run")
        #expect(try client.stats().int(CefRemote.Key.count) == 1)
        try client.closeBrowser(1)
        #expect(ChromiumServiceClient.secondsUntilGone(pid, within: 5) != nil, "the last browser closed: the linger runs and the service leaves")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func closingTheControlConnectionEndsTheServiceWithinFourSeconds() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        client.close()
        #expect(ChromiumServiceClient.secondsUntilGone(pid, within: 4) != nil, "the control connection closed: the service must leave")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func closingTheControlConnectionDoesNotWaitLongerThanTheCapForABrowserThatNeverCloses() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        try client.context("profile")
        try client.stubBrowser(7, answersClose: false)
        // A second connection to the same service, to read what the control connection can no longer ask for.
        let observer = try ChromiumServiceClient(root: client.root)
        defer { observer.close() }
        _ = try observer.stats()
        let closed = Date()
        client.close()
        // The cookie stores are asked for when the close begins, not after the last browser (which here never comes).
        var flushes: Int64 = 0
        let deadline = Date().addingTimeInterval(2)
        while flushes == 0, Date() < deadline {
            flushes = (try? observer.stats())?.int(CefRemote.Key.flushes) ?? 0
            usleep(50_000)
        }
        #expect(flushes >= 1, "the cookies must be flushed before the service waits for its browsers")
        _ = try #require(ChromiumServiceClient.secondsUntilGone(pid, within: 4.5), "a stuck browser kept the service up past its 3 s cap")
        let took = Date().timeIntervalSince(closed)
        #expect(took >= 2.5, "the service should have given the browser its time to close first (left after \(took) s)")
        // Measured from the close itself, as the lower bound is (the flush poll above is part of the wait).
        #expect(took <= 4.5, "the cap is 3 s: the service left after \(took) s")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserThatClosesWhenAskedDoesNotMakeTheServiceWaitForTheCap() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        try client.stubBrowser(3)
        client.close()
        let took = try #require(ChromiumServiceClient.secondsUntilGone(pid, within: 4))
        #expect(took < 2.5, "a browser that closes at once does not make the service wait for the cap (left after \(took) s)")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anExitWhoseMainThreadIsStuckIsEndedByTheBackstop() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        // The service begins its exit and then blocks its main thread for 15 s (what a hung cef_shutdown does). Nothing queued
        // on the main thread can run: the 5.5 s backstop, which has a queue of its own, is the only way out before the 15 s.
        #expect(try client.call(CefRemoteMessage(CefRemote.Op.debugHangExit)).bool(CefRemote.Key.success))
        let took = ChromiumServiceClient.secondsUntilGone(pid, within: 9)
        #expect(took != nil, "a stuck exit was not forced within 9 s: the service waited for its own main thread")
        print("ChromiumServiceHostTests observed: stuck exit, service gone after \(took ?? -1) s")
    }

    // MARK: Memory pressure

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func memoryPressureFlushesButDoesNotExitWhileABrowserIsOpen() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        try client.context("profile")
        try client.stubBrowser(1)
        let flushed = try client.memoryPressure(true).int(CefRemote.Key.flushes)
        #expect(flushed >= 1, "the cookie store is written under pressure")
        #expect(ChromiumServiceClient.secondsUntilGone(pid, within: 1.5) == nil, "a service with a browser open must not leave under pressure")
        let stats = try client.stats()
        #expect(stats.int(CefRemote.Key.pid) == Int64(pid))
        #expect(stats.int(CefRemote.Key.count) == 1, "the person's page is still open")
        // The pressure has not passed: when the last browser closes the service leaves at once, not after the linger.
        try client.closeBrowser(1)
        // The linger is 60 s: leaving within 3 s is the pressure's doing.
        #expect(ChromiumServiceClient.secondsUntilGone(pid, within: 3) != nil, "pressure still on, last browser closed: the service must leave at once")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func memoryPressureWithNoBrowserFlushesAndExitsAtOnce() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        try client.context("profile")
        #expect(try client.memoryPressure(true).int(CefRemote.Key.flushes) >= 1)
        // The linger is 60 s: leaving within 3 s is the pressure's doing.
        #expect(ChromiumServiceClient.secondsUntilGone(pid, within: 3) != nil, "no browser and memory pressure: the service must leave")
    }

    // MARK: askHost

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func askHostAgainstAPeerThatNeverAnswersTimesOutWithinOneAndAHalfSeconds() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        client.hostAnswersQuestions = false
        let started = Date()
        let reply = try client.call(CefRemoteMessage(CefRemote.Op.debugAskHost, browser: 1), timeout: 5)
        let wall = Date().timeIntervalSince(started)
        #expect(reply.string(CefRemote.Key.askHostAnswer) == CefRemote.AskHostAnswer.timedOut)
        #expect(wall < 1.5, "askHost's timeout is 1 s; it took \(wall) s")
        #expect(wall >= 0.9, "askHost must wait its second before it cancels (\(wall) s)")
        #expect(client.questionsAsked >= 1, "the question did reach the host")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func askHostAgainstAPeerThatAnswersIsAnswered() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        client.hostAnswersQuestions = true
        let reply = try client.call(CefRemoteMessage(CefRemote.Op.debugAskHost, browser: 1), timeout: 5)
        #expect(reply.string(CefRemote.Key.askHostAnswer) == CefRemote.AskHostAnswer.answered)
        #expect(reply.double(CefRemote.Key.value) < 500, "an answer needs no timeout")
    }

    // MARK: DEBUG ops

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func debugAbortKillsTheServiceAsACrashWould() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        client.send(CefRemoteMessage(CefRemote.Op.debugAbort))
        #expect(ChromiumServiceClient.secondsUntilGone(pid, within: 3) != nil)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func debugExitOnHelloKillsTheNextHellosEvenOfARelaunchedServiceAndThenAnswers() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish() }
        let arm = CefRemoteMessage(CefRemote.Op.debugExitOnHello)
        arm.set(CefRemote.Key.rootPath, client.root.path)
        arm.set(CefRemote.Key.count, 2)
        #expect(try client.call(arm).bool(CefRemote.Key.success))
        _ = try client.stats()
        let first = try #require(client.pid)
        // Hello 1 reaches the service that was armed, and hello 2 the instance launchd starts after it: a crash loop. Neither
        // is answered, and neither starts CEF (the connection reports the interruption).
        #expect(throws: ChromiumServiceClient.Failure.self) { _ = try client.hello() }
        #expect(ChromiumServiceClient.secondsUntilGone(first, within: 5) != nil)
        #expect(throws: ChromiumServiceClient.Failure.self) { _ = try client.hello() }
        // The marker is used up: the third instance answers.
        let reply = try client.hello()
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        let third = try #require(client.pid)
        #expect(third != first, "a new process")
    }
}
