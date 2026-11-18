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
    var browserID: Int32 = -1
    private(set) var isClosed = false
    private(set) var raw: UnsafeMutablePointer<cef_browser_t>?
    private(set) var client: ChromiumClient?
    lazy var devTools = ChromiumDevTools(page: self)
    /// D4: the page's browser when it runs in the Chromium service (`ChromiumPage+Remote`); nil for a page in process. Exactly one of
    /// this and `raw` is set once the page has a browser.
    var remote: ChromiumRemoteBrowser?
    /// The connection a page in the service runs through (the process's own; a test gives one of its own). D4-10 recovery state:
    /// see `ChromiumPage+Remote`.
    var remoteConnection: ChromiumRemote = ChromiumPage.initialConnection
    #if DEBUG
    /// A test's connection for the pages made while it is set (nil: the process's own), so a test can drive the tabs of a whole window
    /// through a connection that has no real service.
    static var testConnection: ChromiumRemote?
    private static var initialConnection: ChromiumRemote {
        testConnection ?? .shared
    }
    #else
    private static var initialConnection: ChromiumRemote {
        .shared
    }
    #endif
    var recovery = RemoteRecovery.none
    var heldReload: URLRequest?
    var isRecovering = false
    var recoveryCheckPending = false
    /// The frame layer of a browser the service took with it, with its last frame: shown while a shown page waits for its replacement
    /// (`ChromiumPage+Display`).
    var retainedPreview: CALayer?
    var preparation: Task<Void, Error>?
    var pendingLoad: Task<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var closing = false
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
    var history = PageHistoryList()
    var historyRecord = ChromiumHistoryRecord()
    var requestedURL: URL?
    var awaitingNativeNavigation = false
    /// The address of a same-document move the engine reported before it reported the address.
    private var awaitedMoveAddress: URL?
    /// Set while the awaited native navigation may stay inside the document, so it never reaches `willNavigate`.
    var sameDocumentWait: SameDocumentWait?
    var navigationStarted = false
    var initialDocument = true
    /// Chromium records the startup about:blank as a real history entry. The first commit starts the reset that drops it. Until a reset has dropped
    /// it, it stays Chromium's first entry and Back never goes there (`nativeCanGoBack`, `loadHistory`). `kept`: no reset dropped it (none landed, or the history grew first).
    enum StartupEntry {
        case inHistory, resetting, dropped, kept
    }
    var startupEntry = StartupEntry.inHistory
    /// Moves on when a main-frame navigation is requested, starts or commits, or the renderer is lost (`load`,
    /// `willNavigate`, `didStartLoad`, `didTerminate`). It proves a request made before the tab committed any document.
    private(set) var mainFrameGeneration: UInt64 = 0
    /// Test seam: runs in place of the `Page.resetNavigationHistory` command; a throw is a refused reset.
    var startupResetCommand: (@MainActor () async throws -> Void)?
    /// Times `closeTimeout` (ChromiumPage+Close.swift). Test seams: a clock, and losing CEF's `on_before_close`.
    var closeClock: any Clock<Duration> = ContinuousClock()
    var dropsCloseAnswerForTesting = false
    private(set) var htmlDocumentURL: URL?
    var hasAppliedInitialSettings = false
    /// Whether `applySettings` left a user agent override in place, so a later return to the engine's own string clears it.
    var hasUserAgentOverride = false
    var zoom: CGFloat = 1
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
    /// Why it is not offered, for a menu that shows the item disabled; asked only while `canPickCredential` says no.
    var credentialRefusal: (() -> CredentialPicker.Refusal?)?
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
        // Out of process the content view is the first responder (`BrowserPage` makes it so), never the page.
        if remote?.contentView != nil {
            return false
        }
        withHost { $0.pointee.set_focus?($0, 1) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Out of process the service makes the browser, and nothing here waits for it or for a window.
        if materializeRemoteOnAttach() {
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
        nativeView?.frame = bounds
    }

    // D4: a page in the Chromium service tells it its size, scale, screen and visibility (`ChromiumPage+Display`). Each is a no-op for
    // a page in process.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRemoteGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRemoteGeometry()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateRemoteGeometry()
        updateRemoteVisibility()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateRemoteVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRemoteVisibility()
    }

    func materialize() throws {
        if runsRemotely {
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
            if popup {
                ChromiumInterop.closeLater(browser)
            } else {
                withHost { $0.pointee.close_browser?($0, 1) }
            }
            throw error
        }
        nativeView?.frame = bounds
        nativeView?.autoresizingMask = [.width, .height]
    }

    func ensureReady() async throws {
        guard !isClosed, !closing else { throw ChromiumError.closed }
        if runsRemotely {
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
            remote.setMuted(muted)
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
    func load(_ request: URLRequest, byPerson: Bool = false) -> PageNavigation? {
        guard !isClosed, !closing, let url = request.url else { return nil }
        guard !holdsForRecovery(request, byPerson: byPerson) else { return nil }
        pendingLoad?.cancel()
        mainFrameGeneration &+= 1
        let next = PageNavigation()
        navigation = next
        requestedURL = url
        htmlDocumentURL = nil
        awaitLoad(of: url)
        navigationStarted = false
        owner?.isLoading = true
        owner?.estimatedProgress = 0
        pendingLoad = Task { [weak self] in
            guard let self else { return }
            do {
                // Loads may be requested before SwiftUI attaches the view. Attachment starts preparation.
                if window == nil, !runsRemotely {
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

    var attachmentWaiters: [CheckedContinuation<Void, Never>] = []

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
            // The service has no per-file scope yet (phase 4): said here, so the tab shows it (`remoteNavigationDecision` is the floor
            // for a page's own moves).
            guard !url.isFileURL else {
                throw ChromiumError.unavailable("Chromium cannot open a local file in this build yet.")
            }
            // A plain GET only: a request with a body or headers needs the service to build it (phase 4), and is refused here, never
            // turned into a GET.
            guard (request.httpMethod ?? "GET").uppercased() == "GET", request.httpBody == nil, request.httpBodyStream == nil,
                  request.allHTTPHeaderFields?.isEmpty != false else {
                throw ChromiumError.unavailable("Chromium cannot send a request with a body or headers in this build yet.")
            }
            guard remote.send(CefRemote.Op.load, { $0.set(CefRemote.Key.url, url.absoluteString) }) else { throw ChromiumError.closed }
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
        // An error document (the tab's) cannot be made while the service is given up, and making it must not ask for the service:
        // the page waits for a person's load, and `requestedURL` stays the address that person reloads.
        guard !remoteConnection.isGivenUp else { return nil }
        let next = load(URLRequest(url: dataURL))
        htmlDocumentURL = dataURL
        return next
    }

    @discardableResult
    func reload(ignoreCache: Bool = false, byPerson: Bool = false) -> PageNavigation? {
        guard raw != nil || remote != nil, !isClosed, !closing else {
            return requestedURL.flatMap { load(URLRequest(url: $0), byPerson: byPerson) }
        }
        let next = PageNavigation()
        navigation = next
        awaitLoad(of: nil)
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
        awaitHistoryMove()
        navigationStarted = false
        remote?.send(CefRemote.Op.goBack)
        withBrowser { $0.pointee.go_back?($0) }
        return navigation
    }

    @discardableResult
    func goForward() -> PageNavigation? {
        guard owner?.canGoForward == true else { return nil }
        navigation = PageNavigation()
        awaitHistoryMove()
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
        awaitHistoryMove()
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
        guard let responder = window?.firstResponder, responder !== self, ownsResponder(responder) else { return }
        responder.selectAll(nil)
    }

    func ownsResponder(_ responder: NSResponder?) -> Bool {
        responder === self || (responder as? NSView)?.isDescendant(of: self) == true
    }

    func sendKeyEvent(_ event: NSEvent) -> Bool {
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
        sameDocumentWait = nil
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
        historyRecord.noteCommit(frame.request.url, navigation: navigation)
        if startupEntry == .inHistory {
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
            // The visible entry's title, which the service sends with its events.
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
        owner?.canGoBack = logicalCanGoBack()
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
        completeAwaitedMoveWithinDocument()
        guard owner?.url == url else {
            awaitedMoveAddress = url
            return
        }
        owner?.onNavigatedWithinDocument?()
    }
    func didChangeLoading(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard !closing, !isClosed, !initialDocument else { return }
        // Chromium counts the startup page while it is in the history, and reports it on every loading change.
        owner?.canGoBack = canGoBack && nativeCanGoBack() || !historyRecord.back.isEmpty
        owner?.canGoForward = canGoForward || !historyRecord.forward.isEmpty
        sameDocumentWait?.held = loading
        guard !awaitingNativeNavigation || loading else { return }
        owner?.isLoading = loading
        if !loading {
            owner?.estimatedProgress = 1
        }
    }
    /// DevTools says the page's security changed: read the entry again under `hasOnlySecureContent(url:...)`, not its rating.
    func didChangeSecurity() {
        guard !closing, !isClosed else { return }
        updateNativeSecurity()
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
        remote?.page = nil
        remote?.detachFrameLayer()
        dropRetainedPreview()
        remote = nil
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
        client.fileScope.markOpenerCreated()
        let pointer = client.makeClient()
        self.client = client
        opener.pendingPopups[id] = self
        popupInCreation = (reserved.address, { [weak opener] in opener?.pendingPopups[id] = nil })
        embed(in: &info)
        ChromiumInterop.retain(UnsafeMutableRawPointer(pointer))
        return pointer
    }

    /// CEF made the pop-up's browser (`on_after_created`, whose reference stays the callback's). A page closed meanwhile closes it,
    /// but not inside the callback: CEF uses the browser when it returns, and this page (the view's owner) may be freed there.
    func adoptPopup(_ browser: UnsafeMutablePointer<cef_browser_t>) {
        guard let creation = popupInCreation, raw == nil else { return }
        popupInCreation = nil
        creation.release()
        defer { resumePopupWaiters() }
        guard !closing, !isClosed else {
            ChromiumInterop.closeLater(browser, keeping: self)
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
