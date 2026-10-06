// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import WebKit

@MainActor
final class BrowserPage: NSView {
    let engine: BrowserEngine
    let webKit: WKWebView?
    let chromium: ChromiumPage?
    let profileID: UUID
    let isPrivate: Bool
    var nativeView: NSView {
        self
    }
    var topBarInset: CGFloat = 0 {
        didSet {
            guard topBarInset != oldValue else { return }
            (superview as? WebViewContainer)?.layoutPage()
        }
    }

    func frameInViewport(_ viewport: CGRect) -> CGRect {
        CGRect(x: viewport.minX, y: viewport.minY, width: viewport.width, height: max(1, viewport.height - topBarInset))
    }

    @objc dynamic var url: URL?
    @objc dynamic var title: String?
    @objc dynamic var isLoading = false
    @objc dynamic var estimatedProgress: Double = 0
    @objc dynamic var canGoBack = false
    @objc dynamic var canGoForward = false
    @objc dynamic var hasOnlySecureContent = false
    @objc dynamic var underPageBackgroundColor: NSColor = .windowBackgroundColor
    @objc dynamic var isFullscreen = false

    var onNavigationStarted: ((PageNavigation?, URL?) -> Void)?
    var onNavigationCommitted: ((PageNavigation?) -> Void)?
    var onNavigationFinished: ((PageNavigation?) -> Void)?
    var onNavigationFailed: ((PageNavigation?, Error) -> Void)?
    var onContentProcessTerminated: (() -> Void)?
    var onHistoryChanged: (() -> Void)?
    var onLinkHovered: ((URL?) -> Void)?
    var onZoomChanged: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []
    private let navigations = NSMapTable<WKNavigation, PageNavigation>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private static let owners = NSMapTable<WKWebView, BrowserPage>(keyOptions: .weakMemory, valueOptions: .weakMemory)
    private static let scriptWorlds = NSMapTable<WKUserScript, WKContentWorld>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var handlers: [String: (BrowserScriptMessage) -> Void] = [:]
    private var closed = false
    var isClosed: Bool {
        closed || chromium?.isClosed == true
    }

    init(webKit: WKWebView, profile: Profile? = nil) {
        engine = .webKit
        self.webKit = webKit
        chromium = nil
        let profile = profile ?? ChromiumRuntime.shared.currentProfile
        profileID = profile.id
        isPrivate = profile.isPrivate
        super.init(frame: webKit.frame)
        embed(webKit)
        Self.owners.setObject(self, forKey: webKit)
        observe(webKit)
    }

    init(chromium: ChromiumPage) {
        engine = .chromium
        webKit = nil
        self.chromium = chromium
        profileID = chromium.profileID
        isPrivate = chromium.isPrivate
        super.init(frame: chromium.frame)
        chromium.owner = self
        embed(chromium)
    }

    required init?(coder: NSCoder) {
        nil
    }
    override var isFlipped: Bool {
        true
    }
    override var acceptsFirstResponder: Bool {
        !closed
    }

    override func becomeFirstResponder() -> Bool {
        guard !closed else { return false }
        if let webKit {
            return window?.makeFirstResponder(webKit) == true
        }
        return chromium?.becomeFirstResponder() == true
    }

    static func from(_ view: WKWebView) -> BrowserPage? {
        owners.object(forKey: view)
    }

    private func embed(_ view: NSView) {
        autoresizingMask = [.width, .height]
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
    }

    private func observe(_ view: WKWebView) {
        observations = [
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.url = view.url }
            },
            view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.title = view.title }
            },
            view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            view.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.estimatedProgress = view.estimatedProgress }
            },
            view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
            view.observe(\.hasOnlySecureContent, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.hasOnlySecureContent = view.hasOnlySecureContent }
            },
            view.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.underPageBackgroundColor = view.underPageBackgroundColor }
            },
            view.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    self?.isFullscreen = view.fullscreenState == .inFullscreen || view.fullscreenState == .enteringFullscreen
                }
            },
        ]
    }

    func navigation(for native: WKNavigation?) -> PageNavigation? {
        guard let native else { return nil }
        if let existing = navigations.object(forKey: native) {
            return existing
        }
        let wrapped = PageNavigation(webKit: native)
        navigations.setObject(wrapped, forKey: native)
        return wrapped
    }

    @discardableResult
    func load(_ request: URLRequest) -> PageNavigation? {
        guard !closed else { return nil }
        if let webKit {
            return navigation(for: webKit.load(request))
        }
        return chromium?.load(request)
    }

    @discardableResult
    func loadFileURL(_ url: URL, allowingReadAccessTo directory: URL) -> PageNavigation? {
        guard !closed else { return nil }
        if let webKit {
            return navigation(for: webKit.loadFileURL(url, allowingReadAccessTo: directory))
        }
        return chromium?.load(URLRequest(url: url))
    }

    @discardableResult
    func loadHTMLString(_ html: String, baseURL: URL?) -> PageNavigation? {
        guard !closed else { return nil }
        if let webKit {
            return navigation(for: webKit.loadHTMLString(html, baseURL: baseURL))
        }
        return chromium?.loadHTML(html, baseURL: baseURL)
    }

    @discardableResult
    func reload() -> PageNavigation? {
        if let webKit {
            return navigation(for: webKit.reload())
        }
        return chromium?.reload()
    }

    @discardableResult
    func reloadFromOrigin() -> PageNavigation? {
        if let webKit {
            return navigation(for: webKit.reloadFromOrigin())
        }
        return chromium?.reload(ignoreCache: true)
    }

    @discardableResult
    func goBack() -> PageNavigation? {
        if let webKit {
            return navigation(for: webKit.goBack())
        }
        return chromium?.goBack()
    }

    @discardableResult
    func goForward() -> PageNavigation? {
        if let webKit {
            return navigation(for: webKit.goForward())
        }
        return chromium?.goForward()
    }

    @discardableResult
    func go(to item: PageHistoryItem) -> PageNavigation? {
        if let webKit, let native = item.webKit {
            return navigation(for: webKit.go(to: native))
        }
        return chromium?.go(to: item)
    }

    func stopLoading() {
        webKit?.stopLoading()
        chromium?.stopLoading()
    }

    var pageZoom: CGFloat {
        get { webKit?.pageZoom ?? chromium?.pageZoom ?? 1 }
        set {
            webKit?.pageZoom = newValue
            chromium?.pageZoom = newValue
        }
    }

    var magnification: CGFloat {
        get { webKit?.magnification ?? 1 }
        set {
            if let webKit {
                webKit.magnification = newValue
            } else {
                pageZoom = newValue * pageZoom
            }
        }
    }

    var backForwardList: PageHistoryList {
        guard let webKit else { return chromium?.history ?? PageHistoryList() }
        return PageHistoryList(
            backList: webKit.backForwardList.backList.map(PageHistoryItem.init(webKit:)),
            forwardList: webKit.backForwardList.forwardList.map(PageHistoryItem.init(webKit:)),
            currentItem: webKit.backForwardList.currentItem.map(PageHistoryItem.init(webKit:)))
    }

    private struct SavedState: Codable {
        let engine: BrowserEngine
        let webKit: Data?
    }

    static func canRestore(_ data: Data, using engine: BrowserEngine) -> Bool {
        guard engine == .webKit else { return false }
        guard let saved = try? JSONDecoder().decode(SavedState.self, from: data) else { return true }
        return saved.engine == .webKit && saved.webKit != nil
    }

    var interactionState: Any? {
        get {
            // Chromium unloads restore the tab's saved URL, never an imported history or replayed request.
            guard let data = webKit?.interactionState as? Data else { return nil }
            return try? JSONEncoder().encode(SavedState(engine: .webKit, webKit: data))
        }
        set {
            guard let webKit, let data = newValue as? Data else { return }
            if let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
                guard saved.engine == .webKit, let state = saved.webKit else { return }
                webKit.interactionState = state
            } else {
                // Existing sessions contain WebKit's untagged native state.
                webKit.interactionState = data
            }
        }
    }

    func evaluateJavaScript(_ script: String, completionHandler: (@MainActor (Any?, Error?) -> Void)? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await evaluateJavaScript(script)
                completionHandler?(result, nil)
            } catch { completionHandler?(nil, error) }
        }
    }

    func evaluateJavaScript(_ script: String) async throws -> Any {
        try await evaluateJavaScript(script, in: nil, contentWorld: .page)
    }

    func evaluateJavaScript(_ script: String, in frame: BrowserFrame?, contentWorld: WKContentWorld) async throws -> Any {
        guard !closed else { throw ChromiumError.closed }
        if let webKit {
            if let frame, frame.webKit == nil {
                throw ChromiumError.staleFrame
            }
            var result: Result<Any, Error>!
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                webKit.evaluateJavaScript(script, in: frame?.webKit, in: contentWorld, completionHandler: {
                    result = $0
                    continuation.resume()
                })
            }
            return try result.get()
        }
        guard let chromium else { throw ChromiumError.closed }
        try await chromium.ensureReady()
        return try await chromium.devTools.evaluate(script, in: frame, world: contentWorld)
    }

    func callAsyncJavaScript(_ body: String, arguments: [String: Any] = [:], in frame: BrowserFrame?, contentWorld: WKContentWorld) async throws -> Any {
        guard !closed else { throw ChromiumError.closed }
        if let webKit {
            if let frame, frame.webKit == nil {
                throw ChromiumError.staleFrame
            }
            var result: Result<Any, Error>!
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                webKit.callAsyncJavaScript(body, arguments: arguments, in: frame?.webKit, in: contentWorld, completionHandler: {
                    result = $0
                    continuation.resume()
                })
            }
            return try result.get()
        }
        guard let chromium else { throw ChromiumError.closed }
        try await chromium.ensureReady()
        return try await chromium.devTools.callAsync(body, arguments: arguments, in: frame, world: contentWorld)
    }

    func capture(rect: CGRect? = nil, width: CGFloat? = nil, afterScreenUpdates: Bool = false) async throws -> NSImage {
        guard !closed else { throw ChromiumError.closed }
        if let webKit {
            let configuration = WKSnapshotConfiguration()
            if let rect {
                configuration.rect = rect
            }
            configuration.snapshotWidth = width.map { NSNumber(value: Double($0)) }
            configuration.afterScreenUpdates = afterScreenUpdates
            return try await withCheckedThrowingContinuation { continuation in
                webKit.takeSnapshot(with: configuration) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(
                            throwing: error ?? ChromiumError.unavailable(
                                String(localized: "The page image is unavailable.")
                            )
                        )
                    }
                }
            }
        }
        guard let chromium else { throw ChromiumError.closed }
        return try await chromium.capture(rect: rect, width: width)
    }

    func sendKeyEvent(_ event: NSEvent) {
        if let webKit {
            if event.type == .keyUp {
                webKit.keyUp(with: event)
            } else {
                webKit.keyDown(with: event)
            }
        } else {
            chromium?.sendKeyEvent(event)
        }
    }

    private final class MessageAdapter: NSObject, WKScriptMessageHandler {
        let world: WKContentWorld
        init(world: WKContentWorld) {
            self.world = world
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let native = message.webView, let page = BrowserPage.from(native), !page.closed else { return }
            let key = BrowserPage.handlerKey(name: message.name, world: world)
            page.handlers[key]?(BrowserScriptMessage(page: page, body: message.body,
                frameInfo: BrowserFrame(webKit: message.frameInfo), name: message.name))
        }
    }

    private static func handlerKey(name: String, world: WKContentWorld) -> String {
        let realm = world === WKContentWorld.page ? "page" : "isolated:\(world.name ?? "defaultClient")"
        return realm + ":" + name
    }

    private static let bridgeSource = """
        (() => {
          if (Object.prototype.hasOwnProperty.call(globalThis, '__wsurfSend')) return;
          Object.defineProperty(globalThis, '__wsurfSend', { value: (name, body) => {
            const handler = window.webkit?.messageHandlers?.[name];
            if (!handler) throw new Error('WSurf message handler unavailable');
            handler.postMessage(body);
          }});
        })();
        """

    static func installBridge(in controller: WKUserContentController, world: WKContentWorld) {
        guard !controller.userScripts.contains(where: {
            ($0.source == bridgeSource || $0.source.hasPrefix(bridgeSource + "\n")) &&
            Self.scriptWorlds.object(forKey: $0) === world
        }) else { return }
        let userScript = WKUserScript(source: bridgeSource, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: world)
        Self.scriptWorlds.setObject(world, forKey: userScript)
        controller.addUserScript(userScript)
    }

    func installScript(_ source: String, in world: WKContentWorld, injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool) {
        if let webKit {
            let controller = webKit.configuration.userContentController
            let source = Self.bridgeSource + "\n" + source
            guard !controller.userScripts.contains(where: {
                $0.source == source && Self.scriptWorlds.object(forKey: $0) === world &&
                $0.injectionTime == injectionTime && $0.isForMainFrameOnly == forMainFrameOnly
            }) else { return }
            let userScript = WKUserScript(source: source, injectionTime: injectionTime,
                forMainFrameOnly: forMainFrameOnly, in: world)
            Self.scriptWorlds.setObject(world, forKey: userScript)
            controller.addUserScript(userScript)
        } else {
            chromium?.devTools.installScript(source, in: world, injectionTime: injectionTime, forMainFrameOnly: forMainFrameOnly)
        }
    }

    func addScriptMessageHandler(name: String, in world: WKContentWorld, handler: @escaping (BrowserScriptMessage) -> Void) {
        handlers[Self.handlerKey(name: name, world: world)] = handler
        if let webKit {
            let controller = webKit.configuration.userContentController
            Self.installBridge(in: controller, world: world)
            controller.removeScriptMessageHandler(forName: name, contentWorld: world)
            // Opener-created views can share a controller; route by the emitting native view, not the last installed tab.
            controller.add(MessageAdapter(world: world), contentWorld: world, name: name)
        } else {
            chromium?.devTools.addScriptMessageHandler(name: name, in: world, handler: handler)
        }
    }

    func removeScriptMessageHandler(name: String, in world: WKContentWorld) {
        handlers[Self.handlerKey(name: name, world: world)] = nil
        chromium?.devTools.removeScriptMessageHandler(name: name, in: world)
    }

    func close() async {
        guard !closed else { return }
        closed = true
        stopLoading()
        handlers.removeAll()
        observations.removeAll()
        if let webKit {
            webKit.navigationDelegate = nil
            webKit.uiDelegate = nil
            Self.owners.removeObject(forKey: webKit)
        }
        await chromium?.close()
        removeFromSuperview()
    }
}
