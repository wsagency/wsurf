// D4 spike: one windowless browser in the service. Its CEF client forwards every callback WSurf's ChromiumPage acts on as an
// event (WSurf keeps every policy), answers what must be answered synchronously with a safe default, and owns the frames.

import AppKit
import CCef
import CefKit
import IOSurface

@MainActor
final class RemoteBrowser {
    let id: Int64
    let presenter: FramePresenter
    private(set) var raw: UnsafeMutablePointer<cef_browser_t>?
    private(set) var isClosing = false
    private var hasClosed = false

    private var clientPointer: UnsafeMutablePointer<cef_client_t>?
    nonisolated(unsafe) private var lifeSpanPointer: UnsafeMutablePointer<cef_life_span_handler_t>?
    nonisolated(unsafe) private var loadPointer: UnsafeMutablePointer<cef_load_handler_t>?
    nonisolated(unsafe) private var displayPointer: UnsafeMutablePointer<cef_display_handler_t>?
    nonisolated(unsafe) private var requestPointer: UnsafeMutablePointer<cef_request_handler_t>?
    nonisolated(unsafe) private var renderPointer: UnsafeMutablePointer<cef_render_handler_t>?
    nonisolated(unsafe) private var keyboardPointer: UnsafeMutablePointer<cef_keyboard_handler_t>?
    nonisolated(unsafe) private var focusPointer: UnsafeMutablePointer<cef_focus_handler_t>?
    nonisolated(unsafe) private var contextMenuPointer: UnsafeMutablePointer<cef_context_menu_handler_t>?
    nonisolated(unsafe) private var findPointer: UnsafeMutablePointer<cef_find_handler_t>?
    private var accessibilityPointer: UnsafeMutablePointer<cef_accessibility_handler_t>?
    private var observerPointer: UnsafeMutablePointer<cef_dev_tools_message_observer_t>?
    private var registration: UnsafeMutablePointer<cef_registration_t>?
    private var contextMenuCallback: UnsafeMutablePointer<cef_run_context_menu_callback_t>?

    /// What WSurf asked for before CEF made the browser.
    private var pending: [(UnsafeMutablePointer<cef_browser_host_t>) -> Void] = []

    private(set) var sizeDIP: CGSize
    private(set) var scale: CGFloat
    private var screenRect: CGRect
    private var origin: CGPoint
    private(set) var hidden: Bool
    private(set) var parked: Bool
    let createdAt = Clock.nowNanoseconds
    private(set) var readyAt: UInt64 = 0
    private(set) var firstFrameAt: UInt64 = 0

    private var nextServiceCommand = CefRemote.serviceCommandBase
    /// The service's own `Page.resetNavigationHistory`, by its CDP id: WSurf's request id.
    private var collapses: [Int64: Int64] = [:]

    init(id: Int64, message: CefRemoteMessage, serverPort: mach_port_t, debugRoot: Bool = false) {
        self.id = id
        sizeDIP = CGSize(width: max(1, message.double(CefRemote.Key.width)), height: max(1, message.double(CefRemote.Key.height)))
        scale = max(1, message.double(CefRemote.Key.scale))
        screenRect = Self.screenRect(message)
        origin = CGPoint(x: message.double(CefRemote.Key.originX), y: message.double(CefRemote.Key.originY))
        hidden = message.bool(CefRemote.Key.hidden)
        parked = message.bool(CefRemote.Key.parked)
        presenter = FramePresenter(serverPort: serverPort, debugRoot: debugRoot)
        presenter.setGeometry(sizeDIP: sizeDIP, scale: scale)
        presenter.hidden = hidden
        presenter.parked = parked
    }

    private static func screenRect(_ message: CefRemoteMessage) -> CGRect {
        CGRect(x: message.double(CefRemote.Key.screenX), y: message.double(CefRemote.Key.screenY),
               width: max(1, message.double(CefRemote.Key.screenWidth)), height: max(1, message.double(CefRemote.Key.screenHeight)))
    }

    // MARK: Creation and close

    func create(url: String, context: UnsafeMutablePointer<cef_request_context_t>?, javaScript: Bool, frameRate: Int32,
                externalBeginFrames: Bool) -> Bool {
        let client = makeClient()
        var info = cef_window_info_t()
        info.size = MemoryLayout<cef_window_info_t>.stride
        info.windowless_rendering_enabled = 1
        info.shared_texture_enabled = 1
        info.external_begin_frame_enabled = externalBeginFrames ? 1 : 0
        info.bounds = cef_rect_t(x: 0, y: 0, width: Int32(sizeDIP.width.rounded()), height: Int32(sizeDIP.height.rounded()))
        info.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.stride
        settings.windowless_frame_rate = frameRate
        settings.javascript = javaScript ? STATE_ENABLED : STATE_DISABLED
        // Opaque white, as a windowed browser paints: a windowless one is transparent by default.
        settings.background_color = 0xFFFF_FFFF
        // CEF takes a reference to each object it is given.
        Native.retain(UnsafeMutableRawPointer(client))
        if let context {
            Native.retain(UnsafeMutableRawPointer(context))
        }
        let started = Native.withString(url) { cef_browser_host_create_browser(&info, client, $0, &settings, nil, context) }
        note("browser \(id): create \(started == 1 ? "started" : "FAILED") \(Int(sizeDIP.width))x\(Int(sizeDIP.height))@\(scale) fps \(frameRate) external \(externalBeginFrames) hidden \(hidden)")
        return started == 1
    }

    private func didCreate(_ browser: UnsafeMutablePointer<cef_browser_t>) {
        Native.retain(UnsafeMutableRawPointer(browser))
        raw = browser
        readyAt = Clock.nowNanoseconds
        guard let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        attachDevTools(host)
        host.pointee.was_hidden?(host, hidden ? 1 : 0)
        let queued = pending
        pending.removeAll()
        for work in queued {
            work(host)
        }
        let message = CefRemoteMessage(CefRemote.Event.browserReady, browser: id)
        message.set(CefRemote.Key.value, Double(readyAt &- createdAt) / 1e6)
        ServiceHost.shared.send(message)
        note("browser \(id): ready after \(String(format: "%.1f", Double(readyAt &- createdAt) / 1e6)) ms")
        if isClosing {
            host.pointee.close_browser?(host, 1)
        }
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        cancelContextMenu()
        withHost { $0.pointee.close_browser?($0, 1) }
        if raw == nil {
            note("browser \(id): close requested before creation")
        }
    }

    private func didClose() {
        guard !hasClosed else { return }
        hasClosed = true
        cancelContextMenu()
        if let registration {
            Native.release(UnsafeMutableRawPointer(registration))
            self.registration = nil
        }
        if let raw {
            Native.release(UnsafeMutableRawPointer(raw))
            self.raw = nil
        }
        presenter.invalidate()
        for pointer: UnsafeMutableRawPointer? in [
            lifeSpanPointer.map(UnsafeMutableRawPointer.init), loadPointer.map(UnsafeMutableRawPointer.init),
            displayPointer.map(UnsafeMutableRawPointer.init), requestPointer.map(UnsafeMutableRawPointer.init),
            renderPointer.map(UnsafeMutableRawPointer.init), keyboardPointer.map(UnsafeMutableRawPointer.init),
            focusPointer.map(UnsafeMutableRawPointer.init), contextMenuPointer.map(UnsafeMutableRawPointer.init),
            findPointer.map(UnsafeMutableRawPointer.init), observerPointer.map(UnsafeMutableRawPointer.init),
            accessibilityPointer.map(UnsafeMutableRawPointer.init),
            clientPointer.map(UnsafeMutableRawPointer.init),
        ] {
            Native.release(pointer)
        }
        lifeSpanPointer = nil
        loadPointer = nil
        displayPointer = nil
        requestPointer = nil
        renderPointer = nil
        keyboardPointer = nil
        focusPointer = nil
        contextMenuPointer = nil
        findPointer = nil
        accessibilityPointer = nil
        observerPointer = nil
        clientPointer = nil
        ServiceHost.shared.send(CefRemoteMessage(CefRemote.Event.browserClosed, browser: id))
        ServiceHost.shared.browserDidClose(id)
        note("browser \(id): closed")
    }

    /// A +1 host reference, or nil before creation.
    private func hostReference() -> UnsafeMutablePointer<cef_browser_host_t>? {
        guard let raw else { return nil }
        return raw.pointee.get_host?(raw)
    }

    /// Runs `body` with the host now, or once CEF has made the browser.
    func withHost(_ body: @escaping (UnsafeMutablePointer<cef_browser_host_t>) -> Void) {
        guard !hasClosed else { return }
        guard let host = hostReference() else {
            pending.append(body)
            return
        }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        body(host)
    }

    private func withMainFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let raw, let frame = raw.pointee.get_main_frame?(raw) else { return }
        defer { Native.release(UnsafeMutableRawPointer(frame)) }
        body(frame)
    }

    private func withEditingFrame(_ body: (UnsafeMutablePointer<cef_frame_t>) -> Void) {
        guard let raw else { return }
        guard let frame = raw.pointee.get_focused_frame?(raw) ?? raw.pointee.get_main_frame?(raw) else { return }
        defer { Native.release(UnsafeMutableRawPointer(frame)) }
        body(frame)
    }

    private func send(_ message: CefRemoteMessage) {
        ServiceHost.shared.send(message)
    }

    private func event(_ name: String) -> CefRemoteMessage {
        CefRemoteMessage(name, browser: id)
    }

    // MARK: Commands from WSurf

    func handle(_ message: CefRemoteMessage) {
        switch message.op {
        case CefRemote.Op.load:
            let url = message.string(CefRemote.Key.url)
            if raw == nil {
                withHost { [weak self] _ in self?.load(url) }
            } else {
                load(url)
            }
        case CefRemote.Op.reload:
            let ignoreCache = message.bool(CefRemote.Key.flag)
            withBrowserLater { browser in
                if ignoreCache {
                    browser.pointee.reload_ignore_cache?(browser)
                } else {
                    browser.pointee.reload?(browser)
                }
            }
        case CefRemote.Op.goBack:
            withBrowserLater { $0.pointee.go_back?($0) }
        case CefRemote.Op.goForward:
            withBrowserLater { $0.pointee.go_forward?($0) }
        case CefRemote.Op.stop:
            withBrowserLater { $0.pointee.stop_load?($0) }
        case CefRemote.Op.resize:
            resize(message)
        case CefRemote.Op.visibility:
            setVisibility(hidden: message.bool(CefRemote.Key.hidden), parked: message.bool(CefRemote.Key.parked))
        case CefRemote.Op.focus:
            let focused = message.bool(CefRemote.Key.flag)
            withHost { $0.pointee.set_focus?($0, focused ? 1 : 0) }
        case CefRemote.Op.zoom:
            let level = message.double(CefRemote.Key.value)
            withHost { $0.pointee.set_zoom_level?($0, level) }
        case CefRemote.Op.mute:
            let muted = message.bool(CefRemote.Key.flag)
            withHost { $0.pointee.set_audio_muted?($0, muted ? 1 : 0) }
        case CefRemote.Op.find:
            let text = message.string(CefRemote.Key.text)
            let forward = message.bool(CefRemote.Key.forward)
            let matchCase = message.bool(CefRemote.Key.matchCase)
            let next = message.bool(CefRemote.Key.findNext)
            withHost { host in
                Native.withString(text) { host.pointee.find?(host, $0, forward ? 1 : 0, matchCase ? 1 : 0, next ? 1 : 0) }
            }
        case CefRemote.Op.stopFinding:
            let clear = message.bool(CefRemote.Key.flag)
            withHost { $0.pointee.stop_finding?($0, clear ? 1 : 0) }
        case CefRemote.Op.close:
            close()
        case CefRemote.Op.devTools:
            let data = message.data(CefRemote.Key.data)
            withHost { [weak self] host in self?.sendDevTools(data, host: host) }
        case CefRemote.Op.collapseStartup:
            let request = message.int(CefRemote.Key.identifier)
            withHost { [weak self] host in self?.collapseStartup(request: request, host: host) }
        case CefRemote.Op.contextMenuCommand:
            finishContextMenu(command: message.int(CefRemote.Key.command))
        case CefRemote.Op.mouse:
            mouse(message)
        case CefRemote.Op.key:
            key(message)
        case CefRemote.Op.imeSetComposition, CefRemote.Op.imeCommit, CefRemote.Op.imeFinish, CefRemote.Op.imeCancel:
            ime(message)
        case CefRemote.Op.edit:
            edit(message.string(CefRemote.Key.kind))
        case CefRemote.Op.accessibility:
            let enabled = message.bool(CefRemote.Key.flag)
            withHost { $0.pointee.set_accessibility_state?($0, enabled ? STATE_ENABLED : STATE_DISABLED) }
            note("browser \(id): accessibility \(enabled ? "on" : "off")")
        default:
            note("browser \(id): unknown op \(message.op)")
        }
    }

    private func withBrowserLater(_ body: @escaping (UnsafeMutablePointer<cef_browser_t>) -> Void) {
        if let raw {
            body(raw)
        } else {
            withHost { [weak self] _ in
                guard let raw = self?.raw else { return }
                body(raw)
            }
        }
    }

    private func load(_ url: String) {
        withMainFrame { frame in
            Native.withString(url) { frame.pointee.load_url?(frame, $0) }
        }
    }

    private func resize(_ message: CefRemoteMessage) {
        let size = CGSize(width: max(1, message.double(CefRemote.Key.width)), height: max(1, message.double(CefRemote.Key.height)))
        let newScale = max(1, message.double(CefRemote.Key.scale))
        let scaleChanged = newScale != scale
        let sizeChanged = size != sizeDIP
        sizeDIP = size
        scale = newScale
        screenRect = Self.screenRect(message)
        origin = CGPoint(x: message.double(CefRemote.Key.originX), y: message.double(CefRemote.Key.originY))
        presenter.setGeometry(sizeDIP: sizeDIP, scale: scale)
        withHost { host in
            if scaleChanged {
                host.pointee.notify_screen_info_changed?(host)
            }
            if sizeChanged || scaleChanged {
                host.pointee.was_resized?(host)
            }
        }
    }

    private func setVisibility(hidden newHidden: Bool, parked newParked: Bool) {
        let wasShown = !hidden && !parked
        let hiddenChanged = newHidden != hidden
        hidden = newHidden
        parked = newParked
        presenter.hidden = newHidden
        presenter.parked = newParked
        let shown = !newHidden && !newParked
        withHost { host in
            if hiddenChanged {
                host.pointee.was_hidden?(host, newHidden ? 1 : 0)
            }
            if shown && !wasShown {
                // A still page sends no frame of its own after it comes back: ask for one.
                host.pointee.invalidate?(host, PET_VIEW)
            }
        }
    }

    // MARK: DevTools

    private func attachDevTools(_ host: UnsafeMutablePointer<cef_browser_host_t>) {
        let observer = Native.allocate(cef_dev_tools_message_observer_t.self, owner: self)
        observer.pointee.on_dev_tools_message = { observerSelf, browser, message, size in
            defer { Native.release(browser.map(UnsafeMutableRawPointer.init)) }
            guard let message, size > 0,
                  let owner = Native.owner(RemoteBrowser.self, observerSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            return MainActor.assumeIsolated { owner.devToolsMessage(message, size: size) }
        }
        observer.pointee.on_dev_tools_method_result = { observerSelf, browser, messageID, success, result, size in
            defer { Native.release(browser.map(UnsafeMutableRawPointer.init)) }
            guard let owner = Native.owner(RemoteBrowser.self, observerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            MainActor.assumeIsolated { owner.devToolsResult(id: Int64(messageID), success: success != 0, result: result, size: size) }
        }
        observer.pointee.on_dev_tools_event = { observerSelf, browser, method, params, size in
            defer { Native.release(browser.map(UnsafeMutableRawPointer.init)) }
            guard let owner = Native.owner(RemoteBrowser.self, observerSelf.map(UnsafeMutableRawPointer.init)) else { return }
            let name = Native.string(method)
            MainActor.assumeIsolated { owner.devToolsEvent(method: name, params: params, size: size) }
        }
        observer.pointee.on_dev_tools_agent_attached = { _, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
        }
        observer.pointee.on_dev_tools_agent_detached = { observerSelf, browser in
            defer { Native.release(browser.map(UnsafeMutableRawPointer.init)) }
            guard let owner = Native.owner(RemoteBrowser.self, observerSelf.map(UnsafeMutableRawPointer.init)) else { return }
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

    /// Messages of a cross-site frame's session go to WSurf whole: CEF's parsed callbacks would drop their `sessionId`. The
    /// page's own messages are left to CEF, which then calls the result or event callback.
    private func devToolsMessage(_ message: UnsafeRawPointer, size: Int) -> Int32 {
        let needle = "\"sessionId\""
        let found = needle.utf8CString.withUnsafeBufferPointer { pattern in
            memmem(message, size, pattern.baseAddress, pattern.count - 1) != nil
        }
        guard found else { return 0 }
        let forwarded = event(CefRemote.Event.devToolsMessage)
        forwarded.set(CefRemote.Key.data, bytes: message, count: size)
        send(forwarded)
        return 1
    }

    private func devToolsResult(id messageID: Int64, success: Bool, result: UnsafeRawPointer?, size: Int) {
        if messageID >= CefRemote.serviceCommandBase {
            serviceResult(id: messageID, success: success)
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
        let accepted = data.withUnsafeBytes { bytes in
            host.pointee.send_dev_tools_message?(host, bytes.baseAddress, bytes.count) ?? 0
        }
        guard accepted == 0 else { return }
        // Rejected: answer the command so WSurf's wait ends now, not at its timeout.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let messageID = object["id"] as? Int else {
            return
        }
        let failed = event(CefRemote.Event.devToolsResult)
        failed.set(CefRemote.Key.identifier, Int64(messageID))
        failed.set(CefRemote.Key.success, false)
        failed.set(CefRemote.Key.data, data: Data(#"{"message":"Chromium DevTools rejected the command."}"#.utf8))
        send(failed)
    }

    /// Rule 4 of the plan: the check and the send happen in one turn on CEF's UI thread, so no history entry can arrive between them.
    private func collapseStartup(request: Int64, host: UnsafeMutablePointer<cef_browser_host_t>) {
        func reply(_ outcome: Int64) {
            let message = event(CefRemote.Event.collapsed)
            message.set(CefRemote.Key.identifier, request)
            message.set(CefRemote.Key.outcome, outcome)
            send(message)
        }
        guard let history = nativeHistory(host) else {
            reply(CefRemote.CollapseOutcome.refused)
            return
        }
        if history.first != "about:blank" {
            reply(CefRemote.CollapseOutcome.landed)
            return
        }
        if history.count > 2 {
            reply(CefRemote.CollapseOutcome.skipped)
            return
        }
        guard history.count == 2, history.current == 1 else {
            reply(CefRemote.CollapseOutcome.refused)
            return
        }
        let commandID = nextServiceCommand
        nextServiceCommand += 1
        collapses[commandID] = request
        let json = #"{"id":\#(commandID),"method":"Page.resetNavigationHistory","params":{}}"#
        let accepted = Array(json.utf8).withUnsafeBytes { bytes in
            host.pointee.send_dev_tools_message?(host, bytes.baseAddress, bytes.count) ?? 0
        }
        if accepted == 0 {
            collapses[commandID] = nil
            reply(CefRemote.CollapseOutcome.refused)
        }
    }

    private func serviceResult(id commandID: Int64, success: Bool) {
        guard let request = collapses.removeValue(forKey: commandID) else { return }
        let message = event(CefRemote.Event.collapsed)
        message.set(CefRemote.Key.identifier, request)
        message.set(CefRemote.Key.outcome, success ? CefRemote.CollapseOutcome.landed : CefRemote.CollapseOutcome.refused)
        send(message)
    }

    // MARK: Mirrored state

    private final class HistoryReader {
        var count = 0
        var current = 0
        var first: String?
    }

    /// Chromium's entry count, current index and first URL, read now on the UI thread.
    private func nativeHistory(_ host: UnsafeMutablePointer<cef_browser_host_t>) -> (count: Int, current: Int, first: String)? {
        let reader = HistoryReader()
        let visitor = Native.allocate(cef_navigation_entry_visitor_t.self, owner: reader)
        visitor.pointee.visit = { visitorSelf, entry, current, index, total in
            let url = entry.map { Native.take($0.pointee.get_url?($0)) } ?? ""
            Native.release(entry.map(UnsafeMutableRawPointer.init))
            guard let reader = Native.owner(HistoryReader.self, visitorSelf.map(UnsafeMutableRawPointer.init)) else { return 0 }
            reader.count = Int(total)
            if index == 0 {
                reader.first = url
            }
            if current != 0 {
                reader.current = Int(index)
            }
            return 1
        }
        defer { Native.release(UnsafeMutableRawPointer(visitor)) }
        Native.retain(UnsafeMutableRawPointer(visitor))
        guard let entries = host.pointee.get_navigation_entries else {
            Native.release(UnsafeMutableRawPointer(visitor))
            return nil
        }
        entries(host, visitor, 0)
        guard let first = reader.first else { return nil }
        return (reader.count, reader.current, first)
    }

    /// Adds the native history and the visible entry's title and SSL status to an event: the reads WSurf makes in the same
    /// turn today, pushed with the event instead.
    private func addState(to message: CefRemoteMessage) {
        guard let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        if let history = nativeHistory(host) {
            message.set(CefRemote.Key.historyCount, history.count)
            message.set(CefRemote.Key.historyIndex, history.current)
            message.set(CefRemote.Key.historyFirst, history.first)
        }
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

    private func sendState(_ name: String, _ fill: (CefRemoteMessage) -> Void = { _ in }) {
        let message = event(name)
        fill(message)
        addState(to: message)
        send(message)
    }

    // MARK: Context menu

    private func cancelContextMenu() {
        guard let callback = contextMenuCallback else { return }
        contextMenuCallback = nil
        callback.pointee.cancel?(callback)
        Native.release(UnsafeMutableRawPointer(callback))
    }

    private func finishContextMenu(command: Int64) {
        guard let callback = contextMenuCallback else { return }
        contextMenuCallback = nil
        if command >= 0 {
            callback.pointee.cont?(callback, Int32(command), EVENTFLAG_NONE)
        } else {
            callback.pointee.cancel?(callback)
        }
        Native.release(UnsafeMutableRawPointer(callback))
    }

    private func runContextMenu(x: Int32, y: Int32, model: UnsafeMutablePointer<cef_menu_model_t>,
                                callback: UnsafeMutablePointer<cef_run_context_menu_callback_t>) {
        cancelContextMenu()
        contextMenuCallback = callback
        var items: [CefRemoteMessage] = []
        let count = Int(model.pointee.get_count?(model) ?? 0)
        for index in 0..<count {
            let item = CefRemoteMessage("item")
            let type = model.pointee.get_type_at?(model, index)
            if type == MENUITEMTYPE_SEPARATOR {
                item.set(CefRemote.Key.separator, true)
            } else {
                item.set(CefRemote.Key.command, Int64(model.pointee.get_command_id_at?(model, index) ?? -1))
                item.set(CefRemote.Key.label, Native.take(model.pointee.get_label_at?(model, index)))
                item.set(CefRemote.Key.enabled, model.pointee.is_enabled_at?(model, index) == 1)
            }
            items.append(item)
        }
        let message = event(CefRemote.Event.contextMenu)
        message.set(CefRemote.Key.x, Double(x))
        message.set(CefRemote.Key.y, Double(y))
        message.set(CefRemote.Key.items, messages: items)
        send(message)
    }

    // MARK: Input

    private var inputLegMs: [Double] = []

    private func recordInput(_ message: CefRemoteMessage) {
        let stamp = message.double(CefRemote.Key.timestamp)
        guard stamp > 0 else { return }
        let leg = (Clock.nowSeconds - stamp) * 1000
        if inputLegMs.count >= 4_000 {
            inputLegMs.removeFirst(1_000)
        }
        inputLegMs.append(leg)
    }

    private func mouse(_ message: CefRemoteMessage) {
        var event = cef_mouse_event_t(x: Int32(message.double(CefRemote.Key.x).rounded()),
                                      y: Int32(message.double(CefRemote.Key.y).rounded()),
                                      modifiers: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.modifiers)))
        let kind = message.string(CefRemote.Key.kind)
        guard let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        switch kind {
        case "move":
            host.pointee.send_mouse_move_event?(host, &event, 0)
        case "leave":
            host.pointee.send_mouse_move_event?(host, &event, 1)
        case "down", "up":
            let button: cef_mouse_button_type_t = switch message.int(CefRemote.Key.button) {
            case 1: MBT_MIDDLE
            case 2: MBT_RIGHT
            default: MBT_LEFT
            }
            host.pointee.send_mouse_click_event?(host, &event, button, kind == "up" ? 1 : 0,
                                                 Int32(max(1, message.int(CefRemote.Key.clickCount))))
        case "wheel":
            host.pointee.send_mouse_wheel_event?(host, &event, Int32(message.double(CefRemote.Key.deltaX).rounded()),
                                                 Int32(message.double(CefRemote.Key.deltaY).rounded()))
        default:
            return
        }
        recordInput(message)
    }

    private func key(_ message: CefRemoteMessage) {
        var event = cef_key_event_t()
        event.size = MemoryLayout<cef_key_event_t>.stride
        event.type = cef_key_event_type_t(rawValue: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.keyType)))
        event.modifiers = UInt32(truncatingIfNeeded: message.int(CefRemote.Key.modifiers))
        event.windows_key_code = Int32(truncatingIfNeeded: message.int(CefRemote.Key.windowsKeyCode))
        event.native_key_code = Int32(truncatingIfNeeded: message.int(CefRemote.Key.nativeKeyCode))
        event.is_system_key = message.bool(CefRemote.Key.systemKey) ? 1 : 0
        event.character = UInt16(truncatingIfNeeded: message.int(CefRemote.Key.character))
        event.unmodified_character = UInt16(truncatingIfNeeded: message.int(CefRemote.Key.unmodifiedCharacter))
        event.focus_on_editable_field = message.bool(CefRemote.Key.editable) ? 1 : 0
        guard let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        host.pointee.send_key_event?(host, &event)
        recordInput(message)
    }

    private func ime(_ message: CefRemoteMessage) {
        guard let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        let text = message.string(CefRemote.Key.text)
        var replacement = cef_range_t(from: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.replaceFrom)),
                                      to: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.replaceTo)))
        let hasReplacement = message.has(CefRemote.Key.replaceFrom)
        switch message.op {
        case CefRemote.Op.imeSetComposition:
            var selection = cef_range_t(from: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.rangeFrom)),
                                        to: UInt32(truncatingIfNeeded: message.int(CefRemote.Key.rangeTo)))
            var underline = cef_composition_underline_t(
                size: MemoryLayout<cef_composition_underline_t>.stride,
                range: cef_range_t(from: 0, to: UInt32(text.utf16.count)),
                color: 0xFF00_0000, background_color: 0, thick: 0, style: CEF_CUS_SOLID)
            Native.withString(text) { native in
                if hasReplacement {
                    host.pointee.ime_set_composition?(host, native, 1, &underline, &replacement, &selection)
                } else {
                    host.pointee.ime_set_composition?(host, native, 1, &underline, nil, &selection)
                }
            }
        case CefRemote.Op.imeCommit:
            Native.withString(text) { native in
                if hasReplacement {
                    host.pointee.ime_commit_text?(host, native, &replacement, 0)
                } else {
                    host.pointee.ime_commit_text?(host, native, nil, 0)
                }
            }
        case CefRemote.Op.imeFinish:
            host.pointee.ime_finish_composing_text?(host, message.bool(CefRemote.Key.flag) ? 1 : 0)
        default:
            host.pointee.ime_cancel_composition?(host)
        }
        recordInput(message)
    }

    private func edit(_ kind: String) {
        withEditingFrame { frame in
            switch kind {
            case "copy": frame.pointee.copy?(frame)
            case "cut": frame.pointee.cut?(frame)
            case "paste": frame.pointee.paste?(frame)
            case "pasteAndMatchStyle": frame.pointee.paste_and_match_style?(frame)
            case "delete": frame.pointee.del?(frame)
            case "selectAll": frame.pointee.select_all?(frame)
            case "undo": frame.pointee.undo?(frame)
            case "redo": frame.pointee.redo?(frame)
            default: break
            }
        }
    }

    func sendExternalBeginFrame() {
        guard !hidden, let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        host.pointee.send_external_begin_frame?(host)
    }

    // MARK: Statistics

    func statistics(into builder: CefRemoteMessageBuilder) {
        builder.add("readyMs", readyAt == 0 ? -1 : Double(readyAt &- createdAt) / 1e6)
        builder.add("firstFrameMs", firstFrameAt == 0 ? -1 : Double(firstFrameAt &- createdAt) / 1e6)
        builder.add("hidden", hidden ? 1 : 0)
        builder.add("parked", parked ? 1 : 0)
        builder.percentiles("inputLegMs", inputLegMs)
        presenter.statistics(into: builder)
    }

    func resetStatistics() {
        inputLegMs.removeAll()
        presenter.resetStatistics()
    }

    // MARK: The client

    private func makeClient() -> UnsafeMutablePointer<cef_client_t> {
        makeLifeSpanHandler()
        makeLoadHandler()
        makeDisplayHandler()
        makeRequestHandler()
        makeRenderHandler()
        makeKeyboardHandler()
        makeFocusHandler()
        makeContextMenuHandler()
        makeFindHandler()
        let client = Native.allocate(cef_client_t.self, owner: self)
        client.pointee.get_life_span_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.lifeSpanPointer }
        }
        client.pointee.get_load_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.loadPointer }
        }
        client.pointee.get_display_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.displayPointer }
        }
        client.pointee.get_request_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.requestPointer }
        }
        client.pointee.get_render_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.renderPointer }
        }
        client.pointee.get_keyboard_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.keyboardPointer }
        }
        client.pointee.get_focus_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.focusPointer }
        }
        client.pointee.get_context_menu_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.contextMenuPointer }
        }
        client.pointee.get_find_handler = { clientSelf in
            RemoteBrowser.handler(clientSelf) { $0.findPointer }
        }
        clientPointer = client
        return client
    }

    /// A handler to return to CEF, with the reference the caller takes. CEF asks on any thread (the IO thread too), so the
    /// handlers are made once on the main thread before the browser exists and read here without an actor hop.
    private nonisolated static func handler<T>(
        _ clientSelf: UnsafeMutablePointer<cef_client_t>?, _ pick: (RemoteBrowser) -> UnsafeMutablePointer<T>?
    ) -> UnsafeMutablePointer<T>? {
        guard let owner = Native.owner(RemoteBrowser.self, clientSelf.map(UnsafeMutableRawPointer.init)),
              let pointer = pick(owner) else { return nil }
        Native.retain(UnsafeMutableRawPointer(pointer))
        return pointer
    }

    private nonisolated static func owner<T>(_ handlerSelf: UnsafeMutablePointer<T>?) -> RemoteBrowser? {
        Native.owner(RemoteBrowser.self, handlerSelf.map(UnsafeMutableRawPointer.init))
    }

    private nonisolated static func isMain(_ frame: UnsafeMutablePointer<cef_frame_t>?) -> Bool {
        frame?.pointee.is_main?(frame) == 1
    }

    private func makeLifeSpanHandler() {
        let life = Native.allocate(cef_life_span_handler_t.self, owner: self)
        life.pointee.on_after_created = { handlerSelf, browser in
            guard let browser else { return }
            defer { Native.release(UnsafeMutableRawPointer(browser)) }
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.didCreate(browser) }
        }
        life.pointee.do_close = { _, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            return 0
        }
        life.pointee.on_before_close = { handlerSelf, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.didClose() }
        }
        life.pointee.on_before_popup = { handlerSelf, browser, frame, _, targetURL, _, _, userGesture, _, _, popupClient, _, extraInfo, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            Native.release(popupClient?.pointee.map(UnsafeMutableRawPointer.init))
            Native.release(extraInfo?.pointee.map(UnsafeMutableRawPointer.init))
            let url = Native.string(targetURL)
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return 1 }
            MainActor.assumeIsolated {
                // Pop-ups are out of the spike's scope: WSurf hears of it and nothing opens.
                let message = owner.event(CefRemote.Event.popupBlocked)
                message.set(CefRemote.Key.url, url)
                message.set(CefRemote.Key.userGesture, userGesture != 0)
                owner.send(message)
            }
            return 1
        }
        lifeSpanPointer = life
    }

    private func makeLoadHandler() {
        let load = Native.allocate(cef_load_handler_t.self, owner: self)
        load.pointee.on_loading_state_change = { handlerSelf, browser, loading, back, forward in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated {
                owner.sendState(CefRemote.Event.loadingState) { message in
                    message.set(CefRemote.Key.loading, loading != 0)
                    message.set(CefRemote.Key.canGoBack, back != 0)
                    message.set(CefRemote.Key.canGoForward, forward != 0)
                }
            }
        }
        load.pointee.on_load_start = { handlerSelf, browser, frame, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            defer { Native.release(frame.map(UnsafeMutableRawPointer.init)) }
            guard RemoteBrowser.isMain(frame), let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.sendState(CefRemote.Event.loadStart) }
        }
        load.pointee.on_load_end = { handlerSelf, browser, frame, status in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            defer { Native.release(frame.map(UnsafeMutableRawPointer.init)) }
            guard RemoteBrowser.isMain(frame), let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated {
                owner.sendState(CefRemote.Event.loadEnd) { $0.set(CefRemote.Key.status, Int64(status)) }
            }
        }
        load.pointee.on_load_error = { handlerSelf, browser, frame, code, text, failedURL in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            defer { Native.release(frame.map(UnsafeMutableRawPointer.init)) }
            guard RemoteBrowser.isMain(frame), let owner = RemoteBrowser.owner(handlerSelf) else { return }
            let message = Native.string(text)
            let url = Native.string(failedURL)
            MainActor.assumeIsolated {
                owner.sendState(CefRemote.Event.loadError) {
                    $0.set(CefRemote.Key.code, Int64(code.rawValue))
                    $0.set(CefRemote.Key.text, message)
                    $0.set(CefRemote.Key.url, url)
                }
            }
        }
        loadPointer = load
    }

    private func makeDisplayHandler() {
        let display = Native.allocate(cef_display_handler_t.self, owner: self)
        display.pointee.on_address_change = { handlerSelf, browser, frame, url in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            defer { Native.release(frame.map(UnsafeMutableRawPointer.init)) }
            guard RemoteBrowser.isMain(frame), let owner = RemoteBrowser.owner(handlerSelf) else { return }
            let address = Native.string(url)
            MainActor.assumeIsolated { owner.sendState(CefRemote.Event.address) { $0.set(CefRemote.Key.url, address) } }
        }
        display.pointee.on_title_change = { handlerSelf, browser, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.sendState(CefRemote.Event.title) }
        }
        display.pointee.on_loading_progress_change = { handlerSelf, browser, progress in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.progress)
                message.set(CefRemote.Key.progress, progress)
                owner.send(message)
            }
        }
        display.pointee.on_status_message = { handlerSelf, browser, value in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            let text = Native.string(value)
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.statusMessage)
                message.set(CefRemote.Key.text, text)
                owner.send(message)
            }
        }
        display.pointee.on_fullscreen_mode_change = { handlerSelf, browser, fullscreen in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.fullscreen)
                message.set(CefRemote.Key.flag, fullscreen != 0)
                owner.send(message)
            }
        }
        display.pointee.on_cursor_change = { handlerSelf, browser, _, type, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return 1 }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.cursor)
                message.set(CefRemote.Key.cursor, Int64(type.rawValue))
                owner.send(message)
            }
            return 1
        }
        display.pointee.on_tooltip = { handlerSelf, browser, text in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return 1 }
            let tip = text.map { Native.string(UnsafePointer($0)) } ?? ""
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.tooltip)
                message.set(CefRemote.Key.text, tip)
                owner.send(message)
            }
            return 1
        }
        display.pointee.on_console_message = { _, browser, _, _, _, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            return 0
        }
        displayPointer = display
    }

    private func makeRequestHandler() {
        let request = Native.allocate(cef_request_handler_t.self, owner: self)
        request.pointee.on_before_browse = { handlerSelf, browser, frame, nativeRequest, userGesture, isRedirect in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            let main = RemoteBrowser.isMain(frame)
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            let url = nativeRequest.map { Native.take($0.pointee.get_url?($0)) } ?? ""
            Native.release(nativeRequest.map(UnsafeMutableRawPointer.init))
            guard main, let owner = RemoteBrowser.owner(handlerSelf) else { return 0 }
            MainActor.assumeIsolated {
                // The spike lets every navigation proceed and tells WSurf. The plan's synchronous decision (rule 2) comes later.
                let message = owner.event(CefRemote.Event.beforeBrowse)
                message.set(CefRemote.Key.url, url)
                message.set(CefRemote.Key.isRedirect, isRedirect != 0)
                message.set(CefRemote.Key.userGesture, userGesture != 0)
                owner.send(message)
            }
            return 0
        }
        request.pointee.on_open_urlfrom_tab = { handlerSelf, browser, frame, targetURL, _, userGesture in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            let url = Native.string(targetURL)
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return 1 }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.popupBlocked)
                message.set(CefRemote.Key.url, url)
                message.set(CefRemote.Key.userGesture, userGesture != 0)
                owner.send(message)
            }
            return 1
        }
        request.pointee.get_auth_credentials = { _, browser, _, _, _, _, _, _, callback in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(callback.map(UnsafeMutableRawPointer.init))
            return 0
        }
        request.pointee.on_certificate_error = { _, browser, _, _, ssl, callback in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(ssl.map(UnsafeMutableRawPointer.init))
            Native.release(callback.map(UnsafeMutableRawPointer.init))
            return 0
        }
        request.pointee.on_render_process_terminated = { handlerSelf, browser, status, code, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.renderTerminated)
                message.set(CefRemote.Key.status, Int64(status.rawValue))
                message.set(CefRemote.Key.code, Int64(code))
                owner.send(message)
            }
        }
        requestPointer = request
    }

    private func makeRenderHandler() {
        let render = Native.allocate(cef_render_handler_t.self, owner: self)
        render.pointee.get_view_rect = { handlerSelf, browser, rect in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let rect else { return }
            let size = RemoteBrowser.owner(handlerSelf).map { owner in MainActor.assumeIsolated { owner.sizeDIP } } ?? CGSize(width: 1, height: 1)
            rect.pointee = cef_rect_t(x: 0, y: 0, width: Int32(max(1, size.width.rounded())), height: Int32(max(1, size.height.rounded())))
        }
        render.pointee.get_screen_info = { handlerSelf, browser, info in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let info, let owner = RemoteBrowser.owner(handlerSelf) else { return 0 }
            let (scale, screen) = MainActor.assumeIsolated { (owner.scale, owner.screenRect) }
            info.pointee.device_scale_factor = Float(scale)
            info.pointee.depth = 24
            info.pointee.depth_per_component = 8
            info.pointee.is_monochrome = 0
            let rect = cef_rect_t(x: Int32(screen.minX.rounded()), y: Int32(screen.minY.rounded()),
                                  width: Int32(screen.width.rounded()), height: Int32(screen.height.rounded()))
            info.pointee.rect = rect
            info.pointee.available_rect = rect
            return 1
        }
        render.pointee.get_screen_point = { handlerSelf, browser, viewX, viewY, screenX, screenY in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let screenX, let screenY, let owner = RemoteBrowser.owner(handlerSelf) else { return 0 }
            let origin = MainActor.assumeIsolated { owner.origin }
            screenX.pointee = Int32((origin.x + CGFloat(viewX)).rounded())
            screenY.pointee = Int32((origin.y + CGFloat(viewY)).rounded())
            return 1
        }
        render.pointee.on_popup_show = { handlerSelf, browser, show in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.presenter.setPopup(visible: show != 0) }
        }
        render.pointee.on_popup_size = { handlerSelf, browser, rect in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let rect, let owner = RemoteBrowser.owner(handlerSelf) else { return }
            let frame = CGRect(x: CGFloat(rect.pointee.x), y: CGFloat(rect.pointee.y),
                               width: CGFloat(rect.pointee.width), height: CGFloat(rect.pointee.height))
            MainActor.assumeIsolated { owner.presenter.setPopup(rect: frame) }
        }
        render.pointee.on_paint = { handlerSelf, browser, type, _, _, buffer, width, height in
            let entry = Clock.nowNanoseconds
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let buffer, let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated {
                owner.noteFirstFrame(entry)
                owner.presenter.present(pixels: buffer, width: Int(width), height: Int(height),
                                        element: type == PET_POPUP ? .popup : .view, entry: entry)
            }
        }
        render.pointee.on_accelerated_paint = { handlerSelf, browser, type, _, _, info in
            let entry = Clock.nowNanoseconds
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let info, let pointer = info.pointee.shared_texture_io_surface, let owner = RemoteBrowser.owner(handlerSelf) else { return }
            let surface = Unmanaged<IOSurfaceRef>.fromOpaque(pointer).takeUnretainedValue()
            MainActor.assumeIsolated {
                owner.noteFirstFrame(entry)
                owner.presenter.present(surface: surface, element: type == PET_POPUP ? .popup : .view, entry: entry)
            }
        }
        render.pointee.on_ime_composition_range_changed = { handlerSelf, browser, range, count, bounds in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            var rects: [Double] = []
            if let bounds {
                for index in 0..<Int(count) {
                    let rect = bounds[index]
                    rects += [Double(rect.x), Double(rect.y), Double(rect.width), Double(rect.height)]
                }
            }
            let from = Int64(range?.pointee.from ?? 0)
            let to = Int64(range?.pointee.to ?? 0)
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.imeRange)
                message.set(CefRemote.Key.rangeFrom, from)
                message.set(CefRemote.Key.rangeTo, to)
                message.set(CefRemote.Key.rects, doubles: rects)
                owner.send(message)
            }
        }
        render.pointee.on_text_selection_changed = { handlerSelf, browser, text, range in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            let selected = Native.string(text)
            let from = Int64(range?.pointee.from ?? 0)
            let to = Int64(range?.pointee.to ?? 0)
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.textSelection)
                message.set(CefRemote.Key.text, selected)
                message.set(CefRemote.Key.rangeFrom, from)
                message.set(CefRemote.Key.rangeTo, to)
                owner.send(message)
            }
        }
        render.pointee.get_accessibility_handler = { handlerSelf in
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return nil }
            let address = MainActor.assumeIsolated { owner.accessibilityHandler().map { Int(bitPattern: $0) } ?? 0 }
            guard let pointer = UnsafeMutablePointer<cef_accessibility_handler_t>(bitPattern: address) else { return nil }
            Native.retain(UnsafeMutableRawPointer(pointer))
            return pointer
        }
        render.pointee.start_dragging = { _, browser, dragData, _, _, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(dragData.map(UnsafeMutableRawPointer.init))
            return 0
        }
        renderPointer = render
    }

    private func noteFirstFrame(_ entry: UInt64) {
        guard firstFrameAt == 0 else { return }
        firstFrameAt = entry
        note("browser \(id): first frame after \(String(format: "%.1f", Double(entry &- createdAt) / 1e6)) ms (accelerated \(presenter.acceleratedFrames), cpu \(presenter.cpuFrames))")
    }

    private func makeKeyboardHandler() {
        let keyboard = Native.allocate(cef_keyboard_handler_t.self, owner: self)
        keyboard.pointee.on_pre_key_event = { _, browser, _, _, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            return 0
        }
        keyboard.pointee.on_key_event = { handlerSelf, browser, event, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let event, let owner = RemoteBrowser.owner(handlerSelf) else { return 0 }
            let copy = event.pointee
            MainActor.assumeIsolated {
                // The page did not take this key: WSurf may act on it (its own shortcuts, the unhandled-key beep).
                let message = owner.event(CefRemote.Event.unhandledKey)
                message.set(CefRemote.Key.keyType, Int64(copy.type.rawValue))
                message.set(CefRemote.Key.modifiers, Int64(copy.modifiers))
                message.set(CefRemote.Key.windowsKeyCode, Int64(copy.windows_key_code))
                message.set(CefRemote.Key.nativeKeyCode, Int64(copy.native_key_code))
                message.set(CefRemote.Key.character, Int64(copy.character))
                owner.send(message)
            }
            return 0
        }
        keyboardPointer = keyboard
    }

    private func makeFocusHandler() {
        let focus = Native.allocate(cef_focus_handler_t.self, owner: self)
        focus.pointee.on_take_focus = { handlerSelf, browser, next in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.takeFocus)
                message.set(CefRemote.Key.forward, next != 0)
                owner.send(message)
            }
        }
        focus.pointee.on_set_focus = { _, browser, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            return 0
        }
        focus.pointee.on_got_focus = { handlerSelf, browser in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated { owner.send(owner.event(CefRemote.Event.gotFocus)) }
        }
        focusPointer = focus
    }

    private func makeContextMenuHandler() {
        let menu = Native.allocate(cef_context_menu_handler_t.self, owner: self)
        menu.pointee.on_before_context_menu = { _, browser, frame, params, model in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            Native.release(params.map(UnsafeMutableRawPointer.init))
            Native.release(model.map(UnsafeMutableRawPointer.init))
        }
        menu.pointee.run_context_menu = { handlerSelf, browser, frame, params, model, callback in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            defer {
                Native.release(params.map(UnsafeMutableRawPointer.init))
                Native.release(model.map(UnsafeMutableRawPointer.init))
            }
            guard let model, let callback, let owner = RemoteBrowser.owner(handlerSelf) else {
                Native.release(callback.map(UnsafeMutableRawPointer.init))
                return 0
            }
            let x = params?.pointee.get_xcoord?(params) ?? 0
            let y = params?.pointee.get_ycoord?(params) ?? 0
            // The callback's reference is now the browser's, released when WSurf answers or the menu is cancelled.
            MainActor.assumeIsolated { owner.runContextMenu(x: x, y: y, model: model, callback: callback) }
            return 1
        }
        menu.pointee.on_context_menu_command = { _, browser, frame, params, _, _ in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
            Native.release(params.map(UnsafeMutableRawPointer.init))
            return 0
        }
        menu.pointee.on_context_menu_dismissed = { _, browser, frame in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            Native.release(frame.map(UnsafeMutableRawPointer.init))
        }
        contextMenuPointer = menu
    }

    /// The accessibility handler, made on first use: CEF asks for it only once accessibility is on.
    private func accessibilityHandler() -> UnsafeMutablePointer<cef_accessibility_handler_t>? {
        if let accessibilityPointer {
            return accessibilityPointer
        }
        let handler = Native.allocate(cef_accessibility_handler_t.self, owner: self)
        handler.pointee.on_accessibility_tree_change = { handlerSelf, value in
            defer { Native.release(value.map(UnsafeMutableRawPointer.init)) }
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            let data = AccessibilityJSON.data(value)
            MainActor.assumeIsolated { owner.sendAccessibility(CefRemote.Event.accessibilityTree, data) }
        }
        handler.pointee.on_accessibility_location_change = { handlerSelf, value in
            defer { Native.release(value.map(UnsafeMutableRawPointer.init)) }
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            let data = AccessibilityJSON.data(value)
            MainActor.assumeIsolated { owner.sendAccessibility(CefRemote.Event.accessibilityLocation, data) }
        }
        accessibilityPointer = handler
        return handler
    }

    private func sendAccessibility(_ name: String, _ data: Data) {
        let message = event(name)
        message.set(CefRemote.Key.data, data: data)
        send(message)
    }

    private func makeFindHandler() {
        let find = Native.allocate(cef_find_handler_t.self, owner: self)
        find.pointee.on_find_result = { handlerSelf, browser, identifier, count, _, active, final in
            Native.release(browser.map(UnsafeMutableRawPointer.init))
            guard let owner = RemoteBrowser.owner(handlerSelf) else { return }
            MainActor.assumeIsolated {
                let message = owner.event(CefRemote.Event.findResult)
                message.set(CefRemote.Key.identifier, Int64(identifier))
                message.set(CefRemote.Key.count, Int64(count))
                message.set(CefRemote.Key.active, Int64(active))
                message.set(CefRemote.Key.final, final != 0)
                owner.send(message)
            }
        }
        findPointer = find
    }
}
