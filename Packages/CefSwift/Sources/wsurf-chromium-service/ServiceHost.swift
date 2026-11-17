// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-4a: the service's state. Everything here runs on the main thread, which is CEF's UI thread: every connection delivers on
// the main queue, and CEF calls back there through the external message pump. The two exceptions are `askHost`, which waits
// for its reply on a queue of its own, and the memory-pressure source's handler, which is the main queue's too.
//
// The rules of the lifecycle are CefKit's (`CefRemoteLinger`); this file feeds them (the number of browsers, the system's
// memory pressure) and does what they decide.

import AppKit
import CCef
import CCefAppKit
import CefKit
import IOSurface
@preconcurrency import XPC

@MainActor
final class ServiceHost {
    static let shared = ServiceHost()

    /// How long a close may take before the service stops waiting for the browsers (and exits without a CEF shutdown).
    private static let closeCapSeconds: TimeInterval = 3
    /// How long the cookie flush gets to finish on CEF's own threads before CEF is shut down.
    private static let flushGraceSeconds: TimeInterval = 0.5
    /// When a deliberate exit that has begun is forced, whatever the main thread is doing: after the cap, the flush grace and
    /// two seconds for `cef_shutdown`. The normal exits finish well before it, so it never shortens them.
    private static let exitBackstopSeconds: TimeInterval = closeCapSeconds + flushGraceSeconds + 2

    /// The connection that said hello: events go there. The input connection (`attachSideConnection`) carries the input of
    /// every browser (D4-12); the frames connection carries every browser's frames (D4-7).
    private var control: xpc_connection_t?
    private var inputConnection: xpc_connection_t?
    private var framesConnection: xpc_connection_t?
    /// The accessibility connection (D4-40): CEF's tree updates go there, never on the control connection.
    private var accessibilityConnection: xpc_connection_t?
    /// The browsers whose tree is on: the ones a new or lost accessibility connection switches off.
    private var accessibilityBrowsers: Set<Int64> = []
    private var contexts: [String: UnsafeMutablePointer<cef_request_context_t>] = [:]
    /// The open browsers by id (WSurf assigns the ids), and the DEBUG stubs, which count as open browsers too so that the
    /// lifecycle can be tested without CEF.
    private var browsers: [Int64: RemoteBrowser] = [:]
    private var stubs: [Int64: StubBrowser] = [:]
    private var linger: CefRemoteLinger?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var holdsTransaction = false
    private var exiting = false
    private var backstopArmed = false
    private var exitScheduled = false
    private var flushCount = 0
    private var cefStartMs: Double = -1
    private var logFile = "/dev/null"
    /// The control connection's hello was answered "ok" (CEF is up): only then may the input and frames connections attach.
    private var hostReady = false

    /// A browser that is not one: it counts as open and answers a close, or does not (`answersClose`).
    private struct StubBrowser {
        let answersClose: Bool
    }

    /// How many browsers are open, real or stub: what the linger follows.
    private var openCount: Int { browsers.count + stubs.count }

    // MARK: Connections

    nonisolated static func accept(_ peer: xpc_connection_t) {
        xpc_connection_set_target_queue(peer, DispatchQueue.main)
        xpc_connection_set_event_handler(peer) { event in
            MainActor.assumeIsolated { ServiceHost.shared.receive(event, from: peer) }
        }
        xpc_connection_activate(peer)
    }

    private func receive(_ event: xpc_object_t, from peer: xpc_connection_t) {
        if xpc_get_type(event) == XPC_TYPE_ERROR {
            if event === XPC_ERROR_CONNECTION_INVALID {
                peerGone(peer)
            } else if event === XPC_ERROR_TERMINATION_IMMINENT {
                note("termination imminent")
                closeEverythingAndExit()
            }
            return
        }
        guard let message = CefRemoteMessage(wrapping: event) else { return }
        handle(message, from: peer)
    }

    private func peerGone(_ peer: xpc_connection_t) {
        // Independent: one connection may be both (the host's process may use one for each, or one for both).
        if peer === inputConnection {
            inputConnection = nil
        }
        if peer === framesConnection {
            framesConnection = nil
        }
        if peer === accessibilityConnection {
            // Nobody takes the updates any more: the browsers stop building their trees (a new connection starts from none).
            accessibilityConnection = nil
            switchAccessibilityOff()
        }
        guard peer === control else { return }
        note("WSurf's connection ended: closing \(openCount) browsers and exiting")
        control = nil
        hostReady = false
        for side in [inputConnection, framesConnection, accessibilityConnection] {
            if let side {
                xpc_connection_cancel(side)
            }
        }
        inputConnection = nil
        framesConnection = nil
        accessibilityConnection = nil
        closeEverythingAndExit()
    }

    func send(_ message: CefRemoteMessage) {
        guard let control else { return }
        xpc_connection_send_message(control, message.object)
    }

    // MARK: Messages

    private func handle(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        switch message.op {
        case "ping":
            // The D4-2 stub's answer, in plain keys: the bundle tests (launch, TCC attribution) still use it.
            reply(to: message, on: peer) { $0.set(CefRemote.Key.pid, Int64(getpid())) }
        case CefRemote.Op.hello:
            hello(message, from: peer)
        case CefRemote.Op.inputHello, CefRemote.Op.framesHello, CefRemote.Op.axHello:
            attachSideConnection(message, from: peer)
        case CefRemote.Op.accessibility:
            guard isHost(peer, for: message) else { return }
            let refusal = setAccessibility(message)
            reply(to: message, on: peer) {
                $0.set(CefRemote.Key.success, refusal == nil)
                if let refusal { $0.set(CefRemote.Key.error, refusal) }
            }
        case CefRemote.Op.mouse, CefRemote.Op.key, CefRemote.Op.focus, CefRemote.Op.edit:
            routeInput(message, from: peer)
        case CefRemote.Op.createContext:
            guard isHost(peer, for: message) else { return }
            createContext(message, from: peer)
        case CefRemote.Op.createBrowser:
            guard isHost(peer, for: message) else { return }
            createBrowser(message, from: peer)
        case CefRemote.Op.close:
            guard isHost(peer, for: message) else { return }
            closeBrowser(message.browser)
        case CefRemote.Op.load, CefRemote.Op.reload, CefRemote.Op.goBack, CefRemote.Op.goForward, CefRemote.Op.stop,
             CefRemote.Op.zoom, CefRemote.Op.mute, CefRemote.Op.find, CefRemote.Op.stopFinding, CefRemote.Op.devTools,
             CefRemote.Op.collapseHistory, CefRemote.Op.visibility, CefRemote.Op.resize:
            guard isHost(peer, for: message) else { return }
            guard let browser = browsers[message.browser] else {
                reply(to: message, on: peer) { $0.set(CefRemote.Key.error, "no such browser") }
                return
            }
            browser.handle(message, from: peer)
        default:
            #if WSURF_SERVICE_DEBUG_OPS
            if handleDebug(message, from: peer) { return }
            #endif
            // A service ignores an op it does not know; a sender that asked for an answer gets an error, not a silence.
            note("no handler for \(message.op)")
            reply(to: message, on: peer) { $0.set(CefRemote.Key.error, "unknown op") }
        }
    }

    /// Whether `message`, which acts on CEF (a context, a browser), may be served: only the connection that said hello is the host
    /// (a refused second host, or a connection that never said hello, has no say), and nothing new is served once the exit has
    /// begun. Not asked of `ping`, the hellos and the DEBUG ops. A refusal is answered (when the sender asked) and has no effect.
    /// Every op that acts on CEF goes through this, the browser ops too. (`closeEverythingAndExit` calls `closeBrowser` itself.)
    private func isHost(_ peer: xpc_connection_t, for message: CefRemoteMessage) -> Bool {
        guard peer === control else {
            note("\(message.op) refused: not the host")
            reply(to: message, on: peer) { $0.set(CefRemote.Key.error, "not the host") }
            return false
        }
        guard !exiting else {
            note("\(message.op) refused: the service is leaving")
            reply(to: message, on: peer) { $0.set(CefRemote.Key.error, CefRemote.leavingError) }
            return false
        }
        return true
    }

    /// Sends `fill`'s message as the answer to `request`, when the sender asked for one.
    func reply(to request: CefRemoteMessage, on peer: xpc_connection_t, _ fill: (CefRemoteMessage) -> Void) {
        guard let answer = CefRemoteMessage(replyTo: request) else { return }
        fill(answer)
        xpc_connection_send_message(peer, answer.object)
    }

    private func hello(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        let check = message.checkProtocolVersion()
        guard check == .compatible else {
            note("hello refused: \(check)")
            reply(to: message, on: peer) { $0.setRefusal(check) }
            return
        }
        guard !exiting else {
            // A hello that got `ok` from a service that is about to leave would be followed by an interruption.
            note("hello refused: the service is leaving")
            reply(to: message, on: peer) {
                $0.set(CefRemote.Key.success, false)
                $0.set(CefRemote.Key.error, CefRemote.leavingError)
            }
            return
        }
        if let control, control !== peer {
            // One WSurf per service: a second control connection would take the first one's events.
            note("hello refused: the service already has a host")
            reply(to: message, on: peer) {
                $0.set(CefRemote.Key.success, false)
                $0.set(CefRemote.Key.error, "The Chromium service already serves another connection.")
            }
            return
        }
        #if WSURF_SERVICE_DEBUG_OPS
        if Self.consumeExitOnHello(root: message.string(CefRemote.Key.rootPath)) {
            note("debug.exitOnHello: the service kills itself (SIGKILL)")
            kill(getpid(), SIGKILL)
        }
        #endif
        control = peer
        if !holdsTransaction {
            // From the first hello to the exit the service stays up for the linger: launchd must not end it as idle.
            xpc_transaction_begin()
            holdsTransaction = true
        }
        let seconds = message.has(CefRemote.Key.linger) ? message.double(CefRemote.Key.linger) : CefRemoteLinger.defaultSeconds
        if let linger {
            linger.setSeconds(seconds)
        } else {
            linger = CefRemoteLinger(
                seconds: seconds,
                schedule: cefRemoteTimer(on: .main),
                onExit: { reason in
                    DispatchQueue.main.async { MainActor.assumeIsolated { ServiceHost.shared.lingerEnded(reason) } }
                }
            )
        }
        var failure: String?
        do {
            try startCEF(message)
        } catch {
            note("CEF start failed: \(error)")
            failure = "\(error)"
        }
        // The side connections may attach only after a hello that got `ok`: a refused one (a root that is not canonical, a CEF that
        // would not start) leaves a service with a control connection and no CEF, which must not be given frames or input.
        hostReady = failure == nil
        // With no browser the linger starts now, so a service whose CEF failed to start leaves too.
        linger?.start()
        startMemoryPressureSource()
        reply(to: message, on: peer) { answer in
            answer.set(CefRemote.Key.pid, Int64(getpid()))
            answer.set(CefRemote.Key.protocolVersion, CefRemote.protocolVersion)
            if let failure {
                answer.set(CefRemote.Key.success, false)
                answer.set(CefRemote.Key.error, failure)
            } else {
                answer.set(CefRemote.Key.success, true)
                answer.set(CefRemote.Key.startMs, cefStartMs)
            }
        }
    }

    // MARK: CEF

    private func startCEF(_ message: CefRemoteMessage) throws {
        guard !CefRuntime.shared.isInitialized else { return }
        let started = Clock.nowNanoseconds
        let root = message.string(CefRemote.Key.rootPath)
        guard root.hasPrefix("/") else { throw ServiceError(text: "the root cache path must be absolute") }
        // CEF refuses a root with an alias in it (`/var` for `/private/var`, a symlink), so the host sends the canonical one, and
        // anything else is refused here, before anything is made, with a reason that names the cause.
        guard Self.realPath(root) == root else {
            throw ServiceError(text: "the root cache path must exist and be canonical (no symlink or alias in it)")
        }
        let cache = message.string(CefRemote.Key.cachePath)
        guard cache.isEmpty || Self.isInside(cache, root: root) else {
            throw ServiceError(text: "the cache path must be the root cache path or inside it")
        }
        // The framework and the helpers are the service's own copies (`Tools/embed-chromium.sh`): Chromium's sandbox lets a
        // child read only inside the browser process's main bundle, which here is the .xpc.
        let bundle = Bundle.main.bundleURL
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        var configuration = CefConfiguration()
        configuration.noSandbox = false
        // Until the owner picks a "Chromium Safe Storage" option (D4-S), the service never reads the keychain: a profile with
        // cookies encrypted under the real key would lose them, and a new code identity would raise a keychain prompt.
        configuration.safeStorage = .mockKeychain
        configuration.rootCachePath = URL(filePath: root, directoryHint: .isDirectory)
        configuration.cachePath = cache.isEmpty ? nil : URL(filePath: cache, directoryHint: .isDirectory)
        configuration.persistSessionCookies = true
        configuration.defaultRuntimeStyle = .alloy
        // CEF's log goes to /dev/null unless WSurf names a file (a staged run).
        let named = message.string(CefRemote.Key.logFile)
        logFile = named.hasPrefix("/") ? named : "/dev/null"
        configuration.logFile = URL(filePath: logFile)
        configuration.logSeverity = logFile == "/dev/null" ? .error : .warning
        configuration.extraCommandLineSwitches = message.strings(CefRemote.Key.switches).mapValues { $0.isEmpty ? nil : $0 }
        configuration.windowlessRenderingEnabled = true
        configuration.frameworkDirectory = frameworks.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        configuration.browserSubprocessPath = frameworks.appendingPathComponent("WSurf Helper.app/Contents/MacOS/WSurf Helper")
        configuration.mainBundlePath = bundle
        try CefRuntime.shared.initialize(configuration: configuration)
        CEFApplication.setTerminateHandler(nil)
        cefStartMs = Double(Clock.nowNanoseconds &- started) / 1e6
        note(String(format: "CEF started in %.1f ms", cefStartMs))
    }

    /// `path` with every symlink and alias resolved, for a path that may not exist yet: the nearest existing ancestor goes through
    /// `realpath` and the components below it are appended (they do not exist, so they cannot be links). Nil for a relative path,
    /// for one with a `.` or `..` component (which would be resolved before a link in front of it, so the result could name
    /// somewhere else than the path does), and when no ancestor resolves.
    private static func realPath(_ path: String) -> String? {
        let components = (path as NSString).pathComponents
        guard path.hasPrefix("/"), !components.contains(".."), !components.contains(".") else { return nil }
        var existing = path
        var below: [String] = []
        while !FileManager.default.fileExists(atPath: existing) {
            guard existing != "/" else { return nil }
            below.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return nil }
        defer { free(resolved) }
        return ([String(cString: resolved)] + below).joined(separator: "/").replacingOccurrences(of: "//", with: "/")
    }

    /// Whether `path` is `root` (canonical) or below it, as CEF requires of a cache path. The path is resolved first, folders that
    /// do not exist yet included, and nothing is created here: the caller makes the folder only after this says yes.
    private static func isInside(_ path: String, root: String) -> Bool {
        guard let path = realPath(path) else { return false }
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func createContext(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        let identifier = message.string(CefRemote.Key.context)
        let path = message.string(CefRemote.Key.cachePath)
        let root = CefRuntime.shared.configuration?.rootCachePath?.path ?? ""
        var failure: String?
        if !CefRuntime.shared.isInitialized {
            failure = "CEF is not started"
        } else if identifier.isEmpty {
            failure = "a context needs an id"
        } else if !path.isEmpty && !Self.isInside(path, root: root) {
            failure = "the cache path must be inside the root cache path"
        } else if contexts[identifier] == nil {
            var settings = cef_request_context_settings_t()
            settings.size = MemoryLayout<cef_request_context_settings_t>.stride
            if !path.isEmpty {
                try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                Native.set(path, &settings.cache_path)
                settings.persist_session_cookies = 1
            }
            defer { ccef_string_clear(&settings.cache_path) }
            if let context = cef_request_context_create_context(&settings, nil) {
                contexts[identifier] = context
                note("context: \(path.isEmpty ? "in memory" : "disk")")
            } else {
                failure = "CEF could not create the context"
            }
        }
        reply(to: message, on: peer) { answer in
            answer.set(CefRemote.Key.success, failure == nil)
            if let failure { answer.set(CefRemote.Key.error, failure) }
        }
    }

    /// The input, frames and accessibility (D4-40) connections say which control connection they belong to by being its process's: they are accepted
    /// only after a hello that got `ok` (CEF is up), only from the process of the host, only while the service is not leaving,
    /// and are dropped with the control connection (review F8b, pr123 C3). The same peer may be both. A second hello of one kind
    /// replaces the first connection, which is cancelled. Their hello gets an answer: a refusal is how the client learns that
    /// the connection it holds is not attached.
    private func attachSideConnection(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        var failure: String?
        if let control, hostReady, !exiting {
            if peer === control {
                failure = "the control connection cannot be an input, frames or accessibility connection"
            } else if xpc_connection_get_pid(peer) != xpc_connection_get_pid(control) {
                failure = "not the host's process"
            }
        } else {
            failure = exiting ? CefRemote.leavingError : "no host has said hello"
        }
        if failure == nil {
            let old: xpc_connection_t?
            switch message.op {
            case CefRemote.Op.inputHello:
                old = inputConnection
                inputConnection = peer
            case CefRemote.Op.axHello:
                old = accessibilityConnection
                accessibilityConnection = peer
            default:
                old = framesConnection
                framesConnection = peer
            }
            // The replaced connection is cancelled, unless the same peer still serves another kind.
            if let old, old !== peer, ![inputConnection, framesConnection, accessibilityConnection].contains(where: { $0 === old }) {
                xpc_connection_cancel(old)
            }
            note("\(message.op) connection open")
            if message.op == CefRemote.Op.axHello {
                // A new accessibility connection starts from no tree: the first update of an enabled browser is its whole tree.
                switchAccessibilityOff()
            }
            if message.op == CefRemote.Op.framesHello {
                // Whatever was painted before the connection attached went nowhere: every shown page paints again.
                for browser in browsers.values {
                    browser.requestFrame()
                }
            }
        } else {
            note("\(message.op) refused: \(failure ?? "")")
        }
        reply(to: message, on: peer) { answer in
            answer.set(CefRemote.Key.success, failure == nil)
            if let failure { answer.set(CefRemote.Key.error, failure) }
        }
    }

    /// D4-12: input comes on the input connection, in the order the person produced it (the control connection carries it only before
    /// the input connection exists: WSurf's `sendInput` falls back to it while no service runs). It has no reply, and none of it is
    /// served from any other peer or once the exit has begun.
    private func routeInput(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        guard peer === inputConnection || peer === control, !exiting else { return }
        browsers[message.browser]?.handleInput(message)
    }

    /// Whether a frames connection is attached: with none, the browsers copy and send nothing.
    var hasFramesConnection: Bool { framesConnection != nil }

    // MARK: Accessibility (D4-40)

    /// With none attached, CEF's updates are not even converted to JSON.
    var hasAccessibilityConnection: Bool { accessibilityConnection != nil }

    /// `ax.enable`: nil when it was done, else the reason it was not. Turning the tree on is refused while no accessibility
    /// connection is attached: the first update is the whole tree and would go nowhere, and every later one is incremental.
    private func setAccessibility(_ message: CefRemoteMessage) -> String? {
        let enabled = message.bool(CefRemote.Key.flag)
        guard let browser = browsers[message.browser] else { return "no such browser" }
        guard !enabled || accessibilityConnection != nil else { return "no accessibility connection" }
        browser.setAccessibility(enabled)
        if enabled {
            accessibilityBrowsers.insert(message.browser)
        } else {
            accessibilityBrowsers.remove(message.browser)
        }
        return nil
    }

    /// The accessibility connection is gone: no browser builds a tree for nobody.
    private func switchAccessibilityOff() {
        for id in accessibilityBrowsers {
            browsers[id]?.setAccessibility(false)
        }
        accessibilityBrowsers.removeAll()
    }

    /// One of CEF's accessibility updates, as JSON, to the accessibility connection. `name` is ``CefRemote/Event/accessibilityTree``
    /// or ``CefRemote/Event/accessibilityLocation``.
    func sendAccessibility(browser id: Int64, name: String, data: Data) {
        guard let accessibilityConnection else { return }
        let message = CefRemoteMessage(name, browser: id)
        message.set(CefRemote.Key.data, data: data)
        xpc_connection_send_message(accessibilityConnection, message.object)
    }

    /// One frame to WSurf's frames connection. The IOSurface travels as a Mach port; WSurf puts it in a layer from its frames
    /// queue, never its main thread. `entry`: when CEF entered the paint callback, on the mach clock the two processes share.
    func sendFrame(browser id: Int64, surface: IOSurfaceRef, popup: Bool, entry: UInt64) {
        guard let framesConnection else { return }
        let message = CefRemoteMessage(CefRemote.Event.frame, browser: id)
        xpc_dictionary_set_value(message.object, CefRemote.Key.surface, IOSurfaceCreateXPCObject(surface))
        message.set(CefRemote.Key.flag, popup)
        message.set(CefRemote.Key.timestamp, Double(entry) / 1e9)
        xpc_connection_send_message(framesConnection, message.object)
    }

    /// The popup widget was shown, moved or hidden: on the frames connection, so it is ordered with the popup's frames. The
    /// rectangle is in view points, top-left origin.
    func sendPopup(browser id: Int64, visible: Bool, rect: CGRect) {
        guard let framesConnection else { return }
        let message = CefRemoteMessage(CefRemote.Event.popup, browser: id)
        message.set(CefRemote.Key.flag, visible)
        message.set(CefRemote.Key.originX, Double(rect.minX))
        message.set(CefRemote.Key.originY, Double(rect.minY))
        message.set(CefRemote.Key.width, Double(rect.width))
        message.set(CefRemote.Key.height, Double(rect.height))
        xpc_connection_send_message(framesConnection, message.object)
    }

    // MARK: Browsers and the lifecycle

    /// The number of open browsers changed: the linger follows it, and a service that was closing everything is done.
    private func browsersChanged() {
        if exiting {
            if openCount == 0 { flushAndExit() }
            return
        }
        linger?.browserCountChanged(openCount)
    }

    private func createBrowser(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        let identifier = message.browser
        let contextID = message.string(CefRemote.Key.context)
        let url = message.has(CefRemote.Key.url) ? message.string(CefRemote.Key.url) : "about:blank"
        var failure: String?
        var duplicate = false
        if !CefRuntime.shared.isInitialized {
            failure = "CEF is not started"
        } else if !message.has(CefRemote.Key.browser) {
            failure = "a browser needs an id"
        } else if browsers[identifier] != nil || stubs[identifier] != nil {
            failure = "a browser with this id is open"
            duplicate = true
        } else if !contextID.isEmpty && contexts[contextID] == nil {
            failure = "unknown context"
        } else if url.isEmpty {
            failure = "a browser needs a URL"
        }
        if failure == nil {
            let browser = RemoteBrowser(id: identifier, message: message)
            browsers[identifier] = browser
            browsersChanged()
            var debug = ""
            #if WSURF_SERVICE_DEBUG_OPS
            debug = message.string(CefRemote.Key.debugCreate)
            #endif
            if !browser.create(url: url, context: contextID.isEmpty ? nil : contexts[contextID], debug: debug) {
                // The browser, its client and its handlers go with this reference: nothing else holds the browser.
                browsers[identifier] = nil
                browsersChanged()
                failure = "CEF could not create the browser"
            }
        }
        // A refusal because the id is already open is the reply's alone: that browser is still open and untouched, and WSurf must
        // not hear that it closed (D4-5's registry would drop the id).
        if failure != nil, !duplicate {
            // WSurf waits for the browser's events: tell it there will be none.
            send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: identifier))
        }
        reply(to: message, on: peer) { answer in
            answer.set(CefRemote.Key.success, failure == nil)
            if let failure { answer.set(CefRemote.Key.error, failure) }
        }
    }

    /// A browser reached the end of its life (`on_before_close`, or it never was made): WSurf is told, and the host lets it go.
    func browserDidClose(_ id: Int64) {
        guard browsers.removeValue(forKey: id) != nil else { return }
        accessibilityBrowsers.remove(id)
        send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
        browsersChanged()
    }

    /// `on_before_browse`'s question (plan §1.3): true lets the navigation go ahead. A service that has no host or is leaving
    /// has nobody to ask and cancels at once; otherwise the control connection is asked, and a missing answer cancels.
    func askNavigation(browser: Int64, url: String, isRedirect: Bool, userGesture: Bool, details: NavigationDetails = NavigationDetails()) -> Bool {
        guard let control, !exiting else { return false }
        let question = CefRemoteMessage(CefRemote.Event.beforeBrowse, browser: browser)
        question.set(CefRemote.Key.url, url)
        question.set(CefRemote.Key.isRedirect, isRedirect)
        question.set(CefRemote.Key.userGesture, userGesture)
        // What WSurf's gate needs to treat a submitted request, a reload or a Back as it does in process (D4-8).
        question.set(CefRemote.Key.method, details.method)
        question.set(CefRemote.Key.hasPostData, details.hasPostData)
        question.set(CefRemote.Key.transition, details.transition)
        question.set(CefRemote.Key.sourceURL, details.source)
        guard let answer = Self.askHost(question, on: control, timeout: 1) else {
            note("browser \(browser): WSurf did not answer in time: navigation cancelled")
            return false
        }
        return answer.bool(CefRemote.Key.value)
    }

    private func closeBrowser(_ id: Int64) {
        if let browser = browsers[id] {
            // The answer is `browser.closed`, sent when CEF has closed it (`browserDidClose`).
            browser.requestClose()
            return
        }
        guard let stub = stubs[id] else {
            // A close for a browser that never was: WSurf still waits for its answer.
            send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
            return
        }
        guard stub.answersClose else { return }
        stubs[id] = nil
        send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
        browsersChanged()
    }

    private func startMemoryPressureSource() {
        guard memoryPressure == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [unowned source] in
            let data = source.data
            MainActor.assumeIsolated {
                ServiceHost.shared.memoryPressureChanged(isUnder: data.contains(.warning) || data.contains(.critical))
            }
        }
        source.activate()
        memoryPressure = source
    }

    /// Under memory pressure the cookie stores are written at once, whatever is open; the service then leaves only if no
    /// browser is open (`CefRemoteLinger`), so a person's pages are never closed to save memory.
    private func memoryPressureChanged(isUnder: Bool) {
        if isUnder {
            flushCookies()
        }
        linger?.memoryPressureChanged(isUnder: isUnder)
    }

    private func lingerEnded(_ reason: CefRemoteLinger.Reason) {
        guard !exiting else { return }
        note("\(reason): exiting")
        flushAndExit()
    }

    // MARK: Exit

    /// WSurf's control connection ended, or launchd is about to end the service: close every browser, then exit.
    private func closeEverythingAndExit() {
        guard !exiting else { return }
        beginExit()
        guard openCount > 0 else {
            flushAndExit()
            return
        }
        // The stores are asked for now, so they have the whole wait (up to the cap) to reach the disk: a browser that never
        // answers its close ends this wait with the cap, which skips the flush `flushAndExit` does after the last one.
        flushCookies()
        for id in Array(browsers.keys) + Array(stubs.keys) {
            closeBrowser(id)
        }
        // A browser that never answers must not keep the service (and its helpers) alive. Real browsers close asynchronously, so
        // the last one can answer just before the cap: an exit that is already scheduled (`flushAndExit`, which shuts CEF down)
        // is not cut off, and the backstop (`beginExit`) covers it if that hangs.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeCapSeconds) {
            MainActor.assumeIsolated {
                guard !ServiceHost.shared.exitScheduled else { return }
                note("browsers did not all close in \(Self.closeCapSeconds) s: exiting without a CEF shutdown")
                ServiceHost.shared.endTransaction()
                // _exit, not exit: with CEF still up, atexit handlers and static destructors would run on a live Chromium.
                _exit(0)
            }
        }
    }

    /// Every deliberate exit (a linger or pressure exit, the control connection's end, `TERMINATION_IMMINENT`) starts here. The
    /// service stops serving new ops, and a backstop is armed on a queue of its own: the main thread is where a stuck exit would
    /// be stuck (`cef_shutdown`, a CEF callback, `askHost`'s wait), so nothing scheduled on it can be the last resort. The
    /// backstop does not end the transaction: a service that had to be forced stays recorded as having exited dirty.
    private func beginExit() {
        exiting = true
        guard !backstopArmed else { return }
        backstopArmed = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.exitBackstopSeconds) {
            _exit(0)
        }
    }

    /// Tells launchd the work is done, right before a deliberate exit: a service that exits with its transaction open is
    /// recorded as having exited dirty. Held from the first hello (`hello`) so that launchd cannot end the service as idle
    /// during the linger.
    private func endTransaction() {
        guard holdsTransaction else { return }
        holdsTransaction = false
        xpc_transaction_end()
    }

    /// Asks Chromium to write every cookie store to disk; it finishes on its own threads.
    private func flushCookies() {
        for context in contexts.values {
            if let manager = context.pointee.get_cookie_manager?(context, nil) {
                flushCount += 1
                _ = manager.pointee.flush_store?(manager, nil)
                Native.release(UnsafeMutableRawPointer(manager))
            }
        }
    }

    /// Writes every cookie store, shuts CEF down (its helpers end with it) and exits.
    private func flushAndExit() {
        beginExit()
        guard !exitScheduled else { return }
        exitScheduled = true
        flushCookies()
        let finish: @Sendable () -> Void = {
            MainActor.assumeIsolated {
                let host = ServiceHost.shared
                for context in host.contexts.values {
                    Native.release(UnsafeMutableRawPointer(context))
                }
                host.contexts.removeAll()
                if CefRuntime.shared.isInitialized {
                    CefRuntime.shared.shutdown()
                }
                note("exit")
                host.endTransaction()
                exit(0)
            }
        }
        // With no store to flush the wait is only long enough for a reply already queued (a DEBUG op's) to leave.
        DispatchQueue.main.asyncAfter(deadline: .now() + (contexts.isEmpty ? 0.1 : Self.flushGraceSeconds), execute: finish)
    }

    // MARK: askHost

    /// The service's one wait on WSurf (plan §1.3): `message` goes to `peer` (WSurf's control connection), and the answer comes
    /// back on a queue of its own, never the main one, so the wait cannot block the connection it waits on. nil means no answer
    /// within `timeout`: the caller takes the safe one, which is to cancel. A reply that comes late is dropped.
    nonisolated static func askHost(_ message: CefRemoteMessage, on peer: xpc_connection_t, timeout: TimeInterval = 1) -> CefRemoteMessage? {
        let replies = DispatchQueue(label: "wsurf.chromium-service.askhost")
        let done = DispatchSemaphore(value: 0)
        let box = AnswerBox()
        xpc_connection_send_message_with_reply(peer, message.object, replies) { answer in
            box.answer = CefRemoteMessage(wrapping: answer)
            done.signal()
        }
        guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.answer
    }

    private final class AnswerBox: @unchecked Sendable {
        var answer: CefRemoteMessage?
    }

    // MARK: DEBUG ops

    #if WSURF_SERVICE_DEBUG_OPS
    private static func exitOnHelloMarker(root: String) -> URL? {
        root.hasPrefix("/") ? URL(filePath: root, directoryHint: .isDirectory).appending(path: ".debug-exit-on-hello") : nil
    }

    private static func writeExitOnHello(root: String, count: Int) -> Bool {
        guard let marker = exitOnHelloMarker(root: root) else { return false }
        if count <= 0 {
            try? FileManager.default.removeItem(at: marker)
            return true
        }
        return (try? Data(String(count).utf8).write(to: marker)) != nil
    }

    /// True when the marker under `root` still holds a count: one is taken off it.
    private static func consumeExitOnHello(root: String) -> Bool {
        guard let marker = exitOnHelloMarker(root: root),
              let text = try? String(contentsOf: marker, encoding: .utf8), let count = Int(text), count > 0
        else { return false }
        _ = writeExitOnHello(root: root, count: count - 1)
        return true
    }

    /// The ops only tests send. Not in a service that is signed (D4-S makes this conditional on something a signed build lacks).
    private func handleDebug(_ message: CefRemoteMessage, from peer: xpc_connection_t) -> Bool {
        switch message.op {
        case CefRemote.Op.debugAbort:
            // The plan's kill test: SIGKILL, which leaves no crash report (and so no crash dialog) behind.
            note("debug.abort: the service kills itself (SIGKILL)")
            kill(getpid(), SIGKILL)
        case CefRemote.Op.debugStats:
            reply(to: message, on: peer) { answer in
                answer.set(CefRemote.Key.pid, Int64(getpid()))
                answer.set(CefRemote.Key.started, CefRuntime.shared.isInitialized)
                answer.set(CefRemote.Key.startMs, cefStartMs)
                answer.set(CefRemote.Key.count, openCount)
                answer.set(CefRemote.Key.browserObjects, ServiceCounters.browsers.withLock { $0 })
                answer.set(CefRemote.Key.handlerSets, ServiceCounters.handlerSets.withLock { $0 })
                answer.set(CefRemote.Key.refusedNavigations, ServiceCounters.refusedNavigations.withLock { $0 })
                answer.set(CefRemote.Key.droppedExternal, ServiceCounters.droppedExternalSchemes.withLock { $0 })
                answer.set(CefRemote.Key.historyTimeouts, ServiceCounters.historyTimeouts.withLock { $0 })
                answer.set(CefRemote.Key.contexts, contexts.count)
                answer.set(CefRemote.Key.flushes, flushCount)
                answer.set(CefRemote.Key.logFile, logFile)
                answer.set(CefRemote.Key.mockKeychain, CefRuntime.shared.configuration?.safeStorage == .mockKeychain)
                if message.has(CefRemote.Key.browser) {
                    browsers[message.browser]?.presenter.statistics(into: answer)
                    browsers[message.browser]?.geometry(into: answer)
                    browsers[message.browser]?.inputStatistics(into: answer)
                }
            }
        case CefRemote.Op.debugExitOnHello:
            // A relaunched service is a new process with no memory of this op, so the count lives in a file under the root
            // the hellos will name, and every hello (in any instance) takes one off before it starts CEF.
            let written = Self.writeExitOnHello(root: message.string(CefRemote.Key.rootPath), count: Int(message.int(CefRemote.Key.count)))
            reply(to: message, on: peer) { $0.set(CefRemote.Key.success, written) }
        case CefRemote.Op.debugStubBrowser:
            stubs[message.browser] = StubBrowser(answersClose: message.bool(CefRemote.Key.flag))
            browsersChanged()
            reply(to: message, on: peer) { $0.set(CefRemote.Key.count, openCount) }
        case CefRemote.Op.debugHangExit:
            // Bounded, so that a service whose backstop is broken still ends (late) and leaves nothing behind a failed test.
            reply(to: message, on: peer) { $0.set(CefRemote.Key.success, true) }
            closeEverythingAndExit()
            Thread.sleep(forTimeInterval: 15)
        case CefRemote.Op.debugHoldHistory:
            // The F8 case on demand: the browser's next history reads are sent to nobody, as one whose renderer is gone would be.
            let known = browsers[message.browser]
            known?.holdHistoryReads(Int(message.int(CefRemote.Key.count)), delay: message.double(CefRemote.Key.value))
            reply(to: message, on: peer) { $0.set(CefRemote.Key.success, known != nil) }
        case CefRemote.Op.debugMemoryPressure:
            // An exit the handler decides on runs later (the linger's onExit hops to the main queue), so the answer still goes.
            memoryPressureChanged(isUnder: message.bool(CefRemote.Key.flag))
            reply(to: message, on: peer) { $0.set(CefRemote.Key.flushes, flushCount) }
        case CefRemote.Op.debugAskHost:
            let started = Clock.nowNanoseconds
            let question = CefRemoteMessage(CefRemote.Event.beforeBrowse, browser: message.browser)
            question.set(CefRemote.Key.url, message.string(CefRemote.Key.url))
            let answer = Self.askHost(question, on: peer, timeout: 1)
            let milliseconds = Double(Clock.nowNanoseconds &- started) / 1e6
            reply(to: message, on: peer) { reply in
                reply.set(CefRemote.Key.askHostAnswer, answer == nil ? CefRemote.AskHostAnswer.timedOut : CefRemote.AskHostAnswer.answered)
                reply.set(CefRemote.Key.value, milliseconds)
            }
        default:
            return false
        }
        return true
    }
    #endif
}

struct ServiceError: Error, CustomStringConvertible {
    let text: String
    var description: String { text }
}
