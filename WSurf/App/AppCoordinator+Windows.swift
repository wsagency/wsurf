// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import os
import WebKit

extension AppCoordinator {
    func organizeTabs() {
        guard LLMSettings.$scoped.withValue(modelSettings, operation: { TabOrganizer.isAvailable }) else {
            statusMessage = String(localized: "Organizing tabs needs a model: add a provider key or enable Apple Intelligence.")
            return
        }
        let loose = browser.tabs.filter {
            browser.folder(containing: $0) == nil && $0.pinnedURL == nil
        }
        guard loose.count >= 4 else {
            statusMessage = String(localized: "Not enough loose tabs to organize.")
            return
        }
        let context = context
        guard let owner = context.extensions.adapter(for: browser),
              let window = owner.nativeWindow, context.isRegistered(browser) else { return }
        statusMessage = String(localized: "Looking for related tabs…")
        Task { [weak self] in
            guard let self, !isClosed, self.context === context,
                  context.extensions.adapter(for: browser) === owner,
                  owner.nativeWindow === window, context.isRegistered(browser) else { return }
            let outcome = await LLMSettings.$scoped.withValue(context.modelSettings) {
                await TabOrganizer.propose(for: loose.map { ($0.id, $0.title) })
            }
            guard !isClosed, self.context === context,
                  context.extensions.adapter(for: browser) === owner,
                  owner.nativeWindow === window, context.isRegistered(browser) else { return }
            statusMessage = nil
            let plan: TabOrganizer.Plan
            switch outcome {
            case .plan(let proposed):
                plan = proposed
            case .empty:
                statusMessage = String(localized: "No related tabs to group.")
                return
            case .failed:
                statusMessage = String(localized: "The model couldn’t group the tabs. Try again.")
                return
            }
            let proposed = plan.folders.map { ($0.name, $0.tabIDs.count) }
            guard await ConfirmAlert.organize(folders: proposed, in: window),
                  !isClosed, self.context === context,
                  context.extensions.adapter(for: browser) === owner,
                  owner.nativeWindow === window, context.isRegistered(browser) else { return }
            for folder in plan.folders {
                let members = folder.tabIDs
                    .compactMap { id in browser.tabs.first { $0.id == id } }
                    .filter { browser.folder(containing: $0) == nil && $0.pinnedURL == nil }
                guard members.count >= 2 else { continue }
                let made = browser.createFolder(named: folder.name, containing: members)
                if browser.tabs(in: made).count < 2 {
                    Pipeline.log.error("organized folder arrived empty; removing it")
                    browser.deleteFolder(made)
                }
            }
        }
    }

    func configureWindowCallbacks() {
        let extensionTabClosed = browser.onTabClosed
        browser.onTabClosed = { [weak self] tab in
            extensionTabClosed?(tab)
            self?.tabDidClose(tab)
        }
        let extensionTabChanged = browser.onActiveTabChanged
        browser.onActiveTabChanged = { [weak self] newTab, previousTab in
            extensionTabChanged?(newTab, previousTab)
            guard let self else { return }
            if conversationSpaceID != browser.activeSpaceID {
                conversationVoice?.stop()
            }
            followMedia(to: newTab, from: previousTab)
            applyHoverShield()
            updateWindowAppearance()
        }
    }

    var windowTitle: String {
        let pageTitle = browser.activeTab?.title ?? String(localized: "New Window")
        // AppKit also uses this title to size the Dock menu.
        let title = pageTitle.count > 40 ? String(pageTitle.prefix(39)) + "…" : pageTitle
        return profiles.isPrivate
            ? String(localized: "\(title) — Private Browsing")
            : String(localized: "\(title) — \(profiles.current.name)")
    }

    var otherWindows: [AppCoordinator] {
        application?.windows.filter { $0 !== self && $0.browser.context === browser.context } ?? []
    }

    func requestNewWindow(isPrivate: Bool = false) {
        guard !isClosed else { return }
        let app = application ?? BrowserApplication.shared
        app.newWindow(
            profile: isPrivate ? .privateBrowsing()
                : (profiles.isPrivate ? profiles.profileToReturnTo : profiles.current),
            settingsOwner: profiles.isPrivate ? profiles.profileToReturnTo : profiles.current
        )
    }

    @discardableResult
    func openLinkInNewWindow(_ url: URL, isPrivate: Bool = false) -> AppCoordinator? {
        guard !isClosed else { return nil }
        let app = application ?? BrowserApplication.shared
        let settingsOwner = profiles.isPrivate ? profiles.profileToReturnTo : profiles.current
        return app.newWindow(
            profile: (isPrivate || profiles.isPrivate) ? .privateBrowsing() : profiles.current,
            settingsOwner: settingsOwner, urls: [url]
        )
    }

    func closeWindow() {
        if let nativeWindow {
            nativeWindow.performClose(nil)
        } else {
            windowDidClose()
        }
    }

    func windowDidBecomeKey() {
        application?.focus(self)
        activation.setSuspended(false)
        updateWindowAppearance()
    }

    func windowDidResignKey() {
        extensions.focus(browser: nil)
        activation.setSuspended(true)
        controlDownAt = nil
        browser.endTabSwitching()
        tabPreview.dismiss()
    }

    func updateWindowAppearance() {
        if profiles.isPrivate {
            browser.context.favicons.schemeOverride = .dark
        } else {
            switch settings.appearance {
            case .system:
                browser.context.favicons.schemeOverride = nil
            case .light, .lightCalm:
                browser.context.favicons.schemeOverride = .light
            case .dark, .darkCalm:
                browser.context.favicons.schemeOverride = .dark
            }
        }
        nativeWindow?.appearance = profiles.isPrivate
            ? NSAppearance(named: .darkAqua) : settings.appearance.nsAppearance
        nativeWindow?.title = windowTitle
        reloadFaviconsIfSchemeChanged()
    }

    func windowDidClose() {
        guard application?.isTerminating != true, beginClosingWindow() else { return }
        if !profiles.isPrivate {
            browser.markSessionClosed()
        }
        conversationLog.saveBlocking()
        stopAgent()
        voiceInput.cancel()
        voicePreparation?.cancel()
        voicePreparation = nil
        activation.stop()
        memoryPressure.stop()
        media.releaseControl()
        media.unwatch()
        downloadFlights.stopWatching()
        linkPeek.end()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        if let tabSwitchMonitor {
            NSEvent.removeMonitor(tabSwitchMonitor)
        }
        escapeMonitor = nil
        tabSwitchMonitor = nil
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
        }
        resignActiveObserver = nil
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
        becomeActiveObserver = nil
        browser.cancelPendingSave()
        closePeekImmediately()
        browser.closeAllTabs(saving: false)
        context.unregister(browser)
        if let application {
            application.didClose(self)
        } else {
            mcpServer.stop()
            extensions.unregister(browser: browser)
        }
        releaseWindowHost()
        if profiles.isPrivate {
            browser.downloads.forgetPrivateDownloads()
            conversationLog.clearAll()
            privateSession = nil
            let context = browser.context
            if let application {
                application.endPrivateSession(context)
            } else {
                Task { await context.endPrivateSession() }
            }
        }
    }

    @discardableResult
    func moveTab(_ tab: BrowserTab, to destination: AppCoordinator) -> Bool {
        guard !isClosed, !destination.isClosed,
              destination.browser.adoptTab(tab, from: browser) else { return false }
        destination.showBrowser()
        return true
    }

    func moveTabToNewWindow(_ tab: BrowserTab) {
        // Private windows have independent cookie stores. Moving a live page
        // between those stores would also move its authenticated session.
        guard !profiles.isPrivate, let application else { return }
        let destination = application.newWindow(profile: profiles.current)
        let placeholder = destination.browser.activeTab
        if moveTab(tab, to: destination), let placeholder {
            destination.browser.close(placeholder, recordForReopening: false)
        }
    }

    @discardableResult
    func finishWindowDrag(_ items: [SidebarItem], at screenPoint: NSPoint) -> Bool {
        guard let sourceWindow = nativeWindow, !sourceWindow.frame.contains(screenPoint),
              !profiles.isPrivate, let application
        else { return false }
        let ids = browser.sidebarTree.expanded(Set(items)).compactMap { item -> UUID? in
            guard case .tab(let id) = item else { return nil }
            return id
        }
        let tabs = browser.tabs.filter { ids.contains($0.id) }
        guard !tabs.isEmpty else { return false }
        let target = NSApp.orderedWindows.lazy
            .filter { $0.isVisible && !$0.isMiniaturized && $0.frame.contains(screenPoint) }
            .compactMap { window in application.windows.first { $0.nativeWindow === window } }
            .first { $0 !== self }
        if let target, target.browser.context !== browser.context {
            return false
        }
        let destination = target ?? application.newWindow(profile: profiles.current)
        let placeholder = target == nil ? destination.browser.activeTab : nil
        for tab in tabs {
            _ = destination.browser.adoptTab(tab, from: browser)
        }
        if let placeholder {
            destination.browser.close(placeholder, recordForReopening: false)
        }
        if target == nil, let window = destination.nativeWindow {
            window.setFrameTopLeftPoint(NSPoint(x: screenPoint.x - 100, y: screenPoint.y + 20))
        }
        destination.showBrowser()
        return true
    }
}
