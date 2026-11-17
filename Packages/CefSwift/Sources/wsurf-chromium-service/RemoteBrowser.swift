// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-4b: one windowless browser in the service. WSurf keeps every policy: this class forwards what its page does as events,
// does what WSurf asks, and keeps what must be answered at once to a safe default. Its frames go through `FramePresenter`
// (D4-7). Geometry changes (D4-9) and input (phase 3) are not here. Everything runs on the main thread, which is CEF's UI thread.
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
    let box = BrowserBox()
    private(set) var raw: UnsafeMutablePointer<cef_browser_t>?
    private(set) var isClosing = false
    var hasClosed = false
    /// CEF was asked to make the browser and has not yet said so (`on_after_created`).
    private var creationPending = false

    /// This browser's +1 on its client (the client owns the handlers). Given up in `deinit`: not at the close, because CEF may
    /// still call the client's getters on another thread.
    private var clientPointer: UnsafeMutablePointer<cef_client_t>?
    var observerPointer: UnsafeMutablePointer<cef_dev_tools_message_observer_t>?
    var registration: UnsafeMutablePointer<cef_registration_t>?

    /// What WSurf asked for before CEF made the browser.
    private var pending: [(UnsafeMutablePointer<cef_browser_host_t>) -> Void] = []

    private(set) var sizeDIP: CGSize
    private(set) var scale: CGFloat
    /// The screen the page is on, as WSurf last said (`browser.resize`); nil until it did, and then `get_screen_info` describes the view.
    private(set) var screenDIP: CGRect?
    /// `browser.visibility` messages received (`debug.stats`).
    private var visibilityMessages = 0
    let presenter: FramePresenter
    /// What `debug.stats` reports of the input this browser was given (`RemoteBrowser+Input`).
    var inputStats = InputStatistics()

    var nextServiceCommand = CefRemote.serviceCommandBase
    /// The service's own `Page.resetNavigationHistory`, by its CDP id: WSurf's request id.
    var collapses: [Int64: Int64] = [:]
    var historyCommand: Int64?
    var historyDirty = false
    var historyMismatches = 0
    /// A read that disagreed with the visitor is to be made again in a moment (the 50 ms wait in `historyResult`).
    var historyRetryPending = false
    /// Ends the wait for the read in flight if Chromium never answers it (review F8).
    var historyTimer: DispatchWorkItem?
    var consecutiveHistoryTimeouts = 0
    static let historyReadTimeout: TimeInterval = 2
    /// The last list sent, ids included: what a `collapseHistory` is checked against (and the native list against it).
    var lastHistory: [CefRemote.HistoryEntry]?

    struct ParkedCollapse {
        let request: Int64
        let keep: Int64
        let expected: [Int64]
    }

    /// Collapse requests that arrived while the cached list might be stale: they run when it is fresh (review F5).
    var parkedCollapses: [ParkedCollapse] = []
    #if WSURF_SERVICE_DEBUG_OPS
    /// How many of the next history reads are held back (`debug.holdHistory`): sent to nobody (delay 0, as a read whose renderer went
    /// away), or answered only after `heldHistoryDelay` seconds (a read that is slow).
    var heldHistoryReads = 0
    var heldHistoryDelay: TimeInterval = 0
    var delayNextResult: TimeInterval = 0
    #endif

    init(id: Int64, message: CefRemoteMessage) {
        self.id = id
        sizeDIP = CGSize(width: max(1, message.double(CefRemote.Key.width)), height: max(1, message.double(CefRemote.Key.height)))
        scale = max(1, message.double(CefRemote.Key.scale))
        presenter = FramePresenter(browser: id)
        presenter.hidden = message.bool(CefRemote.Key.hidden)
        ServiceCounters.browsers.withLock { $0 += 1 }
        box.browser = self
        presenter.repaint = { [weak self] in self?.requestFrame() }
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
        // Frames arrive as IOSurfaces (`on_accelerated_paint`), which `FramePresenter` copies; the DEBUG `cpuPaint` asks for the
        // memory path (`on_paint`) instead, which is what a session without a GPU path would take.
        info.shared_texture_enabled = 1
        #if WSURF_SERVICE_DEBUG_OPS
        if debug == CefRemote.DebugCreate.cpuPaint {
            info.shared_texture_enabled = 0
        }
        if debug == CefRemote.DebugCreate.smallSourceCache {
            presenter.sourceTextureLimit = 1
        }
        #endif
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
        #if WSURF_SERVICE_DEBUG_OPS
        if started == 1, debug == CefRemote.DebugCreate.closeFirst {
            // CEF makes the browser in a later task (`on_after_created`), so this close always comes first.
            requestClose()
        }
        #endif
        return started == 1
    }

    func didCreate(_ browser: UnsafeMutablePointer<cef_browser_t>) {
        creationPending = false
        // This runs inside `on_after_created`: a close is never made here, only after it (`Native.closeLater`).
        guard !hasClosed else {
            Native.closeLater(browser)
            return
        }
        Native.retain(UnsafeMutableRawPointer(browser))
        raw = browser
        if isClosing {
            // A close arrived while CEF was still making the browser: it is closed next, and `didClose` ends it.
            Native.closeLater(browser)
            return
        }
        guard let host = hostReference() else { return }
        defer { Native.release(UnsafeMutableRawPointer(host)) }
        attachDevTools(host)
        if presenter.hidden {
            host.pointee.was_hidden?(host, 1)
        }
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
        presenter.freeRing()
        ServiceHost.shared.browserDidClose(id)
    }

    func didClose() {
        guard !hasClosed else { return }
        hasClosed = true
        pending.removeAll()
        presenter.freeRing()
        historyTimer?.cancel()
        historyTimer = nil
        answerParkedCollapses(.refused)
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
    func hostReference() -> UnsafeMutablePointer<cef_browser_host_t>? {
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

    func withBrowserLater(_ body: @escaping (UnsafeMutablePointer<cef_browser_t>) -> Void) {
        withHost { [weak self] _ in
            guard let raw = self?.raw else { return }
            body(raw)
        }
    }

    func send(_ message: CefRemoteMessage) {
        ServiceHost.shared.send(message)
    }

    func event(_ name: String) -> CefRemoteMessage {
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
        case CefRemote.Op.resize:
            accepted()
            resize(message)
        case CefRemote.Op.visibility:
            let hidden = message.bool(CefRemote.Key.hidden)
            let parked = message.bool(CefRemote.Key.parked)
            accepted()
            visibilityMessages += 1
            setVisibility(hidden: hidden, parked: parked)
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

    /// `browser.resize`: the view's size in points, the backing scale and the screen. The values are taken now, so that CEF's next
    /// `get_view_rect` and `get_screen_info` (on this thread) answer with them; CEF is told in the browser's own turn (or once the
    /// browser exists): `was_resized` for a new size, `notify_screen_info_changed` for a new scale or screen.
    private func resize(_ message: CefRemoteMessage) {
        let size = CGSize(width: max(1, message.double(CefRemote.Key.width)), height: max(1, message.double(CefRemote.Key.height)))
        let newScale = max(1, message.double(CefRemote.Key.scale))
        let screen = message.has(CefRemote.Key.screenWidth)
            ? CGRect(x: message.double(CefRemote.Key.screenX), y: message.double(CefRemote.Key.screenY),
                     width: max(1, message.double(CefRemote.Key.screenWidth)), height: max(1, message.double(CefRemote.Key.screenHeight)))
            : nil
        let sizeChanged = size != sizeDIP
        let screenChanged = newScale != scale || screen != screenDIP
        sizeDIP = size
        scale = newScale
        screenDIP = screen
        guard sizeChanged || screenChanged else { return }
        withHost { host in
            if screenChanged {
                host.pointee.notify_screen_info_changed?(host)
            }
            if sizeChanged || screenChanged {
                host.pointee.was_resized?(host)
            }
        }
    }

    /// What `debug.stats` reports of the geometry: the view's size in points and the backing scale, as CEF is told them.
    func geometry(into message: CefRemoteMessage) {
        message.set(CefRemote.Key.width, Double(sizeDIP.width))
        message.set(CefRemote.Key.height, Double(sizeDIP.height))
        message.set(CefRemote.Key.scale, Double(scale))
        message.set(CefRemote.Key.visibilityMessages, visibilityMessages)
    }

    /// `hidden`: Chromium stops painting (`was_hidden`) and the ring is freed; it is built again by the first frame after the page
    /// is shown. `parked`: the page is visible to itself but not to the person, so its frames are dropped.
    private func setVisibility(hidden newHidden: Bool, parked newParked: Bool) {
        let wasShown = !presenter.hidden && !presenter.parked
        let hiddenChanged = newHidden != presenter.hidden
        presenter.hidden = newHidden
        presenter.parked = newParked
        let shown = !newHidden && !newParked
        withHost { host in
            if hiddenChanged {
                host.pointee.was_hidden?(host, newHidden ? 1 : 0)
            }
            if shown, !wasShown {
                // A still page sends no frame of its own after it comes back: ask for one.
                host.pointee.invalidate?(host, PET_VIEW)
            }
        }
    }

    /// Asks Chromium for a frame of the whole view, when the page is shown: a frames connection that attaches after a still page
    /// painted would otherwise wait for the page's next change.
    func requestFrame() {
        guard !presenter.hidden, !presenter.parked else { return }
        withHost { $0.pointee.invalidate?($0, PET_VIEW) }
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
        // Both ways, not only when loading ends: a collapse that arrives while a read of an unchanged list is in flight must wait for
        // that read's result (`aCollapseThatArrivesWhileAReadOfAnUnchangedListIsInFlightWaitsForItsResult`, review F5), and the read
        // that is in flight is the one this loading start asks for.
        refreshHistory()
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
        // The visible entry's own title wins over the display title (which is the address for an untitled page), as WSurf reads it
        // in process, and its SSL status comes with it.
        addVisibleState(to: message)
        send(message)
        refreshHistory()
    }

    func progressChanged(_ progress: Double) {
        let message = event(CefRemote.Event.progress)
        message.set(CefRemote.Key.progress, progress)
        send(message)
    }

    func renderProcessTerminated(status: Int64, code: Int64) {
        // A read that the lost renderer was to answer never will be.
        abandonHistoryRead()
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
    func mayNavigate(to url: String, isRedirect: Bool, userGesture: Bool, details: NavigationDetails = NavigationDetails()) -> Bool {
        // A browser being closed goes nowhere (its first load starts before a close taken during its creation is made).
        guard !isClosing else { return false }
        return ServiceHost.shared.askNavigation(browser: id, url: url, isRedirect: isRedirect, userGesture: userGesture, details: details)
    }

    /// A navigation to a scheme WSurf does not load (`mailto:`, `tel:`, an app's own) was cancelled here. WSurf is told, one way, so
    /// that it can offer the app that handles it, as it does for a tab in process (review D1). A page can trigger this as often as it
    /// likes, so at most `externalLimit` events go out in `externalWindow` seconds per browser, and an address over `maxExternalURL`
    /// bytes is not sent at all. The cancel does not depend on any of this.
    func refusedScheme(url: String, isMain: Bool, userGesture: Bool, source: String) {
        guard !isClosing, url.utf8.count <= Self.maxExternalURL, externalRate.allow(at: Double(Clock.nowNanoseconds) / 1e9) else {
            ServiceCounters.droppedExternalSchemes.withLock { $0 += 1 }
            return
        }
        let message = event(CefRemote.Event.externalScheme)
        message.set(CefRemote.Key.url, url)
        message.set(CefRemote.Key.isMain, isMain)
        message.set(CefRemote.Key.userGesture, userGesture)
        message.set(CefRemote.Key.sourceURL, source)
        send(message)
    }

    private static let maxExternalURL = 8192
    private var externalRate = CefRemoteRateLimit(maxEvents: 3, window: 10)

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
}
