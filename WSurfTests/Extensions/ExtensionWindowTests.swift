// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct ExtensionWindowTests {
    private func extensionContext() async throws -> WKWebExtensionContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-extension-windows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"manifest_version":3,"name":"Windows","version":"1.0"}"#.utf8)
            .write(to: directory.appendingPathComponent("manifest.json"))
        return WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: directory))
    }

    @Test func registeringAnotherWindowKeepsTheProfileControllerAndCallbacks() {
        let manager = ExtensionManager(profile: .original())
        let controller = manager.controller
        let first = BrowserModel(database: .temporary())
        let second = BrowserModel(database: .temporary())
        let adapter = manager.register(browser: first)
        var activations = 0
        let original = first.onActiveTabChanged
        first.onActiveTabChanged = { new, previous in
            original?(new, previous)
            activations += 1
        }

        manager.register(browser: second)
        #expect(manager.register(browser: first) === adapter)
        _ = first.newTab()

        #expect(manager.controller === controller)
        #expect(manager.windowAdapters.count == 2)
        #expect(activations == 1)
        manager.unregister(browser: second)
        #expect(manager.windowAdapters.count == 1)
        #expect(manager.adapter(for: first) === adapter)
        manager.unregister(browser: first)
    }

    @Test func theExtensionSeesEveryWindowAndOnlyThatWindowsTabs() async throws {
        let context = try await extensionContext()
        let manager = ExtensionManager()
        let first = BrowserModel(database: .temporary())
        let second = BrowserModel(database: .temporary())
        let firstWindow = manager.register(browser: first)
        let secondWindow = manager.register(browser: second)
        let firstTab = first.newTab()
        let secondTab = second.newTab()
        defer {
            manager.unregister(browser: first)
            manager.unregister(browser: second)
        }

        let windows = manager.webExtensionController(manager.controller, openWindowsFor: context)
        #expect(windows.count == 2)
        #expect((firstWindow.tabs(for: context).first as? ExtensionTabAdapter)?.tab === firstTab)
        #expect((secondWindow.tabs(for: context).first as? ExtensionTabAdapter)?.tab === secondTab)
        #expect((manager.adapter(for: firstTab).window(for: context) as? ExtensionWindowAdapter) === firstWindow)
        #expect((manager.adapter(for: secondTab).window(for: context) as? ExtensionWindowAdapter) === secondWindow)
    }

    @Test func aTransferredTabKeepsItsExtensionIdentityAndChangesWindow() async throws {
        let context = try await extensionContext()
        let manager = ExtensionManager()
        let database = AppDatabase.temporary()
        let first = BrowserModel(windowID: UUID(), database: database)
        let second = BrowserModel(windowID: UUID(), database: database)
        manager.register(browser: first)
        let destination = manager.register(browser: second)
        let tab = first.newTab()
        let adapter = manager.adapter(for: tab)
        defer {
            manager.unregister(browser: first)
            manager.unregister(browser: second)
        }

        #expect(second.adoptTab(tab, from: first))
        #expect(manager.adapter(for: tab) === adapter)
        #expect(adapter.browser === second)
        #expect((adapter.window(for: context) as? ExtensionWindowAdapter) === destination)
        #expect(adapter.indexInWindow(for: context) == 0)
        #expect(first.tabs.isEmpty)
        #expect(!tab.isClosed)
    }

    @Test func eachAdapterUsesItsOwnNativeFrameAndPrivateStatus() async throws {
        let context = try await extensionContext()
        let normal = ExtensionManager(profile: .original())
        let privateManager = ExtensionManager(profile: .privateBrowsing())
        let first = BrowserModel(database: .temporary())
        let second = BrowserModel(database: .temporary())
        let firstNative = NSWindow(contentRect: NSRect(x: 10, y: 20, width: 700, height: 500), styleMask: [], backing: .buffered, defer: true)
        let secondNative = NSWindow(contentRect: NSRect(x: 80, y: 90, width: 600, height: 400), styleMask: [], backing: .buffered, defer: true)
        firstNative.isReleasedWhenClosed = false
        secondNative.isReleasedWhenClosed = false
        let firstWindow = normal.register(browser: first, window: firstNative)
        let secondWindow = privateManager.register(browser: second, window: secondNative)
        defer {
            normal.unregister(browser: first)
            privateManager.unregister(browser: second)
            firstNative.close()
            secondNative.close()
        }

        #expect(firstWindow.frame(for: context) == firstNative.frame)
        #expect(secondWindow.frame(for: context) == secondNative.frame)
        #expect(!firstWindow.isPrivate(for: context))
        #expect(secondWindow.isPrivate(for: context))
        let moved = CGRect(x: 100, y: 200, width: 800, height: 600)
        secondWindow.setFrame(moved, for: context) { error in #expect(error == nil) }
        #expect(secondNative.frame == moved)
        #expect(firstNative.frame != moved)
    }

    @Test func retiredAdaptersCannotReadOrChangeTheBrowsersNextProfile() async throws {
        let context = try await extensionContext()
        let personal = ExtensionManager(profile: .original())
        let work = ExtensionManager(profile: Profile(id: UUID(), name: "Work", symbol: "person", color: .gray))
        let browser = BrowserModel(database: .temporary())
        let oldWindow = personal.register(browser: browser)
        let oldTab = browser.newTab()
        let oldAdapter = personal.adapter(for: oldTab)

        personal.unregister(browser: browser)
        browser.closeAllTabs(saving: false)
        let newWindow = work.register(browser: browser)
        let newTab = browser.newTab()
        defer {
            work.unregister(browser: browser)
            browser.closeAllTabs(saving: false)
        }

        #expect(oldWindow.browser == nil)
        #expect(oldWindow.tabs(for: context).isEmpty)
        #expect(oldWindow.activeTab(for: context) == nil)
        #expect(oldAdapter.tab == nil)
        #expect(oldAdapter.webView(for: context) == nil)
        #expect(oldAdapter.window(for: context) == nil)
        #expect(oldAdapter.indexInWindow(for: context) == NSNotFound)
        #expect(!oldAdapter.isSelected(for: context))
        oldAdapter.activate(for: context) { #expect($0 as? ExtensionWindowError == .unavailable) }
        oldAdapter.close(for: context) { #expect($0 as? ExtensionWindowError == .unavailable) }
        #expect(browser.activeTab === newTab)
        #expect(!newTab.isClosed)
        #expect((newWindow.activeTab(for: context) as? ExtensionTabAdapter)?.tab === newTab)
    }

    @Test func capturedCallbacksStayRetiredWhenTheSameBrowserRegistersAgain() throws {
        let manager = ExtensionManager()
        let browser = BrowserModel(database: .temporary())
        let oldWindow = manager.register(browser: browser)
        let didOpen = try #require(browser.onTabOpened)
        let didClose = try #require(browser.onTabClosed)
        let didActivate = try #require(browser.onActiveTabChanged)
        manager.unregister(browser: browser)
        let newWindow = manager.register(browser: browser)
        let newTab = browser.newTab()
        let newAdapter = manager.adapter(for: newTab)
        let foreign = BrowserModel(database: .temporary())
        let foreignTab = foreign.newTab()
        defer {
            manager.unregister(browser: browser)
            browser.closeAllTabs(saving: false)
            foreign.closeAllTabs(saving: false)
        }

        didOpen(foreignTab)
        didActivate(foreignTab, nil)
        didClose(newTab)

        #expect(!manager.owns(oldWindow))
        #expect(manager.owns(newWindow))
        #expect(manager.tabAdapters[newTab.id] === newAdapter)
        #expect(manager.tabAdapters[foreignTab.id] == nil)
        #expect(newAdapter.tab === newTab)
    }

    @Test func unregisteringAfterTabsAreClearedStillInvalidatesTheirAdapters() {
        let manager = ExtensionManager()
        let browser = BrowserModel(database: .temporary())
        manager.register(browser: browser)
        let tab = browser.newTab()
        let adapter = manager.adapter(for: tab)

        browser.closeAllTabs(saving: false)
        manager.unregister(browser: browser)

        #expect(manager.tabAdapters.isEmpty)
        #expect(adapter.tab == nil)
        #expect(adapter.browser == nil)
    }

    @Test func staleToolbarCallsCannotUseAnotherProfilesTabsOrFallbackWindow() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-extension-toolbar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ExtensionLibrary(baseDirectory: directory)
        let id = "window-registration-test"
        let package = library.packageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Windows","version":"1.0","action":{"default_title":"Windows"}}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        library.recordInstall(id: id)
        let personal = ExtensionManager(profile: .original(), library: library)
        let work = ExtensionManager(profile: Profile(id: UUID(), name: "Work", symbol: "person", color: .gray))
        let browser = BrowserModel(database: .temporary())
        let sibling = BrowserModel(database: .temporary())
        let oldWindow = personal.register(browser: browser)
        personal.register(browser: sibling)
        _ = browser.newTab()
        _ = sibling.newTab()
        defer {
            personal.unregister(browser: browser)
            personal.unregister(browser: sibling)
            work.unregister(browser: browser)
            browser.closeAllTabs(saving: false)
            sibling.closeAllTabs(saving: false)
            personal.stop()
        }
        await personal.start()
        _ = try #require(personal.contexts[id])
        _ = try #require(personal.action(for: id, in: browser))

        personal.unregister(browser: browser)
        browser.closeAllTabs(saving: false)
        work.register(browser: browser)
        let workTab = browser.newTab()
        let siblingCount = sibling.tabs.count

        #expect(personal.action(for: id, inWindow: oldWindow) == nil)
        #expect(personal.contextMenu(for: id, inWindow: oldWindow) == nil)
        personal.performAction(for: id, inWindow: oldWindow)
        #expect(personal.openTab(nil, in: browser) == nil)
        #expect(sibling.tabs.count == siblingCount)
        #expect(browser.tabs.map(\.id) == [workTab.id])
        #expect(personal.tabAdapters[workTab.id] == nil)
        #expect(personal.action(for: id, in: sibling) != nil)
    }

    @Test func closingPrivateContextWhileLoadingNeverRestartsExtensions() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-extension-close-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = BrowserProfileContext.shared(for: .privateBrowsing())
        let library = ExtensionLibrary(baseDirectory: directory, profile: context.profile)
        let id = "pending-private-load"
        let package = library.packageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Pending private load","version":"1.0","background":{"service_worker":"background.js"}}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        try Data("globalThis.started = true;".utf8).write(to: package.appendingPathComponent("background.js"))
        library.recordInstall(id: id)
        context.extensions = ExtensionManager(profile: context.profile, dataStore: context.dataStore, library: library)
        let manager = context.extensions
        let controller = manager.controller
        let browser = BrowserModel(context: context)
        manager.register(browser: browser)
        let gate = ResponseGate()
        let startup = Task {
            await ExtensionManager.$extensionCreatedForTesting.withValue({
                await withCheckedContinuation { continuation in
                    gate.submit { continuation.resume() }
                }
            }) {
                await manager.start()
            }
        }
        defer {
            gate.open()
            startup.cancel()
            manager.stop()
            browser.closeAllTabs(saving: false)
        }
        try #require(await waitUntil { gate.requestCount == 1 })
        await context.endPrivateSession()
        gate.open()
        await startup.value
        await manager.start()

        #expect(context.privateSessionEnded)
        #expect(manager.controller === controller)
        #expect(!controller.configuration.isPersistent)
        #expect(controller.extensionContexts.isEmpty)
        #expect(manager.contexts.isEmpty)
        #expect(manager.windowAdapters.isEmpty)
        #expect(!manager.hasStarted)
    }

    @Test func aRegularExtensionCanCreateAPrivateWindowWithURLs() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/first": .html("<title>First URL</title>"),
            "/second": .html("<title>Second URL</title>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let urls = try [server.url("/first"), server.url("/second")]
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-extension-private-window-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceContext = BrowserProfileContext(profile: .original())
        let destinationContext = BrowserProfileContext.shared(for: .privateBrowsing())
        let library = ExtensionLibrary(baseDirectory: directory)
        let id = "create-private-window"
        let package = library.packageURL(for: id)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Create private window","version":"1.0","permissions":["tabs"]}"#.utf8)
            .write(to: package.appendingPathComponent("manifest.json"))
        try Data("<title>Extension window fixture</title>".utf8).write(to: package.appendingPathComponent("test.html"))
        library.recordInstall(id: id)
        sourceContext.extensions = ExtensionManager(profile: sourceContext.profile, dataStore: sourceContext.dataStore, library: library)
        let manager = sourceContext.extensions
        let source = BrowserModel(context: sourceContext)
        let destination = BrowserModel(context: destinationContext)
        let native = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let privateNative = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                                     styleMask: .borderless, backing: .buffered, defer: false)
        native.isReleasedWhenClosed = false
        privateNative.isReleasedWhenClosed = false
        manager.register(browser: source, window: native)
        defer {
            manager.stop()
            destinationContext.extensions.stop()
            source.closeAllTabs(saving: false)
            destination.closeAllTabs(saving: false)
            native.close()
            privateNative.close()
        }
        var creations = 0
        manager.onOpenWindow = { configuration in
            creations += 1
            #expect(configuration.shouldBePrivate)
            #expect(configuration.tabs.isEmpty)
            for url in configuration.tabURLs.reversed() {
                destination.newTab(url: url)
            }
            return destinationContext.extensions.register(browser: destination, window: privateNative)
        }
        await manager.start()
        let extensionContext = try #require(manager.contexts[id])
        extensionContext.hasAccessToPrivateData = true
        let configuration = try #require(extensionContext.webViewConfiguration)
        let view = WKWebView(frame: native.contentView?.bounds ?? .zero, configuration: configuration)
        native.contentView = view
        native.orderFront(nil)
        let extensionURL = extensionContext.baseURL.appendingPathComponent("test.html")
        view.load(URLRequest(url: extensionURL))
        try #require(await waitUntil { view.url == extensionURL && !view.isLoading })
        let result = try await view.callAsyncJavaScript("""
            const created = await browser.windows.create({
                url: urls, incognito: true,
                width: 640, height: 480, focused: false
            });
            return created.incognito;
            """, arguments: ["urls": urls.map(\.absoluteString)], in: nil, contentWorld: .page)

        #expect(result as? Bool == true)
        #expect(creations == 1)
        #expect(destination.tabs.map(\.urlString) == urls.map(\.absoluteString))
        #expect(destination.activeTab?.urlString == urls.first?.absoluteString)
        #expect(privateNative.frame.size == CGSize(width: 640, height: 480))
        #expect(source.tabs.isEmpty)
        await destinationContext.endPrivateSession()
    }

    private func nativeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 10, y: 20, width: 700, height: 500), styleMask: [], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A registry key that outlived its weak browser, now looked up by a new browser:
    /// the state left when a browser deallocates without unregistering. The key is
    /// seeded by hand because address reuse cannot be forced.
    private func retiredEntry(
        in manager: ExtensionManager, context: BrowserProfileContext,
        keyedBy browser: BrowserModel, window: NSWindow
    ) throws -> ExtensionWindowAdapter {
        var departed: BrowserModel? = BrowserModel(context: context, windowID: UUID())
        let stale = ExtensionWindowAdapter(browser: try #require(departed), manager: manager, window: window)
        departed = nil
        try #require(stale.browser == nil)
        let key = ObjectIdentifier(browser)
        manager.windows[key] = stale
        manager.windowOrder.append(key)
        return stale
    }

    @Test func registeringOverARetiredCacheKeyCreatesAFreshAdapter() throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let manager = context.extensions
        let browser = BrowserModel(context: context, windowID: UUID())
        let native = nativeWindow()
        let stale = try retiredEntry(in: manager, context: context, keyedBy: browser, window: native)

        let fresh = manager.register(browser: browser, window: native)
        defer {
            manager.unregister(browser: browser)
            native.close()
        }

        #expect(fresh !== stale)
        #expect(fresh.browser === browser)
        #expect(manager.adapter(for: browser) === fresh)
        #expect(manager.owns(fresh))
        #expect(!manager.owns(stale))
        #expect(stale.browser == nil)
        #expect(manager.windowAdapters.count == 1)
        #expect(manager.windowAdapters.first === fresh)
    }

    @Test func aConsentScopeCapturedForARetiredAdapterStaysInvalidWhenItsKeyIsReused() async throws {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let manager = context.extensions
        let browser = BrowserModel(context: context, windowID: UUID())
        let native = nativeWindow()
        let stale = try retiredEntry(in: manager, context: context, keyedBy: browser, window: native)
        let fresh = manager.register(browser: browser, window: native)
        defer {
            manager.unregister(browser: browser)
            native.close()
        }
        try #require(context.isRegistered(browser))
        var prompts = 0
        let stub = AgentActionConsent.Stub { _, _, _, _ in
            prompts += 1
            return .allowOnce
        }
        func permit(in scope: ExtensionWindowAdapter) async -> Bool {
            await AgentActionConsent.$decisionForTesting.withValue(stub) {
                await AgentActionConsent.$scopedWindow.withValue(scope) {
                    await AgentActionConsent.permit(
                        label: "Publish post", category: .publication, host: "example.invalid",
                        policy: context.actionPolicy
                    )
                }
            }
        }

        #expect(await permit(in: stale) == false)
        #expect(prompts == 0)
        #expect(await permit(in: fresh))
        #expect(prompts == 1)
    }
}
