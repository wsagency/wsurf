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
struct ExtensionWebsiteAccessTests {
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-ext-access-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func library(_ directory: URL, _ profile: Profile = .original()) -> ExtensionLibrary {
        let library = ExtensionLibrary(baseDirectory: directory, profile: profile)
        library.load()
        return library
    }

    private func installEveryWebsiteExtension(id: String, in library: ExtensionLibrary) throws {
        let package = library.packageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"""
        {"manifest_version":3,"name":"Everywhere","version":"1.0","host_permissions":["<all_urls>"]}
        """#.utf8).write(to: package.appendingPathComponent("manifest.json"))
        library.recordInstall(id: id)
    }

    /// A started manager for `profile` with the every-website extension loaded, and a registered window.
    private func startedManager(
        id: String, in directory: URL, profile: Profile = .original()
    ) async throws -> (ExtensionManager, BrowserModel, WKWebExtensionContext) {
        let shared = library(directory, profile)
        try installEveryWebsiteExtension(id: id, in: shared)
        let manager = ExtensionManager(profile: profile, library: shared)
        let browser = BrowserModel(database: .temporary())
        manager.register(browser: browser)
        await manager.start()
        return (manager, browser, try #require(manager.contexts[id]))
    }

    private func finish(_ manager: ExtensionManager, _ browsers: BrowserModel...) {
        for browser in browsers {
            manager.unregister(browser: browser)
            browser.closeAllTabs(saving: false)
        }
        manager.stop()
    }

    // MARK: - Websites and patterns

    @Test func theWebsiteDropsSchemePathAndWWW() {
        #expect(ExtensionManager.website(of: URL(string: "https://www.Example.com/a?b")) == "example.com")
        #expect(ExtensionManager.website(of: URL(string: "http://news.example.com")) == "news.example.com")
        #expect(ExtensionManager.website(of: URL(string: "wsurf://settings")) == nil)
        #expect(ExtensionManager.website(of: URL(string: "file:///tmp/a.html")) == nil)
    }

    @Test func everyWebsiteHasAPattern() throws {
        for address in ["https://example.com/", "http://192.168.1.1/", "http://[::1]:8080/"] {
            let url = try #require(URL(string: address))
            let host = try #require(ExtensionManager.website(of: url))
            let patterns = ExtensionManager.websitePatterns(for: host)
            #expect(patterns.contains { $0.matches(url) }, "\(host)")
        }
    }

    @Test func hostsAreNormalizedWithoutCaseRootDotOrWWW() {
        #expect(ExtensionManager.normalizedHost("Example.COM.") == "example.com")
        #expect(ExtensionManager.normalizedHost("www.example.com..") == "example.com")
        #expect(ExtensionManager.normalizedHost(".") == nil)
        #expect(ExtensionManager.website(of: URL(string: "https://Sub.Example.com./")) == "sub.example.com")
        #expect(ExtensionManager.websitePatterns(for: "example.com").map(\.string) == ["*://*.example.com/*", "*://*.example.com./*"])
    }

    @Test func aBlockCoversSubdomainsOnADotBoundary() {
        #expect(ExtensionManager.website("example.com", isCoveredBy: "example.com"))
        #expect(ExtensionManager.website("news.example.com", isCoveredBy: "example.com"))
        #expect(!ExtensionManager.website("notexample.com", isCoveredBy: "example.com"))
        #expect(!ExtensionManager.website("example.com", isCoveredBy: "news.example.com"))
    }

    // MARK: - Storage

    @Test func aBlockedWebsiteIsKeptPerProfileAndSurvivesReordering() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let work = Profile(id: UUID(), name: "Work", symbol: "person", color: .gray)

        let personal = library(directory)
        personal.recordInstall(id: "first")
        personal.recordInstall(id: "second")
        personal.setBlocked(true, host: "example.com", id: "first")
        personal.move("first", before: nil)
        personal.setPinned(false, id: "first")
        personal.recordInstall(id: "first")

        #expect(library(directory).blockedHosts(for: "first") == ["example.com"])
        #expect(library(directory, work).blockedHosts(for: "first").isEmpty)

        personal.setBlocked(false, host: "example.com", id: "first")
        #expect(library(directory).blockedHosts(for: "first").isEmpty)
    }

    /// A `profiles.json` from before blocking existed loads with every extension as it was and nothing blocked.
    @Test func anOldProfilesFileStillDecodes() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = Profile.originalID.uuidString
        try Data(#"""
        {"entries":[{"id":"old","displayName":"Old","version":"1.0","installedAt":0}]}
        """#.utf8).write(to: directory.appendingPathComponent("library.json"))
        try Data(#"""
        {"profiles":{"\#(key)":{"old":{"enabled":true,"isPinned":false,"toolbarOrder":0}}}}
        """#.utf8).write(to: directory.appendingPathComponent("profiles.json"))

        let loaded = library(directory)
        #expect(loaded.records.map(\.id) == ["old"])
        #expect(loaded.records.first?.enabled == true)
        #expect(loaded.records.first?.isPinned == false)
        #expect(loaded.blockedHosts(for: "old").isEmpty)
    }

    @Test func uninstallingForgetsTheBlocks() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shared = library(directory)
        try installEveryWebsiteExtension(id: "gone", in: shared)
        shared.setBlocked(true, host: "example.com", id: "gone")

        shared.uninstall(id: "gone")
        try installEveryWebsiteExtension(id: "gone", in: shared)
        #expect(shared.blockedHosts(for: "gone").isEmpty)
    }

    // MARK: - Enforcement

    @Test func aBlockedWebsiteOverridesTheEveryWebsiteGrant() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-test"
        let (manager, browser, context) = try await startedManager(id: id, in: directory)
        defer { finish(manager, browser) }
        let blocked = try #require(URL(string: "https://www.example.com/page"))
        let subdomain = try #require(URL(string: "https://news.example.com/"))
        let other = try #require(URL(string: "https://example.org/"))
        let lookalike = try #require(URL(string: "https://notexample.com/"))
        #expect(context.permissionStatus(for: blocked) == .grantedImplicitly)

        manager.setAllowed(false, on: "www.example.com", id: id)
        #expect(manager.blockedHosts(id: id) == ["example.com"])
        #expect(manager.blockingHost(id: id, for: "news.example.com") == "example.com")
        #expect(!manager.isBlocked(id: id, on: lookalike))
        #expect(context.permissionStatus(for: blocked) == .deniedExplicitly)
        #expect(context.permissionStatus(for: subdomain) == .deniedExplicitly)
        #expect(context.permissionStatus(for: other) == .grantedImplicitly)
        #expect(context.permissionStatus(for: lookalike) == .grantedImplicitly)

        manager.setAllowed(true, on: "example.com", id: id)
        #expect(!manager.isBlocked(id: id, on: blocked))
        #expect(context.permissionStatus(for: blocked) == .grantedImplicitly)
    }

    /// Unblocking one website re-grants what the extension asked for, and must not lift a block that covers it or a sibling.
    @Test func overlappingBlocksSurviveAnUnblock() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-overlap"
        let (manager, browser, context) = try await startedManager(id: id, in: directory)
        defer { finish(manager, browser) }
        let news = try #require(URL(string: "https://news.example.com/"))
        let shop = try #require(URL(string: "https://shop.example.net/"))

        manager.setAllowed(false, on: "example.com", id: id)
        manager.setAllowed(false, on: "news.example.com", id: id)
        manager.setAllowed(false, on: "example.net", id: id)
        manager.setAllowed(true, on: "news.example.com", id: id)

        #expect(manager.blockedHosts(id: id) == ["example.com", "example.net"])
        #expect(context.permissionStatus(for: news) == .deniedExplicitly)
        #expect(context.permissionStatus(for: shop) == .deniedExplicitly)

        manager.setAllowed(true, on: "example.com", id: id)
        #expect(context.permissionStatus(for: news) == .grantedImplicitly)
        #expect(context.permissionStatus(for: shop) == .deniedExplicitly)
    }

    @Test func aRuntimeGrantCannotLiftABlock() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-runtime"
        let (manager, browser, context) = try await startedManager(id: id, in: directory)
        defer { finish(manager, browser) }
        let blocked = try #require(URL(string: "https://example.com/page"))
        let other = try #require(URL(string: "https://example.org/"))
        manager.setAllowed(false, on: "example.com", id: id)

        // What a permissions.request approval hands back is filtered before WebKit records it.
        #expect(manager.withoutBlockedWebsites([blocked, other], id: id) == [other])
        let patterns = try Set(["*://*.example.com/*", "*://news.example.com/*", "<all_urls>", "*://*.example.org/*"]
            .map { try WKWebExtension.MatchPattern(string: $0) })
        let kept = manager.withoutBlockedWebsites(patterns, id: id).map(\.string).sorted()
        #expect(kept == ["*://*.example.org/*", "<all_urls>"])

        // A grant that reached the context anyway is denied again.
        for pattern in ExtensionManager.websitePatterns(for: "example.com") {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
        manager.reapplyBlocks(id: id)
        #expect(context.permissionStatus(for: blocked) == .deniedExplicitly)
        #expect(context.permissionStatus(for: other) == .grantedImplicitly)
    }

    /// The root-dot spelling of a host is the same website and does not escape the block.
    @Test func aTrailingDotDoesNotEscapeABlock() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-root-dot"
        let (manager, browser, context) = try await startedManager(id: id, in: directory)
        defer { finish(manager, browser) }

        manager.setAllowed(false, on: "Example.COM.", id: id)

        #expect(manager.blockedHosts(id: id) == ["example.com"])
        for address in ["https://example.com./", "https://sub.example.com./", "https://example.com/", "https://sub.example.com/"] {
            let url = try #require(URL(string: address))
            #expect(manager.isBlocked(id: id, on: url), "\(address)")
            #expect(context.permissionStatus(for: url) == .deniedExplicitly, "\(address)")
        }
        #expect(context.permissionStatus(for: try #require(URL(string: "https://example.org./"))) == .grantedImplicitly)
    }

    @Test func aBlockedWebsiteStaysBlockedAfterRelaunch() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-relaunch"
        let first = library(directory)
        try installEveryWebsiteExtension(id: id, in: first)
        first.setBlocked(true, host: "example.com", id: id)

        let manager = ExtensionManager(profile: .original(), library: library(directory))
        let browser = BrowserModel(database: .temporary())
        manager.register(browser: browser)
        defer { finish(manager, browser) }
        await manager.start()
        let context = try #require(manager.contexts[id])
        #expect(context.permissionStatus(for: try #require(URL(string: "https://example.com/"))) == .deniedExplicitly)
        #expect(context.permissionStatus(for: try #require(URL(string: "https://example.org/"))) == .grantedImplicitly)
    }

    /// A private window keeps its blocks for the session only: nothing reaches `profiles.json`.
    @Test func aPrivateBlockIsNeverWritten() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-private"
        let (manager, browser, context) = try await startedManager(id: id, in: directory, profile: .privateBrowsing())
        defer { finish(manager, browser) }

        manager.setAllowed(false, on: "example.com", id: id)

        #expect(manager.blockedHosts(id: id) == ["example.com"])
        #expect(context.permissionStatus(for: try #require(URL(string: "https://example.com/"))) == .deniedExplicitly)
        #expect(library(directory, .privateBrowsing()).blockedHosts(for: id).isEmpty)
        let written = try String(contentsOf: directory.appendingPathComponent("profiles.json"), encoding: .utf8)
        #expect(!written.contains("example.com"))
    }

    // MARK: - Tabs

    private static let countingPage = """
        <script>
        sessionStorage.loads = String(Number(sessionStorage.loads || 0) + 1);
        document.title = "Loads " + sessionStorage.loads;
        </script>
        """

    private func openPage(_ url: URL, in browser: BrowserModel) async -> BrowserTab {
        let tab = browser.newTab(url: url)
        #expect(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        #expect(await waitUntil { tab.page.title == "Loads 1" })
        return tab
    }

    /// Blocking reloads the website's WebKit tabs in every window of the profile, and leaves other websites alone.
    @Test(.boundedWebViews) func blockingAWebsiteReloadsItsTabsInEveryWindow() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-reload"
        let (manager, browser, _) = try await startedManager(id: id, in: directory)
        let sibling = BrowserModel(database: .temporary())
        manager.register(browser: sibling)
        defer { finish(manager, browser, sibling) }
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.countingPage)])
        let address = try server.url()
        let blocked = await openPage(address, in: browser)
        let blockedElsewhere = await openPage(address, in: sibling)
        let otherSite = await openPage(try #require(URL(string: "http://localhost:\(address.port ?? 0)/")), in: sibling)

        manager.setAllowed(false, on: "127.0.0.1", id: id)

        #expect(await waitUntil { blocked.page.title == "Loads 2" })
        #expect(await waitUntil { blockedElsewhere.page.title == "Loads 2" })
        #expect(otherSite.page.title == "Loads 1", "a tab on another website is left alone")
        // Running the extension's action for a tab on the blocked website hands it no tab, so no activeTab grant.
        #expect(manager.actionTab(manager.adapter(for: blocked), id: id) == nil)
        #expect(manager.actionTab(manager.adapter(for: otherSite), id: id) != nil)
    }

    /// On a blocked website the toolbar button neither opens the popup nor shows the extension's menu items, so a click cannot
    /// act on the page. The same steps on an allowed website show both, so the checks are not vacuous.
    @Test(.boundedWebViews) func aBlockedWebsiteGetsNoPopupAndNoMenuItems() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-action"
        let shared = library(directory)
        let package = shared.packageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 2, "name": "Acts here", "version": "1.0",
            "permissions": ["contextMenus", "<all_urls>"],
            "background": ["scripts": ["background.js"], "persistent": true],
            "browser_action": ["default_popup": "popup.html"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        try "chrome.contextMenus.create({id: 'act', title: 'Act here', contexts: ['browser_action']});"
            .write(to: package.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Popup</title><p>Popup</p>"
            .write(to: package.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        shared.recordInstall(id: id)

        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.countingPage)])
        let browser = BrowserModel(database: .temporary())
        let manager = ExtensionManager(profile: .original(), dataStore: browser.context.dataStore, library: shared)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let windowAdapter = manager.register(browser: browser, window: window)
        let anchor = NSView(frame: CGRect(x: 20, y: 20, width: 30, height: 30))
        window.contentView?.addSubview(anchor)
        window.orderFront(nil)
        defer {
            manager.action(for: id, inWindow: windowAdapter)?.closePopup()
            window.close()
            finish(manager, browser)
        }
        await manager.start()
        manager.registerAnchor(anchor, for: id, inWindow: windowAdapter)
        _ = await openPage(try server.url(), in: browser)
        let menuTitles = { manager.contextMenu(for: id, inWindow: windowAdapter)?.items.map(\.title) ?? [] }
        #expect(await waitUntil { menuTitles().contains("Act here") })

        manager.setAllowed(false, on: "127.0.0.1", id: id)
        #expect(!menuTitles().contains("Act here"))
        manager.performAction(for: id, inWindow: windowAdapter)
        #expect(manager.action(for: id, inWindow: windowAdapter)?.popupPopover?.isShown != true)

        manager.setAllowed(true, on: "127.0.0.1", id: id)
        #expect(await waitUntil { menuTitles().contains("Act here") })
        manager.performAction(for: id, inWindow: windowAdapter)
        #expect(await waitUntil { manager.action(for: id, inWindow: windowAdapter)?.popupPopover?.isShown == true })
    }

    /// Extensions run only in WebKit: a Chromium tab gives the extension no page, and blocking never reloads it.
    @Test(.boundedWebViews) func aChromiumTabHasNoExtensionPage() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = "website-access-chromium"
        let (manager, browser, context) = try await startedManager(id: id, in: directory)
        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.countingPage)])
        let tab = browser.newTab(url: try server.url(), engine: .chromium)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
            finish(manager, browser)
        }
        #expect(await waitUntil {
            if window.contentView !== tab.page {
                window.contentView = tab.page
            }
            return tab.page.engine == .chromium && tab.page.title == "Loads 1" && !tab.page.isLoading
        })

        #expect(manager.adapter(for: tab).webView(for: context) == nil)
        manager.setAllowed(false, on: "127.0.0.1", id: id)
        #expect(tab.page.title == "Loads 1")
    }
}
