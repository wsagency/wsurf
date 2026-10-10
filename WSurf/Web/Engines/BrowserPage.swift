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
    private(set) var credentialGeneration: UInt64 = 0
    private var credentialInvalidationObservers: [UUID: @MainActor @Sendable (BrowserPage, String?) -> Void] = [:]

    @discardableResult
    func addCredentialInvalidationObserver(
        _ handler: @escaping @MainActor @Sendable (BrowserPage, String?) -> Void
    ) -> UUID {
        let id = UUID()
        credentialInvalidationObservers[id] = handler
        return id
    }

    func removeCredentialInvalidationObserver(_ id: UUID) {
        credentialInvalidationObservers[id] = nil
    }

    func invalidateCredentialContexts(documentID: String? = nil) {
        if documentID == nil {
            precondition(credentialGeneration < .max, "WebAuthn context generation exhausted.")
            credentialGeneration += 1
        }
        for handler in Array(credentialInvalidationObservers.values) {
            handler(self, documentID)
        }
    }

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
        try await evaluateJavaScript(script, in: nil, contentWorld: .page, dispatchCheck: {})
    }

    func evaluateJavaScript(
        _ script: String,
        dispatchCheck: @escaping @MainActor @Sendable () throws -> Void
    ) async throws -> Any {
        try await evaluateJavaScript(script, in: nil, contentWorld: .page, dispatchCheck: dispatchCheck)
    }

    func evaluateJavaScript(
        _ script: String,
        in frame: BrowserFrame?,
        contentWorld: WKContentWorld
    ) async throws -> Any {
        try await evaluateJavaScript(script, in: frame, contentWorld: contentWorld, dispatchCheck: {})
    }

    func evaluateJavaScript(
        _ script: String,
        in frame: BrowserFrame?,
        contentWorld: WKContentWorld,
        dispatchCheck: @escaping @MainActor @Sendable () throws -> Void
    ) async throws -> Any {
        guard !closed else { throw ChromiumError.closed }
        if let webKit {
            if let frame, frame.webKit == nil { throw ChromiumError.staleFrame }
            try dispatchCheck()
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
        return try await chromium.devTools.evaluate(
            script, in: frame, world: contentWorld, dispatchCheck: dispatchCheck
        )
    }

    func callAsyncJavaScript(
        _ body: String,
        arguments: [String: Any] = [:],
        in frame: BrowserFrame?,
        contentWorld: WKContentWorld
    ) async throws -> Any {
        try await callAsyncJavaScript(
            body, arguments: arguments, in: frame, contentWorld: contentWorld, dispatchCheck: {}
        )
    }

    func callAsyncJavaScript(
        _ body: String,
        arguments: [String: Any] = [:],
        in frame: BrowserFrame?,
        contentWorld: WKContentWorld,
        dispatchCheck: @escaping @MainActor @Sendable () throws -> Void
    ) async throws -> Any {
        guard !closed else { throw ChromiumError.closed }
        if let webKit {
            if let frame, frame.webKit == nil { throw ChromiumError.staleFrame }
            try dispatchCheck()
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
        return try await chromium.devTools.callAsync(
            body, arguments: arguments, in: frame, world: contentWorld, dispatchCheck: dispatchCheck
        )
    }

    func callAsyncJavaScript(
        _ body: String,
        in frame: BrowserFrame?,
        contentWorld: WKContentWorld,
        prepareArguments: @escaping @MainActor @Sendable () throws -> [String: Any],
        dispatchCheck: @escaping @MainActor @Sendable () throws -> Void = {}
    ) async throws -> Any {
        guard !closed else { throw ChromiumError.closed }
        if let webKit {
            if let frame, frame.webKit == nil { throw ChromiumError.staleFrame }
            let arguments = try prepareArguments()
            try dispatchCheck()
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
        return try await chromium.devTools.callAsync(
            body, in: frame, world: contentWorld, prepareArguments: prepareArguments, dispatchCheck: dispatchCheck
        )
    }



    func validateCredentialContext(_ context: WebAuthnContext) async throws {
        guard context.belongs(to: self) else { throw WebAuthnContextError.staleFrame }
        guard !isClosed else { throw WebAuthnContextError.closedPage }
        guard !isPrivate else { throw WebAuthnContextError.privateProfile }
        guard !isLoading, context.credentialGeneration == credentialGeneration,
              context.profileID == profileID, !context.isPrivate,
              context.frame.documentID == context.frameDocumentID,
              context.frame.securityOrigin == context.originEvidence,
              context.frame.hasTrustedSecurityOrigin else {
            throw WebAuthnContextError.staleFrame
        }
        let origin = try Self.credentialOrigin(context.frame.securityOrigin)
        guard origin.serialized == context.origin else { throw WebAuthnContextError.untrustedOrigin }
        if let chromium {
            let chain = try await chromium.devTools.frameChain(for: context.frame)
            guard let topFrame = chain.last, topFrame.isMainFrame,
                  chain.first?.documentID == context.frameDocumentID else {
                throw WebAuthnContextError.staleFrame
            }
            let top = try Self.credentialOrigin(topFrame.securityOrigin)
            let crossOrigin = try chain.contains {
                try Self.credentialOrigin($0.securityOrigin).serialized != origin.serialized
            }
            guard crossOrigin == context.crossOrigin,
                  (crossOrigin ? top.serialized : nil) == context.topOrigin,
                  let expectedExecutionContextID = context.executionContextID else {
                throw WebAuthnContextError.staleFrame
            }
            guard try await chromium.devTools.permissionsPolicyAllows(
                frame: context.frame, feature: context.policyFeature
            ) else { throw WebAuthnContextError.policyDenied }
            let executionContextID = try await chromium.devTools.executionContextIdentity(
                for: context.frame, world: PageAutomationGuard.world
            )
            guard executionContextID == expectedExecutionContextID else {
                throw WebAuthnContextError.staleFrame
            }
        } else {
            guard context.frame.isMainFrame, context.executionContextID == nil,
                  context.topOrigin == nil, !context.crossOrigin,
                  PageFrameRegistry.shared.isCurrent(context.frame, in: self),
                  await PageFrameRegistry.shared.isLive(context.frame, in: self) else {
                throw WebAuthnContextError.staleFrame
            }
            guard PageFrameRegistry.shared.mainFramePolicyAllows(
                context.frame, feature: context.policyFeature, in: self
            ) == true else {
                throw WebAuthnContextError.policyDenied
            }
        }
        guard !isClosed, !isLoading, credentialGeneration == context.credentialGeneration else {
            throw WebAuthnContextError.staleFrame
        }
    }

    func validateCredentialContextForDispatch(_ context: WebAuthnContext) throws {
        guard context.belongs(to: self), !isClosed else { throw WebAuthnContextError.closedPage }
        guard !isPrivate, !isLoading,
              credentialGeneration == context.credentialGeneration,
              context.profileID == profileID, !context.isPrivate,
              context.frame.documentID == context.frameDocumentID,
              context.frame.securityOrigin == context.originEvidence,
              context.frame.hasTrustedSecurityOrigin else {
            throw WebAuthnContextError.staleFrame
        }
        let origin = try Self.credentialOrigin(context.frame.securityOrigin)
        guard origin.serialized == context.origin else { throw WebAuthnContextError.untrustedOrigin }
        if let chromium {
            guard let executionContextID = context.executionContextID,
                  chromium.devTools.isCurrentCredentialContext(
                    frame: context.frame, executionContextID: executionContextID
                  ) else { throw WebAuthnContextError.staleFrame }
        } else {
            guard context.frame.isMainFrame, context.executionContextID == nil,
                  !context.crossOrigin, context.topOrigin == nil,
                  PageFrameRegistry.shared.isCurrent(context.frame, in: self) else {
                throw WebAuthnContextError.staleFrame
            }
            guard PageFrameRegistry.shared.mainFramePolicyAllows(
                context.frame, feature: context.policyFeature, in: self
            ) == true else { throw WebAuthnContextError.policyDenied }
        }
    }

    static func credentialOrigin(_ origin: BrowserSecurityOrigin) throws -> (url: URL, serialized: String) {
        guard let scheme = ["https", "http"].first(where: { $0 == origin.protocol }),
              let host = RelyingPartyPolicy.canonicalDomain(origin.host),
              scheme == "https" || (scheme == "http" && host == "localhost"),
              (0...65_535).contains(origin.port) else {
            throw WebAuthnContextError.insecureOrigin
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        let standardPort = scheme == "https" ? 443 : 80
        if origin.port != 0, origin.port != standardPort { components.port = origin.port }
        guard let url = components.url else { throw WebAuthnContextError.untrustedOrigin }
        let serialized = url.absoluteString.hasSuffix("/")
            ? String(url.absoluteString.dropLast())
            : url.absoluteString
        return (url, serialized)
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

    func insertText(_ text: String) async throws {
        guard !closed else { throw ChromiumError.closed }
        if let webKit {
            webKit.insertText(text)
        } else {
            try await chromium?.insertText(text)
        }
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
    func replaceScript(_ old: String, with new: String, in world: WKContentWorld) async throws {
        guard !closed else { throw ChromiumError.closed }
        if let webKit {
            let controller = webKit.configuration.userContentController
            let scripts = controller.userScripts
            let oldSource = Self.bridgeSource + "\n" + old
            let newSource = Self.bridgeSource + "\n" + new
            guard let index = scripts.firstIndex(where: {
                $0.source == oldSource && Self.scriptWorlds.object(forKey: $0) === world
            }) else {
                let scriptDetails = scripts.enumerated().map { index, script in
                    let scriptWorld = Self.scriptWorlds.object(forKey: script)
                    let scriptWorldName = scriptWorld.map {
                        $0 === WKContentWorld.page ? "page" : $0.name ?? "defaultClient"
                    } ?? "missing"
                    let scriptWorldIdentity = scriptWorld.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
                    return "\(index):length=\(script.source.count),matchesOld=\(script.source == oldSource),matchesNew=\(script.source == newSource),storedWorld=\(scriptWorldName)@\(scriptWorldIdentity),sameWorld=\(scriptWorld === world)"
                }
                let wantedWorldName = world === WKContentWorld.page ? "page" : world.name ?? "defaultClient"
                print("[TEMP WK replaceScript] oldLength=\(oldSource.count) newLength=\(newSource.count) wantedWorld=\(wantedWorldName)@\(ObjectIdentifier(world)) scripts=\(scriptDetails)")
                guard scripts.contains(where: {
                    $0.source == newSource && Self.scriptWorlds.object(forKey: $0) === world
                }) else { throw ChromiumError.staleFrame }
                return
            }
            let replaced = scripts[index]
            let replacement = WKUserScript(
                source: Self.bridgeSource + "\n" + new,
                injectionTime: replaced.injectionTime,
                forMainFrameOnly: replaced.isForMainFrameOnly,
                in: world
            )
            Self.scriptWorlds.setObject(world, forKey: replacement)
            controller.removeAllUserScripts()
            for (offset, script) in scripts.enumerated() {
                controller.addUserScript(offset == index ? replacement : script)
            }
        } else if let chromium {
            try await chromium.devTools.replaceScript(old, with: new, in: world)
        } else {
            throw ChromiumError.closed
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
        invalidateCredentialContexts()
        PageFrameRegistry.shared.retire(self)
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
