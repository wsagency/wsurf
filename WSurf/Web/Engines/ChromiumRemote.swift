// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CefKit
import CoreGraphics
import Foundation
import IOSurface
import os
@preconcurrency import XPC

// D4 (out-of-process Chromium), phase 2, PR D4-5: WSurf's side of the connection to `WSurf Chromium.xpc`.
//
// - `ChromiumOOP` decides, once per process, whether Chromium runs in the service or in WSurf, and refuses the other path after.
// - `ChromiumRemote` owns the connections (control on the main queue, input, frames on the frame sink's queue), the hello, the
//   browser registry and the requests, and relaunches the service when it dies (`CefRemoteRelaunchPolicy`).
//
// Contract (`plans/d4-phase2-plan.md` §1): WSurf never waits on the service. Everything here queues a message or runs when the
// service's answer, interruption or timeout arrives; the one wait that exists, the service's `askHost`, is the service's.

nonisolated enum ChromiumOOP {
    enum Mode: Equatable, Sendable {
        case inProcess
        case outOfProcess
    }

    /// Which path this process took at its first Chromium start (a page, the prewarm or a data command). CEF holds a
    /// process-singleton lock on its root cache path, so in-process CEF and the service must never run on one root at once: after
    /// the first start the other path refuses, and the tab shows its error.
    nonisolated final class Latch: Sendable {
        private let state = OSAllocatedUnfairLock<Mode?>(initialState: nil)

        /// The mode in force, or nil before the first start.
        var mode: Mode? {
            state.withLock { $0 }
        }

        /// The mode of this process: decided now, from `wantsOutOfProcess`, if nobody has decided yet; the decision of the first
        /// caller afterwards, whatever it would answer now.
        func resolve(wantsOutOfProcess: () -> Bool) -> Mode {
            state.withLockUnchecked { current in
                if let current {
                    return current
                }
                let chosen: Mode = wantsOutOfProcess() ? .outOfProcess : .inProcess
                current = chosen
                return chosen
            }
        }
    }

    /// The process's latch.
    static let latch = Latch()
    static let log = Logger(subsystem: "io.wsagency.wsurf", category: "chromium-oop")

    /// Whether the out-of-process path may be used: only in DEBUG (Release is the constant `false`, until the owner's signing PR),
    /// only if asked for (the environment variable `WSURF_CHROMIUM_OOP`, or a test's override, which wins over it), only in a test
    /// host or a staged run (the service always uses the mock keychain until D4-S, so pointed at a real profile it would lose every
    /// session), and only if the build has the service.
    static func isAllowed(request: String?, override: Bool?, isTestHost: Bool, isStaged: Bool, servicePresent: Bool) -> Bool {
        #if DEBUG
        let requested = override ?? isOn(request)
        return requested && (isTestHost || isStaged) && servicePresent
        #else
        return false
        #endif
    }

    static func isOn(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value != "0"
    }

    private static var environmentRequest: String? {
        ProcessInfo.processInfo.environment["WSURF_CHROMIUM_OOP"]
    }

    static var isStaged: Bool {
        #if DEBUG
        return StageMode.isActive
        #else
        return false
        #endif
    }

    #if DEBUG
    private static let overrideValue = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    /// A test's choice, which wins over the environment. It has an effect only if set before the first Chromium start: the latch
    /// keeps what it decided then.
    static var testOverride: Bool? {
        get {
            overrideValue.withLock { $0 }
        }
        set {
            overrideValue.withLock { $0 = newValue }
        }
    }
    #endif

    private static var currentOverride: Bool? {
        #if DEBUG
        return testOverride
        #else
        return nil
        #endif
    }

    /// The guard, on this process's own inputs.
    static var isEnabled: Bool {
        isAllowed(
            request: environmentRequest, override: currentOverride, isTestHost: AppDatabase.isRunningTests,
            isStaged: isStaged, servicePresent: ChromiumServiceBundle.isPresent
        )
    }

    /// The first Chromium start decides, and every later call gets the same answer. A request the guard refuses is logged once.
    static func resolveMode() -> Mode {
        latch.resolve {
            let allowed = isEnabled
            if !allowed, currentOverride ?? isOn(environmentRequest) {
                log.notice("out-of-process Chromium was asked for, but this process may not use it: Chromium stays in process")
            }
            return allowed
        }
    }
}

/// What the service pushes to one browser, and what happens to it when the service ends. D4-8's page proxy conforms.
@MainActor
protocol ChromiumRemoteBrowserHandle: AnyObject {
    /// An event of this browser, in the order the service produced it (CEF events and CDP traffic share one stream).
    func remoteEvent(_ message: CefRemoteMessage)
    /// The service ended (a crash, a kill, its own exit) with this browser in it: the browser, and with it the page's native
    /// history, is gone. This is also "the browser closed": a `browser.close` that was sent to a leaving service gets no
    /// `browser.closed`, so the dropped connection is the answer.
    func remoteServiceEnded()
    /// The service asks (`askHost`) whether a main-frame navigation may go ahead; it cancels if it hears nothing for a second.
    func remoteAllowsNavigation(to url: String) -> Bool
    /// The same question with everything the service knows of the navigation (method, whether it submits a body, transition type,
    /// the page that started it). A page proxy answers from this; the default asks only about the address.
    func remoteAllowsNavigation(question: CefRemoteMessage) -> Bool
}

extension ChromiumRemoteBrowserHandle {
    func remoteAllowsNavigation(question: CefRemoteMessage) -> Bool {
        remoteAllowsNavigation(to: question.string(CefRemote.Key.url))
    }
}

@MainActor
final class ChromiumRemote {
    static let shared = ChromiumRemote()

    enum Failure: Equatable {
        /// This process did not take the out-of-process path (the guard refused it, or in-process Chromium started first).
        case notEnabled
        /// The service speaks another protocol version.
        case protocolMismatch(service: Int64)
        /// The service is up, but CEF did not start there.
        case cefStartFailed
        /// The service did not answer the hello in time, or refused it in a way that is not its leaving.
        case noAnswer
    }

    enum ServiceState: Equatable {
        /// No service is running: none was needed yet, or it left idle (the next page launches it).
        case stopped
        /// The first hello is on its way.
        case starting
        /// The service died and its replacement has been asked for. launchd starts a replacement no sooner than 10 s after the
        /// spawn of the instance that died, so a service that died young takes about that long: this is not an error.
        case relaunching
        case running(pid: pid_t)
        /// The service keeps dying (`CefRemoteRelaunchPolicy`): nothing relaunches it until the person reloads (`userReload`).
        case crashLooping
        case failed(Failure)
    }

    /// How long a hello may take. launchd spawns a service no sooner than 10 s after the previous spawn, so a hello after a young
    /// death waits that long before CEF even starts: this must stay above 12 s.
    nonisolated static let defaultHelloTimeout: TimeInterval = 15
    /// How long a `browser.close` waits for its `browser.closed`.
    static let closeTimeout: TimeInterval = 5

    let serviceName: String
    let sink: ChromiumFrameSink
    private let root: () -> URL
    private let linger: Double?
    private let logFile: String?
    private let helloTimeout: TimeInterval
    private let protocolVersion: Int64
    let clock: () -> TimeInterval
    private let isEnabled: () -> Bool
    private let latch: ChromiumOOP.Latch
    /// The connection seam (D4-20): whether an `XPC_ERROR_CONNECTION_INVALID` that comes while a hello waits for its answer means
    /// "the service cannot be reached" (`.failed(.noAnswer)`: libxpc found no such service, or refused it, which no relaunch cures)
    /// rather than a death (counted toward the crash loop). A unit test that gives the client a service name that does not exist
    /// gets such an INVALID at the next turn of the main queue, and passes false to keep feeding it only the events it scripts.
    private let invalidMeansUnreachable: Bool
    /// The hello of this relaunch was asked again after it timed out (`helloEnded`): once.
    private var helloRetried = false
    /// Every completion runs on the main queue: replies and interruptions come on it, and so do the timers.
    private let requests = CefRemoteRequests<CefRemoteMessage>(schedule: cefRemoteTimer(on: .main))

    private var control: xpc_connection_t?
    var input: xpc_connection_t?
    var frames: xpc_connection_t?
    /// The accessibility transport (D4-40): the fourth connection, and when the tree is on. `ChromiumRemote+Accessibility.swift`.
    let accessibility = ChromiumRemoteAccessibility()
    /// Bumped when a control connection is opened or abandoned: its late events are ignored (`receive`).
    private(set) var generation = 0
    private var needsHello = true
    private var relaunching = false
    /// `disconnect` is telling the browsers: nothing they do meanwhile reconnects.
    private var isDisconnecting = false
    /// The hello (or a request) that is waiting was refused because the service was leaving (`noteLeavingRefusal`).
    private var refusedAsLeaving = false
    private var policy = CefRemoteRelaunchPolicy()
    private var browsers: [Int64: any ChromiumRemoteBrowserHandle] = [:]
    /// Browser ids start at 1 and are never reused (0 is what a message with no `bid` reads as).
    private var nextBrowserID: Int64 = 1
    private var contexts: Set<UUID> = []
    /// The request that waits for each browser's `browser.closed`.
    private var closing: [Int64: Int64] = [:]
    /// Bumped each time the service ends: an answer that comes back after it belongs to the instance that died.
    private(set) var instance = 0

    private(set) var state = ServiceState.stopped
    /// The service's process, once it answered a hello.
    private(set) var servicePID: pid_t = 0
    private(set) var helloCount = 0
    private(set) var interruptions = 0
    /// How many requests were asked again because the service refused them as leaving (see `request`).
    private(set) var leavingRetries = 0
    /// How many input or frames hellos the service refused (and the connections dropped for it).
    var sideRefusals = 0
    /// Milliseconds from hello to its answer (launch, the launchd throttle and CEF's start), and CEF's own start inside it.
    private(set) var helloRoundTripMs: Double = -1
    private(set) var cefStartMs: Double = -1
    /// The service's own sentence about the last refused hello, for logs and tests only: the tab's text never shows it.
    private(set) var lastRefusalText = ""
    var onStateChange: ((ServiceState) -> Void)?

    init(
        serviceName: String = (Bundle.main.bundleIdentifier ?? "io.wsagency.wsurf") + CefRemote.serviceSuffix,
        sink: ChromiumFrameSink = ChromiumFrameSink(),
        root: @escaping () -> URL = { ChromiumRuntime.shared.rootDirectory },
        linger: Double? = nil,
        logFile: String? = ChromiumRemote.stagedLogPath,
        helloTimeout: TimeInterval = ChromiumRemote.defaultHelloTimeout,
        protocolVersion: Int64 = CefRemote.protocolVersion,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        latch: ChromiumOOP.Latch = ChromiumOOP.latch,
        isEnabled: @escaping () -> Bool = { ChromiumOOP.isEnabled },
        invalidMeansUnreachable: Bool = true
    ) {
        self.invalidMeansUnreachable = invalidMeansUnreachable
        self.serviceName = serviceName
        self.sink = sink
        self.root = root
        self.linger = linger
        self.logFile = logFile
        self.helloTimeout = helloTimeout
        self.protocolVersion = protocolVersion
        self.clock = clock
        self.latch = latch
        self.isEnabled = isEnabled
    }

    var isRunning: Bool {
        if case .running = state {
            return true
        }
        return false
    }

    var browserCount: Int {
        browsers.count
    }

    /// Which connection that is, for a test that refuses it.
    var framesConnectionID: ObjectIdentifier? {
        frames.map(ObjectIdentifier.init)
    }

    var pendingRequestCount: Int {
        requests.pendingCount
    }

    // MARK: Connecting

    /// Launches the service if it is not running and says hello to it. Costs the main thread one message. Idempotent. A crash
    /// loop and a refused hello stay as they are until `userReload`.
    @discardableResult
    func connect() -> ServiceState {
        switch state {
        case .crashLooping, .failed:
            return state
        default:
            break
        }
        guard !isDisconnecting else { return state }
        #if !DEBUG
        // Only a DEBUG build may inject its own guard and latch (the tests'): a Release caller that passed `isEnabled: { true }`
        // and a fresh latch would otherwise get past both.
        setState(.failed(.notEnabled))
        return state
        #else
        // The first Chromium start decides the process's path: a process that took the other one refuses here.
        guard latch.resolve(wantsOutOfProcess: isEnabled) == .outOfProcess else {
            setState(.failed(.notEnabled))
            return state
        }
        if control == nil {
            openControl()
        }
        if needsHello {
            sendHello()
        }
        return state
        #endif
    }

    /// The service is given up: it keeps dying, or its hello failed for good. Only a person's action asks for it again (`userReload`);
    /// nothing automatic does (a tab's reload, its error page, a fallback). `.notEnabled` is not this: it is this process's choice of
    /// path, and no action of a person changes it.
    var isGivenUp: Bool {
        switch state {
        case .crashLooping:
            true
        case let .failed(failure):
            failure != .notEnabled
        default:
            false
        }
    }

    /// A person's action (a Reload, a load typed or picked: `ChromiumPage.holdsForRecovery`) gives a crash loop or a refusal up, and the
    /// service is asked for again.
    func userReload() {
        policy.userReload()
        switch state {
        case .crashLooping, .failed:
            relaunching = false
            setState(.stopped)
        default:
            break
        }
        connect()
    }

    /// Closes the connections: the service sees its control connection end and leaves. Browsers are told it ended.
    func disconnect() {
        generation += 1
        let lost = takeEverythingDown()
        needsHello = true
        relaunching = false
        servicePID = 0
        setState(.stopped)
        // A handle that sends from `remoteServiceEnded` must not bring the connection back.
        isDisconnecting = true
        defer { isDisconnecting = false }
        requests.interruptAll()
        for handle in lost {
            handle.remoteServiceEnded()
        }
    }

    private func openControl() {
        generation += 1
        let current = generation
        let connection = xpc_connection_create(serviceName, DispatchQueue.main)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            // The handler is Sendable and the XPC object is not: only a Sendable reading of it crosses to the main actor.
            let incoming = Incoming(event)
            MainActor.assumeIsolated { self?.receive(incoming, generation: current) }
        }
        xpc_connection_activate(connection)
        control = connection
    }

    private func sendHello() {
        guard let control else { return }
        needsHello = false
        helloCount += 1
        refusedAsLeaving = false
        setState(relaunching ? .relaunching : .starting)
        let message: CefRemoteMessage
        do {
            // The root exists and is canonical, which the service requires. The cache folder below it is the service's to make: it
            // resolves a folder that does not exist yet against the root before it creates anything.
            let directory = try Self.prepareRoot(root())
            message = Self.makeHello(
                protocolVersion: protocolVersion, root: directory, linger: linger, logFile: logFile, stageHome: Self.stageHome
            )
        } catch {
            ChromiumOOP.log.error("hello: the Chromium root could not be made: \(error.localizedDescription, privacy: .private)")
            fail(.noAnswer)
            return
        }
        let sent = clock()
        let current = generation
        let id = requests.begin(timeout: helloTimeout) { [weak self] reply in
            MainActor.assumeIsolated { self?.helloEnded(reply, sentAt: sent, generation: current) }
        }
        let table = requests
        xpc_connection_send_message_with_reply(control, message.object, DispatchQueue.main) { [weak self] answer in
            // An error object (the connection ended) is left to the control connection's own event, which ends every request
            // (`serviceEnded`); ending them here too could end a request of the next instance. The timeout is the backstop.
            guard let reply = CefRemoteMessage(wrapping: answer) else { return }
            // A service that is leaving refuses the hello without a pid or a version, and then ends: the hello stays waiting, so
            // that the interruption that follows is a death with a hello pending and the replacement is asked for. (If the
            // service never ends, as one that already has another host, the hello's timeout ends it.)
            if Self.isLeavingRefusal(reply) {
                MainActor.assumeIsolated { self?.noteLeavingRefusal() }
                return
            }
            table.reply(id, reply)
        }
        ChromiumOOP.log.notice("hello sent to \(self.serviceName, privacy: .public) (hello \(self.helloCount))")
    }

    func helloEnded(_ reply: CefRemoteReply<CefRemoteMessage>, sentAt: TimeInterval, generation sentGeneration: Int) {
        guard sentGeneration == generation else { return }
        // Nothing undoes a crash loop or a refusal but `userReload`: an answer that still arrives (from an instance launched
        // before the state was decided) is not an instance to run on.
        switch state {
        case .crashLooping, .failed:
            return
        default:
            break
        }
        switch reply {
        case .interrupted:
            // `serviceEnded` handles the end, and it decides whether this was a death.
            return
        case .timedOut:
            ChromiumOOP.log.error("hello: no answer in \(self.helloTimeout) s")
            // A replacement that launchd held back (10 s after the spawn that died) and CEF on a loaded machine can outlast the
            // timeout once: the hello is asked again, on the same connection (a service that answers the first one too is
            // answered twice, and the late reply finds no request). A second timeout is the hard failure (review C4).
            if relaunching, !helloRetried, control != nil {
                helloRetried = true
                sendHello()
                return
            }
            fail(.noAnswer)
        case let .value(message):
            guard message.bool(CefRemote.Key.success) else {
                refused(message)
                return
            }
            servicePID = pid_t(clamping: message.int(CefRemote.Key.pid))
            cefStartMs = message.double(CefRemote.Key.startMs)
            helloRoundTripMs = (clock() - sentAt) * 1000
            relaunching = false
            helloRetried = false
            ChromiumOOP.log.notice("hello answered: pid \(self.servicePID), CEF start \(self.cefStartMs) ms, round trip \(self.helloRoundTripMs) ms")
            setState(.running(pid: servicePID))
            openFrames()
            syncAccessibility()
        }
    }

    /// The tab's error text is WSurf's own, built from this: the service's `error` sentence is never shown as it is.
    private func refused(_ message: CefRemoteMessage) {
        lastRefusalText = message.string(CefRemote.Key.error)
        fail(Self.failure(forRefusedHello: message, ourVersion: protocolVersion))
    }

    /// Why a hello that was answered "not ok" failed: the versions differ (the refusal carries the service's), or CEF did not
    /// start (the reply has the pid and the same version), or it is a refusal that is neither.
    nonisolated static func failure(forRefusedHello reply: CefRemoteMessage, ourVersion: Int64) -> Failure {
        let theirs = reply.int(CefRemote.Key.protocolVersion)
        if theirs != ourVersion {
            return .protocolMismatch(service: theirs)
        }
        return reply.has(CefRemote.Key.pid) ? .cefStartFailed : .noAnswer
    }

    /// The hello failed for good (until `userReload`): the connections are given up, and the service, which has no host, leaves.
    private func fail(_ failure: Failure) {
        generation += 1
        let lost = takeEverythingDown()
        needsHello = true
        relaunching = false
        servicePID = 0
        setState(.failed(failure))
        requests.interruptAll()
        for handle in lost {
            handle.remoteServiceEnded()
        }
    }

    /// A refusal a leaving (or already hosted) service gives: not ok, and neither a pid nor a protocol version.
    nonisolated static func isLeavingRefusal(_ reply: CefRemoteMessage) -> Bool {
        !reply.bool(CefRemote.Key.success) && !reply.has(CefRemote.Key.pid) && !reply.has(CefRemote.Key.protocolVersion)
    }

    /// The service answered the hello (or request) that is waiting with "I am leaving" (a linger or pressure exit that was under way):
    /// its end is coming, and it is not a crash. See `serviceEnded`.
    func noteLeavingRefusal() {
        refusedAsLeaving = true
    }

    private func setState(_ new: ServiceState) {
        guard new != state else { return }
        state = new
        onStateChange?(new)
    }

    // MARK: Incoming

    /// What a connection delivered, read off the main actor: a message (a Sendable wrapper) or the error kind.
    nonisolated enum Incoming: Sendable {
        case message(CefRemoteMessage)
        case interrupted
        case invalid
        case other

        init(_ event: xpc_object_t) {
            if xpc_get_type(event) == XPC_TYPE_ERROR {
                if event === XPC_ERROR_CONNECTION_INTERRUPTED {
                    self = .interrupted
                } else if event === XPC_ERROR_CONNECTION_INVALID {
                    self = .invalid
                } else {
                    self = .other
                }
            } else if let message = CefRemoteMessage(wrapping: event) {
                self = .message(message)
            } else {
                self = .other
            }
        }
    }

    func receive(_ incoming: Incoming, generation sentGeneration: Int) {
        guard sentGeneration == generation else { return }
        switch incoming {
        case .interrupted:
            serviceEnded(reason: "interrupted")
        case .invalid:
            control = nil
            // INVALID is terminal for the connection's name: with no answer to the hello yet it is "unreachable", not a death
            // (three of them in a row would end in a crash loop that names the wrong thing, and relaunch nothing that exists).
            if invalidMeansUnreachable, state == .starting || state == .relaunching {
                ChromiumOOP.log.error("hello: the connection to \(self.serviceName, privacy: .public) is invalid, with no answer")
                fail(.noAnswer)
            } else {
                serviceEnded(reason: "invalid")
            }
        case .other:
            return
        case let .message(message):
            route(message)
        }
    }

    private func route(_ message: CefRemoteMessage) {
        let id = message.browser
        if message.op == CefRemote.Event.beforeBrowse {
            answerBeforeBrowse(message)
            return
        }
        guard let handle = browsers[id] else { return }
        if message.op == CefRemote.Event.browserClosed {
            browsers[id] = nil
            handle.remoteEvent(message)
            if let request = closing.removeValue(forKey: id) {
                requests.reply(request, message)
            }
            return
        }
        handle.remoteEvent(message)
    }

    private func answerBeforeBrowse(_ message: CefRemoteMessage) {
        guard let control, let reply = CefRemoteMessage(replyTo: message) else { return }
        let allowed = browsers[message.browser]?.remoteAllowsNavigation(question: message) ?? false
        reply.set(CefRemote.Key.value, allowed)
        xpc_connection_send_message(control, reply.object)
    }

    // MARK: The service ends

    /// The service ended: a crash, the debug abort, or its own exit after the linger or under memory pressure. Every browser
    /// in it is gone (and with it the page's native history: D3b's store is the way back), every request waiting on it ends
    /// interrupted, and a `browser.close` that was waiting for its `browser.closed` is answered by this: the dropped
    /// connection means every browser closed.
    private func serviceEnded(reason: String) {
        interruptions += 1
        instance += 1
        // Asked before anything is cleared: a browser in the service, or a request (a hello, a browser being created) that was
        // waiting on it, makes this a death; with neither it is an idle exit, which is not relaunched and not counted.
        let wasInUse = !browsers.isEmpty || requests.pendingCount > 0
        // A service that refused the waiting hello because it was leaving, with no browser of ours in it, ended as it said it
        // would: that is neither a crash (not counted toward the cap) nor a reason to give up (the hello's purpose is still
        // wanted, so the replacement is asked for, unless the cap was already reached).
        let leftAsItSaid = refusedAsLeaving && browsers.isEmpty
        refusedAsLeaving = false
        ChromiumOOP.log.notice("service ended (\(reason, privacy: .public)): \(self.browsers.count) browsers lost, in use \(wasInUse)")
        let lost = takeEverythingDown(keepingControl: true)
        needsHello = true
        servicePID = 0
        // Decide first and set the state, and only then tell anyone: a browser (or a request's completion) that sends from its
        // callback must see the new state, so that a crash loop refuses it instead of launching one more service.
        let relaunch: Bool
        if leftAsItSaid, !policy.isCrashLooping {
            relaunch = true
        } else {
            switch policy.recordDeath(at: clock(), serviceWasInUse: wasInUse) {
            case .relaunch:
                relaunch = true
            case .crashLooping, .idleExit:
                relaunch = false
            }
        }
        relaunching = relaunch
        helloRetried = false
        if relaunch {
            setState(.relaunching)
        } else {
            // An end that arrives after the cap was reached (nothing is in the service then) must not undo the crash state.
            setState(policy.isCrashLooping ? .crashLooping : .stopped)
        }
        requests.interruptAll()
        for handle in lost {
            handle.remoteServiceEnded()
        }
        if relaunch {
            // At once, not at the next message. launchd decides when the replacement starts (not before 10 s after the spawn of
            // the one that died), and the hello waits for it with a timeout that allows for that. After the callbacks, so that the
            // hello is not interrupted with the requests above; a callback that sent already made the hello, and this is a no-op.
            connect()
        }
    }

    /// Cancels the input and frames connections and forgets everything that belonged to the instance. Returns the browsers.
    private func takeEverythingDown(keepingControl: Bool = false) -> [any ChromiumRemoteBrowserHandle] {
        if let input {
            xpc_connection_cancel(input)
        }
        if let frames {
            xpc_connection_cancel(frames)
        }
        input = nil
        frames = nil
        closeAccessibility()
        if !keepingControl, let control {
            xpc_connection_cancel(control)
            self.control = nil
        }
        contexts.removeAll()
        closing.removeAll()
        let lost = Array(browsers.values)
        browsers.removeAll()
        return lost
    }

    // MARK: Sending

    /// Whether a service is running or on its way (a hello is out): messages sent now are served, in order, once it is up.
    private var isServiceExpected: Bool {
        switch state {
        case .starting, .relaunching, .running:
            return control != nil
        case .stopped, .crashLooping, .failed:
            return false
        }
    }

    /// Whether a message may go to the service now (launching it if needed); false when nothing is, or will be, running.
    private func prepareToSend() -> Bool {
        connect()
        return isServiceExpected
    }

    /// Queues one message for the service. False when there is none (a crash loop, a refusal, a process that is not out of
    /// process): the message is dropped. Messages sent before the hello is answered are served after it, in order.
    @discardableResult
    func send(_ message: CefRemoteMessage) -> Bool {
        guard prepareToSend(), let control else { return false }
        xpc_connection_send_message(control, message.object)
        return true
    }

    /// One message and the service's reply; it ends once, on the reply, the service's end, or the timeout (default 5 s, plus the
    /// hello's while the service is not up yet: see `effectiveTimeout`). Never waits on a thread: the caller suspends.
    ///
    /// A service that has begun to leave refuses every op that acts on CEF with `CefRemote.leavingError` and ends a moment later.
    /// That refusal is not an answer: the request is asked once more, on the instance that replaces it (the end that follows is
    /// then an idle exit, which counts as no death, unless a browser of ours was in it). Once only: a second refusal is the answer.
    /// Only for a request that names no browser (`ensureContext`, the debug ops): one that does (`browser.create` included) is
    /// not asked again and ends as `.interrupted`.
    func request(_ message: CefRemoteMessage, timeout: TimeInterval? = nil) async -> CefRemoteReply<CefRemoteMessage> {
        await requestTracked(message, timeout: timeout).reply
    }

    /// What one send of a request came to: the reply, and the instance of the service it went to.
    typealias Attempt = (reply: CefRemoteReply<CefRemoteMessage>, instance: Int)

    /// `request`, and the instance of the service that the last attempt was sent to (a caller that remembers what the service
    /// has, like `ensureContext`, must compare with that one: a retry goes to a newer instance than the first attempt). `sending`
    /// replaces the send itself, for a test that scripts the replies.
    func requestTracked(
        _ message: CefRemoteMessage, timeout: TimeInterval? = nil, sending: (@MainActor (CefRemoteMessage) async -> Attempt)? = nil
    ) async -> Attempt {
        let send: @MainActor (CefRemoteMessage) async -> Attempt = sending ?? { [self] in await requestOnce($0, timeout: timeout) }
        let first = await send(message)
        // A sent message is not changed: the retry goes out as a copy, made only when it is needed.
        guard case let .value(reply) = first.reply, Self.isServiceLeavingReply(reply) else { return first }
        // A request that names a browser is not asked again: that browser ends with the instance, and a retried browser.create
        // would make an orphan in the replacement that nobody closes. It ends as `.interrupted`, like any request that the end
        // of the service cuts off (the caller then hears `remoteServiceEnded`).
        guard message.browser == 0 else { return (.interrupted, first.instance) }
        guard let spare = xpc_copy(message.object).flatMap({ CefRemoteMessage(wrapping: $0) }) else { return first }
        leavingRetries += 1
        // Its end is coming: with no browser of ours in it, that is a clean exit and not a death.
        noteLeavingRefusal()
        // The old instance ends within a few seconds (its own exit backstop), and the replacement is asked for then. Bounded by
        // the hello's timeout, which is what a replacement may take.
        guard await waitUntil(helloTimeout, { instance != first.instance }) else {
            refusedAsLeaving = false
            return first
        }
        return await send(spare)
    }

    /// Whether `reply` is the refusal of a service that is leaving (see `request`): not ok, with exactly that text.
    nonisolated static func isServiceLeavingReply(_ reply: CefRemoteMessage) -> Bool {
        !reply.bool(CefRemote.Key.success) && reply.string(CefRemote.Key.error) == CefRemote.leavingError
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            // One turn of the main actor before the sleep: an end that is already queued (the control connection's event) is seen
            // now, and the retry does not wait 50 ms of real time for it (a replacement that is itself short-lived would be asked
            // for, and could end, in that gap).
            await Task.yield()
            if condition() {
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    private func requestOnce(_ message: CefRemoteMessage, timeout: TimeInterval?) async -> Attempt {
        guard prepareToSend(), let control else { return (.interrupted, instance) }
        let table = requests
        let sentTo = instance
        let wait = Self.effectiveTimeout(timeout, defaultTimeout: table.defaultTimeout, isRunning: isRunning, helloTimeout: helloTimeout)
        let answered = await table.request(timeout: wait) { id in
            message.set(CefRemote.Key.identifier, id)
            xpc_connection_send_message_with_reply(control, message.object, DispatchQueue.main) { answer in
                // An error object is left to the connection's event (`serviceEnded`), as in the hello.
                guard let reply = CefRemoteMessage(wrapping: answer) else { return }
                table.reply(id, reply)
            }
        }
        return (answered, sentTo)
    }

    /// A message sent while the service is starting or relaunching is served after the hello, which launchd may hold back for
    /// about 10 s (`defaultHelloTimeout`): its own timeout starts after that wait, or the page would see an error during a
    /// relaunch that is not one. The wait is bounded: the hello's timeout or the service's end ends every queued request.
    nonisolated static func effectiveTimeout(
        _ timeout: TimeInterval?, defaultTimeout: TimeInterval, isRunning: Bool, helloTimeout: TimeInterval
    ) -> TimeInterval {
        (timeout ?? defaultTimeout) + (isRunning ? 0 : helloTimeout)
    }

    /// Input goes on its own connection, so a multi-megabyte DevTools reply never holds a keystroke back. (Input is phase 3.)
    func sendInput(_ message: CefRemoteMessage) {
        guard isRunning else {
            send(message)
            return
        }
        if input == nil {
            let connection = xpc_connection_create(serviceName, DispatchQueue.main)
            xpc_connection_set_event_handler(connection) { _ in }
            xpc_connection_activate(connection)
            sendSideHello(CefRemote.Op.inputHello, on: connection)
            input = connection
        }
        if let input {
            xpc_connection_send_message(input, message.object)
        }
    }

    /// Creates the profile's request context in the service (a disk profile when `cacheDirectory` is given, which must be a child
    /// of the root). True when the service has it. The service compares the cache path with the root it was given (the hello's,
    /// which is canonical), so a path built from a root that has an alias in it (`/var` for `/private/var`) is made canonical here
    /// first, the way the hello's root is. A path that is not the root or under it is refused here, before anything is made.
    func ensureContext(id: UUID, cacheDirectory: URL?) async -> Bool {
        if contexts.contains(id) {
            return true
        }
        let message = CefRemoteMessage(CefRemote.Op.createContext)
        message.set(CefRemote.Key.context, id.uuidString)
        if let cacheDirectory {
            guard let rootURL = try? Self.prepareRoot(root()), let wanted = Self.canonicalPath(of: cacheDirectory),
                  Self.isInside(wanted, root: rootURL)
            else { return false }
            // The folder is not made here: the service checks the path against its root and then makes it.
            message.set(CefRemote.Key.cachePath, wanted.path)
        }
        let (answer, answeredBy) = await requestTracked(message)
        guard case let .value(reply) = answer, reply.bool(CefRemote.Key.success), answeredBy == instance else {
            return false
        }
        contexts.insert(id)
        return true
    }

    // MARK: Browsers

    /// Registers a browser and gives it its id on the wire. The browser itself is created with `browser.create` (D4-4b, D4-8).
    func makeBrowser(_ handle: any ChromiumRemoteBrowserHandle) -> Int64 {
        let id = nextBrowserID
        nextBrowserID += 1
        browsers[id] = handle
        return id
    }

    /// Drops a browser from the registry without telling the service (the browser was never created there).
    func forgetBrowser(_ id: Int64) {
        browsers[id] = nil
    }

    /// Closes a browser and returns when it is closed as far as WSurf is concerned (`beginClose`).
    func closeBrowser(_ id: Int64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            beginClose(id) { continuation.resume() }
        }
    }

    /// Asks the service to close a browser; `completion` runs once, when the browser is closed as far as WSurf is concerned: the
    /// service said so (`browser.closed`), the service ended (the dropped connection means every browser closed), or it did not
    /// answer in `closeTimeout`, in which case WSurf lets go of the browser. A service that is leaving answers no `browser.close`,
    /// so none of the three is waited on for ever. Registered at once, not on a later turn.
    func beginClose(_ id: Int64, completion: @escaping @MainActor () -> Void) {
        guard browsers[id] != nil else {
            completion()
            return
        }
        // A browser asked for while the service is still starting exists there once the hello has been served, so it is closed
        // there too; every way the service can fail to answer (its end, a refused hello, the timeout) ends the wait.
        guard isServiceExpected else {
            finishClose(id)
            completion()
            return
        }
        let request = requests.begin(timeout: Self.closeTimeout) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.finishClose(id)
                completion()
            }
        }
        closing[id] = request
        send(CefRemoteMessage(CefRemote.Op.close, browser: id))
    }

    /// WSurf lets go of the browser: the page hears `browser.closed` (once) if the service did not say it.
    private func finishClose(_ id: Int64) {
        closing[id] = nil
        browsers.removeValue(forKey: id)?.remoteEvent(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
    }

    // MARK: Debug

    /// The service's live counts, or nil when it does not answer (the request's timeout) or ends first.
    func statistics() async -> CefRemoteMessage? {
        guard case let .value(reply) = await request(CefRemoteMessage(CefRemote.Op.debugStats)) else { return nil }
        return reply
    }

    /// The kill test: the service ends itself, as a crash would. Nothing outside signals it.
    func abortService() {
        send(CefRemoteMessage(CefRemote.Op.debugAbort))
    }
}
