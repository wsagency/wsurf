// D4 spike: the service's state. Everything here runs on the main thread, which is CEF's UI thread: both XPC connections
// deliver on the main queue, and CEF calls back there through the external message pump.

import AppKit
import CCef
import CCefAppKit
import CefKit
import XPC

@MainActor
final class ServiceHost {
    static let shared = ServiceHost()

    /// The connection that said hello: events go there. The input connection only sends.
    private var control: xpc_connection_t?
    private var peers: [xpc_connection_t] = []
    private var layerServerPort: mach_port_t = 0
    private var contexts: [String: UnsafeMutablePointer<cef_request_context_t>] = [:]
    private var browsers: [Int64: RemoteBrowser] = [:]
    private var lingerSeconds: Double = 60
    private var lingerTimer: Timer?
    private var frameRate: Int32 = 60
    private var externalBeginFrames = false
    private var displayLink: CADisplayLink?
    private var holdsTransaction = false
    private var exiting = false
    private let startedAt = Clock.nowNanoseconds
    private var cefStartMs: Double = -1

    // MARK: Connections

    nonisolated static func accept(_ peer: xpc_connection_t) {
        xpc_connection_set_target_queue(peer, DispatchQueue.main)
        xpc_connection_set_event_handler(peer) { event in
            MainActor.assumeIsolated { ServiceHost.shared.receive(event, from: peer) }
        }
        xpc_connection_activate(peer)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { ServiceHost.shared.peers.append(peer) }
        }
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
        peers.removeAll { $0 === peer }
        guard peer === control else { return }
        note("WSurf's connection ended: closing \(browsers.count) browsers and exiting")
        control = nil
        closeEverythingAndExit()
    }

    func send(_ message: CefRemoteMessage) {
        guard let control else { return }
        xpc_connection_send_message(control, message.object)
    }

    // MARK: Messages

    private func handle(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        switch message.op {
        case CefRemote.Op.hello:
            hello(message, from: peer)
        case CefRemote.Op.inputHello:
            note("input connection open")
        case CefRemote.Op.createContext:
            createContext(message)
        case CefRemote.Op.createBrowser:
            createBrowser(message)
        case CefRemote.Op.debugAbort:
            // As the plan's kill test: SIGKILL, which leaves no crash report (and so no crash dialog) behind.
            note("debug.abort: the service kills itself (SIGKILL)")
            kill(getpid(), SIGKILL)
        case CefRemote.Op.debugStats:
            statistics(replyTo: message, peer: peer)
        default:
            guard let browser = browsers[message.browser] else {
                if message.op != CefRemote.Op.close {
                    note("no browser \(message.browser) for \(message.op)")
                } else {
                    // A close for a browser that never was: WSurf still waits for its answer.
                    send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: message.browser))
                }
                return
            }
            browser.handle(message)
        }
    }

    private func hello(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        control = peer
        ServiceLog.shared.open(path: message.string(CefRemote.Key.path))
        note("hello: protocol \(message.int(CefRemote.Key.identifier)), service pid \(getpid()), parent \(getppid())")
        if message.has(CefRemote.Key.linger) {
            lingerSeconds = max(1, message.double(CefRemote.Key.linger))
        }
        frameRate = Int32(max(1, min(240, message.int(CefRemote.Key.frameRate))))
        externalBeginFrames = message.string(CefRemote.Key.beginFrames) == "external"
        let port = xpc_dictionary_copy_mach_send(message.object, CefRemote.Key.layerServer)
        if port != 0 {
            layerServerPort = port
        }
        let reply = CefRemoteMessage(replyTo: message)
        reply?.set(CefRemote.Key.pid, Int64(getpid()))
        do {
            try startCEF(message)
            reply?.set(CefRemote.Key.success, true)
            reply?.set(CefRemote.Key.value, cefStartMs)
        } catch {
            note("CEF start FAILED: \(error)")
            reply?.set(CefRemote.Key.success, false)
            reply?.set(CefRemote.Key.error, "\(error)")
        }
        if let reply {
            xpc_connection_send_message(peer, reply.object)
        }
    }

    /// WSurf.app, from this service's place inside it: `WSurf.app/Contents/XPCServices/WSurf Chromium.xpc`.
    private var appBundle: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func startCEF(_ message: CefRemoteMessage) throws {
        guard !CefRuntime.shared.isInitialized else { return }
        let started = Clock.nowNanoseconds
        // The framework and the helpers are the service's own copies (`Tools/embed-chromium.sh`): Chromium's sandbox lets a
        // child read only inside the browser process's main bundle, which here is the .xpc.
        let app = Bundle.main.bundleURL
        let frameworks = app.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        var configuration = CefConfiguration()
        configuration.noSandbox = false
        // The spike never reads the real "Chromium Safe Storage" item: a new code identity reading it raises a keychain prompt.
        configuration.safeStorage = .mockKeychain
        let root = message.string(CefRemote.Key.rootPath)
        let cache = message.string(CefRemote.Key.cachePath)
        guard !root.isEmpty else { throw ServiceError(text: "no root cache path") }
        configuration.rootCachePath = URL(filePath: root, directoryHint: .isDirectory)
        configuration.cachePath = cache.isEmpty ? nil : URL(filePath: cache, directoryHint: .isDirectory)
        configuration.persistSessionCookies = true
        configuration.defaultRuntimeStyle = .alloy
        configuration.logSeverity = .error
        var logFile = message.string(CefRemote.Key.logFile)
        let serviceLog = message.string(CefRemote.Key.path)
        if logFile.isEmpty || logFile == "/dev/null", !serviceLog.isEmpty {
            // Staged runs: CEF's own log next to the service's, at warning level, so a CHECK names itself.
            logFile = URL(filePath: serviceLog).deletingLastPathComponent().appendingPathComponent("chromium-cef.log").path
            configuration.logSeverity = .warning
        }
        configuration.logFile = URL(filePath: logFile.isEmpty ? "/dev/null" : logFile)
        note("CEF log: \(configuration.logFile?.path ?? "none")")
        probeBootstrap()
        configuration.extraCommandLineSwitches = message.strings(CefRemote.Key.switches).mapValues { $0.isEmpty ? nil : $0 }
        configuration.windowlessRenderingEnabled = true
        configuration.frameworkDirectory = frameworks.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        configuration.browserSubprocessPath = frameworks.appendingPathComponent("WSurf Helper.app/Contents/MacOS/WSurf Helper")
        configuration.mainBundlePath = app
        note("CEF start: app \(app.path), root \(root)")
        try CefRuntime.shared.initialize(configuration: configuration)
        CEFApplication.setTerminateHandler(nil)
        cefStartMs = Double(Clock.nowNanoseconds &- started) / 1e6
        note(String(format: "CEF started in %.1f ms (%.1f ms after service start)", cefStartMs,
                    Double(Clock.nowNanoseconds &- startedAt) / 1e6))
    }

    /// Chromium's Mach rendezvous registers a bootstrap name at the first child process. In an XPC service that may be
    /// refused; this tries the same call with a throwaway name and logs the answer.
    private func probeBootstrap() {
        typealias CheckIn = @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_check_in"),
              let portSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "bootstrap_port") else {
            note("bootstrap probe: symbols not found")
            return
        }
        let checkIn = unsafeBitCast(symbol, to: CheckIn.self)
        let bootstrap = portSymbol.assumingMemoryBound(to: mach_port_t.self).pointee
        var port: mach_port_t = 0
        let name = "\(Bundle.main.bundleIdentifier ?? "service").d4probe.\(getpid())"
        let result = name.withCString { checkIn(bootstrap, $0, &port) }
        note("bootstrap probe: bootstrap_check_in(\(name)) = \(result) (0 is success), port \(port)")
    }

    private func createContext(_ message: CefRemoteMessage) {
        let identifier = message.string(CefRemote.Key.context)
        guard contexts[identifier] == nil, CefRuntime.shared.isInitialized else { return }
        var settings = cef_request_context_settings_t()
        settings.size = MemoryLayout<cef_request_context_settings_t>.stride
        let path = message.string(CefRemote.Key.cachePath)
        if !path.isEmpty {
            try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            Native.set(path, &settings.cache_path)
            settings.persist_session_cookies = 1
        }
        defer { ccef_string_clear(&settings.cache_path) }
        guard let context = cef_request_context_create_context(&settings, nil) else {
            note("context \(identifier): create FAILED")
            return
        }
        contexts[identifier] = context
        note("context \(identifier): \(path.isEmpty ? "in memory" : "disk")")
    }

    private func createBrowser(_ message: CefRemoteMessage) {
        let id = message.browser
        guard browsers[id] == nil else { return }
        guard CefRuntime.shared.isInitialized, layerServerPort != 0 else {
            note("browser \(id): CEF not started or no layer server")
            send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
            return
        }
        lingerTimer?.invalidate()
        lingerTimer = nil
        if !holdsTransaction {
            // While a browser lives, launchd must not end this service as idle.
            xpc_transaction_begin()
            holdsTransaction = true
        }
        let browser = RemoteBrowser(id: id, message: message, serverPort: layerServerPort)
        browsers[id] = browser
        let created = CefRemoteMessage(CefRemote.Event.browserCreated, browser: id)
        created.set(CefRemote.Key.layerClient, Int64(browser.presenter.clientID))
        send(created)
        let context = contexts[message.string(CefRemote.Key.context)]
        let started = browser.create(url: message.string(CefRemote.Key.url), context: context,
                                     javaScript: !message.has(CefRemote.Key.javaScript) || message.bool(CefRemote.Key.javaScript),
                                     frameRate: frameRate, externalBeginFrames: externalBeginFrames)
        if !started {
            browserDidClose(id)
            send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
            return
        }
        CefRuntime.shared.externalBrowserDidOpen()
        updateDisplayLink()
    }

    func browserDidClose(_ id: Int64) {
        guard browsers.removeValue(forKey: id) != nil else { return }
        CefRuntime.shared.externalBrowserDidClose()
        updateDisplayLink()
        guard browsers.isEmpty else { return }
        if holdsTransaction {
            xpc_transaction_end()
            holdsTransaction = false
        }
        if exiting {
            finishExit()
            return
        }
        note(String(format: "last browser closed: exiting in %.0f s unless a browser comes", lingerSeconds))
        lingerTimer?.invalidate()
        let timer = Timer(timeInterval: lingerSeconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard ServiceHost.shared.browsers.isEmpty else { return }
                note("linger over: exiting")
                ServiceHost.shared.flushAndExit()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lingerTimer = timer
    }

    // MARK: Exit

    private func closeEverythingAndExit() {
        guard !exiting else { return }
        exiting = true
        lingerTimer?.invalidate()
        guard !browsers.isEmpty else {
            flushAndExit()
            return
        }
        for browser in browsers.values {
            browser.close()
        }
        // A browser that never answers must not keep the service (and its helpers) alive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                note("browsers did not all close in 3 s: exiting without CEF shutdown")
                exit(0)
            }
        }
    }

    private func finishExit() {
        flushAndExit()
    }

    /// Writes every cookie store, shuts CEF down (its helpers end with it) and exits.
    func flushAndExit() {
        exiting = true
        for context in contexts.values {
            if let manager = context.pointee.get_cookie_manager?(context, nil) {
                _ = manager.pointee.flush_store?(manager, nil)
                Native.release(UnsafeMutableRawPointer(manager))
            }
        }
        // The flush finishes on CEF's own threads; give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                let host = ServiceHost.shared
                for context in host.contexts.values {
                    Native.release(UnsafeMutableRawPointer(context))
                }
                host.contexts.removeAll()
                host.displayLink?.invalidate()
                if CefRuntime.shared.isInitialized {
                    CefRuntime.shared.shutdown()
                }
                note("CEF shut down: exit")
                exit(0)
            }
        }
    }

    // MARK: External begin frames (optional frame source)

    private func updateDisplayLink() {
        let wanted = externalBeginFrames && browsers.values.contains { !$0.hidden }
        if wanted, displayLink == nil, let screen = NSScreen.main {
            let link = screen.displayLink(target: DisplayLinkTarget.shared, selector: #selector(DisplayLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
            note("external begin frames: display link on, max \(screen.maximumFramesPerSecond) fps")
        } else if !wanted, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    fileprivate func beginFrame() {
        for browser in browsers.values {
            browser.sendExternalBeginFrame()
        }
    }

    // MARK: Statistics

    private func statistics(replyTo message: CefRemoteMessage, peer: xpc_connection_t) {
        guard let reply = CefRemoteMessage(replyTo: message) else { return }
        reply.set(CefRemote.Key.pid, Int64(getpid()))
        reply.set("cefStartMs", cefStartMs)
        reply.set("browsers", browsers.count)
        reply.set("frameRate", Int64(frameRate))
        reply.set("externalBeginFrames", externalBeginFrames)
        var entries: [CefRemoteMessage] = []
        for (id, browser) in browsers.sorted(by: { $0.key < $1.key }) {
            let entry = CefRemoteMessage("browser", browser: id)
            browser.statistics(into: CefRemoteMessageBuilder(entry))
            if message.bool(CefRemote.Key.flag) {
                browser.resetStatistics()
            }
            entries.append(entry)
        }
        reply.set(CefRemote.Key.stats, messages: entries)
        xpc_connection_send_message(peer, reply.object)
    }
}

@MainActor
private final class DisplayLinkTarget: NSObject {
    static let shared = DisplayLinkTarget()

    @objc func tick() {
        ServiceHost.shared.beginFrame()
    }
}

struct ServiceError: Error, CustomStringConvertible {
    let text: String
    var description: String { text }
}

/// Fills a message with numbers for the debug statistics reply.
final class CefRemoteMessageBuilder {
    let message: CefRemoteMessage

    init(_ message: CefRemoteMessage) {
        self.message = message
    }

    func add(_ key: String, _ value: Double) {
        message.set(key, value)
    }

    func percentiles(_ key: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        message.set(key + ".n", Double(sorted.count))
        guard !sorted.isEmpty else { return }
        func at(_ fraction: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
        }
        message.set(key + ".p50", at(0.5))
        message.set(key + ".p95", at(0.95))
        message.set(key + ".p99", at(0.99))
        message.set(key + ".max", sorted.last ?? 0)
    }
}
