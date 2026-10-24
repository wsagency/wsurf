// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// The micro window: one page, no chrome until the pointer reaches the top. It is an ordinary window (coordinator, model
/// and host) with `WindowKind.micro`, so everything that owns a page (permissions, dialogs, downloads, media, extensions)
/// still has its owner.
extension AppCoordinator {
    var isMicro: Bool {
        browser.windowKind == .micro
    }

    /// Opens an empty micro window with the address focused. From a private window it opens a regular one, as New Window does.
    @discardableResult
    func requestNewMicroWindow(show: Bool = true) -> AppCoordinator? {
        guard !isClosed else { return nil }
        let app = application ?? BrowserApplication.shared
        let owner = profiles.isPrivate ? profiles.profileToReturnTo : profiles.current
        let micro = app.newWindow(profile: owner, settingsOwner: owner, show: show, kind: .micro)
        micro.focusAddressBar()
        return micro
    }

    /// Float on Top, set from the bar and the Window menu. Off is a normal window that can zoom but never enter full screen.
    func applyFloatOnTop() {
        guard isMicro, let window = nativeWindow else { return }
        window.level = floatsOnTop ? .floating : .normal
        window.collectionBehavior = MicroWindowMetrics.collectionBehavior(floating: floatsOnTop)
    }

    /// The window the commands that open app pages (a new tab, the palette, Settings, History, Downloads, release notes) act
    /// in. A micro window holds one page, so those go to the regular window of its profile used last, or to a new one.
    func mainWindowForCommands() -> AppCoordinator {
        guard isMicro, !isClosed else { return self }
        let app = application ?? BrowserApplication.shared
        return app.browsingWindow(for: self)
            ?? app.newWindow(profile: profiles.isPrivate ? profiles.profileToReturnTo : profiles.current)
    }

    // MARK: - Moving a page out and back

    /// Whether `tab` can move to a micro window: a page of this window that shows a site. Settings, History, Downloads and
    /// the vault pages stay out, so none of them is ever drawn without chrome, always on top and on every desktop.
    func canMoveToMicroWindow(_ tab: BrowserTab) -> Bool {
        !isMicro && !isClosed && application != nil
            && browser.tabsByID[tab.id] === tab && !tab.isClosed
            && tab.internalPage == nil && tab.extensionBaseURL == nil && !tab.urlString.isEmpty
    }

    /// Moves `tab`, the live page and all it holds, into a new micro window and shows that window. The page is not
    /// reloaded; if it was a pin, the pin stays here with an unloaded page, and the page is an ordinary tab over there.
    @discardableResult
    func moveToMicroWindow(_ tab: BrowserTab) -> AppCoordinator? {
        guard canMoveToMicroWindow(tab), let application else { return nil }
        let micro = newCompanionWindow(kind: .micro, show: false, in: application)
        let placeholder = micro.browser.activeTab
        guard moveTab(tab, to: micro) else {
            micro.closeWindow()
            return nil
        }
        if let placeholder {
            micro.browser.close(placeholder, recordForReopening: false)
        }
        return micro
    }

    /// Moves `tab` of this micro window to the regular window used last, or to a new one when there is none. A page that
    /// was opened in the background stays in the background there. Moving it takes it out of any hold a connected app
    /// or the assistant had on it, as dragging a tab to another window does.
    @discardableResult
    func giveToMainWindow(_ tab: BrowserTab, activate: Bool) -> Bool {
        guard isMicro, !isClosed, browser.tabsByID[tab.id] === tab, let application else { return false }
        guard let main = application.browsingWindow(for: self) else {
            moveTabToNewWindow(tab)
            return browser.tabsByID[tab.id] == nil
        }
        guard main.browser.adoptTab(tab, from: browser, activate: activate) else { return false }
        if activate {
            main.showBrowser()
        } else {
            tab.isUnseen = true
        }
        return true
    }

    /// A new window for a page that leaves this one: the same profile, or, for a private tab, the same private session. A
    /// private page never moves into a context of its own, which would be a different cookie store.
    func newCompanionWindow(kind: WindowKind, show: Bool, in application: BrowserApplication) -> AppCoordinator {
        let owner = profiles.isPrivate ? profiles.profileToReturnTo : profiles.current
        return application.newWindow(
            profile: profiles.current, settingsOwner: owner, show: show, kind: kind, joining: profiles.isPrivate ? context : nil
        )
    }

    /// Move Back to Main Window: the page in front goes where it came from, and this window closes.
    func moveBackToMainWindow() {
        guard isMicro, let tab = browser.activeTab else { return }
        giveToMainWindow(tab, activate: true)
    }

    /// A micro window holds exactly one page. Any other tab that reaches it, by a link, a popup, an extension or the
    /// assistant, moves to the main window as it is, and the window closes when its own page leaves.
    func configureMicroCallbacks() {
        guard isMicro else { return }
        let previous = browser.onTabOpened
        browser.onTabOpened = { [weak self] tab in
            previous?(tab)
            // After the tab has been made, so an opener that chose to show it has already done so.
            Task { @MainActor [weak self, weak tab] in
                guard let self, let tab else { return }
                handOff(tab)
            }
        }
        // Assigned, not chained: nothing else sets it, and a second call of `configureWindowCallbacks` stays harmless.
        browser.onTabTransferredOut = { [weak self] _, _ in self?.closeMicroWindowIfEmpty() }
    }

    private func handOff(_ tab: BrowserTab) {
        guard browser.tabs.count > 1, browser.tabsByID[tab.id] === tab else { return }
        giveToMainWindow(tab, activate: browser.activeTabID == tab.id)
    }

    /// A micro window with no page left has nothing to show: it closes.
    func closeMicroWindowIfEmpty() {
        guard isMicro, !isClosed, browser.tabs.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.closeWindow()
        }
    }
}
