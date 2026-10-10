// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import WebKit

extension ExtensionManager {
    var windowAdapters: [ExtensionWindowAdapter] {
        windowOrder.compactMap { windows[$0] }.filter { $0.browser != nil }
    }

    var focusedWindowAdapter: ExtensionWindowAdapter? {
        windowAdapters.first { $0.nativeWindow?.isKeyWindow == true }
    }

    var preferredWindowAdapter: ExtensionWindowAdapter? {
        focusedWindowAdapter ?? lastFocusedWindow.flatMap { owns($0) ? $0 : nil }
    }

    func registeredWindow(in browser: BrowserModel?) -> ExtensionWindowAdapter? {
        guard let browser else { return preferredWindowAdapter }
        return windows[ObjectIdentifier(browser)]
    }

    func owns(_ window: ExtensionWindowAdapter) -> Bool {
        guard let browser = window.browser else { return false }
        return windows[ObjectIdentifier(browser)] === window
    }

    func action(for id: String, in browser: BrowserModel? = nil) -> WKWebExtension.Action? {
        guard let window = registeredWindow(in: browser), let context = contexts[id] else { return nil }
        return context.action(for: window.browser?.activeTab.map { adapter(for: $0) })
    }

    @discardableResult
    func register(browser: BrowserModel, window: NSWindow? = nil) -> ExtensionWindowAdapter {
        let identifier = ObjectIdentifier(browser)
        if let existing = windows[identifier] {
            if existing.browser === browser {
                if let window {
                    existing.nativeWindow = window
                }
                return existing
            }
            // The key outlived its browser. Rebinding the retired adapter would
            // revive every consent scope captured for the old window.
            retire(existing, key: identifier)
        }

        let adapter = ExtensionWindowAdapter(browser: browser, manager: self, window: window)
        windows[identifier] = adapter
        windowOrder.append(identifier)
        browser.extensionPageHost = { [weak self, weak adapter] url in
            guard let self, let adapter, self.owns(adapter),
                  let context = self.controller.extensionContext(for: url),
                  let configuration = context.webViewConfiguration else { return nil }
            let webExtension = context.webExtension
            return ExtensionPageHost(
                configuration: configuration,
                baseURL: context.baseURL,
                name: webExtension.displayName ?? String(localized: "Extension"),
                icon: webExtension.icon(for: CGSize(width: 32, height: 32))
            )
        }
        browser.onTabOpened = { [weak self, weak adapter] tab in
            guard let self, let adapter, self.owns(adapter) else { return }
            self.controller.didOpenTab(self.adapter(for: tab))
        }
        browser.onTabClosed = { [weak self, weak adapter] tab in
            guard let self, let adapter, self.owns(adapter),
                  let closed = self.tabAdapters.removeValue(forKey: tab.id) else { return }
            self.controller.didCloseTab(closed, windowIsClosing: false)
            closed.invalidate()
        }
        browser.onActiveTabChanged = { [weak self, weak adapter] newTab, previousTab in
            guard let self, let adapter, self.owns(adapter), let newTab else { return }
            let previous = previousTab.flatMap { self.tabAdapters[$0.id] }
            self.controller.didActivateTab(self.adapter(for: newTab), previousActiveTab: previous)
        }
        browser.onTabTransferredIn = { [weak self, weak adapter] tab, source, oldIndex in
            guard let self, let adapter, self.owns(adapter), let destination = adapter.browser else { return }
            self.didMove(tab: tab, from: source, to: destination, oldIndex: oldIndex)
        }
        browser.onNavigationStarted = { [weak self, weak adapter] _, url in
            guard let self, let adapter, self.owns(adapter) else { return }
            self.wakeBackgrounds(for: url)
        }
        if hasStarted {
            controller.didOpenWindow(adapter)
        }
        return adapter
    }

    func unregister(browser: BrowserModel) {
        let identifier = ObjectIdentifier(browser)
        guard let window = windows[identifier] else { return }
        for tab in browser.tabs {
            _ = adapter(for: tab)
        }
        let closingTabs = tabAdapters.filter { $0.value.browser === browser }
        for (tabID, tabAdapter) in closingTabs {
            controller.didCloseTab(tabAdapter, windowIsClosing: true)
            tabAdapters[tabID] = nil
            tabAdapter.invalidate()
        }
        retire(window, key: identifier)
        if windows.isEmpty, profile?.isPrivate == true {
            stop()
        }
    }

    /// Drops a window's registry entry. A key can outlive its weak browser, so the
    /// browser is read from the adapter and is nil once it deallocated.
    private func retire(_ window: ExtensionWindowAdapter, key: ObjectIdentifier) {
        controller.didCloseWindow(window)
        windows[key] = nil
        windowOrder.removeAll { $0 == key }
        if lastFocusedWindow === window {
            lastFocusedWindow = nil
        }
        if let browser = window.browser {
            browser.extensionPageHost = nil
            browser.onTabOpened = nil
            browser.onTabClosed = nil
            browser.onActiveTabChanged = nil
            browser.onNavigationStarted = nil
            browser.onTabTransferredIn = nil
        }
        window.invalidate()
        didUnregister(key: key, window: window)
    }

    func focus(browser: BrowserModel?) {
        let window = browser.flatMap { windows[ObjectIdentifier($0)] }
        if let window {
            lastFocusedWindow = window
        }
        controller.didFocusWindow(window)
        noteActionUpdate()
    }

    func adapter(for browser: BrowserModel) -> ExtensionWindowAdapter? {
        windows[ObjectIdentifier(browser)]
    }

    func didMove(tab: BrowserTab, from source: BrowserModel, to destination: BrowserModel, oldIndex: Int) {
        guard let previousWindow = adapter(for: source), let newWindow = adapter(for: destination),
              destination.tabs.contains(where: { $0 === tab }) else { return }
        let tabAdapter = tabAdapters[tab.id] ?? ExtensionTabAdapter(
            tab: tab,
            browser: source,
            windowAdapter: previousWindow
        )
        tabAdapters[tab.id] = tabAdapter
        tabAdapter.move(to: destination, window: newWindow)
        controller.didMoveTab(tabAdapter, from: oldIndex, in: previousWindow)
    }

    @discardableResult
    func openTab(_ url: URL?, in browser: BrowserModel? = nil) -> BrowserTab? {
        registeredWindow(in: browser)?.browser?.newTab(url: url)
    }

    func adapter(for tab: BrowserTab) -> ExtensionTabAdapter {
        if let existing = tabAdapters[tab.id], existing.tab === tab,
           let window = existing.windowAdapter, owns(window) {
            return existing
        }
        guard let window = windowAdapters.first(where: { candidate in
            candidate.browser?.tabs.contains(where: { $0 === tab }) == true
        }), let browser = window.browser else {
            preconditionFailure("Extension tabs must belong to a registered browser window")
        }
        let adapter = ExtensionTabAdapter(tab: tab, browser: browser, windowAdapter: window)
        tabAdapters[tab.id] = adapter
        return adapter
    }
}
