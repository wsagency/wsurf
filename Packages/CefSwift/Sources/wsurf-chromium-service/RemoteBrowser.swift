// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-4b: one windowless browser in the service. WSurf keeps every policy: this class forwards what its page does as events,
// does what WSurf asks, and keeps what must be answered at once to a safe default. Frames (D4-7), geometry changes (D4-9) and
// input (phase 3) are not here. Everything runs on the main thread, which is CEF's UI thread.
//
// Memory: see `RemoteClientHandlers.swift`. The browser holds one reference on its client, given up in `deinit`, and its
// handlers reach it only through a weak box.

import CCef
import CefKit
import Foundation
@preconcurrency import XPC

@MainActor
final class RemoteBrowser {
    let id: Int64
    private let box = BrowserBox()
    private(set) var raw: UnsafeMutablePointer<cef_browser_t>?
    private(set) var isClosing = false
    private var hasClosed = false
    /// CEF was asked to make the browser and has not yet said so (`on_after_created`).
    private var creationPending = false

    /// This browser's +1 on its client (the client owns the handlers). Given up in `deinit`: not at the close, because CEF may
    /// still call the client's getters on another thread.
    private var clientPointer: UnsafeMutablePointer<cef_client_t>?
    private var observerPointer: UnsafeMutablePointer<cef_dev_tools_message_observer_t>?
    private var registration: UnsafeMutablePointer<cef_registration_t>?

    /// What WSurf asked for before CEF made the browser.
    private var pending: [(UnsafeMutablePointer<cef_browser_host_t>) -> Void] = []

    private(set) var sizeDIP: CGSize
    private(set) var scale: CGFloat

    private var nextServiceCommand = CefRemote.serviceCommandBase
    /// The service's own `Page.resetNavigationHistory`, by its CDP id: WSurf's request id.
    private var collapses: [Int64: Int64] = [:]
    private var historyCommand: Int64?
    private var historyDirty = false
    private var historyMismatches = 0
    /// The last list sent, ids included: what a `collapseHistory` is checked against (and the native list against it).
    private var lastHistory: [CefRemote.HistoryEntry]?

    init(id: Int64, message: CefRemoteMessage) {
        self.id = id
        sizeDIP = CGSize(width: max(1, message.double(CefRemote.Key.width)), height: max(1, message.double(CefRemote.Key.height)))
        scale = max(1, message.double(CefRemote.Key.scale))
        ServiceCounters.browsers.withLock { $0 += 1 }
        box.browser = self
    }

    deinit {
        Native.release(clientPointer.map(UnsafeMutableRawPointer.init))
        ServiceCounters.browsers.withLock { $0 -= 1 }
    }

    // MARK: Creation and close

    /// Asks CEF for the browser; it arrives later (`didCreate`). False when CEF refused: the caller drops this browser, and
    /// everything it made goes with it.
    func create(url: String, context: UnsafeMutablePointer<cef_request_context_t>?, debug: String) -> Bool {
        let client = RemoteClientHandlers.makeClient(for: box)
        clientPointer = client
        #if WSURF_SERVICE_DEBUG_OPS
        // Not in a service that is signed: the flags and their log lines are not compiled there (D4-S makes the define conditional).
        switch debug {
        case CefRemote.DebugCreate.fail:
            // Stops before CEF's own refusal path (the references handed to CEF below), which is CEF's wrappers' to consume.
            note("browser \(id): create FAILED (debug)")
            return false
        case CefRemote.DebugCreate.hold:
            note("browser \(id): create held (debug)")
            return true
        default:
            break
        }
        #endif
        var info = cef_window_info_t()
        info.size = MemoryLayout<cef_window_info_t>.stride
        info.windowless_rendering_enabled = 1
        info.bounds = cef_rect_t(x: 0, y: 0, width: Int32(sizeDIP.width.rounded()), height: Int32(sizeDIP.height.rounded()))
        info.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.stride
        settings.windowless_frame_rate = 30
        // Opaque white, as a windowed browser paints: a windowless one is transparent by default.
        settings.background_color = 0xFFFF_FFFF
        // CEF takes ownership of one reference to each object it is given, and gives it up if it refuses.
        Native.retain(UnsafeMutableRawPointer(client))
        if let context {
            Native.retain(UnsafeMutableRawPointer(context))
        }
        let started = Native.withString(url) { cef_browser_host_create_browser(&info, client, $0, &settings, nil, context) }
        creationPending = started == 1
        note("browser \(id): create \(started == 1 ? "started" : "FAILED") \(Int(sizeDIP.width))x\(Int(sizeDIP.height))@\(scale)")
        return started == 1
    }

    func didCreate(_ browser: UnsafeMutablePointer<cef_browser_t>) {
        creationPending = false
        guard !hasClosed else {
            if let host = browser.pointee.get_host?(browser) {
                host.pointee.close_browser?(host, 1)
                Native.release(UnsafeMutableRawPointer(host))
            }
            return
        }
        Native.retain(UnsafeMutableRawPointer(browser))
        raw = browser
        guard let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        if isClosing {
            // A close arrived while CEF was still making the browser: it is closed now, and `didClose` ends it.
            host.pointee.close_browser?(host, 1)
            return
        }
        attachDevTools(host)
        let queued = pending
        pending.removeAll()
        for work in queued {
            work(host)
        }
        send(event(CefRemote.Event.browserReady))
        note("browser \(id): ready")
    }

    /// WSurf (or the service's own close-all) wants this browser gone. A browser CEF is still making is closed when CEF has made
    /// it (`didCreate`): CEF must not be shut down under a browser it has not finished creating. One CEF was never asked to
    /// make (the DEBUG `hold`) has nothing to wait for and is dropped at once.
    func requestClose() {
        guard !isClosing else { return }
        isClosing = true
        if let host = hostReference() {
            defer { Native.release(UnsafeMutableRawPointer(host)) }
            host.pointee.close_browser?(host, 1)
            return
        }
        guard !creationPending else {
            note("browser \(id): close requested before CEF made it")
            return
        }
        note("browser \(id): closed before CEF made it")
        hasClosed = true
        pending.removeAll()
        ServiceHost.shared.browserDidClose(id)
    }

    func didClose() {
        guard !hasClosed else { return }
        hasClosed = true
        pending.removeAll()
        if let registration {
            Native.release(UnsafeMutableRawPointer(registration))
            self.registration = nil
        }
        if let raw {
            Native.release(UnsafeMutableRawPointer(raw))
            self.raw = nil
        }
        // The observer is this browser's own reference (the registration held CEF's, now released).
        Native.release(observerPointer.map(UnsafeMutableRawPointer.init))
        observerPointer = nil
        note("browser \(id): closed")
        ServiceHost.shared.browserDidClose(id)
    }

    /// A +1 host reference, or nil before creation.
    private func hostReference() -> UnsafeMutablePointer<cef_browser_host_t>? {
        guard let raw else { return nil }
        return raw.pointee.get_host?(raw)
    }

    /// Runs `body` with the host now, or once CEF has made the browser.
    private func withHost(_ body: @escaping (UnsafeMutablePointer<cef_browser_host_t>) -> Void) {
        guard !hasClosed else { return }
        guard let host = hostReference() else {
            pending.append(body)
            return
        }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        body(host)
    }

    private func withBrowserLater(_ body: @escaping (UnsafeMutablePointer<cef_browser_t>) -> Void) {
        withHost { [weak self] _ in
            guard let raw = self?.raw else { return }
            body(raw)
        }
    }

    private func send(_ message: CefRemoteMessage) {
        ServiceHost.shared.send(message)
    }

    private func event(_ name: String) -> CefRemoteMessage {
        CefRemoteMessage(name, browser: id)
    }

    // MARK: Commands from WSurf

    func handle(_ message: CefRemoteMessage, from peer: xpc_connection_t) {
        func reply(_ fill: (CefRemoteMessage) -> Void) {
            ServiceHost.shared.reply(to: message, on: peer, fill)
        }
        /// A sender that asked gets its answer first: what the op does may run `on_before_browse`, which waits on WSurf.
        func accepted() {
            reply { $0.set(CefRemote.Key.success, true) }
        }
        switch message.op {
        case CefRemote.Op.load:
            let url = message.string(CefRemote.Key.url)
            guard !url.isEmpty else {
                reply {
                    $0.set(CefRemote.Key.success, false)
                    $0.set(CefRemote.Key.error, "a load needs a URL")
                }
                return
            }
            accepted()
            withHost { [weak self] _ in self?.load(url) }
        case CefRemote.Op.reload:
            let ignoreCache = message.bool(CefRemote.Key.flag)
            accepted()
            withBrowserLater { browser in
                if ignoreCache {
                    browser.pointee.reload_ignore_cache?(browser)
                } else {
                    browser.pointee.reload?(browser)
                }
            }
        case CefRemote.Op.goBack, CefRemote.Op.goForward:
            let back = message.op == CefRemote.Op.goBack
            // Native history decides now, on the UI thread; when it cannot, WSurf makes its own hop (D3b).
            let possible = raw.map { browser in
                (back ? browser.pointee.can_go_back?(browser) : browser.pointee.can_go_forward?(browser)) == 1
            } ?? false
            guard possible, let raw else {
                reply {
                    $0.set(CefRemote.Key.success, false)
                    $0.set(CefRemote.Key.error, CefRemote.noNativeEntry)
                }
                return
            }
            accepted()
            if back {
                raw.pointee.go_back?(raw)
            } else {
                raw.pointee.go_forward?(raw)
            }
        case CefRemote.Op.stop:
            accepted()
            withBrowserLater { $0.pointee.stop_load?($0) }
        case CefRemote.Op.zoom:
            let level = message.double(CefRemote.Key.value)
            accepted()
            withHost { $0.pointee.set_zoom_level?($0, level) }
        case CefRemote.Op.mute:
            let muted = message.bool(CefRemote.Key.flag)
            accepted()
            withHost { [weak self] host in
                host.pointee.set_audio_muted?(host, muted ? 1 : 0)
                guard let self else { return }
                let message = event(CefRemote.Event.muteChanged)
                message.set(CefRemote.Key.muted, host.pointee.is_audio_muted?(host) == 1)
                send(message)
            }
        case CefRemote.Op.find:
            let text = message.string(CefRemote.Key.text)
            let forward = message.bool(CefRemote.Key.forward)
            let matchCase = message.bool(CefRemote.Key.matchCase)
            let next = message.bool(CefRemote.Key.findNext)
            accepted()
            withHost { host in
                Native.withString(text) { host.pointee.find?(host, $0, forward ? 1 : 0, matchCase ? 1 : 0, next ? 1 : 0) }
            }
        case CefRemote.Op.stopFinding:
            let clear = message.bool(CefRemote.Key.flag)
            accepted()
            withHost { $0.pointee.stop_finding?($0, clear ? 1 : 0) }
        case CefRemote.Op.devTools:
            let data = message.data(CefRemote.Key.data)
            accepted()
            withHost { [weak self] host in self?.sendDevTools(data, host: host) }
        case CefRemote.Op.collapseHistory:
            let request = message.int(CefRemote.Key.identifier)
            let keep = message.collapseKeep
            let expected = message.collapseExpected
            // Acknowledged here; the answer to the question is the `history.collapsed` event.
            accepted()
            withHost { [weak self] host in self?.collapseHistory(request: request, keeping: keep, expected: expected, host: host) }
        default:
            note("browser \(id): unknown op \(message.op)")
            reply { $0.set(CefRemote.Key.error, "unknown op") }
        }
    }

    private func load(_ url: String) {
        guard let raw, let frame = raw.pointee.get_main_frame?(raw) else { return }
        defer { Native.release(UnsafeMutableRawPointer(frame)) }
        Native.withString(url) { frame.pointee.load_url?(frame, $0) }
    }

    // MARK: Events from the page

    func loadingStateChanged(loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        let message = event(CefRemote.Event.loadingState)
        message.set(CefRemote.Key.loading, loading)
        message.set(CefRemote.Key.canGoBack, canGoBack)
        message.set(CefRemote.Key.canGoForward, canGoForward)
        send(message)
        if !loading {
            refreshHistory()
        }
    }

    func loadStarted() {
        send(event(CefRemote.Event.loadStart))
    }

    func loadEnded(url: String, status: Int64) {
        let message = event(CefRemote.Event.loadEnd)
        message.set(CefRemote.Key.url, url)
        message.set(CefRemote.Key.status, status)
        addVisibleState(to: message)
        send(message)
        refreshHistory()
    }

    func loadFailed(code: Int64, text: String, url: String) {
        let message = event(CefRemote.Event.loadError)
        message.set(CefRemote.Key.code, code)
        message.set(CefRemote.Key.text, text)
        message.set(CefRemote.Key.url, url)
        send(message)
    }

    func addressChanged(_ url: String) {
        let message = event(CefRemote.Event.address)
        message.set(CefRemote.Key.url, url)
        addVisibleState(to: message)
        send(message)
        refreshHistory()
    }

    func titleChanged(_ title: String) {
        let message = event(CefRemote.Event.title)
        message.set(CefRemote.Key.title, title)
        send(message)
        refreshHistory()
    }

    func progressChanged(_ progress: Double) {
        let message = event(CefRemote.Event.progress)
        message.set(CefRemote.Key.progress, progress)
        send(message)
    }

    func renderProcessTerminated(status: Int64, code: Int64) {
        let message = event(CefRemote.Event.renderTerminated)
        message.set(CefRemote.Key.status, status)
        message.set(CefRemote.Key.code, code)
        send(message)
    }

    func findResult(identifier: Int64, count: Int64, active: Int64, final: Bool) {
        let message = event(CefRemote.Event.findResult)
        message.set(CefRemote.Key.identifier, identifier)
        message.set(CefRemote.Key.count, count)
        message.set(CefRemote.Key.active, active)
        message.set(CefRemote.Key.final, final)
        send(message)
    }

    /// WSurf decides whether a main-frame navigation goes ahead (`askHost`, plan §1.3): no answer within a second cancels it.
    func mayNavigate(to url: String, isRedirect: Bool, userGesture: Bool) -> Bool {
        ServiceHost.shared.askNavigation(browser: id, url: url, isRedirect: isRedirect, userGesture: userGesture)
    }

    /// The visible entry's title and SSL status, pushed with the event instead of read by WSurf (plan §1.5).
    private func addVisibleState(to message: CefRemoteMessage) {
        guard let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        guard let entry = host.pointee.get_visible_navigation_entry?(host) else { return }
        defer { Native.release(UnsafeMutableRawPointer(entry)) }
        message.set(CefRemote.Key.title, Native.take(entry.pointee.get_title?(entry)))
        message.set(CefRemote.Key.securityURL, Native.take(entry.pointee.get_url?(entry)))
        guard let ssl = entry.pointee.get_sslstatus?(entry) else { return }
        defer { Native.release(UnsafeMutableRawPointer(ssl)) }
        message.set(CefRemote.Key.secureConnection, ssl.pointee.is_secure_connection?(ssl) == 1)
        message.set(CefRemote.Key.certStatus, Int64(ssl.pointee.get_cert_status?(ssl).rawValue ?? ~0))
        message.set(CefRemote.Key.contentStatus, Int64(ssl.pointee.get_content_status?(ssl).rawValue ?? ~0))
    }

    // MARK: DevTools

    private func attachDevTools(_ host: UnsafeMutablePointer<cef_browser_host_t>) {
        let observer = Native.allocate(cef_dev_tools_message_observer_t.self, owner: box)
        observer.pointee.on_dev_tools_message = { observerSelf, browser, message, size in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let message, size > 0, let owner = RemoteBrowser.owner(observerSelf) else { return 0 }
            return MainActor.assumeIsolated { owner.devToolsMessage(message, size: size) }
        }
        observer.pointee.on_dev_tools_method_result = { observerSelf, browser, messageID, success, result, size in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(observerSelf) else { return }
            MainActor.assumeIsolated { owner.devToolsResult(id: Int64(messageID), success: success != 0, result: result, size: size) }
        }
        observer.pointee.on_dev_tools_event = { observerSelf, browser, method, params, size in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(observerSelf) else { return }
            let name = Native.string(method)
            MainActor.assumeIsolated { owner.devToolsEvent(method: name, params: params, size: size) }
        }
        observer.pointee.on_dev_tools_agent_attached = { _, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
        }
        observer.pointee.on_dev_tools_agent_detached = { observerSelf, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(observerSelf) else { return }
            MainActor.assumeIsolated { owner.send(owner.event(CefRemote.Event.devToolsDetached)) }
        }
        observerPointer = observer
        // The call takes a reference to the observer.
        Native.retain(UnsafeMutableRawPointer(observer))
        registration = host.pointee.add_dev_tools_message_observer?(host, observer)
        if registration == nil {
            note("browser \(id): DevTools observer NOT attached")
        }
    }

    private nonisolated static func owner<T>(_ observerSelf: UnsafeMutablePointer<T>?) -> RemoteBrowser? {
        Native.owner(BrowserBox.self, observerSelf.map(UnsafeMutableRawPointer.init))?.browser
    }

    /// Messages of a cross-site frame's session go to WSurf whole: CEF's parsed callbacks would drop their `sessionId`. The
    /// page's own messages are left to CEF, which then calls the result or event callback.
    private func devToolsMessage(_ message: UnsafeRawPointer, size: Int) -> Int32 {
        guard RemoteBrowser.isSessionMessage(message, size: size) else { return 0 }
        let forwarded = event(CefRemote.Event.devToolsMessage)
        forwarded.set(CefRemote.Key.data, bytes: message, count: size)
        send(forwarded)
        return 1
    }

    /// Whether `message` is a cross-site frame session's, by its top-level `sessionId`. The text alone proves nothing: a page
    /// controls its title and the values its scripts return, and a message that merely contains the word would be taken from CEF
    /// (whose result callback then never runs, so the service's own history read would never end). So the search is only a
    /// pre-filter; the message is parsed, and is claimed only when its top-level `sessionId` is a string. One that does not parse
    /// is claimed only when it ends as Chromium ends a session's message (the ID last), as `ChromiumDevTools` does in process.
    /// A message answering a command of the service's own is never claimed.
    private nonisolated static func isSessionMessage(_ message: UnsafeRawPointer, size: Int) -> Bool {
        let needle = "\"sessionId\""
        let found = needle.utf8CString.withUnsafeBufferPointer { pattern in
            memmem(message, size, pattern.baseAddress, pattern.count - 1) != nil
        }
        guard found else { return false }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: message), count: size, deallocator: .none)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let tail = String(decoding: data.suffix(160), as: UTF8.self)
            return tail.range(of: #","sessionId":"[^"\\]*"\}\s*$"#, options: .regularExpression) != nil
        }
        guard object["sessionId"] is String else { return false }
        if let messageID = object["id"] as? Int, Int64(messageID) >= CefRemote.serviceCommandBase {
            return false
        }
        return true
    }

    private func devToolsResult(id messageID: Int64, success: Bool, result: UnsafeRawPointer?, size: Int) {
        if messageID >= CefRemote.serviceCommandBase {
            serviceResult(id: messageID, success: success, result: result, size: size)
            return
        }
        let forwarded = event(CefRemote.Event.devToolsResult)
        forwarded.set(CefRemote.Key.identifier, messageID)
        forwarded.set(CefRemote.Key.success, success)
        forwarded.set(CefRemote.Key.data, bytes: result, count: size)
        send(forwarded)
    }

    private func devToolsEvent(method: String, params: UnsafeRawPointer?, size: Int) {
        let forwarded = event(CefRemote.Event.devToolsEvent)
        forwarded.set(CefRemote.Key.method, method)
        forwarded.set(CefRemote.Key.data, bytes: params, count: size)
        send(forwarded)
    }

    private func sendDevTools(_ data: Data, host: UnsafeMutablePointer<cef_browser_host_t>) {
        let messageID = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? Int
        // The ids from `serviceCommandBase` up are the service's own (its history read and collapse): a command of the host's
        // with one would be taken for those, and its result would never reach WSurf. Refused at once, and not sent.
        if let messageID, Int64(messageID) >= CefRemote.serviceCommandBase {
            failDevTools(id: messageID, "The command id is reserved for the service.")
            return
        }
        let accepted = data.withUnsafeBytes { bytes in
            host.pointee.send_dev_tools_message?(host, bytes.baseAddress, bytes.count) ?? 0
        }
        guard accepted == 0, let messageID else { return }
        // Rejected: answer the command so WSurf's wait ends now, not at its timeout.
        failDevTools(id: messageID, "Chromium DevTools rejected the command.")
    }

    private func failDevTools(id messageID: Int, _ message: String) {
        let failed = event(CefRemote.Event.devToolsResult)
        failed.set(CefRemote.Key.identifier, Int64(messageID))
        failed.set(CefRemote.Key.success, false)
        failed.set(CefRemote.Key.data, data: Data(#"{"message":"\#(message)"}"#.utf8))
        send(failed)
    }

    /// One of the service's own CDP commands (ids from `CefRemote.serviceCommandBase`, never forwarded to WSurf). `track` gets the
    /// id BEFORE the command is sent, because Chromium may deliver the result inside the send call; it is taken back with
    /// `untrack` when Chromium does not accept the command. False when it did not.
    private func sendServiceCommand(
        _ method: String, host: UnsafeMutablePointer<cef_browser_host_t>, track: (Int64) -> Void, untrack: (Int64) -> Void
    ) -> Bool {
        let commandID = nextServiceCommand
        nextServiceCommand += 1
        track(commandID)
        let json = Array(#"{"id":\#(commandID),"method":"\#(method)","params":{}}"#.utf8)
        let accepted = json.withUnsafeBytes { bytes in
            host.pointee.send_dev_tools_message?(host, bytes.baseAddress, bytes.count) ?? 0
        }
        if accepted == 0 {
            untrack(commandID)
        }
        return accepted != 0
    }

    private func serviceResult(id commandID: Int64, success: Bool, result: UnsafeRawPointer?, size: Int) {
        if commandID == historyCommand {
            historyCommand = nil
            historyResult(success: success, data: result.map { Data(bytes: $0, count: size) } ?? Data())
        } else if let request = collapses.removeValue(forKey: commandID) {
            send(CefRemoteMessage.historyCollapsed(browser: id, request: request, outcome: success ? .landed : .refused))
            refreshHistory()
        }
    }

    // MARK: History

    // The ids WSurf keeps history by are Chromium's navigation-entry ids, and only CDP carries them (`Page.getNavigationHistory`;
    // CEF's own entry objects have none). CEF's navigation-entry visitor adds what CDP lacks (`has_post_data`) and is the only
    // read that is synchronous on the UI thread. So `historyChanged` is built from both: a CDP read (its result arrives in a
    // later turn), then, in the turn it arrives, a visitor read that must agree with it (count, current index, every URL); a
    // list that does not agree is read again, a few times, then sent without `has_post_data`. `collapseHistory` needs the
    // check and the reset in ONE turn, so it checks the visitor's list against the last list sent (the one with ids) and
    // refuses when they disagree: a retry then finds the refreshed list.

    /// Asks Chromium for its navigation list. Calls while one is in flight are folded into one more read after it.
    func refreshHistory() {
        guard !hasClosed, !isClosing else { return }
        guard historyCommand == nil else {
            historyDirty = true
            return
        }
        withHost { [weak self] host in
            guard let self, historyCommand == nil else { return }
            _ = sendServiceCommand("Page.getNavigationHistory", host: host, track: { self.historyCommand = $0 }, untrack: { _ in self.historyCommand = nil })
        }
    }

    private func historyResult(success: Bool, data: Data) {
        defer {
            if historyDirty {
                historyDirty = false
                refreshHistory()
            }
        }
        guard !hasClosed, !isClosing else { return }
        guard success, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = object["currentIndex"] as? Int, let list = object["entries"] as? [[String: Any]] else {
            note("browser \(id): the history read failed (ok \(success), \(data.count) bytes)")
            return
        }
        var entries: [CefRemote.HistoryEntry] = []
        for (index, item) in list.enumerated() {
            guard let entryID = item["id"] as? Int, let url = item["url"] as? String else {
                note("browser \(id): the history read has an entry without an id or URL")
                return
            }
            entries.append(CefRemote.HistoryEntry(id: Int64(entryID), url: url, title: item["title"] as? String ?? "", isCurrent: index == current))
        }
        let native = readNativeEntries()
        if let native, RemoteBrowser.agree(native, with: entries) {
            for index in entries.indices {
                entries[index].hasPostData = native[index].hasPostData
                if !native[index].title.isEmpty {
                    entries[index].title = native[index].title
                }
            }
            historyMismatches = 0
        } else if historyMismatches < 3 {
            // Chromium's two lists were read in different turns and the list moved between them: read again shortly.
            historyMismatches += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.refreshHistory() }
            }
            return
        } else {
            historyMismatches = 0
        }
        guard entries != lastHistory else { return }
        lastHistory = entries
        send(CefRemoteMessage.historyChanged(browser: id, entries: entries))
    }

    /// Whether the visitor's list is the same list as `entries`: same length, same current entry, same URL at every position.
    private static func agree(_ native: [NativeEntry], with entries: [CefRemote.HistoryEntry]) -> Bool {
        native.count == entries.count
            && native.firstIndex(where: \.isCurrent) == entries.firstIndex(where: \.isCurrent)
            && zip(native, entries).allSatisfy { $0.url == $1.url }
    }

    /// "Collapse to `keeping` if the native list is exactly `expected`", checked and sent in one turn (the caller's, on the UI
    /// thread), so no entry can arrive between the check and the reset.
    private func collapseHistory(request: Int64, keeping: Int64, expected: [Int64], host: UnsafeMutablePointer<cef_browser_host_t>) {
        func answer(_ outcome: CefRemote.CollapseOutcome) {
            send(CefRemoteMessage.historyCollapsed(browser: id, request: request, outcome: outcome))
        }
        guard let known = lastHistory, let native = readNativeEntries(), RemoteBrowser.agree(native, with: known) else {
            // The list WSurf's ids come from is not the list Chromium holds now: nothing can be said about the ids.
            answer(.refused)
            refreshHistory()
            return
        }
        if let verdict = CefRemote.collapseVerdict(native: known, keeping: keeping, expected: expected) {
            answer(verdict)
            return
        }
        let sent = sendServiceCommand("Page.resetNavigationHistory", host: host, track: { self.collapses[$0] = request }, untrack: { self.collapses[$0] = nil })
        if !sent {
            answer(.refused)
        }
    }

    /// Chromium's entries as CEF's visitor reports them, read now on the UI thread: the visitor runs before the call returns.
    private func readNativeEntries() -> [NativeEntry]? {
        guard let host = hostReference() else { return nil }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        guard let visit = host.pointee.get_navigation_entries else { return nil }
        let reader = NativeEntryReader()
        let visitor = Native.allocate(cef_navigation_entry_visitor_t.self, owner: reader)
        visitor.pointee.visit = { visitorSelf, entry, current, _, _ in
            guard let entry else { return 1 }
            let item = NativeEntry(
                url: Native.take(entry.pointee.get_url?(entry)), title: Native.take(entry.pointee.get_title?(entry)),
                hasPostData: entry.pointee.has_post_data?(entry) == 1, isCurrent: current != 0)
            // Callback object arguments arrive with a reference.
            Native.release(UnsafeMutableRawPointer(entry))
            guard let reader = Native.owner(NativeEntryReader.self, visitorSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            reader.entries.append(item)
            return 1
        }
        defer { Native.release(UnsafeMutableRawPointer(visitor)) }
        // The call takes a reference to the visitor.
        Native.retain(UnsafeMutableRawPointer(visitor))
        visit(host, visitor, 0)
        return reader.entries
    }
}

/// One entry as CEF's visitor reports it.
private struct NativeEntry {
    var url: String
    var title: String
    var hasPostData: Bool
    var isCurrent: Bool
}

/// What the navigation-entry visitor collects. A class of its own: the visitor's C callback must not be isolated.
private final class NativeEntryReader: @unchecked Sendable {
    var entries: [NativeEntry] = []
}
