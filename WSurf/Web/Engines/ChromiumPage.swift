// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import CefKit
import Foundation
import MachO
import WebKit

@MainActor
final class ChromiumPage: NSView {
    let profile: Profile
    var profileID: UUID {
        profile.id
    }
    var isPrivate: Bool {
        profile.isPrivate
    }
    weak var owner: BrowserPage?
    private(set) var browserID: Int32 = -1
    private(set) var isClosed = false
    private var raw: UnsafeMutablePointer<cef_browser_t>?
    private(set) var client: ChromiumClient?
    private(set) lazy var devTools = ChromiumDevTools(page: self)
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

    private(set) var navigation: PageNavigation?
    private(set) var history = PageHistoryList()
    private var requestedURL: URL?
    private var awaitingNativeNavigation = false
    private var navigationStarted = false
    private var initialDocument = true
    private(set) var htmlDocumentURL: URL?
    private var hasAppliedInitialSettings = false
    private var zoom: CGFloat = 1
    var navigationDecision: ((URLRequest, Bool, Bool, Bool, WKNavigationType, URL?) -> Bool)?
    var openWindow: ((URL, Bool) -> Void)?
    var captureChanged: ((Bool, Bool) -> Void)?
    var onCloseRequested: (() -> Void)?
    var permissionDecision: ((BrowserFrame, [WebPermission]) async -> Bool)?
    var downloadDecision: ((CefDownload, String, @escaping (CefDownloadDecision) -> Void) -> Void)?
    var downloadProgress: ((CefDownload) -> Void)?

    init(profile: Profile) {
        self.profile = profile
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
        withHost { $0.pointee.set_focus?($0, 1) }
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, raw == nil, !closing, !isClosed else { return }
        do {
            defer {
                for waiter in attachmentWaiters {
                    waiter.resume()
                }
                attachmentWaiters.removeAll()
            }
            try materialize()
        } catch {
            owner?.onNavigationFailed?(navigation, error)
        }
    }

    override func layout() {
        super.layout()
        nativeView?.frame = bounds
    }

    func materialize() throws {
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
        info.parent_view = Unmanaged.passUnretained(self).toOpaque()
        info.bounds = cef_rect_t(x: 0, y: 0,
            width: Int32(max(1, bounds.width.rounded())), height: Int32(max(1, bounds.height.rounded())))
        info.runtime_style = CEF_RUNTIME_STYLE_ALLOY
        var settings = cef_browser_settings_t()
        settings.size = MemoryLayout<cef_browser_settings_t>.stride
        Self.configureBrowserSettings(&settings)
        let created = try ChromiumRuntime.shared.withContext(for: profile) { context in
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
        raw = created
        browserID = created.pointee.get_identifier?(created) ?? -1
        ChromiumRuntime.shared.register(self)
        do {
            withHost { $0.pointee.set_accessibility_state?($0, STATE_ENABLED) }
            guard let attached = try withHost({ host in try devTools.attach(to: host) }) else {
                throw ChromiumError.closed
            }
            _ = attached
            preparation = Task { [weak self] in
                guard let self else { throw ChromiumError.closed }
                try await devTools.prepare()
                pageZoom = zoom
            }
        } catch {
            withHost { $0.pointee.close_browser?($0, 1) }
            throw error
        }
        nativeView?.frame = bounds
        nativeView?.autoresizingMask = [.width, .height]
    }

    func ensureReady() async throws {
        guard !isClosed, !closing else { throw ChromiumError.closed }
        if raw == nil {
            try materialize()
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

    func command(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        try await devTools.command(method, params: params)
    }

    @discardableResult
    func load(_ request: URLRequest) -> PageNavigation? {
        guard !isClosed, !closing, let url = request.url else { return nil }
        pendingLoad?.cancel()
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
                    try await applySettings()
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
        guard raw != nil, !isClosed, !closing else {
            return requestedURL.flatMap { load(URLRequest(url: $0)) }
        }
        let next = PageNavigation()
        navigation = next
        awaitingNativeNavigation = true
        navigationStarted = false
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
        withBrowser { $0.pointee.go_back?($0) }
        return navigation
    }

    @discardableResult
    func goForward() -> PageNavigation? {
        guard owner?.canGoForward == true else { return nil }
        navigation = PageNavigation()
        awaitingNativeNavigation = true
        navigationStarted = false
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
        withBrowser { $0.pointee.stop_load?($0) }
    }

    var pageZoom: CGFloat {
        get { zoom }
        set {
            zoom = newValue
            withHost { $0.pointee.set_zoom_level?($0, log(Double(newValue)) / log(1.2)) }
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

    func capture(rect: CGRect?, width: CGFloat?) async throws -> NSImage {
        try await ensureReady()
        var parameters: [String: Any] = ["format": "png", "captureBeyondViewport": false]
        let area = rect ?? bounds
        if let width, area.width > 0 {
            parameters["clip"] = ["x": area.minX, "y": area.minY, "width": area.width,
                "height": area.height, "scale": Double(width / area.width), ]
        } else if rect != nil {
            parameters["clip"] = ["x": area.minX, "y": area.minY, "width": area.width,
                "height": area.height, "scale": 1, ]
        }
        let response = try await command("Page.captureScreenshot", params: parameters)
        guard let encoded = response["data"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) else {
            throw ChromiumError.protocolFailure(String(localized: "Chromium did not return a page image."))
        }
        return image
    }

    func insertText(_ text: String) {
        nativeView?.insertText(text)
    }

    func selectAll() {
        nativeView?.selectAll(nil)
    }

    func ownsResponder(_ responder: NSResponder?) -> Bool {
        responder === self || (responder as? NSView)?.isDescendant(of: self) == true
    }

    func sendKeyEvent(_ event: NSEvent) {
        if event.type == .keyUp {
            nativeView?.keyUp(with: event)
        } else {
            nativeView?.keyDown(with: event)
        }
    }

    func willNavigate(_ request: URLRequest, isRedirect: Bool) {
        guard !closing, !isClosed, let url = request.url else { return }
        if initialDocument && url.absoluteString == "about:blank" { return }
        initialDocument = false
        if !awaitingNativeNavigation && !isRedirect {
            navigation = PageNavigation()
            navigationStarted = false
        }
        if navigation == nil {
            navigation = PageNavigation()
        }
        awaitingNativeNavigation = false
        requestedURL = url
        owner?.isLoading = true
        owner?.estimatedProgress = 0
        if !navigationStarted {
            navigationStarted = true
            owner?.onNavigationStarted?(navigation, url)
        }
    }

    func didStartLoad() {
        guard !initialDocument, !awaitingNativeNavigation, !closing, !isClosed else { return }
        updateNativeSecurity()
        owner?.isLoading = true
    }

    func didNavigate(frame: BrowserFrame) {
        guard !closing, !isClosed else { return }
        if let url = frame.request.url {
            ChromiumRuntime.shared.recordOrigin(url, profileID: profileID, isPrivate: isPrivate)
        }
        guard frame.isMainFrame else { return }
        guard !initialDocument,
              frame.request.url?.absoluteString != "about:blank" || requestedURL?.absoluteString == "about:blank" else { return }
        owner?.url = frame.request.url
        updateNativeSecurity()
        owner?.onNavigationCommitted?(navigation)
        refreshHistory()
    }

    func didFinishLoad(status: Int) {
        guard !closing, !isClosed else { return }
        guard !initialDocument, navigationStarted, !awaitingNativeNavigation else { return }
        updateNativeSecurity()
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
        owner?.onContentProcessTerminated?()
    }
    func didChangeTitle(_ title: String) {
        owner?.title = title
    }
    func didChangeURL(_ url: URL?) {
        guard !initialDocument || url?.absoluteString != "about:blank" else { return }
        owner?.url = url
        requestedURL = url
        refreshHistory()
    }
    func didChangeLoading(_ loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard !closing, !isClosed else { return }
        guard !initialDocument, !awaitingNativeNavigation || loading else { return }
        owner?.isLoading = loading
        owner?.canGoBack = canGoBack
        owner?.canGoForward = canGoForward
        if !loading {
            owner?.estimatedProgress = 1
        }
    }
    func didChangeProgress(_ progress: Double) {
        owner?.estimatedProgress = progress
    }
    func didChangeSecurity(_ secure: Bool) {
        owner?.hasOnlySecureContent = secure
    }

    private func updateNativeSecurity() {
        let secure = withHost { host -> Bool in
            guard let entry = host.pointee.get_visible_navigation_entry?(host) else { return false }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(entry)) }
            guard let ssl = entry.pointee.get_sslstatus?(entry) else { return false }
            defer { ChromiumInterop.release(UnsafeMutableRawPointer(ssl)) }
            return ssl.pointee.is_secure_connection?(ssl) == 1
                && ssl.pointee.get_content_status?(ssl).rawValue == 0
        } ?? false
        owner?.hasOnlySecureContent = secure
    }
    func didHoverLink(_ url: URL?) {
        owner?.onLinkHovered?(url)
    }
    func didChangeFullscreen(_ enabled: Bool) {
        owner?.isFullscreen = enabled
    }

    private func refreshHistory() {
        guard raw != nil, !closing, !isClosed else { return }
        Task { [weak self] in
            guard let self, let response = try? await command("Page.getNavigationHistory"),
                  let index = response["currentIndex"] as? Int,
                  let entries = response["entries"] as? [[String: Any]] else { return }
            let items = entries.enumerated().compactMap { position, entry -> (Int, PageHistoryItem)? in
                guard let id = entry["id"] as? Int, let address = entry["url"] as? String,
                      let url = URL(string: address) else { return nil }
                return (position, PageHistoryItem(url: url, title: entry["title"] as? String, chromiumIndex: id))
            }
            history = PageHistoryList(
                backList: items.filter { $0.0 < index }.map(\.1),
                forwardList: items.filter { $0.0 > index }.map(\.1),
                currentItem: items.first { $0.0 == index }?.1)
            owner?.onHistoryChanged?()
        }
    }

    func close() async {
        guard !isClosed else { return }
        if raw == nil {
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
            withHost { $0.pointee.close_browser?($0, 1) }
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
        client?.close()
        client = nil
        if let raw {
            ChromiumInterop.release(UnsafeMutableRawPointer(raw))
        }
        raw = nil
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

    func restoreCapturePrompt(_ permission: WebPermission) async throws {
        guard let client else { throw ChromiumError.closed }
        try await client.restoreCapturePrompt(permission)
    }
}
