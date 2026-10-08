// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import WebKit

@MainActor
final class ExtensionMenuCommand: NSObject {
    let id: String
    weak var window: ExtensionWindowAdapter?

    init(id: String, window: ExtensionWindowAdapter) {
        self.id = id
        self.window = window
    }
}
@MainActor
final class ExtensionTabAdapter: NSObject, WKWebExtensionTab {
    private(set) weak var tab: BrowserTab?
    private(set) weak var browser: BrowserModel?
    private(set) weak var windowAdapter: ExtensionWindowAdapter?

    init(tab: BrowserTab, browser: BrowserModel, windowAdapter: ExtensionWindowAdapter) {
        self.tab = tab
        self.browser = browser
        self.windowAdapter = windowAdapter
    }

    func move(to browser: BrowserModel, window: ExtensionWindowAdapter) {
        self.browser = browser
        windowAdapter = window
    }

    func invalidate() {
        tab = nil
        browser = nil
        windowAdapter = nil
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard let windowAdapter, windowAdapter.browser != nil else { return nil }
        return windowAdapter
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let index = browser?.tabs.firstIndex(where: { $0 === tab }) else { return NSNotFound }
        return index
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        guard let tab, tab.isMaterialised else { return nil }
        return tab.page.webKit
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        guard let tab else { return nil }
        if let url = tab.committedURL {
            return url
        }
        guard !tab.isMaterialised, !tab.urlString.isEmpty else { return nil }
        return URL(string: tab.urlString)
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        guard let tab, tab.isLoading, !tab.urlString.isEmpty,
              let url = URL(string: tab.urlString), url != tab.committedURL
        else { return nil }
        return url
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        tab.map { !$0.isLoading } ?? false
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        guard let tab else { return false }
        return browser?.activeTabID == tab.id
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let tab, let browser, windowAdapter?.browser === browser else {
            completionHandler(ExtensionWindowError.unavailable)
            return
        }
        browser.activate(tab)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let tab, let browser, windowAdapter?.browser === browser else {
            completionHandler(ExtensionWindowError.unavailable)
            return
        }
        browser.close(tab)
        completionHandler(nil)
    }
}

enum ExtensionWindowError: LocalizedError {
    case unavailable
    case creationFailed
    case foreignTab

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "The browser window is no longer available.")
        case .creationFailed:
            String(localized: "The browser could not create the requested window.")
        case .foreignTab:
            String(localized: "Tabs cannot move between profiles or private sessions.")
        }
    }
}

@MainActor
final class ExtensionWindowAdapter: NSObject, WKWebExtensionWindow {
    private(set) weak var browser: BrowserModel?
    private weak var manager: ExtensionManager?
    weak var nativeWindow: NSWindow?

    init(browser: BrowserModel, manager: ExtensionManager, window: NSWindow? = nil) {
        self.browser = browser
        self.manager = manager
        nativeWindow = window
    }

    func invalidate() {
        browser = nil
        manager = nil
        nativeWindow = nil
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let browser, let manager, manager.owns(self) else { return [] }
        return browser.tabs.map { manager.adapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let browser, let manager, manager.owns(self), let active = browser.activeTab else { return nil }
        return manager.adapter(for: active)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nativeWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) {
            return .fullscreen
        }
        if window.isMiniaturized {
            return .minimized
        }
        if window.isZoomed {
            return .maximized
        }
        return .normal
    }

    func setWindowState(
        _ state: WKWebExtension.WindowState,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let window = nativeWindow, manager?.owns(self) == true else {
            completionHandler(ExtensionWindowError.unavailable)
            return
        }
        if window.styleMask.contains(.fullScreen) != (state == .fullscreen) {
            window.toggleFullScreen(nil)
        }
        if state == .minimized {
            window.miniaturize(nil)
        } else {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if state != .fullscreen, window.isZoomed != (state == .maximized) {
                window.zoom(nil)
            }
        }
        completionHandler(nil)
    }

    func apply(configuration: WKWebExtension.WindowConfiguration) {
        guard let window = nativeWindow, manager?.owns(self) == true else { return }
        let proposed = configuration.frame
        var frame = window.frame
        if proposed.origin.x.isFinite {
            frame.origin.x = proposed.origin.x
        }
        if proposed.origin.y.isFinite {
            frame.origin.y = proposed.origin.y
        }
        if proposed.width.isFinite, proposed.width > 0 {
            frame.size.width = proposed.width
        }
        if proposed.height.isFinite, proposed.height > 0 {
            frame.size.height = proposed.height
        }
        window.setFrame(frame, display: true)
        if window.styleMask.contains(.fullScreen) != (configuration.windowState == .fullscreen) {
            window.toggleFullScreen(nil)
        }
        if configuration.windowState == .minimized {
            window.miniaturize(nil)
        } else {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            if configuration.windowState != .fullscreen,
               window.isZoomed != (configuration.windowState == .maximized) { window.zoom(nil) }
        }
        if configuration.shouldBeFocused {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        manager?.profile?.isPrivate ?? false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        nativeWindow?.frame ?? .null
    }

    func setFrame(
        _ frame: CGRect,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let nativeWindow, manager?.owns(self) == true else {
            completionHandler(ExtensionWindowError.unavailable)
            return
        }
        nativeWindow.setFrame(frame, display: true)
        completionHandler(nil)
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        nativeWindow?.screen?.frame ?? .null
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = nativeWindow, let browser, let manager, manager.owns(self) else {
            completionHandler(ExtensionWindowError.unavailable)
            return
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        manager.focus(browser: browser)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let window = nativeWindow, manager?.owns(self) == true else {
            completionHandler(ExtensionWindowError.unavailable)
            return
        }
        window.performClose(nil)
        completionHandler(nil)
    }
}
