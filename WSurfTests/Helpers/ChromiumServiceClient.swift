// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import os
import Testing
import XPC

@testable import CefKit
@testable import WSurf

/// One raw XPC client of the service, as WSurf's own client (D4-5) will be, with none of its code. Shared by the service suites
/// (`ChromiumServiceHostTests`, `ChromiumServiceBrowserTests`). The replies and events
/// come on a queue of this client's own, so the test thread can block on them. `nonisolated` for that.
nonisolated final class ChromiumServiceClient: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case noAnswer(String)
        case connection(String)
        case serviceEnded(String)
        case setup(String)

        var description: String {
            switch self {
            case let .noAnswer(op):
                "no answer to \(op)"
            case let .connection(text):
                "the connection failed: \(text)"
            case let .serviceEnded(text):
                "the service ended during the test (a crash? see ~/Library/Logs/DiagnosticReports/WSurf Chromium-*.ips): \(text)"
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
        var questionURLs: [String] = []
        var firstReplyNoted = false
        /// `XPC_ERROR_CONNECTION_INTERRUPTED` events: the instance this connection talked to ended (exited or crashed).
        var interruptions = 0
        var events: [(op: String, message: CefRemoteMessage)] = []
    }

    /// The service's pid, once a hello (or the first `stats`, for a client that says no hello) has told. A hello names the instance
    /// this client talks to; after that only that instance may answer `stats` (a relaunched one would answer 0 and look healthy).
    var pid: pid_t? {
        state.withLock { $0.pid }
    }

    var questionsAsked: Int {
        state.withLock { $0.questions }
    }

    /// The URLs of the navigations the service asked about (`nav.before`), in order.
    var questionURLs: [String] {
        state.withLock { $0.questionURLs }
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
            let made = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-host-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            // The service refuses a root with an alias in it (a temporary folder is under `/var`, which is `/private/var`), as
            // CEF does: a host sends the canonical path, and so does this client.
            let canonical = realpath(made.path, nil)
            defer { free(canonical) }
            self.root = canonical.map { URL(filePath: String(cString: $0), directoryHint: .isDirectory) } ?? made
            ownsRoot = true
        }
        let identifier = (Bundle.main.bundleIdentifier ?? "") + ".chromium"
        connection = xpc_connection_create(identifier, queue)
        xpc_connection_set_event_handler(connection) { [weak self] event in self?.handle(event) }
        xpc_connection_activate(connection)
    }

    /// An event or a question from the service. A question (`nav.before` is the one `debug.askHost` sends) has a reply the
    /// service waits for; a host that "never answers" leaves it unanswered.
    private func handle(_ event: xpc_object_t) {
        if event === XPC_ERROR_CONNECTION_INTERRUPTED {
            state.withLock { $0.interruptions += 1 }
            return
        }
        guard let message = CefRemoteMessage(wrapping: event) else { return }
        let answer = state.withLock { state -> Bool in
            state.events.append((message.op, message))
            if message.op == CefRemote.Event.beforeBrowse {
                state.questions += 1
                state.questionURLs.append(message.string(CefRemote.Key.url))
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
        let op = message.op
        xpc_connection_send_message_with_reply(connection, message.object, queue) { answer in
            let outcome: Result<CefRemoteMessage, Failure>
            if let reply = CefRemoteMessage(wrapping: answer) {
                outcome = .success(reply)
            } else if answer === XPC_ERROR_CONNECTION_INTERRUPTED {
                outcome = .failure(.serviceEnded("\(op) was interrupted"))
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

    /// `debug.stats`. The reply's pid is adopted only when the client has none yet; a reply from any other instance than the one
    /// this client knows is an error, not a number to compare (review F6).
    func stats() throws -> CefRemoteMessage {
        let reply = try call(CefRemoteMessage(CefRemote.Op.debugStats))
        if reply.has(CefRemote.Key.pid) {
            let replied = pid_t(reply.int(CefRemote.Key.pid))
            let (known, interruptions) = state.withLock { state -> (pid_t, Int) in
                if state.pid == nil {
                    state.pid = replied
                }
                return (state.pid ?? replied, state.interruptions)
            }
            guard known == replied else {
                // The instance this client knows is gone: libxpc started a new one for this message.
                throw Failure.serviceEnded("service \(known) is gone (\(interruptions) interruptions seen); debug.stats was answered by a new instance, \(replied)")
            }
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

    // MARK: Events

    func events(_ op: String) -> [CefRemoteMessage] {
        state.withLock { $0.events.filter { $0.op == op }.map(\.message) }
    }

    /// The first event of `op` (already received or arriving within `timeout`) that `match` accepts.
    func waitEvent(_ op: String, timeout: TimeInterval = 20, where match: (CefRemoteMessage) -> Bool = { _ in true }) -> CefRemoteMessage? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let found = events(op).first(where: match) {
                return found
            }
            usleep(20_000)
        } while Date() < deadline
        return events(op).first(where: match)
    }

    /// How many `history.changed` events have arrived: a baseline for `waitHistory(after:)`.
    var historyCount: Int {
        events(CefRemote.Event.historyChanged).count
    }

    /// The first `history.changed` list that `match` accepts, among those after the first `after` of them (a baseline from
    /// `historyCount`, so that a list from before a step cannot answer for it), received now or within `timeout`.
    func waitHistory(after: Int = 0, timeout: TimeInterval = 20, where match: ([CefRemote.HistoryEntry]) -> Bool) -> [CefRemote.HistoryEntry]? {
        let deadline = Date().addingTimeInterval(timeout)
        func found() -> [CefRemote.HistoryEntry]? {
            events(CefRemote.Event.historyChanged).dropFirst(after).map(\.historyEntries).first(where: match)
        }
        repeat {
            if let list = found() {
                return list
            }
            usleep(20_000)
        } while Date() < deadline
        return found()
    }

    // MARK: Browsers

    /// `browser.create` with a 800 x 600 view at scale 1; its reply says whether CEF took the request.
    func createBrowser(_ id: Int64, url: String, context: String = "", debug: String? = nil) throws -> CefRemoteMessage {
        let message = CefRemoteMessage(CefRemote.Op.createBrowser, browser: id)
        message.set(CefRemote.Key.url, url)
        if !context.isEmpty {
            message.set(CefRemote.Key.context, context)
        }
        message.set(CefRemote.Key.width, 800.0)
        message.set(CefRemote.Key.height, 600.0)
        message.set(CefRemote.Key.scale, 1.0)
        if let debug {
            message.set(CefRemote.Key.debugCreate, debug)
        }
        return try call(message)
    }

    /// Sends a browser op (`browser.load` and the like) and returns its reply.
    func command(_ op: String, browser id: Int64, _ fill: (CefRemoteMessage) -> Void = { _ in }) throws -> CefRemoteMessage {
        let message = CefRemoteMessage(op, browser: id)
        fill(message)
        return try call(message)
    }

    func load(_ url: String, browser id: Int64) throws {
        let reply = try command(CefRemote.Op.load, browser: id) { $0.set(CefRemote.Key.url, url) }
        guard !reply.has(CefRemote.Key.error) else { throw Failure.setup("load: \(reply.string(CefRemote.Key.error))") }
    }

    /// One CDP command and the `devtools.result` that answers it (the result's `data` is its JSON).
    func devTools(_ method: String, params: String = "{}", id commandID: Int64, browser id: Int64) -> CefRemoteMessage? {
        let message = CefRemoteMessage(CefRemote.Op.devTools, browser: id)
        message.set(CefRemote.Key.data, data: Data(#"{"id":\#(commandID),"method":"\#(method)","params":\#(params)}"#.utf8))
        send(message)
        return waitEvent(CefRemote.Event.devToolsResult) { $0.int(CefRemote.Key.identifier) == commandID }
    }

    /// `debug.stats`, repeated until `done` accepts it or `timeout` ends (CEF frees its clients on its own threads).
    func waitStats(timeout: TimeInterval = 10, until done: (CefRemoteMessage) -> Bool) throws -> CefRemoteMessage {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try stats()
        while !done(latest), Date() < deadline {
            usleep(100_000)
            latest = try stats()
        }
        return latest
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
