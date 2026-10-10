// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

@MainActor
final class PageFrameRegistry: NSObject, WKScriptMessageHandlerWithReply {
    static let shared = PageFrameRegistry()
    static let handlerName = "wsurfFrameRegistry"
    static let acknowledgementHandlerName = "wsurfFrameRegistryAck"
    static let resumeHandlerName = "wsurfFrameRegistryResume"
    static let markerName = "__wsurfNativeFrameNonce"
    static let readyName = "__wsurfNativeFrameReady"
    static let script = """
        (() => {
          const reply = globalThis.webkit?.messageHandlers?.wsurfFrameRegistry;
          const acknowledge = globalThis.webkit?.messageHandlers?.wsurfFrameRegistryAck;
          const resume = globalThis.webkit?.messageHandlers?.wsurfFrameRegistryResume;
          if (!reply || !acknowledge || !resume || globalThis.__wsurfNativeFrameNonce || globalThis.__wsurfNativeFrameReady) return;
          let epoch = 0;
          let resolveCurrentReady;
          let currentReady = new Promise(resolve => { resolveCurrentReady = resolve; });
          Object.defineProperties(globalThis, {
            '__wsurfNativeFrameReady': {
              get: () => currentReady, configurable: false, enumerable: false
            },
            '__wsurfNativeFrameEpoch': {
              get: () => epoch, configurable: false, enumerable: false
            }
          });
          const settle = (issuedEpoch, resolver, value) => {
            if (issuedEpoch !== epoch || resolver !== resolveCurrentReady) return;
            resolveCurrentReady = null;
            resolver(value === true);
          };
          const rearm = () => {
            let resolver;
            currentReady = new Promise(resolve => { resolver = resolve; });
            resolveCurrentReady = resolver;
            return resolver;
          };
          addEventListener('pagehide', event => {
            if (!event.isTrusted) return;
            epoch += 1;
            resolveCurrentReady?.(false);
            resolveCurrentReady = null;
            currentReady = Promise.resolve(false);
          });
          addEventListener('pageshow', event => {
            if (globalThis !== globalThis.top || !event.isTrusted || !event.persisted) return;
            const issuedEpoch = epoch;
            const resolver = rearm();
            const nonce = globalThis.__wsurfNativeFrameNonce;
            if (typeof nonce !== 'string' || nonce.length === 0) {
              settle(issuedEpoch, resolver, false);
              return;
            }
            resume.postMessage({nonce, epoch: issuedEpoch}).then(
              accepted => settle(issuedEpoch, resolver, accepted),
              () => settle(issuedEpoch, resolver, false)
            );
          });
          const initialEpoch = epoch;
          const initialResolver = resolveCurrentReady;
          reply.postMessage(null).then(nonce => {
            if (typeof nonce !== 'string' || nonce.length === 0 || nonce.length > 64) {
              throw new TypeError('Native frame nonce is invalid.');
            }
            Object.defineProperty(globalThis, '__wsurfNativeFrameNonce', {
              value: nonce, writable: false, configurable: false, enumerable: false
            });
            return acknowledge.postMessage(nonce);
          }).then(
            accepted => settle(initialEpoch, initialResolver, accepted),
            () => settle(initialEpoch, initialResolver, false)
          );
        })();
        """

    final class Target {
        let id: String
        let root: String
        let frame: BrowserFrame
        let url: URL
        init(id: String, root: String, frame: BrowserFrame, url: URL) {
            self.id = id
            self.root = root
            self.frame = frame
            self.url = url
        }
    }

    private struct MainResponse {
        let navigation: WKNavigation
        let url: URL
        let permissionsPolicy: String?
    }

    private struct IssuedFrame {
        let frame: BrowserFrame
        let navigation: WKNavigation?
    }

    private final class RestorableMainFrame {
        let securityOrigin: BrowserSecurityOrigin
        let response: MainResponse?
        let children: [Target]

        init(securityOrigin: BrowserSecurityOrigin, response: MainResponse?, children: [Target]) {
            self.securityOrigin = securityOrigin
            self.response = response
            self.children = children
        }
    }

    private final class Store {
        var root = ""
        var mainFrame: BrowserFrame?
        var mainFrameNavigation: WKNavigation?
        var frames: [String: Target] = [:]
        var issued: [String: IssuedFrame] = [:]
        var restorationToken: UUID?
        var restorable: [String: RestorableMainFrame] = [:]
        var restorableOrder: [String] = []
        var activeNavigation: WKNavigation?
        var supersededNavigations: [WKNavigation] = []
        var pendingResponse: MainResponse?
        var committedResponse: MainResponse?
        var committedNavigation: WKNavigation?
        var policyRootNonce: String?
    }
    private let stores = NSMapTable<BrowserPage, Store>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func install(in controller: WKUserContentController) {
        controller.addScriptMessageHandler(shared, contentWorld: PageAutomationGuard.world, name: handlerName)
        controller.addScriptMessageHandler(shared, contentWorld: PageAutomationGuard.world, name: acknowledgementHandlerName)
        controller.addScriptMessageHandler(shared, contentWorld: PageAutomationGuard.world, name: resumeHandlerName)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: PageAutomationGuard.world))
    }

    func navigationStarted(_ navigation: WKNavigation?, in view: BrowserPage) {
        let store = store(for: view)
        print("[TEMP registry navStart] nav=\(navigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") active=\(store.activeNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") committed=\(store.committedNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") root=\(store.root) archives=\(store.restorable.keys.sorted())")
        if let active = store.activeNavigation, active !== navigation {
            if !store.supersededNavigations.contains(where: { $0 === active }) {
                store.supersededNavigations.append(active)
            }
            store.issued = store.issued.filter { $0.value.navigation !== active }
        }
        store.activeNavigation = navigation
        store.pendingResponse = nil
        store.restorationToken = nil
        view.invalidateCredentialContexts()
    }

    func recordMainFrameResponse(_ navigationResponse: WKNavigationResponse, in view: BrowserPage) {
        let store = store(for: view)
        guard navigationResponse.isForMainFrame,
              let active = store.activeNavigation,
              let response = navigationResponse.response as? HTTPURLResponse,
              (200..<400).contains(response.statusCode),
              store.supersededNavigations.isEmpty,
              let url = response.url else {
            store.pendingResponse = nil
            return
        }
        let policy = response.allHeaderFields.first {
            String(describing: $0.key).caseInsensitiveCompare("Permissions-Policy") == .orderedSame
        }.map { String(describing: $0.value) }
        store.pendingResponse = MainResponse(
            navigation: active,
            url: url,
            permissionsPolicy: policy
        )
    }

    func navigationCommitted(_ navigation: WKNavigation?, in view: BrowserPage) {
        guard let navigation else { return }
        let store = store(for: view)
        print("[TEMP registry navCommit] nav=\(String(describing: ObjectIdentifier(navigation))) active=\(store.activeNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") committed=\(store.committedNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") root=\(store.root) archives=\(store.restorable.keys.sorted())")
        if let index = store.supersededNavigations.firstIndex(where: { $0 === navigation }) {
            store.supersededNavigations.remove(at: index)
            return
        }
        guard store.activeNavigation === navigation else { return }
        let acceptedCurrentDocument = store.mainFrameNavigation === navigation
        if !acceptedCurrentDocument { archiveCurrentMainFrame(store) }
        if store.pendingResponse?.navigation === navigation, store.supersededNavigations.isEmpty {
            store.committedResponse = store.pendingResponse
        } else {
            store.committedResponse = nil
        }
        store.activeNavigation = nil
        store.committedNavigation = navigation
        store.pendingResponse = nil
        store.issued = store.issued.filter { $0.value.navigation === navigation }
        if acceptedCurrentDocument, let frame = store.mainFrame {
            store.root = frame.documentID
            bindCommittedPolicy(store, to: frame)
        } else {
            store.root = ""
            store.mainFrame = nil
            store.mainFrameNavigation = nil
            store.frames.removeAll()
            store.policyRootNonce = nil
            store.restorationToken = nil
        }
        pruneRestorable(in: view)
        print("[TEMP registry committed] nav=\(String(describing: ObjectIdentifier(navigation))) committed=\(store.committedNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") root=\(store.root) main=\(store.mainFrame?.documentID ?? "nil") archives=\(store.restorable.keys.sorted())")
    }

    func navigationFailed(_ navigation: WKNavigation?, in view: BrowserPage) {
        guard let navigation else { return }
        let store = store(for: view)
        if let index = store.supersededNavigations.firstIndex(where: { $0 === navigation }) {
            store.supersededNavigations.remove(at: index)
            return
        }
        guard store.activeNavigation === navigation else { return }
        store.activeNavigation = nil
        store.pendingResponse = nil
        store.issued = store.issued.filter { $0.value.navigation !== navigation }
        if store.mainFrameNavigation === navigation {
            store.root = ""
            store.mainFrame = nil
            store.mainFrameNavigation = nil
            store.frames.removeAll()
            store.policyRootNonce = nil
            if store.committedNavigation === navigation {
                store.committedNavigation = nil
                store.committedResponse = nil
            }
            store.restorationToken = nil
        }
    }
    func retire(_ view: BrowserPage) {
        if let store = stores.object(forKey: view) {
            store.activeNavigation = nil
            store.pendingResponse = nil
            store.committedResponse = nil
            store.committedNavigation = nil
            store.mainFrameNavigation = nil
            store.mainFrame = nil
            store.root = ""
            store.policyRootNonce = nil
            store.frames.removeAll()
            store.issued.removeAll()
            store.restorable.removeAll()
            store.supersededNavigations.removeAll()
            store.restorableOrder.removeAll()
            store.restorationToken = nil
        }
        stores.removeObject(forKey: view)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let native = message.webView, let view = BrowserPage.from(native) else {
            replyHandler(nil, "Frame is unavailable.")
            return
        }
        let store = store(for: view)
        if message.name == Self.handlerName {
            let frame = BrowserFrame(webKit: message.frameInfo)
            guard let url = frame.request.url,
                  frame.isMainFrame || (
                    frame.hasTrustedSecurityOrigin && Self.urlMatches(url, origin: frame.securityOrigin)
                  ) else {
                replyHandler(nil, "Frame origin is unavailable.")
                return
            }
            let nonce = UUID().uuidString.lowercased()
            let navigation = store.activeNavigation ?? store.committedNavigation
            store.issued[nonce] = IssuedFrame(frame: frame, navigation: navigation)
            replyHandler(nonce, nil)
            return
        }
        if message.name == Self.resumeHandlerName {
            guard let body = message.body as? [String: Any],
                  let nonce = body["nonce"] as? String,
                  let epoch = body["epoch"] as? Int,
                  epoch >= 0 else {
                replyHandler(false, nil)
                return
            }
            print("[TEMP registry resumeRequest] nonce=\(nonce) epoch=\(epoch) url=\(message.frameInfo.request.url?.absoluteString ?? "nil") active=\(store.activeNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") committed=\(store.committedNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") root=\(store.root) archives=\(store.restorable.keys.sorted())")
            let frameInfo = message.frameInfo
            Task { @MainActor [weak self, weak view] in
                guard let self, let view else {
                    replyHandler(false, nil)
                    return
                }
                let accepted = await self.resumeMainFrame(
                    nonce, epoch: epoch, frameInfo: frameInfo, in: view
                )
                replyHandler(accepted, accepted ? nil : "Frame restoration was refused.")
            }
            return
        }
        guard message.name == Self.acknowledgementHandlerName,
              let nonce = message.body as? String,
              acknowledge(nonce, frameInfo: message.frameInfo, in: view) else {
            replyHandler(nil, "Frame acknowledgement was refused.")
            return
        }
        replyHandler(true, nil)
    }

    private func acknowledge(_ nonce: String, frameInfo: WKFrameInfo, in view: BrowserPage) -> Bool {
        guard let store = stores.object(forKey: view),
              let issued = store.issued.removeValue(forKey: nonce),
              Self.sameNavigation(issued.navigation, store.activeNavigation ?? store.committedNavigation) else {
            return false
        }
        let frame = BrowserFrame(webKit: frameInfo, documentID: nonce)
        guard frame.isMainFrame == issued.frame.isMainFrame,
              frame.securityOrigin == issued.frame.securityOrigin,
              frame.request.url == issued.frame.request.url,
              let url = frame.request.url else { return false }
        if frame.isMainFrame {
            if !store.root.isEmpty, store.root != nonce { archiveCurrentMainFrame(store) }
            if store.root != nonce, !store.root.isEmpty {
                view.invalidateCredentialContexts()
                store.frames.removeAll()
                store.policyRootNonce = nil
            }
            store.restorationToken = nil
            store.root = nonce
            store.mainFrame = frame
            store.mainFrameNavigation = issued.navigation
            bindCommittedPolicy(store, to: frame)
            return true
        }
        guard frame.hasTrustedSecurityOrigin,
              Self.urlMatches(url, origin: frame.securityOrigin),
              !store.root.isEmpty, store.frames.count < 256 else { return false }
        store.frames[nonce] = Target(id: nonce, root: store.root, frame: frame, url: url)
        return true
    }

    private func resumeMainFrame(
        _ nonce: String,
        epoch: Int,
        frameInfo: WKFrameInfo,
        in view: BrowserPage
    ) async -> Bool {
        let store = stores.object(forKey: view)
        let archived = store?.restorable[nonce]
        print("[TEMP registry resumeStart] nonce=\(nonce) epoch=\(epoch) active=\(store?.activeNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") committed=\(store?.committedNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") root=\(store?.root ?? "nil") archive=\(archived.map { String(describing: ObjectIdentifier($0)) } ?? "nil") archives=\(store?.restorable.keys.sorted() ?? [])")
        guard let store, store.activeNavigation == nil, store.root.isEmpty,
              let archived, let navigation = store.committedNavigation else {
            print("[TEMP registry resumeReject] preflight nonce=\(nonce) epoch=\(epoch)")
            return false
        }
        let frame = BrowserFrame(webKit: frameInfo, documentID: nonce)
        guard frame.isMainFrame,
              frame.securityOrigin == archived.securityOrigin,
              archived.response.map({ Self.sameOrigin($0.url, frame.securityOrigin) }) ?? true else {
            print("[TEMP registry resumeReject] frame nonce=\(nonce) epoch=\(epoch) main=\(frame.isMainFrame) origin=\(frame.securityOrigin) archivedOrigin=\(archived.securityOrigin)")
            return false
        }
        let proof: [String: Any]
        do {
            guard let value = try await view.callAsyncJavaScript(
                "return {nonce: globalThis.__wsurfNativeFrameNonce, epoch: globalThis.__wsurfNativeFrameEpoch};",
                in: nil,
                contentWorld: PageAutomationGuard.world
            ) as? [String: Any] else {
                print("[TEMP registry resumeReject] proofUnavailable nonce=\(nonce) epoch=\(epoch)")
                return false
            }
            proof = value
        } catch {
            print("[TEMP registry resumeReject] proofError nonce=\(nonce) epoch=\(epoch) error=\(error)")
            return false
        }
        let currentStore = stores.object(forKey: view)
        print("[TEMP registry resumeProof] nonce=\(nonce) epoch=\(epoch) proof=\(proof) nav=\(String(describing: ObjectIdentifier(navigation))) active=\(store.activeNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") committed=\(store.committedNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") root=\(store.root) archiveSame=\(store.restorable[nonce] === archived) storeSame=\(currentStore === store)")
        guard proof["nonce"] as? String == nonce,
              proof["epoch"] as? Int == epoch,
              currentStore === store,
              store.activeNavigation == nil,
              store.committedNavigation === navigation,
              store.root.isEmpty,
              store.restorable[nonce] === archived else {
            print("[TEMP registry resumeReject] proof nonce=\(nonce) epoch=\(epoch) proof=\(proof)")
            return false
        }
        store.restorable[nonce] = nil
        store.restorableOrder.removeAll { $0 == nonce }
        store.root = nonce
        store.mainFrame = frame
        store.mainFrameNavigation = navigation
        store.committedResponse = archived.response
        store.frames.removeAll()
        store.policyRootNonce = nil
        bindCommittedPolicy(store, to: frame)

        let token = UUID()
        store.restorationToken = token
        for child in archived.children where child.root == nonce {
            guard isRestoringChildren(token, store: store, navigation: navigation, mainFrame: frame, nonce: nonce, in: view) else {
                return true
            }
            guard ["http", "https"].contains(child.url.scheme?.lowercased() ?? ""),
                  store.frames.count < 256 else { continue }
            let restoredChild = Target(id: child.id, root: nonce, frame: child.frame, url: child.url)
            let live = await isLiveDocument(restoredChild.frame, in: view)
            guard isRestoringChildren(token, store: store, navigation: navigation, mainFrame: frame, nonce: nonce, in: view) else {
                return true
            }
            if live, store.frames.count < 256 {
                store.frames[restoredChild.id] = restoredChild
            }
        }
        if isRestoringChildren(token, store: store, navigation: navigation, mainFrame: frame, nonce: nonce, in: view) {
            store.restorationToken = nil
        }
        return true
    }

    private func isRestoringChildren(
        _ token: UUID,
        store: Store,
        navigation: WKNavigation,
        mainFrame: BrowserFrame,
        nonce: String,
        in view: BrowserPage
    ) -> Bool {
        guard let currentStore = stores.object(forKey: view) else { return false }
        return currentStore === store
            && store.restorationToken == token
            && store.activeNavigation == nil
            && store.committedNavigation === navigation
            && store.root == nonce
            && store.mainFrame.map({ $0 === mainFrame }) == true
    }

    private static func sameNavigation(_ lhs: WKNavigation?, _ rhs: WKNavigation?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs === rhs
        default:
            return false
        }
    }

    private func store(for view: BrowserPage) -> Store {
        if let store = stores.object(forKey: view) { return store }
        let store = Store()
        stores.setObject(store, forKey: view)
        return store
    }

    private func archiveCurrentMainFrame(_ store: Store) {
        guard let frame = store.mainFrame, store.root == frame.documentID else { return }
        let nonce = frame.documentID
        store.restorableOrder.removeAll { $0 == nonce }
        store.restorable[nonce] = RestorableMainFrame(
            securityOrigin: frame.securityOrigin,
            response: store.committedResponse,
            children: store.frames.values
                .filter { $0.root == nonce && ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") }
                .sorted { $0.id < $1.id }
        )
        store.restorableOrder.append(nonce)
        print("[TEMP registry archive] nonce=\(nonce) navigation=\(store.committedNavigation.map { String(describing: ObjectIdentifier($0)) } ?? "nil") origin=\(frame.securityOrigin.`protocol`)://\(frame.securityOrigin.host):\(frame.securityOrigin.port) archives=\(store.restorable.keys.sorted())")
    }

    private func pruneRestorable(in view: BrowserPage) {
        guard let store = stores.object(forKey: view),
              let history = view.webKit?.backForwardList else { return }
        let historySize = history.backList.count + history.forwardList.count + 1
        while store.restorableOrder.count > historySize {
            let retired = store.restorableOrder.removeFirst()
            store.restorable[retired] = nil
        }
    }
    func mainFrame(in view: BrowserPage) -> BrowserFrame? {
        guard let store = stores.object(forKey: view), store.root == store.mainFrame?.documentID else { return nil }
        return store.mainFrame
    }


    func currentMainFrame(
        matching messageFrame: BrowserFrame,
        documentNonce: String,
        in view: BrowserPage
    ) -> BrowserFrame? {
        guard view.webKit != nil, messageFrame.webKit != nil, messageFrame.isMainFrame,
              messageFrame.hasTrustedSecurityOrigin, !documentNonce.isEmpty,
              let store = stores.object(forKey: view),
              store.root == documentNonce,
              let current = store.mainFrame, current.documentID == documentNonce,
              current.securityOrigin == messageFrame.securityOrigin,
              isCurrent(current, in: view) else { return nil }
        return current
    }
    func mainFramePolicyAllows(_ frame: BrowserFrame, feature: String, in view: BrowserPage) -> Bool? {
        guard frame.isMainFrame, let store = stores.object(forKey: view),
              store.activeNavigation == nil,
              store.root == frame.documentID, store.policyRootNonce == frame.documentID,
              let response = store.committedResponse,
              Self.sameOrigin(response.url, frame.securityOrigin) else { return nil }
        guard let header = response.permissionsPolicy else { return true }
        return PermissionsPolicyHeader.allows(feature, origin: frame.securityOrigin, header: header)
    }

    func isCurrent(_ frame: BrowserFrame, in view: BrowserPage) -> Bool {
        guard !frame.documentID.isEmpty,
              let store = stores.object(forKey: view) else { return false }
        if frame.isMainFrame {
            return store.root == frame.documentID && store.mainFrame?.documentID == frame.documentID
                && store.mainFrame?.securityOrigin == frame.securityOrigin
        }
        guard frame.hasTrustedSecurityOrigin else { return false }
        return store.root != "" && store.frames[frame.documentID]?.frame.securityOrigin == frame.securityOrigin
    }

    private func isLiveDocument(_ frame: BrowserFrame, in view: BrowserPage) async -> Bool {
        guard let value = try? await view.callAsyncJavaScript(
            "return globalThis.__wsurfNativeFrameNonce === nonce;",
            arguments: ["nonce": frame.documentID],
            in: frame,
            contentWorld: PageAutomationGuard.world
        ) as? Bool else { return false }
        return value
    }

    func isLive(_ frame: BrowserFrame, in view: BrowserPage) async -> Bool {
        if let chromium = view.chromium {
            return (try? await chromium.isLive(frame: frame)) == true
        }
        guard isCurrent(frame, in: view) else { return false }
        let live = await isLiveDocument(frame, in: view)
        return live && isCurrent(frame, in: view)
    }

    private func bindCommittedPolicy(_ store: Store, to frame: BrowserFrame) {
        guard let response = store.committedResponse, Self.sameOrigin(response.url, frame.securityOrigin) else {
            store.policyRootNonce = nil
            return
        }
        store.policyRootNonce = frame.documentID
    }

    private static func urlMatches(_ url: URL, origin: BrowserSecurityOrigin) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        return ["https", "http"].contains(scheme)
            && url.host()?.lowercased() == origin.host
            && scheme == origin.protocol
            && portMatches(url: url, securityPort: origin.port)
    }

    private static func sameOrigin(_ url: URL, _ origin: BrowserSecurityOrigin) -> Bool {
        url.scheme?.lowercased() == origin.protocol
            && url.host()?.lowercased() == origin.host
            && portMatches(url: url, securityPort: origin.port)
    }


    func targets(in view: BrowserPage) async -> [Target] {
        if let chromium = view.chromium, let frames = try? await chromium.frames() {
            return frames.filter { !$0.isMainFrame }.prefix(256).compactMap { frame in
                guard let url = frame.request.url,
                      ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return Target(id: frame.chromiumID ?? frame.documentID, root: frame.documentID, frame: frame, url: url)
            }.sorted { $0.id < $1.id }
        }
        guard let store = stores.object(forKey: view), store.restorationToken == nil else { return [] }
        return Array(store.frames.values).sorted { $0.id < $1.id }
    }

    nonisolated static func portMatches(url: URL, securityPort: Int) -> Bool {
        let standard = url.scheme?.lowercased() == "https" ? 443 : 80
        return (url.port ?? standard) == (securityPort == 0 ? standard : securityPort)
    }

    func target(_ id: String, in view: BrowserPage) -> Target? {
        guard let store = stores.object(forKey: view), store.restorationToken == nil else { return nil }
        return store.frames[id]
    }

    func isCurrent(_ target: Target, in view: BrowserPage) -> Bool {
        if view.engine == .chromium {
            return !target.frame.documentID.isEmpty
        }
        let store = stores.object(forKey: view)
        return store?.root == target.root && store?.frames[target.id] === target
    }

    func isLive(_ target: Target, in view: BrowserPage) async -> Bool {
        guard isCurrent(target, in: view) else { return false }
        return await isLive(target.frame, in: view)
    }
}
private enum PermissionsPolicyHeader {
    static func allows(_ feature: String, origin: BrowserSecurityOrigin, header: String) -> Bool? {
        let matching = splitDirectives(header).filter { directive in
            guard let equals = directive.firstIndex(of: "=") else { return false }
            return directive[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(feature) == .orderedSame
        }
        guard !matching.isEmpty else { return true }
        guard matching.count == 1, let equals = matching[0].firstIndex(of: "=") else { return nil }
        let value = matching[0][matching[0].index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "*" { return true }
        guard value.first == "(", value.last == ")" else { return nil }
        let allowlist = value.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !allowlist.isEmpty else { return false }
        if allowlist == "*" { return true }
        let originString = canonicalOrigin(origin)
        for rawToken in allowlist.split(whereSeparator: \.isWhitespace) {
            let token = String(rawToken)
            if token == "self" || token == "'self'" { return true }
            if token.first == "\"", token.last == "\"",
               canonicalOrigin(String(token.dropFirst().dropLast())) == originString {
                return true
            }
        }
        return false
    }

    private static func splitDirectives(_ header: String) -> [String] {
        var directives: [String] = []
        var start = header.startIndex
        var depth = 0
        var quoted = false
        var index = start
        while index < header.endIndex {
            let character = header[index]
            if character == "\"" { quoted.toggle() }
            else if !quoted {
                if character == "(" { depth += 1 }
                else if character == ")" { depth = max(0, depth - 1) }
                else if character == ",", depth == 0 {
                    directives.append(String(header[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines))
                    start = header.index(after: index)
                }
            }
            index = header.index(after: index)
        }
        let last = String(header[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { directives.append(last) }
        return directives
    }

    private static func canonicalOrigin(_ origin: BrowserSecurityOrigin) -> String {
        let port = origin.port == 0 || origin.port == (origin.protocol == "https" ? 443 : 80)
            ? "" : ":\(origin.port)"
        return "\(origin.protocol)://\(origin.host)\(port)"
    }

    private static func canonicalOrigin(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let port = components.port
        let standard = scheme == "https" ? 443 : 80
        let portSuffix: String
        if let port, port != standard {
            portSuffix = ":\(port)"
        } else {
            portSuffix = ""
        }
        return "\(scheme)://\(host)\(portSuffix)"
    }
}

extension PageDriver {
    @TaskLocal static var selectedFrame: PageFrameRegistry.Target?
}
