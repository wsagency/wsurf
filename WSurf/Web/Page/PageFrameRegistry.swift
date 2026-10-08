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
        var mainFrame: BrowserFrame?
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
            store.mainFrame = frame
            store.frames = [:]
            return
        }
        guard !store.root.isEmpty, let url = message.frameInfo.request.url,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host()?.lowercased() == message.frameInfo.securityOrigin.host.lowercased(),
              url.scheme?.lowercased() == message.frameInfo.securityOrigin.protocol.lowercased(),
              Self.portMatches(url: url, securityPort: message.frameInfo.securityOrigin.port),
              store.frames.count < 256 else { return }
        let previousDocuments = store.frames.filter {
            $0.key != token
                && ($0.value.frame.webKit === message.frameInfo
                    || $0.value.frame.webKit?.isEqual(message.frameInfo) == true)
        }.map { $0.key }
        for id in previousDocuments {
            store.frames[id] = nil
        }
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
    func sourceFrame(_ source: WKFrameInfo, in view: BrowserPage) -> BrowserFrame? {
        guard let store = stores.object(forKey: view) else { return nil }
        var registered: [BrowserFrame] = []
        if let mainFrame = store.mainFrame {
            registered.append(mainFrame)
        }
        registered.append(contentsOf: store.frames.values.map { $0.frame })
        if let exact = registered.first(where: {
            $0.webKit === source || $0.webKit?.isEqual(source) == true
        }) { return exact }
        let request = BrowserFrame(webKit: source)
        let candidates = registered.filter {
            $0.isMainFrame == request.isMainFrame
                && $0.request.url == request.request.url
                && $0.securityOrigin == request.securityOrigin
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    func isCurrent(_ frame: BrowserFrame, in view: BrowserPage) -> Bool {
        guard let store = stores.object(forKey: view), !frame.documentID.isEmpty else { return false }
        if store.mainFrame === frame {
            return store.root == frame.documentID
        }
        return store.frames[frame.documentID]?.frame === frame && store.root != ""
    }

    func isLive(_ frame: BrowserFrame, in view: BrowserPage) async -> Bool {
        if let chromium = view.chromium {
            return (try? await chromium.isLive(frame: frame)) == true
        }
        guard isCurrent(frame, in: view) else { return false }
        guard let token = try? await view.evaluateJavaScript(
            "window.__wsurfFrameToken", in: frame, contentWorld: PageAutomationGuard.world
        ) as? String else { return false }
        return token == frame.documentID && isCurrent(frame, in: view)
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
