// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Testing
import WebKit

@testable import WSurf

/// Extensions hear a tab's address, title and loading changes (`tabs.onUpdated`), exactly when they may see that tab.
///
/// `BrowserTab` raises the change for both engines (it reads the `BrowserPage` seam through `refreshChrome`), so the sink
/// tests drive the tab's own properties and read what the manager would send. The last test runs real extensions on a
/// WebKit page served from 127.0.0.1. A Chromium page needs no separate path: its `BrowserPage` writes the same properties.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ExtensionTabEventTests {
    private static let id = "tab-events"

    @MainActor
    private final class Sent {
        var changes: [WKWebExtension.TabChangedProperties] = []
    }

    private struct Rig {
        let manager: ExtensionManager
        let browser: BrowserModel
        let context: BrowserProfileContext
        let sent: Sent
    }

    private static func write(_ manifest: String, as id: String, in library: ExtensionLibrary) throws {
        let package = library.packageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: package.appendingPathComponent("manifest.json"))
        library.recordInstall(id: id)
    }

    private static func manifest(permissions: [String] = [], hosts: [String] = []) -> String {
        let list = { (values: [String]) in "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        return #"{"manifest_version":3,"name":"Tab events","version":"1.0","permissions":\#(list(permissions)),"host_permissions":\#(list(hosts))}"#
    }

    /// Runs `body` with one loaded extension, a browser registered with its manager, and the manager's sink recording.
    private func withRig(
        privately: Bool = false,
        manifest: String,
        _ body: (Rig) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-extension-tab-events-\(UUID().uuidString)", isDirectory: true)
        ExtensionManager.systemCatalogue = []
        let context = privately
            ? BrowserProfileContext.shared(for: .privateBrowsing())
            : BrowserProfileContext(profile: .original())
        let library = ExtensionLibrary(baseDirectory: directory, profile: context.profile)
        try Self.write(manifest, as: Self.id, in: library)
        context.extensions = ExtensionManager(profile: context.profile, dataStore: context.dataStore, library: library)
        let manager = context.extensions
        let sent = Sent()
        manager.tabChangeSink = { properties, _ in sent.changes.append(properties) }
        let browser = BrowserModel(context: context)
        manager.register(browser: browser)

        func finish() async {
            manager.stop()
            browser.closeAllTabs(saving: false)
            try? FileManager.default.removeItem(at: directory)
            if privately {
                await context.endPrivateSession()
            }
        }
        do {
            await manager.start()
            try #require(Set(manager.contexts.keys) == [Self.id])
            try await body(Rig(manager: manager, browser: browser, context: context, sent: sent))
        } catch {
            await finish()
            throw error
        }
        await finish()
    }

    @Test func anExtensionWithTheTabsPermissionHearsEachRealChangeOnce() async throws {
        try await withRig(manifest: Self.manifest(permissions: ["tabs"])) { rig in
            let tab = rig.browser.newTab()
            rig.sent.changes.removeAll()

            tab.committedURL = URL(string: "https://wsurf.test/page")
            tab.pageTitle = "Loaded"
            tab.isLoading = true
            #expect(rig.sent.changes == [.URL, .title, .loading])

            // The same values again are not changes.
            tab.committedURL = URL(string: "https://wsurf.test/page")
            tab.pageTitle = "Loaded"
            tab.isLoading = true
            #expect(rig.sent.changes == [.URL, .title, .loading])

            tab.customTitle = "Mine"
            #expect(rig.sent.changes == [.URL, .title, .loading, .title])
        }
    }

    @Test func anExtensionWithNoAccessToTheTabLearnsNothing() async throws {
        try await withRig(manifest: Self.manifest()) { rig in
            let tab = rig.browser.newTab()

            tab.committedURL = URL(string: "https://wsurf.test/page")
            tab.pageTitle = "Secret title"
            tab.isLoading = true

            #expect(rig.sent.changes.isEmpty)
        }
    }

    @Test func hostAccessToTheTabsSiteIsEnoughAndOtherSitesAreNotReported() async throws {
        try await withRig(manifest: Self.manifest(hosts: ["https://allowed.test/*"])) { rig in
            let tab = rig.browser.newTab()

            tab.committedURL = URL(string: "https://allowed.test/page")
            rig.sent.changes.removeAll()
            tab.pageTitle = "Allowed"
            #expect(rig.sent.changes == [.title])

            tab.committedURL = URL(string: "https://elsewhere.test/page")
            rig.sent.changes.removeAll()
            tab.pageTitle = "Elsewhere"
            tab.isLoading = true
            #expect(rig.sent.changes.isEmpty)
        }
    }

    @Test func aPrivateWindowsTabsSendNothingEvenToAnExtensionWithEveryPermission() async throws {
        try await withRig(privately: true, manifest: Self.manifest(permissions: ["tabs"], hosts: ["<all_urls>"])) { rig in
            let tab = rig.browser.newTab()
            // WSurf has no private-browsing allowance; even a context that was given access must hear nothing.
            rig.manager.contexts[Self.id]?.hasAccessToPrivateData = true

            tab.committedURL = URL(string: "https://wsurf.test/private")
            tab.pageTitle = "Private title"
            tab.isLoading = true

            #expect(rig.sent.changes.isEmpty)
        }
    }

    @Test func aTabOfAnUnregisteredWindowIsNeverReported() async throws {
        try await withRig(manifest: Self.manifest(permissions: ["tabs"])) { rig in
            let other = BrowserModel(database: .temporary())
            defer { other.closeAllTabs(saving: false) }
            let stray = other.newTab()

            stray.committedURL = URL(string: "https://wsurf.test/stray")
            stray.pageTitle = "Stray"

            #expect(rig.sent.changes.isEmpty)
        }
    }

    /// Two real extensions on a real WebKit page: the one with `tabs` hears the load; the one without hears nothing of the
    /// address or title. Each extension marks what it heard by opening a tab on the fixture server.
    @Test func aBackgroundWorkerHearsATabLoadAndOneWithoutPermissionNeverHearsItsAddress() async throws {
        let server = try await HTTPFixtureServer.start(routes: ["/page": .html("<title>Loaded</title>")])
        defer { withExtendedLifetime(server) {} }
        let page = try server.url("/page").absoluteString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-extension-tab-load-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        ExtensionManager.systemCatalogue = []
        let library = ExtensionLibrary(baseDirectory: directory)
        let make = "const make = (kind, name) => chrome.tabs.create({ url: \"\(try server.url("/").absoluteString)\" + kind + \"/\" + name, active: false });\n"
        try Self.write(#"""
        {"manifest_version": 3, "name": "Hears", "version": "1.0",
         "permissions": ["tabs"], "host_permissions": ["<all_urls>"],
         "background": {"service_worker": "worker.js"}}
        """#, as: "hears", in: library)
        try (make + """
        chrome.tabs.onUpdated.addListener((id, change, tab) => {
            if (tab.url !== "\(page)") return;
            if (change.status === "complete" && tab.status === "complete") make("heard", "complete");
            if (change.url === "\(page)") make("heard", "url");
            if (change.title === "Loaded") make("heard", "title");
        });
        """).write(to: library.packageURL(for: "hears").appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)
        try Self.write(#"""
        {"manifest_version": 3, "name": "Blind", "version": "1.0",
         "background": {"service_worker": "worker.js"}}
        """#, as: "blind", in: library)
        try (make + """
        make("alive", "start");
        const seen = new Set();
        chrome.tabs.onUpdated.addListener((id, change, tab) => {
            if (seen.has("x")) return;
            if (change.url || change.title || tab.url || tab.title) { seen.add("x"); make("leaked", "address"); }
        });
        """).write(to: library.packageURL(for: "blind").appendingPathComponent("worker.js"), atomically: true, encoding: .utf8)

        let manager = ExtensionManager(profile: .original(), library: library)
        let controller = manager.controller
        let browser = BrowserModel(database: .temporary(), webViewFactory: {
            let configuration = WebViewPool.makeConfiguration()
            configuration.webExtensionController = controller
            return WKWebView(frame: .zero, configuration: configuration)
        })
        manager.register(browser: browser)
        // A worker's tabs.create goes to the focused (or last focused) window.
        manager.focus(browser: browser)
        defer {
            manager.stop()
            browser.closeAllTabs(saving: false)
        }
        await manager.start()
        try #require(Set(manager.contexts.keys) == ["hears", "blind"])
        for context in manager.contexts.values {
            try await context.loadBackgroundContent()
        }

        browser.newTab().load(try server.url("/page"))

        func marks() -> Set<String> {
            Set(browser.tabs.compactMap { tab in
                guard let path = URL(string: tab.urlString)?.pathComponents, path.count >= 3 else { return nil }
                return path.suffix(2).joined(separator: "/")
            })
        }
        var heard: Set<String> = []
        let settled = await waitUntil(timeout: .seconds(20)) {
            heard = marks()
            return ["heard/complete", "heard/title", "heard/url", "alive/start"].allSatisfy(heard.contains)
        }
        #expect(settled, "Heard \(heard.sorted())")
        // Let any late event from the extension without permission arrive before reading what it made.
        try await Task.sleep(for: .seconds(1))
        heard = marks()
        #expect(!heard.contains("leaked/address"), "An extension without permission heard \(heard.sorted())")
    }
}
