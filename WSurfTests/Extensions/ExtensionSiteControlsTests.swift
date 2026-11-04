// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import Observation
import Testing
import WebKit

@testable import WSurf

/// The per-site controls over EX1's blocking: the Website Settings buttons, the toolbar-menu item and Settings' list all act
/// on the same store, a private window keeps its blocks in memory, and a Chromium tab is told extensions are off there.
@MainActor
@Suite(.serialized)
struct ExtensionSiteControlsTests {
    private static let everywhere = "everywhere"
    private static let narrow = "narrow"

    private nonisolated final class Flag: @unchecked Sendable {
        var isSet = false
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-ext-controls-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func library(_ directory: URL, _ profile: Profile = .original()) -> ExtensionLibrary {
        let library = ExtensionLibrary(baseDirectory: directory, profile: profile)
        library.load()
        return library
    }

    private func install(id: String, name: String, hosts: [String], in library: ExtensionLibrary) throws {
        let package = library.packageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": name, "version": "1.0", "host_permissions": hosts]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        library.recordInstall(id: id)
    }

    /// A started manager with "Everywhere" (every website) loaded, and with "Narrow" (only example.org) when asked.
    private func startedManager(
        in directory: URL, profile: Profile = .original(), withNarrow: Bool = false
    ) async throws -> (ExtensionManager, BrowserModel, WKWebExtensionContext) {
        let shared = library(directory, profile)
        try install(id: Self.everywhere, name: "Everywhere", hosts: ["<all_urls>"], in: shared)
        if withNarrow {
            try install(id: Self.narrow, name: "Narrow", hosts: ["*://*.example.org/*"], in: shared)
        }
        let manager = ExtensionManager(profile: profile, library: shared)
        let browser = BrowserModel(database: .temporary())
        manager.register(browser: browser)
        await manager.start()
        return (manager, browser, try #require(manager.contexts[Self.everywhere]))
    }

    private func finish(_ manager: ExtensionManager, _ browser: BrowserModel) {
        manager.unregister(browser: browser)
        browser.closeAllTabs(saving: false)
        manager.stop()
    }

    /// Clicks the menu item the way AppKit does: the target receives the item's action.
    private func choose(_ title: String, in menu: NSMenu?) throws {
        let item = try #require(menu?.items.first { $0.title == title }, "\(title)")
        let target = try #require(item.target as? NSObject)
        _ = target.perform(try #require(item.action), with: item)
    }

    private func titles(_ menu: NSMenu?) -> [String] {
        menu?.items.map(\.title) ?? []
    }

    // MARK: - The Website Settings buttons

    /// "Block on this site" and "Allow on this site" write EX1's store and its deny, and the control follows.
    @Test func theButtonBlocksAnExtensionOnTheWebsiteAndAllowsItAgain() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, context) = try await startedManager(in: directory)
        defer { finish(manager, browser) }
        let page = try #require(URL(string: "https://www.example.com/news"))

        let allowed = try #require(manager.siteControls(on: page).first)
        #expect(allowed == ExtensionSiteControl(id: Self.everywhere, name: "Everywhere", isBlocked: false, host: "example.com", isPageWebsite: true))

        manager.toggle(allowed)
        #expect(library(directory).blockedHosts(for: Self.everywhere) == ["example.com"])
        #expect(context.permissionStatus(for: page) == .deniedExplicitly)
        let blocked = try #require(manager.siteControls(on: page).first)
        #expect(blocked.isBlocked)
        #expect(blocked.host == "example.com")

        manager.toggle(blocked)
        #expect(library(directory).blockedHosts(for: Self.everywhere).isEmpty)
        #expect(context.permissionStatus(for: page) == .grantedImplicitly)
        #expect(manager.siteControls(on: page).first?.isBlocked == false)
    }

    /// On `news.example.com` with the block on `example.com`, the button names the parent and allows it: allowing only the
    /// subdomain would change nothing.
    @Test func aBlockOnAParentWebsiteIsAllowedFromItsSubdomain() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, context) = try await startedManager(in: directory)
        defer { finish(manager, browser) }
        let news = try #require(URL(string: "https://news.example.com/"))
        manager.setAllowed(false, on: "example.com", id: Self.everywhere)

        let control = try #require(manager.siteControls(on: news).first)
        #expect(control.isBlocked)
        #expect(control.host == "example.com")
        #expect(!control.isPageWebsite)

        manager.toggle(control)
        #expect(manager.blockedHosts(id: Self.everywhere).isEmpty)
        #expect(context.permissionStatus(for: news) == .grantedImplicitly)
    }

    @Test func onlyExtensionsThatRunOnThePageOrAreBlockedThereAreListed() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, _) = try await startedManager(in: directory, withNarrow: true)
        defer { finish(manager, browser) }
        let com = try #require(URL(string: "https://example.com/"))
        let org = try #require(URL(string: "https://example.org/"))

        #expect(manager.siteControls(on: com).map(\.id) == [Self.everywhere])
        #expect(Set(manager.siteControls(on: org).map(\.id)) == [Self.everywhere, Self.narrow])

        // A block stays listed on a website the extension does not ask for, so the person can undo it.
        manager.setAllowed(false, on: "example.com", id: Self.narrow)
        #expect(Set(manager.siteControls(on: com).map(\.id)) == [Self.everywhere, Self.narrow])
        #expect(manager.siteControls(on: com).first { $0.id == Self.narrow }?.isBlocked == true)

        // A disabled extension is not on the page, whatever it is blocked on.
        manager.setEnabled(false, id: Self.narrow)
        #expect(manager.siteControls(on: com).map(\.id) == [Self.everywhere])
    }

    @Test func internalAndNonWebPagesGetNoControls() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, _) = try await startedManager(in: directory)
        defer { finish(manager, browser) }
        for address in ["wsurf://settings", "file:///tmp/a.html", "about:blank", "ftp://example.com/"] {
            #expect(manager.siteControls(on: URL(string: address)).isEmpty, "\(address)")
        }
        let none: URL? = nil
        #expect(manager.siteControls(on: none).isEmpty)
        #expect(!manager.siteControls(on: URL(string: "https://example.com/")).isEmpty)
    }

    // MARK: - Private windows

    /// A private window's block is shown and removed like any other, and never reaches disk or another profile.
    @Test func aPrivateBlockIsShownButKeptInMemoryOnly() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, context) = try await startedManager(in: directory, profile: .privateBrowsing())
        defer { finish(manager, browser) }
        let page = try #require(URL(string: "https://example.com/"))

        manager.toggle(try #require(manager.siteControls(on: page).first))

        let blocked = try #require(manager.siteControls(on: page).first)
        #expect(blocked.isBlocked)
        #expect(manager.blockedHosts(id: Self.everywhere) == ["example.com"])
        #expect(context.permissionStatus(for: page) == .deniedExplicitly)
        #expect(library(directory, .privateBrowsing()).blockedHosts(for: Self.everywhere).isEmpty)
        #expect(library(directory).blockedHosts(for: Self.everywhere).isEmpty)
        let written = try String(contentsOf: directory.appendingPathComponent("profiles.json"), encoding: .utf8)
        #expect(!written.contains("example.com"))

        manager.toggle(blocked)
        #expect(manager.blockedHosts(id: Self.everywhere).isEmpty)
        #expect(manager.siteControls(on: page).first?.isBlocked == false)
    }

    // MARK: - Settings list

    /// The list under an extension's row shows its blocks, and Remove allows a website again, while the extension is off too.
    @Test func theSettingsListShowsAndRemovesBlocksWhileTheExtensionIsOff() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, _) = try await startedManager(in: directory)
        defer { finish(manager, browser) }
        manager.setAllowed(false, on: "news.example.net", id: Self.everywhere)
        manager.setAllowed(false, on: "example.com", id: Self.everywhere)
        manager.setEnabled(false, id: Self.everywhere)

        #expect(manager.blockedHosts(id: Self.everywhere) == ["example.com", "news.example.net"])

        manager.setAllowed(true, on: "example.com", id: Self.everywhere)  // Remove, on the first row

        #expect(manager.blockedHosts(id: Self.everywhere) == ["news.example.net"])
        #expect(library(directory).blockedHosts(for: Self.everywhere) == ["news.example.net"])
    }

    /// A view that reads the list is told when a block is made or removed, in a normal and in a private profile.
    @Test(arguments: [false, true]) func theSettingsListRedrawsWhenABlockChanges(isPrivate: Bool) async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, _) = try await startedManager(in: directory, profile: isPrivate ? .privateBrowsing() : .original())
        defer { finish(manager, browser) }

        let blocked = Flag()
        withObservationTracking {
            _ = manager.blockedHosts(id: Self.everywhere)
        } onChange: {
            blocked.isSet = true
        }
        manager.setAllowed(false, on: "example.com", id: Self.everywhere)
        #expect(blocked.isSet)

        let removed = Flag()
        withObservationTracking {
            _ = manager.blockedHosts(id: Self.everywhere)
        } onChange: {
            removed.isSet = true
        }
        manager.setAllowed(true, on: "example.com", id: Self.everywhere)
        #expect(removed.isSet)
    }

    // MARK: - Tabs and the toolbar menu

    /// On a WebKit tab the extension's toolbar menu offers Block on the website, then Allow on it, and choosing either writes
    /// the store through the host the item carries.
    @Test(.boundedWebViews) func theToolbarMenuBlocksAndAllowsOnAWebKitTab() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, _) = try await startedManager(in: directory)
        defer { finish(manager, browser) }
        let window = manager.register(browser: browser)
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Ready</title>")])
        let tab = browser.newTab(url: try server.url())
        #expect(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        let menu = { manager.contextMenu(for: Self.everywhere, inWindow: window) }

        #expect(manager.siteControls(for: tab) == .extensions([
            ExtensionSiteControl(id: Self.everywhere, name: "Everywhere", isBlocked: false, host: "127.0.0.1", isPageWebsite: true),
        ]))
        #expect(titles(menu()).contains("Block on 127.0.0.1"))
        #expect(!titles(menu()).contains("Allow on 127.0.0.1"))

        try choose("Block on 127.0.0.1", in: menu())
        #expect(manager.blockedHosts(id: Self.everywhere) == ["127.0.0.1"])
        #expect(titles(menu()).contains("Allow on 127.0.0.1"))
        #expect(!titles(menu()).contains("Block on 127.0.0.1"))

        try choose("Allow on 127.0.0.1", in: menu())
        #expect(manager.blockedHosts(id: Self.everywhere).isEmpty)
        #expect(titles(menu()).contains("Block on 127.0.0.1"))
    }

    /// A tab with no page, such as a new tab's start page, offers no control and no menu item.
    @Test(.boundedWebViews) func aTabWithoutAWebsiteOffersNothing() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, _) = try await startedManager(in: directory)
        defer { finish(manager, browser) }
        let window = manager.register(browser: browser)
        let tab = browser.newTab()

        #expect(manager.siteControls(for: tab) == .none)
        let menu = titles(manager.contextMenu(for: Self.everywhere, inWindow: window))
        #expect(!menu.isEmpty, "the menu itself still opens")
        #expect(!menu.contains { $0.hasPrefix("Block on") || $0.hasPrefix("Allow on") })
    }

    /// Extensions run only in WebKit: on a Chromium tab the panel and the menu say so instead of offering a control, and
    /// nothing is blocked.
    @Test(.boundedWebViews) func aChromiumTabSaysExtensionsRunInWebKitAndOffersNoControl() async throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (manager, browser, _) = try await startedManager(in: directory)
        let window = manager.register(browser: browser)
        let server = try await HTTPFixtureServer.start(routes: ["/": .html("<title>Ready</title>")])
        let tab = browser.newTab(url: try server.url(), engine: .chromium)
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.orderBack(nil)
        defer {
            host.contentView = nil
            host.close()
            finish(manager, browser)
        }
        #expect(await waitUntil {
            if host.contentView !== tab.page {
                host.contentView = tab.page
            }
            return tab.page.engine == .chromium && tab.page.title == "Ready" && !tab.page.isLoading
        })
        let note = "Extensions run only in WebKit tabs. This tab uses Chromium."

        // The extension would run on this address in a WebKit tab, so the note is not an empty page's.
        #expect(!manager.siteControls(on: URL(string: tab.urlString)).isEmpty)
        #expect(manager.siteControls(for: tab) == .webKitOnly)
        let menu = manager.contextMenu(for: Self.everywhere, inWindow: window)
        #expect(titles(menu).contains(note))
        #expect(menu?.items.first { $0.title == note }?.isEnabled == false)
        #expect(!titles(menu).contains { $0.hasPrefix("Block on") || $0.hasPrefix("Allow on") })
        #expect(manager.blockedHosts(id: Self.everywhere).isEmpty)
    }
}
