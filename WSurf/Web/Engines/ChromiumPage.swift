// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import CCef
import CefKit
import Foundation
import MachO
import WebKit

@MainActor
final class ChromiumPage: NSView {
    let context: BrowserProfileContext
    var profileID: UUID {
        context.profile.id
    }
    var isPrivate: Bool {
        context.profile.isPrivate
    }
    weak var owner: BrowserPage?
    private(set) var browserID: Int32 = -1
    private(set) var isClosed = false
    private var raw: UnsafeMutablePointer<cef_browser_t>?
    private(set) var client: ChromiumClient?
    private(set) lazy var devTools = ChromiumDevTools(page: self)
    /// D4 spike: the browser in the out-of-process service (OOP mode only), its remote layer and the cursor it asked for.
    var remote: ChromiumRemoteBrowser?
    var remoteLayer: CALayer?
    var remoteCursor: NSCursor = .arrow
    /// D4 spike: input state of the out-of-process page (`ChromiumPage+RemoteInput`).
    var remoteInput = ChromiumRemoteInputState()
    var isClosing: Bool {
        closing
    }
    private var preparation: Task<Void, Error>?
    private var pendingLoad: Task<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var closing = false
    private var nativeView: NSView? {
        withHost { host in
            host.pointee.get_window_handle?(host).map {
                Unmanaged<NSView>.fromOpaque($0).takeUnretainedValue()
            }
        } ?? nil
    }

    private(set) var navigation: PageNavigation? {
        didSet { client?.documentResponses.reset() }
    }
    private(set) var history = PageHistoryList()
    private var requestedURL: URL?
    private var awaitingNativeNavigation = false
    /// The address of a same-document move the engine reported before it reported the address.
    private var awaitedMoveAddress: URL?
    private var navigationStarted = false
    private var initialDocument = true
    /// Chromium records the startup about:blank as a real history entry. The first commit starts the reset that drops it.
    /// Until a reset has dropped it, it stays Chromium's first entry and Back never goes there (`nativeCanGoBack`,
    /// `loadHistory`). `kept`: no reset dropped it, because none landed or the history grew before one could.
    enum StartupEntry {
        case inHistory, resetting, dropped, kept
    }
    private(set) var startupEntry = StartupEntry.inHistory
    /// Moves on when a main-frame navigation is requested, starts or commits, or the renderer is lost (`load`,
    /// `willNavigate`, `didStartLoad`, `didTerminate`). It proves a request made before the tab committed any document.
    private(set) var mainFrameGeneration: UInt64 = 0
    private static let startupResetAttempts = 10
    private static let startupResetRetryDelay: Duration = .milliseconds(100)
    /// Test seam: runs in place of the `Page.resetNavigationHistory` command; a throw is a refused reset.
    var startupResetCommand: (@MainActor () async throws -> Void)?
    /// Times `closeTimeout` (ChromiumPage+Close.swift). Test seams: a clock, and losing CEF's `on_before_close`.
    var closeClock: any Clock<Duration> = ContinuousClock()
    var dropsCloseAnswerForTesting = false
    private(set) var htmlDocumentURL: URL?
    private var hasAppliedInitialSettings = false
    /// Whether `applySettings` left a user agent override in place, so a later return to the engine's own string clears it.
    var hasUserAgentOverride = false
    private var zoom: CGFloat = 1
    var navigationDecision: ((URLRequest, Bool, Bool, Bool, WKNavigationType, URL?, BrowserFrame?) -> Bool)?
    /// A link the person opened in a new tab (middle-click, Command-click): a plain tab, with no opener.
    var openWindow: ((URL, Bool, URL?, BrowserFrame?, ClickDisposition) -> Void)?
    /// A pop-up the page opened (`window.open`, `target=_blank`). Returns the page to host the browser CEF makes for it, which keeps `window.opener`; nil cancels it.
    var openPopup: ((URL, Bool, URL?, BrowserFrame?, ClickDisposition) -> ChromiumPage?)?
    /// `window.open` was called, before the engine's pop-up blocker decided: address and whether a click was behind it.
    var windowOpenAttempt: ((URL, Bool) -> Void)?
    /// This page's pop-ups CEF has not made yet, by pop-up ID: held, so a view CEF may still make a browser in stays alive.
    var pendingPopups: [Int32: ChromiumPage] = [:]
    /// While CEF makes this pop-up page's browser: its address, and the end of its opener's hold on it.
    private var popupInCreation: (address: URL, release: @MainActor () -> Void)?
    private var popupWaiters: [CheckedContinuation<Void, Never>] = []
    /// How a link chosen from the context menu is opened.
    nonisolated enum LinkOpening {
        case tab, window, privateWindow
    }
    /// An Open item of the context menu was chosen: the address, the address of the frame it is in, and how to open it.
    var openLinkFromMenu: ((URL, URL?, LinkOpening) -> Void)?
    /// Another WSurf item of the context menu was chosen.
    var onContextAction: ((ChromiumClient.ContextAction) -> Void)?
    /// What the open context menu was opened on, for WSurf's items of it (`ChromiumClient.offerContextItems`).
    var contextTarget: ChromiumClient.ContextTarget?
    var captureChanged: ((Bool, Bool) -> Void)?
    /// A screen share this page was granted. `captureChanged` reports device capture only.
    var displayCaptureStarted: (() -> Void)?
    var onCloseRequested: (() -> Void)?
    /// Pick Credential…: whether the tab offers it now (`CredentialPicker.isOffered`), and what choosing it does. `ChromiumClient` adds
    /// the item to an editable field's menu.
    var canPickCredential: (() -> Bool)?
    var onPickCredential: ((CredentialPicker.Menu) -> Void)?
    /// The PDF items of the context menu: whether the tab shows a PDF it can save now (`BrowserTab.shownPDF`), and what choosing
    /// Download PDF (false) or Open in Preview (true) does (`BrowserTab.savePDF`). `ChromiumClient` adds the items.
    var showsPDF: (() -> Bool)?
    var onSavePDF: ((Bool) -> Void)?
    /// Inspect Element: whether the tab offers it now (`BrowserTab.canShowWebInspector`). `ChromiumClient` adds the item to the menu.
    var canInspect: (() -> Bool)?
    let find = ChromiumFind()
    var baseColorScheme: DevelopmentMedia.ColorScheme?
    var leaseMedia = DevelopmentMedia()
    var permissionDecision: ((BrowserFrame, [WebPermission]) async -> Bool)?
    var downloadDecision: ((CefDownload, String, @escaping (CefDownloadDecision) -> Void) -> Void)?
    var downloadProgress: ((CefDownload) -> Void)?

    /// `popup`: a pop-up CEF is about to make here (`hostPopup`); until then the page makes no browser of its own, even when shown.
    init(context: BrowserProfileContext, popup: URL? = nil) {
        self.context = context
        popupInCreation = popup.map { ($0, {}) }
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        nil
    }
    override var isFlipped: Bool {
        true
    }
    override var acceptsFirstResponder: Bool {
        !isClosed
    }

    override func becomeFirstResponder() -> Bool {
        guard !isClosed else { return false }
        if let remote {
            remote.send(CefRemote.Op.focus) { $0.set(CefRemote.Key.flag, true) }
            return true
        }
        withHost { $0.pointee.set_focus?($0, 1) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        remote?.send(CefRemote.Op.focus) { $0.set(CefRemote.Key.flag, false) }
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isRemote {
            // D4 spike: the service makes the browser; nothing here waits for it.
            if window != nil, remote == nil, !awaitsPopup, !closing, !isClosed {
                do {
                    try materializeRemote()
                } catch {
                    owner?.onNavigationFailed?(navigation, error)
                }
            }
            if window != nil {
                for waiter in attachmentWaiters {
                    waiter.resume()
                }
                attachmentWaiters.removeAll()
            }
            updateRemoteGeometry()
            return
        }
        guard window != nil, raw == nil, !awaitsPopup, !closing, !isClosed else { return }
        do {
            defer {
                for waiter in attachmentWaiters {
                    waiter.resume()
                }
                attachmentWaiters.removeAll()
            }
            // A profile still loading from disk gets its browser in `ensureReady`, once it has loaded.
            guard try ChromiumRuntime.shared.startContext(for: context) else { return }
            try materialize()
        } catch {
            owner?.onNavigationFailed?(navigation, error)
        }
    }

    override func layout() {
        super.layout()
        if isRemote {
            updateRemoteGeometry()
            return
        }
        nativeView?.frame = bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isRemote {
            updateRemoteGeometry()
        }
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRemoteVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRemoteVisibility()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if isRemote {
            updateRemoteGeometry()
        }
    }

    func materialize() throws {
        if isRemote {
            try materializeRemote()
            return
        }
        guard !closing, !isClosed else { throw ChromiumError.closed }
        guard raw == nil else { return }
        guard window != nil else {
            throw ChromiumError.unavailable(String(localized: "Chromium requires an attached browser view."))
        }
        let client = ChromiumClient(page: self)
        let pointer = client.makeClient()
        defer {
            if raw == nil {
                client.close()
            }
        }
        var info = cef_window_info_t()
        info.size = MemoryLayout<cef_window_info_t>.stride
        embed(in: &info)
        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.stride
        Self.configureBrowserSettings(&settings, settings: context.settings)
        let created = try ChromiumRuntime.shared.withContext(for: context) { context in
            ChromiumInterop.retain(UnsafeMutableRawPointer(pointer))
            ChromiumInterop.retain(UnsafeMutableRawPointer(context))
            return ChromiumInterop.withString("about:blank") { url in
                cef_browser_host_create_browser_sync(&info, pointer, url, &settings, nil, context)
            }
        }
        guard let created else {
            throw ChromiumError.unavailable(String(localized: "Chromium could not open this tab."))
        }
        self.client = client
        try adopt(created, popup: false)
    }

    /// A browser CEF makes goes in this view, at its size.
    private func embed(in info: inout cef_window_info_t) {
        info.parent_view = Unmanaged.passUnretained(self).toOpaque()
        info.bounds = cef_rect_t(x: 0, y: 0,
            width: Int32(max(1, bounds.width.rounded())), height: Int32(max(1, bounds.height.rounded())))
        info.runtime_style = CEF_RUNTIME_STYLE_ALLOY
    }

    /// Takes `browser`, whose reference is now this page's: its DevTools, then the preparation every load waits for. A pop-up's
    /// first document predates its scripts, so they also run once there (`runScriptsInEarlierDocuments`).
    private func adopt(_ browser: UnsafeMutablePointer<cef_browser_t>, popup: Bool) throws {
        raw = browser
        browserID = browser.pointee.get_identifier?(browser) ?? -1
        ChromiumRuntime.shared.register(self)
        // CefKit keeps its message-pump safety net while a browser is alive, and stops it when none is.
        CefRuntime.shared.externalBrowserDidOpen()
        do {
            withHost { $0.pointee.set_accessibility_state?($0, STATE_ENABLED) }
            guard let attached = try withHost({ host in try devTools.attach(to: host) }) else {
                throw ChromiumError.closed
            }
            _ = attached
            preparation = Task { [weak self] in
                guard let self else { throw ChromiumError.closed }
                try await devTools.prepare(marksNewDocuments: popup)
                if popup {
                    await devTools.runScriptsInEarlierDocuments()
                }
                pageZoom = zoom
            }
        } catch {
            withHost { $0.pointee.close_browser?($0, 1) }
            throw error
        }
        nativeView?.frame = bounds
        nativeView?.autoresizingMask = [.width, .height]
    }

    /// D4 spike: takes the service's browser as `adopt` takes CEF's: the DevTools pipe, then the preparation every load waits for.
    func adoptRemote(_ browser: ChromiumRemoteBrowser) throws {
        browserID = Int32(truncatingIfNeeded: browser.id)
        ChromiumRuntime.shared.register(self)
        try devTools.attach(remote: browser)
        preparation = Task { [weak self] in
            guard let self else { throw ChromiumError.closed }
            try await devTools.prepare(marksNewDocuments: false)
            pageZoom = zoom
        }
    }

    /// D4 spike: the service ended with this page's browser in it. The page keeps its address and is left with no browser, as
    /// after a renderer crash; the tab's crash handling reloads it, which asks a new service for a new browser.
    func resetAfterServiceEnd() {
        guard remote != nil else { return }
        remote = nil
        pendingLoad?.cancel()
        preparation?.cancel()
        preparation = nil
        devTools.close()
        devTools = ChromiumDevTools(page: self)
        startupEntry = .inHistory
        initialDocument = true
        hasAppliedInitialSettings = false
        awaitingNativeNavigation = false
        ChromiumRuntime.shared.unregister(self)
        didTerminate()
    }

    func ensureReady() async throws {
        guard !isClosed, !closing else { throw ChromiumError.closed }
        if isRemote {
            if remote == nil {
                try materializeRemote()
            }
        } else {
            if raw == nil, awaitsPopup {
                await withCheckedContinuation { popupWaiters.append($0) }
                guard !isClosed, !closing else { throw ChromiumError.closed }
            }
            if raw == nil {
                try await ChromiumRuntime.shared.prepareContext(for: context)
                guard !isClosed, !closing else { throw ChromiumError.closed }
                try materialize()
            }
        }
        guard let preparation else { throw ChromiumError.closed }
        try await preparation.value
        guard !isClosed, !closing else { throw ChromiumError.closed }
    }

    func withBrowser<T>(_ body: (UnsafeMutablePointer<cef_browser_t>) throws -> T) rethrows -> T? {
        guard let raw else { return nil }
        return try body(raw)
    }

    func withHost<T>(_ body: (UnsafeMutablePointer<cef_browser_host_t>) throws -> T) rethrows -> T? {
        guard let raw, let host = raw.pointee.get_host?(raw) else { return nil }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(host)) }
        return try body(host)
    }

    /// The engine's own mute of the page: every frame and every kind of sound, a frame of another site (which no WSurf script
    /// reaches) and Web Audio included. It stays across navigations, like the tab's mute does.
    func setAudioMuted(_ muted: Bool) {
        if let remote {
            remote.isMuted = muted
            remote.send(CefRemote.Op.mute) { $0.set(CefRemote.Key.flag, muted) }
            return
        }
        withHost { $0.pointee.set_audio_muted?($0, muted ? 1 : 0) }
    }

    var isAudioMuted: Bool {
        if let remote {
            return remote.isMuted
        }
        return withHost { ($0.pointee.is_audio_muted?($0) ?? 0) != 0 } ?? false
    }

    func command(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try await devTools.command(method, params: params)
    }
    func sourceFrame(for referrer: URL?) -> BrowserFrame? {
        devTools.sourceFrame(for: referrer)
    }

    @discardableResult
    func load(_ request: URLRequest) -> PageNavigation? {
        guard !isClosed, !closing, let url = request.url else { return nil }
        pendingLoad?.cancel()
        mainFrameGeneration &+= 1
        let next = PageNavigation()
        navigation = next
        requestedURL = url
        htmlDocumentURL = nil
        awaitingNativeNavigation = true
        navigationStarted = false
        owner?.isLoading = true
        owner?.estimatedProgress = 0
        pendingLoad = Task { [weak self] in
            guard let self else { return }
            do {
                // Loads may be requested before SwiftUI attaches the view. Attachment starts preparation.
                if window == nil {
                    await withCheckedContinuation { continuation in
                        attachmentWaiters.append(continuation)
                    }
                }
                guard !Task.isCancelled, navigation === next else { return }
                try await ensureReady()
                guard !Task.isCancelled, navigation === next else { return }
                if !hasAppliedInitialSettings {
                    try await applySettings(context.settings)
                    hasAppliedInitialSettings = true
                }
                guard !Task.isCancelled, navigation === next else { return }
                try loadNative(request)
            } catch {
                guard !Task.isCancelled, navigation === next else { return }
                owner?.isLoading = false
                owner?.onNavigationFailed?(next, error)
            }
        }
        return next
    }

    private var attachmentWaiters: [CheckedContinuation<Void, Never>] = []

    private typealias RequestFactories = (
        request: @convention(c) () -> UnsafeMutablePointer<cef_request_t>?,
        post: @convention(c) () -> UnsafeMutablePointer<cef_post_data_t>?,
        element: @convention(c) () -> UnsafeMutablePointer<cef_post_data_element_t>?
    )

    // CefSwift loads CEF dynamically but does not trampoline these request factories.
    private static let requestFactories = Result<RequestFactories, Error> {
        for index in 0..<_dyld_image_count() {
            guard let path = _dyld_get_image_name(index), let name = strrchr(path, 47),
                  strcmp(name.advanced(by: 1), "Chromium Embedded Framework") == 0 else { continue }
            guard let library = dlopen(path, RTLD_LAZY | RTLD_NOLOAD) else {
                throw ChromiumError.unavailable("Chromium request API could not be opened.")
            }
            defer { dlclose(library) }
            func symbol<T>(_ name: String, as type: T.Type) throws -> T {
                guard let pointer = dlsym(library, name) else {
                    throw ChromiumError.unavailable("Chromium request API is missing \(name).")
                }
                return unsafeBitCast(pointer, to: type)
            }
            return (
                try symbol("cef_request_create", as: (@convention(c) () -> UnsafeMutablePointer<cef_request_t>?).self),
                try symbol("cef_post_data_create", as: (@convention(c) () -> UnsafeMutablePointer<cef_post_data_t>?).self),
                try symbol("cef_post_data_element_create", as: (@convention(c) () -> UnsafeMutablePointer<cef_post_data_element_t>?).self)
            )
        }
        throw ChromiumError.unavailable("Chromium request API is not loaded.")
    }

    private func loadNative(_ request: URLRequest) throws {
        if let remote, let url = request.url {
            // D4 spike: a plain GET only; requests with a body or headers are out of the spike's scope.
            guard (request.httpMethod ?? "GET").uppercased() == "GET", request.httpBody == nil, request.httpBodyStream == nil,
                  request.allHTTPHeaderFields?.isEmpty != false else {
                throw ChromiumError.unavailable("Out-of-process Chromium (spike) loads GET requests only.")
            }
            remote.send(CefRemote.Op.load) { $0.set(CefRemote.Key.url, url.absoluteString) }
            return
        }
        guard let raw, let frame = raw.pointee.get_main_frame?(raw), let url = request.url else {
            throw ChromiumError.closed
        }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(frame)) }
        if (request.httpMethod ?? "GET").uppercased() == "GET",
           request.httpBody == nil, request.httpBodyStream == nil,
           request.allHTTPHeaderFields?.isEmpty != false {
            guard let loadURL = frame.pointee.load_url else { throw ChromiumError.closed }
            ChromiumInterop.withString(url.absoluteString) { loadURL(frame, $0) }
            return
        }
        // CEF LoadRequest rejects cross-origin initiators; never replace a body/header request with a GET.
        let currentURL = URL(string: ChromiumInterop.takeString(frame.pointee.get_url?(frame)))
        guard !SitePermissions.origin(for: url).isEmpty,
              SitePermissions.origin(for: currentURL) == SitePermissions.origin(for: url),
              request.httpBodyStream == nil else {
            throw ChromiumError.unavailable("Chromium requires an existing same-origin document for this request.")
        }
        let factories = try Self.requestFactories.get()
        guard let nativeRequest = factories.request() else { throw ChromiumError.closed }
        var requestTransferred = false
        defer {
            if !requestTransferred {
                ChromiumInterop.release(UnsafeMutableRawPointer(nativeRequest))
            }
        }
        ChromiumInterop.withString(url.absoluteString) { nativeRequest.pointee.set_url?(nativeRequest, $0) }
        ChromiumInterop.withString(request.httpMethod ?? "GET") { nativeRequest.pointee.set_method?(nativeRequest, $0) }
        if let headers = request.allHTTPHeaderFields {
            for (name, value) in headers {
                ChromiumInterop.withString(name) { key in
                    ChromiumInterop.withString(value) { nativeRequest.pointee.set_header_by_name?(nativeRequest, key, $0, 1) }
                }
            }
        }
        if let body = request.httpBody {
            guard let post = factories.post() else { throw ChromiumError.unavailable("Chromium could not create the request body.") }
            var postTransferred = false
            defer {
                if !postTransferred {
                    ChromiumInterop.release(UnsafeMutableRawPointer(post))
                }
            }
            guard let element = factories.element() else { throw ChromiumError.unavailable("Chromium could not create the request body.") }
            var elementTransferred = false
            defer {
                if !elementTransferred {
                    ChromiumInterop.release(UnsafeMutableRawPointer(element))
                }
            }
            body.withUnsafeBytes { element.pointee.set_to_bytes?(element, $0.count, $0.baseAddress) }
            guard let addElement = post.pointee.add_element else {
                throw ChromiumError.unavailable("Chromium could not create the request body.")
            }
            _ = addElement(post, element)
            elementTransferred = true
            guard let setPostData = nativeRequest.pointee.set_post_data else {
                throw ChromiumError.unavailable("Chromium could not create the request body.")
            }
            setPostData(nativeRequest, post)
            postTransferred = true
        }
        guard let loadRequest = frame.pointee.load_request else { throw ChromiumError.closed }
        loadRequest(frame, nativeRequest)
        requestTransferred = true
    }

    @discardableResult
    func loadHTML(_ html: String, baseURL: URL?) -> PageNavigation? {
        // A real data document; the base element controls relative resources, not its security origin.
        let escaped = baseURL?.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let source = escaped.map { "<base href=\"\($0)\">" + html } ?? html
        let dataURL = URL(string: "data:text/html;charset=utf-8;base64," + Data(source.utf8).base64EncodedString())
        guard let dataURL else { return nil }
        let next = load(URLRequest(url: dataURL))
        htmlDocumentURL = dataURL
        return next
    }

    @discardableResult
    func reload(ignoreCache: Bool = false) -> PageNavigation? {
        guard raw != nil || remote != nil, !isClosed, !closing else {
            return requestedURL.flatMap { load(URLRequest(url: $0)) }
        }
        let next = PageNavigation()
        navigation = next
        awaitingNativeNavigation = true
        navigationStarted = false
        remote?.send(CefRemote.Op.reload) { $0.set(CefRemote.Key.flag, ignoreCache) }
        withBrowser { browser in
            if ignoreCache {
                browser.pointee.reload_ignore_cache?(browser)
            } else {
                browser.pointee.reload?(browser)
            }
        }
        return next
    }

    @discardableResult
    func goBack() -> PageNavigation? {
        guard owner?.canGoBack == true else { return nil }
        navigation = PageNavigation()
        awaitingNativeNavigation = true
        navigationStarted = false
        remote?.send(CefRemote.Op.goBack)
        withBrowser { $0.pointee.go_back?($0) }
        return navigation
    }

    @discardableResult
    func goForward() -> PageNavigation? {
        guard owner?.canGoForward == true else { return nil }
        navigation = PageNavigation()
        awaitingNativeNavigation = true
        navigationStarted = false
        remote?.send(CefRemote.Op.goForward)
        withBrowser { $0.pointee.go_forward?($0) }
        return navigation
    }

    @discardableResult
    func go(to item: PageHistoryItem) -> PageNavigation? {
        guard let entry = item.chromiumIndex else { return nil }
        let next = PageNavigation()
        navigation = next
        awaitingNativeNavigation = true
        navigationStarted = false
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await command("Page.navigateToHistoryEntry", params: ["entryId": entry]) } catch { owner?.onNavigationFailed?(next, error) }
        }
        return next
    }

    func stopLoading() {
        pendingLoad?.cancel()
        client?.documentResponses.reset()
        remote?.send(CefRemote.Op.stop)
        withBrowser { $0.pointee.stop_load?($0) }
    }

    var pageZoom: CGFloat {
        get { zoom }
        set {
            zoom = newValue
            let level = log(Double(newValue)) / log(1.2)
            remote?.send(CefRemote.Op.zoom) { $0.set(CefRemote.Key.value, level) }
            withHost { $0.pointee.set_zoom_level?($0, level) }
        }
    }

    func frames() async throws -> [BrowserFrame] {
        try await devTools.frames()
    }
    func isLive(frame: BrowserFrame) async throws -> Bool {
        try await devTools.isLive(frame: frame)
    }

    func frame(id: String?, requestURL: URL?, isMainFrame: Bool) async throws -> BrowserFrame {
        let live = try await frames()
        if let id, let exact = live.first(where: { $0.chromiumID == id && $0.isMainFrame == isMainFrame }) {
            return exact
        }
        let matches = live.filter { $0.isMainFrame == isMainFrame && $0.request.url == requestURL }
        guard matches.count == 1, let match = matches.first else { throw ChromiumError.staleFrame }
        return match
    }

    func insertText(_ text: String) async throws {
        _ = try await command("Input.insertText", params: ["text": text])
    }

    func selectAll() {
        if let remote {
            // D4 spike: the page itself is the responder; the service selects in the focused frame.
            remote.send(CefRemote.Op.edit) { $0.set(CefRemote.Key.kind, "selectAll") }
            return
        }
        guard let responder = window?.firstResponder, responder !== self, ownsResponder(responder) else { return }
        responder.selectAll(nil)
    }

    func ownsResponder(_ responder: NSResponder?) -> Bool {
        responder === self || (responder as? NSView)?.isDescendant(of: self) == true
    }

    func sendKeyEvent(_ event: NSEvent) -> Bool {
        if remote != nil {
            // D4 spike: the page is the first responder itself and forwards the key to the service.
            guard window?.firstResponder === self else { return false }
            if event.type == .keyUp {
                keyUp(with: event)
            } else {
                keyDown(with: event)
            }
            return true
        }
        guard let responder = window?.firstResponder, responder !== self, ownsResponder(responder) else { return false }
        if event.type == .keyUp {
            responder.keyUp(with: event)
        } else {
            responder.keyDown(with: event)
        }
        return true
    }

    func sendMouseMove(to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        var flags: UInt32 = 0
        if modifiers.contains(.shift) {
            flags |= UInt32(EVENTFLAG_SHIFT_DOWN.rawValue)
        }
        if modifiers.contains(.control) {
            flags |= UInt32(EVENTFLAG_CONTROL_DOWN.rawValue)
        }
        if modifiers.contains(.option) {
            flags |= UInt32(EVENTFLAG_ALT_DOWN.rawValue)
        }
        if modifiers.contains(.command) {
            flags |= UInt32(EVENTFLAG_COMMAND_DOWN.rawValue)
        }
        if modifiers.contains(.capsLock) {
            flags |= UInt32(EVENTFLAG_CAPS_LOCK_ON.rawValue)
        }
        if let remote {
            let message = remote.message(CefRemote.Op.mouse)
            message.set(CefRemote.Key.kind, "move")
            message.set(CefRemote.Key.x, Double(point.x))
            message.set(CefRemote.Key.y, Double(point.y))
            message.set(CefRemote.Key.modifiers, Int64(flags))
            remote.sendInput(message)
            return
        }
        withHost { host in
            var event = cef_mouse_event_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()), modifiers: flags)
            host.pointee.send_mouse_move_event?(host, &event, 0)
        }
    }

    func willNavigate(_ request: URLRequest, isRedirect: Bool) {
        guard !closing, !isClosed, let url = request.url else { return }
        if initialDocument && url.absoluteString == "about:blank" { return }
        initialDocument = false
        // Before the request is sent, so the new document reads the store's camera and microphone choice.
        ChromiumRuntime.shared.mirrorCapture([url.absoluteString], in: context)
        ChromiumRuntime.shared.mirrorSiteAnswers(of: self, navigatingTo: url, in: context)
        if !awaitingNativeNavigation && !isRedirect {
            navigation = PageNavigation()
            navigationStarted = false
        }
        if navigation == nil {
            navigation = PageNavigation()
        }
        if !isRedirect {
            mainFrameGeneration &+= 1
            client?.documentResponses.reset()
        }
        awaitingNativeNavigation = false
        awaitedMoveAddress = nil
        requestedURL = url
        owner?.isLoading = true
        owner?.estimatedProgress = 0
        if !navigationStarted {
            navigationStarted = true
            // The old document's passkey requests end where a new main-frame navigation starts, as WebKit's do.
            owner?.invalidateCredentialContexts()
            owner?.onNavigationStarted?(navigation, url)
        }
    }

    func didReceiveMainFrameResponse(_ response: URLResponse) {
        guard !closing, !isClosed, let owner, !owner.isClosed else { return }
        owner.onMainFrameResponse?(response)
    }

    func didStartLoad() {
        mainFrameGeneration &+= 1
        guard !initialDocument, !awaitingNativeNavigation, !closing, !isClosed else { return }
        updateNativeSecurity()
        owner?.isLoading = true
    }

    func didNavigate(frame: BrowserFrame, restoredFromCache: Bool) {
        guard !closing, !isClosed else { return }
        if let url = frame.request.url {
            ChromiumRuntime.shared.recordOrigin(url, under: frame.isMainFrame ? nil : owner?.url, context: context)
        }
        guard frame.isMainFrame else { return }
        guard !initialDocument,
              frame.request.url?.absoluteString != "about:blank" || requestedURL?.absoluteString == "about:blank" else { return }
        if restoredFromCache && !navigationStarted {
            willNavigate(frame.request, isRedirect: false)
        }
        // Observers never see the new address with the old page's security; it is read again below.
        owner?.hasOnlySecureContent = false
        owner?.url = frame.request.url
        if let frameID = frame.chromiumID,
           let response = client?.documentResponses.commit(frameID: frameID, loaderID: frame.documentID) {
            didReceiveMainFrameResponse(response)
        }
        updateNativeSecurity()
        owner?.onNavigationCommitted?(navigation)
        if startupEntry == .inHistory {
            startupEntry = .resetting
            dropStartupEntry()
        } else {
            refreshHistory()
        }
        if restoredFromCache {
            owner?.isLoading = false
            owner?.estimatedProgress = 1
            owner?.onNavigationFinished?(navigation)
            navigationStarted = false
        }
    }

    func didFinishLoad(status: Int) {
        guard !closing, !isClosed else { return }
        guard !initialDocument, navigationStarted, !awaitingNativeNavigation else { return }
        updateNativeSecurity()
        didChangeTitle()
        owner?.estimatedProgress = 1
        refreshHistory()
        owner?.onNavigationFinished?(navigation)
        navigationStarted = false
    }

    func didFailLoad(code: Int, text: String, url: String) {
        guard code != -3, !closing, !isClosed else { return } // ERR_ABORTED is normal cancellation.
        guard !initialDocument, !awaitingNativeNavigation || requestedURL?.absoluteString == url else { return }
        let error = NSError(domain: "Chromium", code: code,
            userInfo: [NSLocalizedDescriptionKey: text, NSURLErrorFailingURLStringErrorKey: url])
        owner?.isLoading = false
        owner?.onNavigationFailed?(navigation, error)
    }

    func didTerminate() {
        // The renderer's documents and execution contexts are gone; no DevTools event reports it.
        mainFrameGeneration &+= 1
        devTools.forgetDocuments()
        owner?.invalidateCredentialContexts()
        owner?.onContentProcessTerminated?()
    }
    func didChangeTitle() {
        guard !closing, !isClosed else { return }
        if let remote {
            // D4 spike: the visible entry's title, which the service sends with its events.
            owner?.title = remote.title
            return
        }
        // The display callback substitutes a URL for an untitled document.
        // The navigation entry retains its actual (possibly empty) title.
        owner?.title = withHost { host in
            guard let entry = host.pointee.get_visible_navigation_entry?(host) else { return "" }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(entry)) }
            return ChromiumInterop.takeString(entry.pointee.get_title?(entry))
        }
    }
    func didChangeURL(_ url: URL?) {
        guard !initialDocument || url?.absoluteString != "about:blank" else { return }
        owner?.url = url
        requestedURL = url
        // A same-document entry (`pushState`) can make Back possible without a loading change.
        owner?.canGoBack = nativeCanGoBack()
        refreshHistory()
        if let url, awaitedMoveAddress == url {
            awaitedMoveAddress = nil
            owner?.onNavigatedWithinDocument?()
        }
    }
    /// The main frame moved inside its document. The owner is told once it also holds the new address, which the engine
    /// reports through `didChangeURL`, before or after this event.
    func didNavigateWithinDocument(to url: URL) {
        guard !closing, !isClosed, !initialDocument else { return }
        guard owner?.url == url else {
            awaitedMoveAddress = url
            return
        }
        owner?.onNavigatedWithinDocument?()
    }
    func didChangeLoading(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard !closing, !isClosed, !initialDocument else { return }
        // Chromium counts the startup page while it is in the history, and reports it on every loading change.
        owner?.canGoBack = canGoBack && nativeCanGoBack()
        owner?.canGoForward = canGoForward
        guard !awaitingNativeNavigation || loading else { return }
        owner?.isLoading = loading
        if !loading {
            owner?.estimatedProgress = 1
        }
    }
    func didChangeProgress(_ progress: Double) {
        owner?.estimatedProgress = progress
    }
    /// DevTools says the page's security changed: read the entry again under `hasOnlySecureContent(url:...)`, not its rating.
    func didChangeSecurity() {
        guard !closing, !isClosed else { return }
        updateNativeSecurity()
    }

    func didHoverLink(_ url: URL?) {
        owner?.onLinkHovered?(url)
    }
    func didChangeFullscreen(_ enabled: Bool) {
        owner?.isFullscreen = enabled
    }

    /// Back must never reach the startup page. The reset keeps only the committed entry, so it may run only while the history
    /// is exactly the startup page and that entry: once the page added an entry (`pushState`) or a later page committed, it
    /// would drop real Back entries. Chromium refuses it while the first commit is still swapping renderers, which the DevTools
    /// session waits out; a refusal of another kind is retried here. A reset that does not land leaves the startup entry hidden from Back.
    private func dropStartupEntry() {
        guard raw != nil || remote != nil, !closing, !isClosed else { return }
        Task { [weak self] in
            guard let self else { return }
            var outcome = StartupReset.refused
            for attempt in 1...Self.startupResetAttempts {
                outcome = await resetNavigationHistory()
                guard outcome == .refused, attempt < Self.startupResetAttempts else { break }
                try? await Task.sleep(for: Self.startupResetRetryDelay)
                guard !closing, !isClosed else { return }
            }
            guard !closing, !isClosed else { return }
            startupEntry = outcome == .landed ? .dropped : .kept
            owner?.canGoBack = nativeCanGoBack()
            await loadHistory()
        }
    }

    private enum StartupReset {
        case landed, refused, skipped
    }

    private struct StartupResetBlocked: Error {
        let outcome: StartupReset
    }

    /// The history check runs in the same synchronous turn that sends the reset, and Chromium applies the reset while it is
    /// sent, so no entry can arrive in between. The test seam replaces only the command.
    private func resetNavigationHistory() async -> StartupReset {
        if let remote, startupResetCommand == nil {
            // D4 spike: rule 4 of the plan. The service checks the native history and sends the reset in one turn on its UI
            // thread, where no entry can arrive in between.
            switch await remote.collapseStartup() {
            case CefRemote.CollapseOutcome.landed:
                return .landed
            case CefRemote.CollapseOutcome.skipped:
                return .skipped
            default:
                return .refused
            }
        }
        do {
            if let startupResetCommand {
                if let outcome = startupResetBlocker() {
                    return outcome
                }
                try await startupResetCommand()
            } else {
                _ = try await devTools.command("Page.resetNavigationHistory", dispatchCheck: { [weak self] in
                    guard let self else { throw StartupResetBlocked(outcome: .refused) }
                    if let outcome = startupResetBlocker() {
                        throw StartupResetBlocked(outcome: outcome)
                    }
                })
            }
            return .landed
        } catch let blocked as StartupResetBlocked {
            return blocked.outcome
        } catch {
            return .refused
        }
    }

    /// Nil while Chromium's history is exactly the startup page and the committed entry, the one state in which the reset
    /// drops nothing else; otherwise the outcome to report instead. The commit event can arrive before Chromium records the
    /// entry, so a history of the startup page alone is retried like a refusal.
    private func startupResetBlocker() -> StartupReset? {
        guard let native = nativeHistory() else { return .refused }
        if native.first != "about:blank" {
            return .landed
        }
        if native.count > 2 {
            return .skipped
        }
        return native.count == 2 && native.current == 1 ? nil : .refused
    }

    /// Back is possible to an entry other than the startup page, from Chromium's history as it is now.
    private func nativeCanGoBack() -> Bool {
        guard let native = nativeHistory() else { return false }
        let floor = startupEntry != .dropped && native.first == "about:blank" ? 1 : 0
        return native.current > floor
    }

    /// Chromium's entry count, current index and first URL. The visitor runs before the call returns on the UI thread, so
    /// the answer is current in the same turn.
    private func nativeHistory() -> (count: Int, current: Int, first: String)? {
        if let remote {
            // D4 spike: the last history the service sent with an event (a synchronous read cannot cross the process).
            return remote.history
        }
        let reader = NavigationEntryReader()
        let visitor = ChromiumInterop.allocate(cef_navigation_entry_visitor_t.self, owner: reader)
        visitor.pointee.visit = { visitorSelf, entry, current, index, total in
            // Callback object arguments arrive with a reference.
            let url = entry.map { ChromiumInterop.takeString($0.pointee.get_url?($0)) } ?? ""
            if let entry {
                ChromiumInterop.release(UnsafeMutableRawPointer(entry))
            }
            guard let visitorSelf,
                  let reader = ChromiumInterop.owner(NavigationEntryReader.self, of: UnsafeMutableRawPointer(visitorSelf)) else { return 0 }
            MainActor.assumeIsolated {
                reader.record(url: url, isCurrent: current != 0, index: Int(index), total: Int(total))
            }
            return 1
        }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(visitor)) }
        // The call consumes the reference it is given.
        ChromiumInterop.retain(UnsafeMutableRawPointer(visitor))
        let visited = withHost { host -> Bool in
            guard let entries = host.pointee.get_navigation_entries else { return false }
            entries(host, visitor, 0)
            return true
        } ?? false
        if !visited {
            ChromiumInterop.release(UnsafeMutableRawPointer(visitor))
        }
        guard let total = reader.total, let first = reader.first else { return nil }
        return (total, reader.current, first)
    }

    private func refreshHistory() {
        guard raw != nil || remote != nil, !closing, !isClosed else { return }
        Task { [weak self] in
            await self?.loadHistory()
        }
    }

    /// Reads Chromium's history into `history`. False when the read fails.
    @discardableResult
    private func loadHistory() async -> Bool {
        guard raw != nil || remote != nil, !closing, !isClosed, let response = try? await command("Page.getNavigationHistory"),
              let index = response["currentIndex"] as? Int,
              let entries = response["entries"] as? [[String: Any]] else { return false }
        let items = entries.enumerated().compactMap { position, entry -> (Int, PageHistoryItem)? in
            guard let id = entry["id"] as? Int, let address = entry["url"] as? String,
                  let url = URL(string: address) else { return nil }
            return (position, PageHistoryItem(url: url, title: entry["title"] as? String, chromiumIndex: id))
        }
        // Until a reset drops it, Chromium's first entry is the startup page, which Back never reaches.
        let hidden = startupEntry != .dropped && entries.first?["url"] as? String == "about:blank" ? 0 : -1
        history = PageHistoryList(
            backList: items.filter { $0.0 < index && $0.0 != hidden }.map(\.1),
            forwardList: items.filter { $0.0 > index }.map(\.1),
            currentItem: items.first { $0.0 == index }?.1)
        owner?.onHistoryChanged?()
        return true
    }

    func close() async {
        guard !isClosed else { return }
        client?.documentResponses.reset()
        if raw == nil && remote == nil {
            didClose()
            return
        }
        await withCheckedContinuation { continuation in
            closeWaiters.append(continuation)
            guard !closing else { return }
            closing = true
            pendingLoad?.cancel()
            preparation?.cancel()
            devTools.close()
            // The tab's protected-work confirmation has already completed before retirement.
            requestBrowserClose(timingOut: true)
            // CEF acknowledges destruction when its child host view is released.
            // Retaining that child until on_before_close would deadlock retirement.
            nativeView?.removeFromSuperview()
        }
    }

    func didClose() {
        guard !isClosed else { return }
        isClosed = true
        pendingLoad?.cancel()
        preparation?.cancel()
        devTools.close()
        // A page still waiting for its pop-up keeps the client: CEF reports the browser or the abort to it.
        if !awaitsPopup {
            client?.close()
            client = nil
        }
        endPopups()
        if let raw {
            ChromiumInterop.release(UnsafeMutableRawPointer(raw))
            CefRuntime.shared.externalBrowserDidClose()
        }
        raw = nil
        remote = nil
        remoteLayer?.removeFromSuperlayer()
        remoteLayer = nil
        ChromiumRuntime.shared.unregister(self)
        for waiter in attachmentWaiters {
            waiter.resume()
        }
        attachmentWaiters.removeAll()
        for waiter in closeWaiters {
            waiter.resume()
        }
        closeWaiters.removeAll()
    }
    /// Downloads `url` through the download handler, in this page's own session: its cookies, credentials and profile.
    func startDownload(of url: URL) {
        withHost { host in
            ChromiumInterop.withString(url.absoluteString) { host.pointee.start_download?(host, $0) }
        }
    }
    func cancelDownload(id: UInt32) {
        client?.cancelDownload(id: id)
    }
    func pauseDownload(id: UInt32) {
        client?.pauseDownload(id: id)
    }
    func resumeDownload(id: UInt32) {
        client?.resumeDownload(id: id)
    }

    func revokeCapture(_ permission: WebPermission) async throws {
        guard let client else { throw ChromiumError.closed }
        try await client.revokeCapture(permission)
    }
}

extension ChromiumPage {
    /// CEF is still making this pop-up page's browser: attaching the view and `ensureReady` wait for it, and nothing makes another.
    var awaitsPopup: Bool {
        popupInCreation != nil
    }

    /// Readies this pop-up page to host pop-up `id` of `opener` (`on_before_popup`): CEF makes it here, with this page's callbacks and
    /// the opener's settings and request context (a private window's pop-up stays private). Returns the client with CEF's reference, or nil.
    func hostPopup(id: Int32, opener: ChromiumPage, in info: inout cef_window_info_t) -> UnsafeMutablePointer<cef_client_t>? {
        guard let reserved = popupInCreation, raw == nil, client == nil, !closing, !isClosed else { return nil }
        let client = ChromiumClient(page: self)
        let pointer = client.makeClient()
        self.client = client
        opener.pendingPopups[id] = self
        popupInCreation = (reserved.address, { [weak opener] in opener?.pendingPopups[id] = nil })
        embed(in: &info)
        ChromiumInterop.retain(UnsafeMutableRawPointer(pointer))
        return pointer
    }

    /// CEF made the pop-up's browser (`on_after_created`, whose reference stays the callback's). A page closed meanwhile closes it.
    func adoptPopup(_ browser: UnsafeMutablePointer<cef_browser_t>) {
        guard let creation = popupInCreation, raw == nil else { return }
        popupInCreation = nil
        creation.release()
        defer { resumePopupWaiters() }
        guard !closing, !isClosed else {
            let host = browser.pointee.get_host?(browser)
            host?.pointee.close_browser?(host, 1)
            ChromiumInterop.release(host.map(UnsafeMutableRawPointer.init))
            return
        }
        ChromiumInterop.retain(UnsafeMutableRawPointer(browser))
        do {
            try adopt(browser, popup: true)
            // What WSurf sets over DevTools (the user agent); the browser settings came from the opener.
            Task { [weak self] in
                guard let self, (try? await applySettings(context.settings)) != nil else { return }
                hasAppliedInitialSettings = true
            }
        } catch {
            owner?.onNavigationFailed?(navigation, error)
        }
    }

    /// CEF did not make the pop-up (aborted, refused, or its opener closed first): the page loads it as a tab with no opener.
    func popupAborted() {
        guard let creation = popupInCreation, raw == nil else { return }
        popupInCreation = nil
        creation.release()
        client?.close()
        client = nil
        resumePopupWaiters()
        if !closing, !isClosed {
            load(URLRequest(url: creation.address))
        }
    }

    /// The page closed: nothing waits for its pop-up's browser any more, and its own pop-ups CEF has not made open without it.
    fileprivate func endPopups() {
        resumePopupWaiters()
        let pending = pendingPopups.values
        pendingPopups.removeAll()
        pending.forEach { $0.popupAborted() }
    }

    private func resumePopupWaiters() {
        popupWaiters.forEach { $0.resume() }
        popupWaiters.removeAll()
    }
}
