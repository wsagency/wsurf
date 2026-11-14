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
        let client = try ServiceClient()
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
        let client = try ServiceClient()
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
        let first = try ServiceClient()
        defer { first.finish() }
        #expect(try first.hello().bool(CefRemote.Key.success))
        let second = try ServiceClient(root: first.root)
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
        let first = try ServiceClient()
        defer { first.finish() }
        #expect(try first.hello().bool(CefRemote.Key.success))
        try first.stubBrowser(1)
        let second = try ServiceClient(root: first.root)
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

    // MARK: Lifecycle

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aLingerOfOneSecondWithNoBrowserEndsTheServiceWithinThreeSeconds() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        _ = try client.hello(linger: 1)
        let pid = try #require(client.pid)
        let took = try #require(ServiceClient.secondsUntilGone(pid, within: 3), "the service outlived its 1 s linger by more than 3 s")
        print("ChromiumServiceHostTests observed: linger 1 s, service gone after \(took) s")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserHoldsTheServiceUpPastItsLingerAndTheLastCloseStartsItAgain() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        // The linger starts with the hello, so the stub has to be registered before it ends: 2 s leave a loaded machine room for
        // that (a lost race would make the service leave under the test and fail it for the wrong reason). The window of the
        // first wait ends 1.5 s after the linger would have, as it did at 1 s, and the second leaves 3 s for the exit.
        _ = try client.hello(linger: 2)
        let pid = try #require(client.pid)
        try client.stubBrowser(1)
        #expect(ServiceClient.secondsUntilGone(pid, within: 3.5) == nil, "a browser is open: the linger must not run")
        #expect(try client.stats().int(CefRemote.Key.count) == 1)
        try client.closeBrowser(1)
        #expect(ServiceClient.secondsUntilGone(pid, within: 5) != nil, "the last browser closed: the linger runs and the service leaves")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func closingTheControlConnectionEndsTheServiceWithinFourSeconds() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        client.close()
        #expect(ServiceClient.secondsUntilGone(pid, within: 4) != nil, "the control connection closed: the service must leave")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func closingTheControlConnectionDoesNotWaitLongerThanTheCapForABrowserThatNeverCloses() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        try client.context("profile")
        try client.stubBrowser(7, answersClose: false)
        // A second connection to the same service, to read what the control connection can no longer ask for.
        let observer = try ServiceClient(root: client.root)
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
        _ = try #require(ServiceClient.secondsUntilGone(pid, within: 4.5), "a stuck browser kept the service up past its 3 s cap")
        let took = Date().timeIntervalSince(closed)
        #expect(took >= 2.5, "the service should have given the browser its time to close first (left after \(took) s)")    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aBrowserThatClosesWhenAskedDoesNotMakeTheServiceWaitForTheCap() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        try client.stubBrowser(3)
        client.close()
        let took = try #require(ServiceClient.secondsUntilGone(pid, within: 4))
        #expect(took < 2.5, "a browser that closes at once does not make the service wait for the cap (left after \(took) s)")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anExitWhoseMainThreadIsStuckIsEndedByTheBackstop() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        // The service begins its exit and then blocks its main thread for 15 s (what a hung cef_shutdown does). Nothing queued
        // on the main thread can run: the 5.5 s backstop, which has a queue of its own, is the only way out before the 15 s.
        #expect(try client.call(CefRemoteMessage(CefRemote.Op.debugHangExit)).bool(CefRemote.Key.success))
        let took = ServiceClient.secondsUntilGone(pid, within: 9)
        #expect(took != nil, "a stuck exit was not forced within 9 s: the service waited for its own main thread")
        print("ChromiumServiceHostTests observed: stuck exit, service gone after \(took ?? -1) s")
    }

    // MARK: Memory pressure

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func memoryPressureFlushesButDoesNotExitWhileABrowserIsOpen() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        try client.context("profile")
        try client.stubBrowser(1)
        let flushed = try client.memoryPressure(true).int(CefRemote.Key.flushes)
        #expect(flushed >= 1, "the cookie store is written under pressure")
        #expect(ServiceClient.secondsUntilGone(pid, within: 1.5) == nil, "a service with a browser open must not leave under pressure")
        let stats = try client.stats()
        #expect(stats.int(CefRemote.Key.pid) == Int64(pid))
        #expect(stats.int(CefRemote.Key.count) == 1, "the person's page is still open")
        // The pressure has not passed: when the last browser closes the service leaves at once, not after the linger.
        try client.closeBrowser(1)
        // The linger is 60 s: leaving within 3 s is the pressure's doing.
        #expect(ServiceClient.secondsUntilGone(pid, within: 3) != nil, "pressure still on, last browser closed: the service must leave at once")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func memoryPressureWithNoBrowserFlushesAndExitsAtOnce() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        try client.context("profile")
        #expect(try client.memoryPressure(true).int(CefRemote.Key.flushes) >= 1)
        // The linger is 60 s: leaving within 3 s is the pressure's doing.
        #expect(ServiceClient.secondsUntilGone(pid, within: 3) != nil, "no browser and memory pressure: the service must leave")
    }

    // MARK: askHost

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func askHostAgainstAPeerThatNeverAnswersTimesOutWithinOneAndAHalfSeconds() throws {
        let client = try ServiceClient()
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
        let client = try ServiceClient()
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
        let client = try ServiceClient()
        defer { client.finish() }
        _ = try client.hello()
        let pid = try #require(client.pid)
        client.send(CefRemoteMessage(CefRemote.Op.debugAbort))
        #expect(ServiceClient.secondsUntilGone(pid, within: 3) != nil)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func debugExitOnHelloKillsTheNextHellosEvenOfARelaunchedServiceAndThenAnswers() throws {
        let client = try ServiceClient()
        defer { client.finish() }
        let arm = CefRemoteMessage(CefRemote.Op.debugExitOnHello)
        arm.set(CefRemote.Key.rootPath, client.root.path)
        arm.set(CefRemote.Key.count, 2)
        #expect(try client.call(arm).bool(CefRemote.Key.success))
        _ = try client.stats()
        let first = try #require(client.pid)
        // Hello 1 reaches the service that was armed, and hello 2 the instance launchd starts after it: a crash loop. Neither
        // is answered, and neither starts CEF (the connection reports the interruption).
        #expect(throws: ServiceClient.Failure.self) { _ = try client.hello() }
        #expect(ServiceClient.secondsUntilGone(first, within: 5) != nil)
        #expect(throws: ServiceClient.Failure.self) { _ = try client.hello() }
        // The marker is used up: the third instance answers.
        let reply = try client.hello()
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        let third = try #require(client.pid)
        #expect(third != first, "a new process")
    }
}

/// One raw XPC client of the service, as WSurf's own client (D4-5) will be, with none of its code. The replies and events
/// come on a queue of this client's own, so the test thread can block on them. `nonisolated` for that.
private nonisolated final class ServiceClient: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case noAnswer(String)
        case connection(String)
        case setup(String)

        var description: String {
            switch self {
            case let .noAnswer(op):
                "no answer to \(op)"
            case let .connection(text):
                "the connection failed: \(text)"
            case let .setup(text):
                text
            }
        }
    }

    let root: URL
    private let ownsRoot: Bool
    private let queue = DispatchQueue(label: "ChromiumServiceHostTests.xpc")
    private let connection: xpc_connection_t
    private let state = OSAllocatedUnfairLock(initialState: State())
    private var closed = false
    private let created = Date()

    private struct State {
        var pid: pid_t?
        var answers = false
        var questions = 0
        var firstReplyNoted = false
        var events: [(op: String, message: CefRemoteMessage)] = []
    }

    /// The service's pid, once a hello (or `stats`) has told.
    var pid: pid_t? {
        state.withLock { $0.pid }
    }

    var questionsAsked: Int {
        state.withLock { $0.questions }
    }

    var hostAnswersQuestions: Bool {
        get { state.withLock { $0.answers } }
        set { state.withLock { $0.answers = newValue } }
    }

    init(root: URL? = nil) throws {
        if let root {
            self.root = root
            ownsRoot = false
        } else {
            self.root = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-host-\(UUID().uuidString)", directoryHint: .isDirectory)
            ownsRoot = true
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        }
        let identifier = (Bundle.main.bundleIdentifier ?? "") + ".chromium"
        connection = xpc_connection_create(identifier, queue)
        xpc_connection_set_event_handler(connection) { [weak self] event in self?.handle(event) }
        xpc_connection_activate(connection)
    }

    /// An event or a question from the service. A question (`nav.before` is the one `debug.askHost` sends) has a reply the
    /// service waits for; a host that "never answers" leaves it unanswered.
    private func handle(_ event: xpc_object_t) {
        guard let message = CefRemoteMessage(wrapping: event) else { return }
        let answer = state.withLock { state -> Bool in
            state.events.append((message.op, message))
            if message.op == CefRemote.Event.beforeBrowse {
                state.questions += 1
            }
            return state.answers
        }
        if message.op == CefRemote.Event.beforeBrowse, answer, let reply = CefRemoteMessage(replyTo: message) {
            reply.set(CefRemote.Key.value, true)
            xpc_connection_send_message(connection, reply.object)
        }
    }

    func expectEvent(_ op: String) -> Bool {
        state.withLock { $0.events.contains { $0.op == op } }
    }

    func send(_ message: CefRemoteMessage) {
        xpc_connection_send_message(connection, message.object)
    }

    /// One message and its reply. The wait is on this thread; the reply comes on the client's queue.
    func call(_ message: CefRemoteMessage, timeout: TimeInterval = 30) throws -> CefRemoteMessage {
        let done = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<Result<CefRemoteMessage, Failure>?>(initialState: nil)
        xpc_connection_send_message_with_reply(connection, message.object, queue) { answer in
            let outcome: Result<CefRemoteMessage, Failure>
            if let reply = CefRemoteMessage(wrapping: answer) {
                outcome = .success(reply)
            } else {
                let text = xpc_copy_description(answer)
                defer { free(text) }
                outcome = .failure(.connection(String(cString: text)))
            }
            box.withLock { $0 = outcome }
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw Failure.noAnswer(message.op)
        }
        noteFirstReply(to: message.op)
        return try box.withLock { try #require($0) }.get()
    }

    /// The first answer of a client comes from an instance launchd may have just started: how long it took is what D4-5's
    /// relaunch assertion (a new hello within 2 s) has to be set against.
    private func noteFirstReply(to op: String) {
        let first = state.withLock { state -> Bool in
            defer { state.firstReplyNoted = true }
            return !state.firstReplyNoted
        }
        if first {
            print("ChromiumServiceHostTests observed: first reply (\(op)) after \(Date().timeIntervalSince(created)) s")
        }
    }

    // MARK: Typed calls

    /// The first message: protocol version, linger, and the temporary root and cache. No log file, so CEF logs nowhere.
    func hello(linger: Double? = nil) throws -> CefRemoteMessage {
        let hello = CefRemoteMessage.hello(linger: linger)
        hello.set(CefRemote.Key.rootPath, root.path)
        hello.set(CefRemote.Key.cachePath, root.appending(path: "default").path)
        let reply = try call(hello, timeout: 30)
        if reply.has(CefRemote.Key.pid) {
            state.withLock { $0.pid = pid_t(reply.int(CefRemote.Key.pid)) }
        }
        return reply
    }

    func stats() throws -> CefRemoteMessage {
        let reply = try call(CefRemoteMessage(CefRemote.Op.debugStats))
        if reply.has(CefRemote.Key.pid) {
            state.withLock { $0.pid = pid_t(reply.int(CefRemote.Key.pid)) }
        }
        return reply
    }

    func context(_ name: String) throws {
        let message = CefRemoteMessage(CefRemote.Op.createContext)
        message.set(CefRemote.Key.context, name)
        message.set(CefRemote.Key.cachePath, root.appending(path: name).path)
        let reply = try call(message)
        guard reply.bool(CefRemote.Key.success) else { throw Failure.setup("context \(name): \(reply.string(CefRemote.Key.error))") }
    }

    func stubBrowser(_ id: Int64, answersClose: Bool = true) throws {
        let message = CefRemoteMessage(CefRemote.Op.debugStubBrowser, browser: id)
        message.set(CefRemote.Key.flag, answersClose)
        _ = try call(message)
    }

    func closeBrowser(_ id: Int64) throws {
        send(CefRemoteMessage(CefRemote.Op.close, browser: id))
        // The service's `browser.closed` event is the evidence; a round trip after it proves the close was handled.
        let deadline = Date().addingTimeInterval(5)
        while !expectEvent(CefRemote.Event.browserClosed), Date() < deadline {
            usleep(20_000)
        }
        guard expectEvent(CefRemote.Event.browserClosed) else {
            throw Failure.noAnswer(CefRemote.Event.browserClosed)
        }
    }

    func memoryPressure(_ under: Bool) throws -> CefRemoteMessage {
        let message = CefRemoteMessage(CefRemote.Op.debugMemoryPressure)
        message.set(CefRemote.Key.flag, under)
        return try call(message)
    }

    // MARK: Teardown

    func close() {
        guard !closed else { return }
        closed = true
        xpc_connection_cancel(connection)
    }

    /// Ends the test so that no service instance outlives it (the next test must get a fresh one, and an instance that
    /// leaves during the next test would fail it). With `expectExit` the control connection closing is what ends the
    /// service; without it (a refused hello leaves the service with no host) the test ends the service itself, with
    /// `debug.abort`. A service that does not leave is recorded as an issue.
    func finish(expectExit: Bool = true) {
        let known = pid
        if !expectExit, known != nil {
            send(CefRemoteMessage(CefRemote.Op.debugAbort))
            usleep(100_000)
        }
        close()
        defer {
            // The root is not removed while the service may still be using it.
            if ownsRoot {
                try? FileManager.default.removeItem(at: root)
            }
        }
        if let known, Self.secondsUntilGone(known, within: 8) == nil {
            Issue.record("the service \(known) did not leave after its connection closed")
        }
    }

    /// How long until `pid` is gone, polling: nil when it is still there after `seconds`. The probe sends no signal.
    static func secondsUntilGone(_ pid: pid_t, within seconds: TimeInterval) -> TimeInterval? {
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            if kill(pid, 0) == -1, errno == ESRCH {
                return Date().timeIntervalSince(started)
            }
            usleep(25_000)
        }
        return kill(pid, 0) == -1 && errno == ESRCH ? Date().timeIntervalSince(started) : nil
    }
}
