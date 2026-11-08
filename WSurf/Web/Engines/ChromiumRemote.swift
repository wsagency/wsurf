// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4 spike (branch spike/chromium-oop, never merged): Chromium out of process. With `WSURF_CHROMIUM_OOP=1` (DEBUG only) CEF
// never loads in WSurf: `WSurf Chromium.xpc` runs it windowless, and each `ChromiumPage` shows its browser through a remote
// layer and talks to it over XPC. WSurf's main thread only queues messages; it never waits on the service.

import AppKit
import CefKit
import QuartzCore
import XPC
import os

nonisolated enum ChromiumOOP {
    static let isEnabled: Bool = {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment["WSURF_CHROMIUM_OOP"] ?? ""
        return !value.isEmpty && value != "0"
        #else
        return false
        #endif
    }()

    static func environment(_ name: String) -> String? {
        #if DEBUG
        let value = ProcessInfo.processInfo.environment[name] ?? ""
        return value.isEmpty ? nil : value
        #else
        return nil
        #endif
    }

    static let log = Logger(subsystem: "io.wsagency.wsurf", category: "chromium-oop")
}

/// The connection to the service: one control connection (requests and every event, in order) and one input connection.
@MainActor
final class ChromiumRemote {
    static let shared = ChromiumRemote()

    private var control: xpc_connection_t?
    private var input: xpc_connection_t?
    private var needsHello = true
    private var browsers: [Int64: ChromiumRemoteBrowser] = [:]
    private var contexts: Set<UUID> = []
    private var nextBrowserID: Int64 = 1
    /// The service's process, once it answered hello.
    private(set) var servicePID: pid_t = 0
    private(set) var helloSentAt: ContinuousClock.Instant?
    /// Milliseconds from hello to the service's answer (launch plus CEF start), and CEF's own start inside it.
    private(set) var helloRoundTripMs: Double = -1
    private(set) var cefStartMs: Double = -1
    private(set) var interruptions = 0
    /// Called when the service is gone (crash, kill, idle exit) with the pages it had.
    var onInterrupted: (() -> Void)?

    var serviceName: String {
        (Bundle.main.bundleIdentifier ?? "io.wsagency.wsurf") + CefRemote.serviceSuffix
    }

    var isRunning: Bool {
        control != nil && !needsHello && servicePID != 0
    }

    var liveBrowserCount: Int {
        browsers.count
    }

    /// CEF's accessibility tree costs work in the renderer, the service and here: it is on only while VoiceOver runs (or for
    /// the spike's own checks, `WSURF_OOP_AX=1`).
    var wantsAccessibility: Bool {
        NSWorkspace.shared.isVoiceOverEnabled || ChromiumOOP.environment("WSURF_OOP_AX") == "1"
    }

    private var voiceOverObservation: NSKeyValueObservation?

    /// Turns every browser's tree on or off as VoiceOver starts or stops.
    private func watchVoiceOver() {
        guard voiceOverObservation == nil else { return }
        // The change may come on any thread: the handler only hops to the main actor.
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled, options: [.new]) { @Sendable _, _ in
            Task { @MainActor in
                let remote = ChromiumRemote.shared
                let enabled = remote.wantsAccessibility
                for browser in remote.browsers.values {
                    browser.send(CefRemote.Op.accessibility) { $0.set(CefRemote.Key.flag, enabled) }
                }
            }
        }
    }

    /// Launches the service (if it is not running) and starts CEF there. Costs WSurf's main thread one message.
    func connect() {
        if control == nil {
            let connection = xpc_connection_create(serviceName, DispatchQueue.main)
            xpc_connection_set_event_handler(connection) { event in
                MainActor.assumeIsolated { ChromiumRemote.shared.receive(event) }
            }
            xpc_connection_activate(connection)
            control = connection
        }
        if needsHello {
            sendHello()
        }
    }

    private func sendHello() {
        guard let control else { return }
        needsHello = false
        let root = ChromiumRuntime.shared.prepareRootForService()
        let message = CefRemoteMessage(CefRemote.Op.hello)
        message.set(CefRemote.Key.identifier, CefRemote.protocolVersion)
        message.set(CefRemote.Key.rootPath, root.path)
        message.set(CefRemote.Key.cachePath, root.appendingPathComponent("Global", isDirectory: true).path)
        message.set(CefRemote.Key.logFile, "/dev/null")
        message.set(CefRemote.Key.path, Self.serviceLogPath ?? "")
        message.set(CefRemote.Key.switches, strings: ChromiumRuntime.extraCommandLineSwitches)
        xpc_dictionary_set_mach_send(message.object, CefRemote.Key.layerServer, CARemoteLayerServer.shared().serverPort)
        message.set(CefRemote.Key.linger, Double(ChromiumOOP.environment("WSURF_OOP_LINGER") ?? "") ?? 60)
        let fps = Int(ChromiumOOP.environment("WSURF_OOP_FPS") ?? "") ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        message.set(CefRemote.Key.frameRate, Int64(fps))
        message.set(CefRemote.Key.beginFrames, ChromiumOOP.environment("WSURF_OOP_BEGIN_FRAMES") ?? "internal")
        let sent = ContinuousClock.now
        helloSentAt = sent
        xpc_connection_send_message_with_reply(control, message.object, DispatchQueue.main) { reply in
            MainActor.assumeIsolated { ChromiumRemote.shared.helloAnswered(reply, sent: sent) }
        }
        ChromiumOOP.log.notice("hello sent to \(self.serviceName, privacy: .public)")
    }

    /// The service's own log, in the stage home: the service cannot see WSurf's environment.
    private static var serviceLogPath: String? {
        #if DEBUG
        guard StageMode.isActive, let home = StageMode.home else { return nil }
        return home.appendingPathComponent("chromium-service.log").path
        #else
        return nil
        #endif
    }

    private func helloAnswered(_ reply: xpc_object_t, sent: ContinuousClock.Instant) {
        guard let message = CefRemoteMessage(wrapping: reply) else {
            ChromiumOOP.log.error("hello: no answer (\(String(describing: reply), privacy: .public))")
            return
        }
        servicePID = pid_t(message.int(CefRemote.Key.pid))
        helloRoundTripMs = Double((ContinuousClock.now - sent).milliseconds)
        cefStartMs = message.double(CefRemote.Key.value)
        let ok = message.bool(CefRemote.Key.success)
        ChromiumOOP.log.notice("hello answered: pid \(self.servicePID), ok \(ok), CEF start \(self.cefStartMs) ms, round trip \(self.helloRoundTripMs) ms")
        if !ok {
            ChromiumOOP.log.error("service could not start CEF: \(message.string(CefRemote.Key.error), privacy: .public)")
        }
    }

    private func receive(_ event: xpc_object_t) {
        if xpc_get_type(event) == XPC_TYPE_ERROR {
            if event === XPC_ERROR_CONNECTION_INTERRUPTED {
                serviceEnded(reason: "interrupted")
            } else if event === XPC_ERROR_CONNECTION_INVALID {
                serviceEnded(reason: "invalid")
                control = nil
            }
            return
        }
        guard let message = CefRemoteMessage(wrapping: event) else { return }
        guard let browser = browsers[message.browser] else { return }
        if message.op == CefRemote.Event.browserClosed {
            browsers[message.browser] = nil
        }
        browser.receive(message)
    }

    /// The service ended: a crash, the debug abort, or its own exit after the linger. Its browsers are gone, and with them
    /// every page's native history (D3b's store is the way back when D4 ships). The next message relaunches it.
    private func serviceEnded(reason: String) {
        interruptions += 1
        ChromiumOOP.log.notice("service ended (\(reason, privacy: .public)): \(self.browsers.count) browsers lost")
        needsHello = true
        servicePID = 0
        contexts.removeAll()
        input = nil
        let lost = browsers.values
        browsers.removeAll()
        for browser in lost {
            browser.serviceEnded()
        }
        onInterrupted?()
    }

    func send(_ message: CefRemoteMessage) {
        connect()
        guard let control else { return }
        xpc_connection_send_message(control, message.object)
    }

    /// Input goes on its own connection, so a multi-megabyte DevTools reply never holds a keystroke back.
    func sendInput(_ message: CefRemoteMessage) {
        guard !needsHello else {
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

    func ensureContext(for owner: BrowserProfileContext) {
        connect()
        guard !contexts.contains(owner.contextID) else { return }
        contexts.insert(owner.contextID)
        let message = CefRemoteMessage(CefRemote.Op.createContext)
        message.set(CefRemote.Key.context, owner.contextID.uuidString)
        if !owner.profile.isPrivate {
            message.set(CefRemote.Key.cachePath, ChromiumRuntime.shared.cacheDirectory(profileID: owner.profile.id).path)
        }
        send(message)
    }

    func makeBrowser(for page: ChromiumPage) -> ChromiumRemoteBrowser {
        watchVoiceOver()
        let browser = ChromiumRemoteBrowser(id: nextBrowserID, page: page)
        nextBrowserID += 1
        browsers[browser.id] = browser
        return browser
    }

    // MARK: Debug

    /// The service's timing statistics (frame copies, output and input legs, frame rate), or nil when it does not answer.
    func statistics(reset: Bool = false) async -> CefRemoteMessage? {
        guard let control, !needsHello else { return nil }
        let request = CefRemoteMessage(CefRemote.Op.debugStats)
        request.set(CefRemote.Key.flag, reset)
        return await withCheckedContinuation { continuation in
            xpc_connection_send_message_with_reply(control, request.object, DispatchQueue.main) { reply in
                continuation.resume(returning: CefRemoteMessage(wrapping: reply))
            }
        }
    }

    /// The day 8-9 kill test: the service ends itself, as a crash would. Nothing outside the app signals it.
    func abortService() {
        guard let control, !needsHello else { return }
        xpc_connection_send_message(control, CefRemoteMessage(CefRemote.Op.debugAbort).object)
    }
}

/// One browser in the service, as WSurf sees it: its id, the remote layer's id, and the state the service pushes with its
/// events (WSurf read them from CEF in the same turn before).
@MainActor
final class ChromiumRemoteBrowser {
    let id: Int64
    weak var page: ChromiumPage?
    private(set) var layerClientID: UInt32 = 0
    private(set) var isReady = false
    private(set) var isClosed = false
    private(set) var readyMs: Double = -1

    var title: String?
    var history: (count: Int, current: Int, first: String)?
    var security: (url: URL?, secureConnection: Bool, certStatus: UInt32, contentStatus: UInt32)?
    var isMuted = false

    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var collapseWaiters: [Int64: CheckedContinuation<Int64, Never>] = [:]
    private var nextCollapse: Int64 = 1

    // What was last sent, so unchanged geometry and visibility are not sent again.
    var sentSize = CGSize.zero
    var sentScale: CGFloat = 0
    var sentHidden: Bool?
    var sentParked: Bool?

    init(id: Int64, page: ChromiumPage) {
        self.id = id
        self.page = page
    }

    func message(_ op: String) -> CefRemoteMessage {
        CefRemoteMessage(op, browser: id)
    }

    func send(_ op: String, _ fill: (CefRemoteMessage) -> Void = { _ in }) {
        guard !isClosed else { return }
        let message = message(op)
        fill(message)
        ChromiumRemote.shared.send(message)
    }

    func sendInput(_ message: CefRemoteMessage) {
        guard !isClosed else { return }
        ChromiumRemote.shared.sendInput(message)
    }

    /// Queues a DevTools message; true when it went to the service (its answer comes as an event).
    func sendDevTools(_ data: Data) -> Bool {
        guard !isClosed else { return false }
        send(CefRemote.Op.devTools) { $0.set(CefRemote.Key.data, data: data) }
        return true
    }

    /// Asks the service to close the browser and waits for its answer, at most `timeout`.
    func close(timeout: Duration = .seconds(5)) async {
        guard !isClosed else { return }
        send(CefRemote.Op.close)
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishClose()
            }
        }
    }

    private func finishClose() {
        isClosed = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
        let collapses = collapseWaiters
        collapseWaiters.removeAll()
        collapses.values.forEach { $0.resume(returning: CefRemote.CollapseOutcome.refused) }
    }

    /// The service's one-turn check and reset of the startup entry (rule 4 of the plan).
    func collapseStartup() async -> Int64 {
        guard !isClosed else { return CefRemote.CollapseOutcome.refused }
        let request = nextCollapse
        nextCollapse += 1
        return await withCheckedContinuation { continuation in
            collapseWaiters[request] = continuation
            send(CefRemote.Op.collapseStartup) { $0.set(CefRemote.Key.identifier, request) }
        }
    }

    func serviceEnded() {
        let page = page
        finishClose()
        page?.remoteServiceEnded()
    }

    func receive(_ message: CefRemoteMessage) {
        mirror(message)
        switch message.op {
        case CefRemote.Event.browserCreated:
            layerClientID = UInt32(truncatingIfNeeded: message.int(CefRemote.Key.layerClient))
            page?.attachRemoteLayer(layerClientID)
        case CefRemote.Event.browserReady:
            isReady = true
            readyMs = message.double(CefRemote.Key.value)
        case CefRemote.Event.browserClosed:
            finishClose()
            page?.remoteBrowserClosed()
        case CefRemote.Event.collapsed:
            collapseWaiters.removeValue(forKey: message.int(CefRemote.Key.identifier))?
                .resume(returning: message.int(CefRemote.Key.outcome))
        default:
            page?.receiveRemote(message)
        }
    }

    /// Keeps what the service pushed with an event: the native history, the visible entry's title and SSL status.
    private func mirror(_ message: CefRemoteMessage) {
        if message.has(CefRemote.Key.historyCount) {
            history = (Int(message.int(CefRemote.Key.historyCount)), Int(message.int(CefRemote.Key.historyIndex)),
                       message.string(CefRemote.Key.historyFirst))
        }
        if message.has(CefRemote.Key.title) {
            title = message.string(CefRemote.Key.title)
        }
        if message.has(CefRemote.Key.securityURL) {
            security = (URL(string: message.string(CefRemote.Key.securityURL)), message.bool(CefRemote.Key.secureConnection),
                        UInt32(truncatingIfNeeded: message.int(CefRemote.Key.certStatus)),
                        UInt32(truncatingIfNeeded: message.int(CefRemote.Key.contentStatus)))
        }
    }
}
