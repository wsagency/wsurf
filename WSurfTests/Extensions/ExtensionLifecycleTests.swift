// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized)
struct ExtensionLifecycleTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 2, "name": "Lifecycle probe", "description": "Lifecycle regression",
            "version": "1.0", "permissions": ["tabs", "webNavigation", "*://*/*"],
            "background": ["scripts": ["background.js"], "persistent": true],
            "browser_action": ["default_popup": "popup.html"],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: root.appendingPathComponent("manifest.json"))
        try """
        const nonce = crypto.randomUUID();
        chrome.runtime.onMessage.addListener((message, sender, reply) => reply({nonce}));
        """.write(to: root.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        return root
    }

    @Test(.boundedWebViews)
    func dormantTabMetadataDoesNotCreateAWebView() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: root))
        let browser = BrowserModel(database: .temporary())
        let manager = ExtensionManager(browser: browser, library: ExtensionLibrary(baseDirectory: root))
        let tab = BrowserTab(restoring: true)
        tab.urlString = "https://example.com/restored"
        tab.title = "Restored tab"
        let adapter = manager.adapter(for: tab)

        #expect(adapter.url(for: context)?.absoluteString == tab.urlString)
        #expect(adapter.title(for: context) == "Restored tab")
        #expect(adapter.isLoadingComplete(for: context))
        #expect(adapter.webView(for: context) == nil)
        #expect(!tab.isMaterialised, "metadata and frame access must not awaken a retained tab")
        tab.isLoading = true
        tab.urlString = "https://example.com/pending"
        #expect(adapter.pendingURL(for: context)?.absoluteString == tab.urlString)
        #expect(!adapter.isLoadingComplete(for: context))
        #expect(!tab.isMaterialised)
    }

    @Test(.boundedWebViews, .exclusiveExternalApp)
    func popupReopensWithoutResettingBackgroundAndInjectsRealFrames() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "lifecycle-" + UUID().uuidString.lowercased()
        let package = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        for name in ["manifest.json", "background.js"] {
            try FileManager.default.copyItem(at: root.appendingPathComponent(name), to: package.appendingPathComponent(name))
        }
        try "<!doctype html><body><script src='adapter.js'></script><script src='popup.js'></script>"
            .write(to: package.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try ExtensionShims.appleAdaptationSource
            .write(to: package.appendingPathComponent("adapter.js"), atomically: true, encoding: .utf8)
        try "document.documentElement.dataset.injected = 'yes';"
            .write(to: package.appendingPathComponent("inject.js"), atomically: true, encoding: .utf8)
        try """
        chrome.runtime.sendMessage({probe: true}, async reply => {
            document.body.dataset.nonce = reply.nonce;
            try {
                const tab = (await chrome.tabs.query({active:true, currentWindow:true}))[0];
                await wsurfAppleExecuteScript(tab.id, ['inject.js'], true);
                const frames = await wsurfAppleFrames({tabId:tab.id});
                document.body.dataset.frames = String(frames.length);
                document.body.dataset.ready = 'yes';
            } catch (error) { document.body.dataset.failure = error.message; }
        });
        """.write(to: package.appendingPathComponent("popup.js"), atomically: true, encoding: .utf8)

        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Parent</title><iframe src='/child'></iframe>"),
            "/child": .html("<!doctype html><title>Child</title>"),
        ])
        let browser = BrowserModel(database: .temporary())
        let library = ExtensionLibrary(baseDirectory: root)
        library.recordInstall(id: id)
        let manager = ExtensionManager(browser: browser, library: library)
        WebViewPool.shared.installExtensionController(manager.controller)
        let tab = browser.newTab(url: try server.url())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let anchor = NSView(frame: CGRect(x: 20, y: 20, width: 30, height: 30))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer {
            manager.setEnabled(false, id: id)
            browser.close(tab)
            window.close()
            WebViewPool.shared.installExtensionController(nil)
        }
        await manager.start()
        manager.registerAnchor(anchor, for: id)
        #expect(await waitUntil { !tab.isLoading && tab.committedURL != nil })
        manager.performAction(for: id)
        let action = try #require(manager.action(for: id))
        #expect(try await waitUntil {
            try await action.popupWebView?.evaluateJavaScript("document.body.dataset.ready") as? String == "yes"
        })
        let view = try #require(action.popupWebView)
        let nonce = try #require(try await view.evaluateJavaScript("document.body.dataset.nonce") as? String)
        #expect(try await view.evaluateJavaScript("document.body.dataset.frames") as? String == "2")
        #expect(try await tab.webView.evaluateJavaScript(
            "document.documentElement.dataset.injected === 'yes' && document.querySelector('iframe').contentDocument.documentElement.dataset.injected === 'yes'"
        ) as? Bool == true)
        _ = try await tab.webView.evaluateJavaScript("history.pushState({}, '', '/spa'); true")
        #expect(await waitUntil { adapterURL(manager, tab) == "/spa" })
        action.closePopup()
        manager.registerAnchor(anchor, for: id)
        manager.contexts[id]?.performAction(for: manager.adapter(for: tab))
        #expect(try await waitUntil {
            try await action.popupWebView?.evaluateJavaScript("document.body.dataset.ready") as? String == "yes"
        })
        #expect(try await action.popupWebView?.evaluateJavaScript("document.body.dataset.nonce") as? String == nonce)
    }

    private func adapterURL(_ manager: ExtensionManager, _ tab: BrowserTab) -> String? {
        guard let context = manager.contexts.values.first else { return nil }
        return manager.adapter(for: tab).url(for: context)?.path
    }
}
