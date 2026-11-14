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
}

extension ChromiumRemoteBrowserHandle {
    func remoteAllowsNavigation(to url: String) -> Bool {
        true
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
    static let defaultHelloTimeout: TimeInterval = 15
    /// How long a `browser.close` waits for its `browser.closed`.
    static let closeTimeout: TimeInterval = 5

    let serviceName: String
    let sink: ChromiumFrameSink
    private let root: () -> URL
    private let linger: Double?
    private let logFile: String?
    private let helloTimeout: TimeInterval
    private let protocolVersion: Int64
    private let clock: () -> TimeInterval
    private let isEnabled: () -> Bool
    private let latch: ChromiumOOP.Latch
    /// Every completion runs on the main queue: replies and interruptions come on it, and so do the timers.
    private let requests = CefRemoteRequests<CefRemoteMessage>(schedule: cefRemoteTimer(on: .main))

    private var control: xpc_connection_t?
    private var input: xpc_connection_t?
    private var frames: xpc_connection_t?
    /// Bumped when a control connection is opened or abandoned: its late events are ignored (`receive`).
    private(set) var generation = 0
    private var needsHello = true
    private var relaunching = false
    private var policy = CefRemoteRelaunchPolicy()
    private var browsers: [Int64: any ChromiumRemoteBrowserHandle] = [:]
    /// Browser ids start at 1 and are never reused (0 is what a message with no `bid` reads as).
    private var nextBrowserID: Int64 = 1
    private var contexts: Set<UUID> = []
    /// The request that waits for each browser's `browser.closed`.
    private var closing: [Int64: Int64] = [:]
    /// Bumped each time the service ends: an answer that comes back after it belongs to the instance that died.
    private var instance = 0

    private(set) var state = ServiceState.stopped
    /// The service's process, once it answered a hello.
    private(set) var servicePID: pid_t = 0
    private(set) var helloCount = 0
    private(set) var interruptions = 0
    /// Milliseconds from hello to its answer (launch, the launchd throttle and CEF's start), and CEF's own start inside it.
    private(set) var helloRoundTripMs: Double = -1
    private(set) var cefStartMs: Double = -1
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
        isEnabled: @escaping () -> Bool = { ChromiumOOP.isEnabled }
    ) {
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

    var hasInputConnection: Bool {
        input != nil
    }

    var hasFramesConnection: Bool {
        frames != nil
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
    }

    /// The person reloaded a page: a crash loop or a refusal is given up, and the service is asked for again.
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
        setState(relaunching ? .relaunching : .starting)
        let message: CefRemoteMessage
        do {
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
        xpc_connection_send_message_with_reply(control, message.object, DispatchQueue.main) { answer in
            // An error object (the connection ended) is left to the control connection's own event, which ends every request
            // (`serviceEnded`); ending them here too could end a request of the next instance. The timeout is the backstop.
            guard let reply = CefRemoteMessage(wrapping: answer) else { return }
            // A service that is leaving refuses the hello without a pid or a version, and then ends: the hello stays waiting, so
            // that the interruption that follows is a death with a hello pending and the replacement is asked for. (If the
            // service never ends, as one that already has another host, the hello's timeout ends it.)
            guard !Self.isLeavingRefusal(reply) else { return }
            table.reply(id, reply)
        }
        ChromiumOOP.log.notice("hello sent to \(self.serviceName, privacy: .public) (hello \(self.helloCount))")
    }

    private func helloEnded(_ reply: CefRemoteReply<CefRemoteMessage>, sentAt: TimeInterval, generation sentGeneration: Int) {
        guard sentGeneration == generation else { return }
        switch reply {
        case .interrupted:
            // `serviceEnded` handles the end, and it decides whether this was a death.
            return
        case .timedOut:
            ChromiumOOP.log.error("hello: no answer in \(self.helloTimeout) s")
            fail(.noAnswer)
        case let .value(message):
            guard message.bool(CefRemote.Key.success) else {
                refused(message)
                return
            }
            servicePID = pid_t(message.int(CefRemote.Key.pid))
            cefStartMs = message.double(CefRemote.Key.startMs)
            helloRoundTripMs = (clock() - sentAt) * 1000
            relaunching = false
            ChromiumOOP.log.notice("hello answered: pid \(self.servicePID), CEF start \(self.cefStartMs) ms, round trip \(self.helloRoundTripMs) ms")
            setState(.running(pid: servicePID))
            openFrames()
        }
    }

    /// The tab's error text is WSurf's own, built from this: the service's `error` sentence is never shown as it is.
    private func refused(_ message: CefRemoteMessage) {
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
            serviceEnded(reason: "invalid")
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
        let allowed = browsers[message.browser]?.remoteAllowsNavigation(to: message.string(CefRemote.Key.url)) ?? false
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
        ChromiumOOP.log.notice("service ended (\(reason, privacy: .public)): \(self.browsers.count) browsers lost, in use \(wasInUse)")
        let lost = takeEverythingDown(keepingControl: true)
        needsHello = true
        servicePID = 0
        requests.interruptAll()
        for handle in lost {
            handle.remoteServiceEnded()
        }
        switch policy.recordDeath(at: clock(), serviceWasInUse: wasInUse) {
        case .relaunch:
            // At once, not at the next message. launchd decides when the replacement starts (not before 10 s after the spawn of
            // the one that died), and the hello waits for it with a timeout that allows for that.
            relaunching = true
            setState(.relaunching)
            connect()
        case .crashLooping:
            relaunching = false
            setState(.crashLooping)
        case .idleExit:
            // An end that arrives after the cap was reached (nothing is in the service then) must not undo the crash state.
            relaunching = false
            setState(policy.isCrashLooping ? .crashLooping : .stopped)
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

    /// One message and the service's reply; it ends once, on the reply, the service's end, or the timeout (default 5 s). Never
    /// waits on a thread: the caller suspends.
    func request(_ message: CefRemoteMessage, timeout: TimeInterval? = nil) async -> CefRemoteReply<CefRemoteMessage> {
        guard prepareToSend(), let control else { return .interrupted }
        let table = requests
        return await table.request(timeout: timeout) { id in
            message.set(CefRemote.Key.identifier, id)
            xpc_connection_send_message_with_reply(control, message.object, DispatchQueue.main) { answer in
                // An error object is left to the connection's event (`serviceEnded`), as in the hello.
                guard let reply = CefRemoteMessage(wrapping: answer) else { return }
                table.reply(id, reply)
            }
        }
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
            xpc_connection_send_message(connection, CefRemoteMessage(CefRemote.Op.inputHello).object)
            input = connection
        }
        if let input {
            xpc_connection_send_message(input, message.object)
        }
    }

    /// Creates the profile's request context in the service (a disk profile when `cacheDirectory` is given, which must be a child
    /// of the root). True when the service has it. The service compares the cache path with the root it was given (the hello's,
    /// which is canonical), so a path built from a root that has an alias in it (`/var` for `/private/var`) is made canonical here
    /// first, the way the hello's root is: its parent, which exists, is resolved and the last component is appended.
    func ensureContext(id: UUID, cacheDirectory: URL?) async -> Bool {
        if contexts.contains(id) {
            return true
        }
        let message = CefRemoteMessage(CefRemote.Op.createContext)
        message.set(CefRemote.Key.context, id.uuidString)
        if let cacheDirectory {
            guard let parent = try? Self.prepareRoot(cacheDirectory.deletingLastPathComponent()) else { return false }
            message.set(CefRemote.Key.cachePath, parent.appending(path: cacheDirectory.lastPathComponent, directoryHint: .isDirectory).path)
        }
        let asked = instance
        guard case let .value(reply) = await request(message), reply.bool(CefRemote.Key.success), asked == instance else {
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

    /// Closes a browser and returns when it is closed as far as WSurf is concerned: the service said so (`browser.closed`), the
    /// service ended (the dropped connection means every browser closed), or it did not answer in `closeTimeout`, in which
    /// case WSurf lets go of it. A service that is leaving answers no `browser.close`, so none of the three is waited on for ever.
    func closeBrowser(_ id: Int64) async {
        guard browsers[id] != nil else { return }
        // A browser asked for while the service is still starting exists there once the hello has been served, so it is closed
        // there too; every way the service can fail to answer (its end, a refused hello, the timeout) ends the wait.
        if isServiceExpected {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let request = requests.begin(timeout: Self.closeTimeout) { _ in continuation.resume() }
                closing[id] = request
                send(CefRemoteMessage(CefRemote.Op.close, browser: id))
            }
        }
        if let handle = browsers.removeValue(forKey: id) {
            closing[id] = nil
            handle.remoteEvent(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
        }
    }

    // MARK: Frames

    private func openFrames() {
        guard frames == nil else { return }
        let sink = sink
        let connection = xpc_connection_create(serviceName, sink.framesQueue)
        xpc_connection_set_event_handler(connection) { event in
            Self.deliverFrame(event, to: sink)
        }
        xpc_connection_activate(connection)
        xpc_connection_send_message(connection, CefRemoteMessage(CefRemote.Op.framesHello).object)
        frames = connection
    }

    /// On the frames queue: decodes a frame or a popup event and hands it to the sink. Anything else is ignored.
    nonisolated static func deliverFrame(_ event: xpc_object_t, to sink: ChromiumFrameSink) {
        guard let message = CefRemoteMessage(wrapping: event) else { return }
        switch message.op {
        case CefRemote.Event.frame:
            guard let object = xpc_dictionary_get_value(event, CefRemote.Key.surface),
                  let surface = IOSurfaceLookupFromXPCObject(object)
            else { return }
            sink.apply(surface: surface, browser: message.browser, popup: message.bool(CefRemote.Key.flag))
        case CefRemote.Event.popup:
            // The popup's rectangle is in view points, top-left origin (D4-7 sends it with these keys).
            let rect = CGRect(
                x: message.double(CefRemote.Key.originX), y: message.double(CefRemote.Key.originY),
                width: message.double(CefRemote.Key.width), height: message.double(CefRemote.Key.height)
            )
            sink.applyPopup(browser: message.browser, visible: message.bool(CefRemote.Key.flag), rect: rect)
        default:
            return
        }
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

    // MARK: The hello

    /// The Chromium switches the service may be given: exactly the ones WSurf's own Chromium has (`ChromiumRuntime`), with the
    /// values it gives them. Anything else a caller asks for (`no-sandbox`, a remote-debugging port, `disable-web-security`, a
    /// profile directory) is dropped here, so no hello, whoever builds it, can loosen the service.
    nonisolated static func allowedSwitches(_ requested: [String: String?]) -> [String: String?] {
        requested.filter { name, value in
            guard let allowed = ChromiumRuntime.extraCommandLineSwitches[name] else { return false }
            return allowed == value
        }
    }

    /// The only log file the service may be told about: the staged run's own (`chromium-service.log` in its home). Any other path,
    /// or none, or any path outside a staged run, is `/dev/null`, so no URL a page visits ever lands in a file of the service's
    /// choosing.
    nonisolated static func validatedLogPath(_ candidate: String?, stageHome: URL?) -> String {
        guard let candidate, candidate.hasPrefix("/"), let stageHome else { return "/dev/null" }
        let staged = stageHome.appending(path: "chromium-service.log", directoryHint: .notDirectory).standardizedFileURL.path
        return URL(filePath: candidate).standardizedFileURL.path == staged ? staged : "/dev/null"
    }

    /// The staged run's home, in a staged DEBUG run.
    nonisolated static var stageHome: URL? {
        #if DEBUG
        return StageMode.isActive ? StageMode.home : nil
        #else
        return nil
        #endif
    }

    /// The staged run's service log, which `validatedLogPath` accepts.
    nonisolated static var stagedLogPath: String? {
        stageHome?.appending(path: "chromium-service.log", directoryHint: .notDirectory).path
    }

    /// The hello: version, root and cache (the root's `Global`, as the in-process path), the allowed switches, the validated log
    /// file, and the linger when one is chosen (else the service's 60 s).
    nonisolated static func makeHello(
        protocolVersion: Int64 = CefRemote.protocolVersion,
        root: URL,
        linger: Double? = nil,
        switches: [String: String?] = ChromiumRuntime.extraCommandLineSwitches,
        logFile: String? = nil,
        stageHome: URL? = ChromiumRemote.stageHome
    ) -> CefRemoteMessage {
        let message = CefRemoteMessage.hello(protocolVersion: protocolVersion, linger: linger)
        message.set(CefRemote.Key.rootPath, root.path)
        message.set(CefRemote.Key.cachePath, root.appending(path: "Global", directoryHint: .isDirectory).path)
        message.set(CefRemote.Key.logFile, validatedLogPath(logFile, stageHome: stageHome))
        message.set(CefRemote.Key.switches, strings: allowedSwitches(switches))
        return message
    }

    /// The root as CEF needs it: it exists, and it is the canonical path (Foundation keeps `/tmp` aliases; CEF refuses them).
    nonisolated static func prepareRoot(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let canonical = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(canonical) }
        return URL(filePath: String(cString: canonical), directoryHint: .isDirectory)
    }
}
