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
@preconcurrency import XPC

@MainActor
final class ServiceHost {
    static let shared = ServiceHost()

    /// How long a close may take before the service stops waiting for the browsers (and exits without a CEF shutdown).
    private static let closeCapSeconds: TimeInterval = 3
    /// How long the cookie flush gets to finish on CEF's own threads before CEF is shut down.
    private static let flushGraceSeconds: TimeInterval = 0.5

    /// The connection that said hello: events go there. The input and frames connections only send (and are not served yet).
    private var control: xpc_connection_t?
    private var contexts: [String: UnsafeMutablePointer<cef_request_context_t>] = [:]
    /// Browsers by id. D4-4b puts real ones here; until then only the DEBUG stub exists, so the lifecycle can be tested.
    private var browsers: [Int64: StubBrowser] = [:]
    private var linger: CefRemoteLinger?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var holdsTransaction = false
    private var exiting = false
    private var flushCount = 0
    private var cefStartMs: Double = -1
    private var logFile = "/dev/null"

    /// A browser that is not one: it counts as open and answers a close, or does not (`answersClose`).
    private struct StubBrowser {
        let answersClose: Bool
    }

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
        guard peer === control else { return }
        note("WSurf's connection ended: closing \(browsers.count) browsers and exiting")
        control = nil
        closeEverythingAndExit()
    }

    private func send(_ message: CefRemoteMessage) {
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
        case CefRemote.Op.inputHello, CefRemote.Op.framesHello:
            // Their messages arrive with D4-4b (input is phase 3, frames D4-7).
            note("\(message.op) connection open")
        case CefRemote.Op.createContext:
            createContext(message, from: peer)
        case CefRemote.Op.close:
            closeBrowser(message.browser)
        default:
            #if WSURF_SERVICE_DEBUG_OPS
            if handleDebug(message, from: peer) { return }
            #endif
            // A service ignores an op it does not know; a sender that asked for an answer gets an error, not a silence.
            note("no handler for \(message.op)")
            reply(to: message, on: peer) { $0.set(CefRemote.Key.error, "unknown op") }
        }
    }

    /// Sends `fill`'s message as the answer to `request`, when the sender asked for one.
    private func reply(to request: CefRemoteMessage, on peer: xpc_connection_t, _ fill: (CefRemoteMessage) -> Void) {
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
                $0.set(CefRemote.Key.error, "The Chromium service is leaving.")
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

    /// Whether `path` is `root` or below it, as CEF requires of a cache path (compared lexically, `..` resolved).
    private static func isInside(_ path: String, root: String) -> Bool {
        let path = URL(filePath: path).standardizedFileURL.path
        let root = URL(filePath: root).standardizedFileURL.path
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

    // MARK: Browsers and the lifecycle

    /// The number of open browsers changed: the linger follows it, and a service that was closing everything is done.
    private func browsersChanged() {
        if exiting {
            if browsers.isEmpty { flushAndExit() }
            return
        }
        linger?.browserCountChanged(browsers.count)
    }

    private func closeBrowser(_ id: Int64) {
        guard let browser = browsers[id] else {
            // A close for a browser that never was: WSurf still waits for its answer.
            send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
            return
        }
        guard browser.answersClose else { return }
        browsers[id] = nil
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
        exiting = true
        guard !browsers.isEmpty else {
            flushAndExit()
            return
        }
        for id in browsers.keys {
            closeBrowser(id)
        }
        // A browser that never answers must not keep the service (and its helpers) alive.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeCapSeconds) {
            note("browsers did not all close in \(Self.closeCapSeconds) s: exiting without a CEF shutdown")
            // _exit, not exit: with CEF still up, atexit handlers and static destructors would run on a live Chromium.
            _exit(0)
        }
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
        exiting = true
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
                answer.set(CefRemote.Key.count, browsers.count)
                answer.set(CefRemote.Key.contexts, contexts.count)
                answer.set(CefRemote.Key.flushes, flushCount)
                answer.set(CefRemote.Key.logFile, logFile)
                answer.set(CefRemote.Key.mockKeychain, CefRuntime.shared.configuration?.safeStorage == .mockKeychain)
            }
        case CefRemote.Op.debugExitOnHello:
            // A relaunched service is a new process with no memory of this op, so the count lives in a file under the root
            // the hellos will name, and every hello (in any instance) takes one off before it starts CEF.
            let written = Self.writeExitOnHello(root: message.string(CefRemote.Key.rootPath), count: Int(message.int(CefRemote.Key.count)))
            reply(to: message, on: peer) { $0.set(CefRemote.Key.success, written) }
        case CefRemote.Op.debugStubBrowser:
            browsers[message.browser] = StubBrowser(answersClose: message.bool(CefRemote.Key.flag))
            browsersChanged()
            reply(to: message, on: peer) { $0.set(CefRemote.Key.count, browsers.count) }
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
