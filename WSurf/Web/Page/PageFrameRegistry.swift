// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

@MainActor
final class PageFrameRegistry: NSObject, WKScriptMessageHandler {
    static let shared = PageFrameRegistry()
    static let handlerName = "wsurfFrameRegistry"
    static let script = """
        (() => {
          if (window.__wsurfFrameToken) return;
          const token = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('-');
          Object.defineProperty(window, '__wsurfFrameToken', { value: token });
          window.__wsurfSend('wsurfFrameRegistry', token);
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

    private final class Store {
        var root = ""
        var frames: [String: Target] = [:]
    }
    private let stores = NSMapTable<BrowserPage, Store>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func install(in controller: WKUserContentController) {
        controller.add(shared, contentWorld: PageAutomationGuard.world, name: handlerName)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: PageAutomationGuard.world))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let native = message.webView, let view = BrowserPage.from(native),
              let token = message.body as? String, token.count <= 80 else { return }
        let store = stores.object(forKey: view) ?? Store()
        stores.setObject(store, forKey: view)
        let frame = BrowserFrame(webKit: message.frameInfo, documentID: token)
        if message.frameInfo.isMainFrame {
            store.root = token
            store.frames = [:]
            return
        }
        guard !store.root.isEmpty, let url = message.frameInfo.request.url,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host()?.lowercased() == message.frameInfo.securityOrigin.host.lowercased(),
              url.scheme?.lowercased() == message.frameInfo.securityOrigin.protocol.lowercased(),
              Self.portMatches(url: url, securityPort: message.frameInfo.securityOrigin.port),
              store.frames.count < 256 else { return }
        store.frames[token] = Target(id: token, root: store.root, frame: frame, url: url)
    }

    func targets(in view: BrowserPage) async -> [Target] {
        if let chromium = view.chromium, let frames = try? await chromium.frames() {
            return frames.filter { !$0.isMainFrame }.prefix(256).compactMap { frame in
                guard let url = frame.request.url,
                      ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return Target(id: frame.chromiumID ?? frame.documentID, root: frame.documentID, frame: frame, url: url)
            }.sorted { $0.id < $1.id }
        }
        return Array(stores.object(forKey: view)?.frames.values ?? [String: Target]().values).sorted { $0.id < $1.id }
    }

    nonisolated static func portMatches(url: URL, securityPort: Int) -> Bool {
        let standard = url.scheme?.lowercased() == "https" ? 443 : 80
        return (url.port ?? standard) == (securityPort == 0 ? standard : securityPort)
    }

    func target(_ id: String, in view: BrowserPage) -> Target? {
        stores.object(forKey: view)?.frames[id]
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
        if let chromium = view.chromium {
            return (try? await chromium.isLive(frame: target.frame)) == true
        }
        guard let token = try? await view.evaluateJavaScript(
            "window.__wsurfFrameToken", in: target.frame, contentWorld: PageAutomationGuard.world) as? String else { return false }
        return token == target.id && isCurrent(target, in: view)
    }
}

extension PageDriver {
    @TaskLocal static var selectedFrame: PageFrameRegistry.Target?
}
