// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import os
import WebKit

extension ExtensionManager {
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        windowAdapters
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let target: ExtensionWindowAdapter?
        if let requested = configuration.window {
            guard let window = requested as? ExtensionWindowAdapter, owns(window) else {
                completionHandler(nil, ExtensionWindowError.unavailable)
                return
            }
            target = window
        } else if let parent = configuration.parentTab as? ExtensionTabAdapter {
            guard let browser = parent.browser, let owner = parent.windowAdapter,
                  owner.browser === browser, owns(owner) else {
                completionHandler(nil, ExtensionWindowError.unavailable)
                return
            }
            target = owner
        } else {
            target = preferredWindowAdapter
        }
        guard let window = target, let browser = window.browser, owns(window) else {
            completionHandler(nil, ExtensionWindowError.unavailable)
            return
        }
        let parent = configuration.parentTab as? ExtensionTabAdapter
        if let parent, parent.browser !== browser {
            completionHandler(nil, ExtensionWindowError.foreignTab)
            return
        }
        let tab = browser.newTab(url: configuration.url, activate: configuration.shouldBeActive, after: parent?.tab)
        if configuration.shouldBePinned {
            browser.pin(tab)
        }
        let others = browser.tabs.filter { $0 !== tab }
        if configuration.index >= 0, configuration.index < others.count {
            browser.move([.tab(tab.id)], into: nil, before: .tab(others[configuration.index].id))
        } else if configuration.index != NSNotFound {
            browser.move([.tab(tab.id)], into: nil, before: nil)
        }
        completionHandler(adapter(for: tab), nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard configuration.tabs.isEmpty || (!configuration.shouldBePrivate && profile?.isPrivate != true) else {
            completionHandler(nil, ExtensionWindowError.foreignTab)
            return
        }
        guard configuration.tabs.allSatisfy({ candidate in
            guard let tab = candidate as? ExtensionTabAdapter, let browser = tab.browser,
                  let window = tab.windowAdapter else { return false }
            return window.browser === browser && owns(window)
        }) else {
            completionHandler(nil, ExtensionWindowError.foreignTab)
            return
        }
        guard let window = onOpenWindow?(configuration), let browser = window.browser,
              browser.context.extensions.owns(window) else {
            completionHandler(nil, ExtensionWindowError.creationFailed)
            return
        }
        window.apply(configuration: configuration)
        completionHandler(window, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard openTab(extensionContext.optionsPageURL) != nil else {
            completionHandler(ExtensionWindowError.unavailable)
            return
        }
        completionHandler(nil)
    }

    private func permissionWindow(for tab: (any WKWebExtensionTab)?) -> ExtensionWindowAdapter? {
        if let tab {
            guard let adapter = tab as? ExtensionTabAdapter, let browser = adapter.browser,
                  let window = adapter.windowAdapter, window.browser === browser, owns(window) else { return nil }
            return window
        }
        return preferredWindowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let name = extensionContext.webExtension.displayName ?? extensionContext.uniqueIdentifier
        guard let window = permissionWindow(for: tab), let nativeWindow = window.nativeWindow else {
            completionHandler([], nil)
            return
        }
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.owns(window) else {
                completionHandler([], nil)
                return
            }
            let granted = await ExtensionConsent.confirmRuntimeGrant(
                name: name,
                permissions: permissions,
                matchPatterns: [],
                in: nativeWindow
            )
            completionHandler(self.owns(window) && granted ? permissions : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let name = extensionContext.webExtension.displayName ?? extensionContext.uniqueIdentifier
        guard let window = permissionWindow(for: tab), let nativeWindow = window.nativeWindow else {
            completionHandler([], nil)
            return
        }
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.owns(window) else {
                completionHandler([], nil)
                return
            }
            let granted = await ExtensionConsent.confirmRuntimeURLAccess(name: name, urls: urls, in: nativeWindow)
            completionHandler(self.owns(window) && granted ? urls : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let name = extensionContext.webExtension.displayName ?? extensionContext.uniqueIdentifier
        guard let window = permissionWindow(for: tab), let nativeWindow = window.nativeWindow else {
            completionHandler([], nil)
            return
        }
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.owns(window) else {
                completionHandler([], nil)
                return
            }
            let granted = await ExtensionConsent.confirmRuntimeGrant(
                name: name,
                permissions: [],
                matchPatterns: matchPatterns,
                in: nativeWindow
            )
            completionHandler(self.owns(window) && granted ? matchPatterns : [], nil)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        noteActionUpdate()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let tab = action.associatedTab as? ExtensionTabAdapter {
            guard let browser = tab.browser, let window = tab.windowAdapter,
                  window.browser === browser, owns(window),
                  present(action, for: context.uniqueIdentifier, in: browser) else {
                completionHandler(ExtensionWindowError.unavailable)
                return
            }
        } else if !present(action, for: context.uniqueIdentifier, in: nil) {
            completionHandler(ExtensionWindowError.unavailable)
            return
        }
        completionHandler(nil)
    }
}
