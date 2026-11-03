// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

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
            && browser.tabsByID[tab.id] === tab && !tab.isClosed && tab.microTabID == nil
            && tab.internalPage == nil && tab.extensionBaseURL == nil && !tab.urlString.isEmpty
    }

    /// Moves `tab`, the live page and all it holds, into a new micro window and shows that window. The page is not
    /// reloaded. Its row stays here, in its place and marked, standing for the page (`insertMicroPlaceholder`); for a pin
    /// that row is the pin's unloaded page, and the page is an ordinary tab over there.
    @discardableResult
    func moveToMicroWindow(_ tab: BrowserTab) -> AppCoordinator? {
        guard canMoveToMicroWindow(tab), let application else { return nil }
        let micro = newCompanionWindow(kind: .micro, show: false, in: application)
        let placeholder = micro.browser.activeTab
        let row = browser.insertMicroPlaceholder(for: tab)
        guard moveTab(tab, to: micro) else {
            row.microTabID = nil
            row.pinID = nil
            browser.close(row, recordForReopening: false)
            micro.closeWindow()
            return nil
        }
        if let placeholder {
            micro.browser.close(placeholder, recordForReopening: false)
        }
        Self.mirror(tab, into: row)
        return micro
    }

    /// Moves `tab` of this micro window to the regular window used last, or to a new one when there is none. A page that
    /// was opened in the background stays in the background there. Moving it takes it out of any hold a connected app
    /// or the assistant had on it, as dragging a tab to another window does.
    @discardableResult
    func giveToMainWindow(_ tab: BrowserTab, activate: Bool) -> Bool {
        guard isMicro, !isClosed, browser.tabsByID[tab.id] === tab, let application else { return false }
        // The page goes back to the row it left, in whichever window keeps it.
        let kept = application.microPlaceholder(for: tab)
        guard let main = kept?.window ?? application.browsingWindow(for: self) else {
            moveTabToNewWindow(tab)
            return browser.tabsByID[tab.id] == nil
        }
        guard main.browser.adoptTab(tab, from: browser, activate: activate) else { return false }
        if let row = kept?.row {
            main.browser.settle(tab, into: row)
        }
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
        guard isMicro else {
            browser.onActivatingMicroPlaceholder = { [weak self] row in self?.openMicroPlaceholder(row) }
            return
        }
        microReveal.start()
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

    // MARK: - The row a page leaves behind

    /// Opening the row a page left behind: the page comes back here, to that row's place, as it is, and its micro window
    /// closes once empty. `showingWindow` (Option-click, or Show Micro Window in the row's menu) brings the micro window to
    /// the front instead. A row whose micro window is gone is an ordinary row again, and opens its page here.
    func openMicroPlaceholder(_ row: BrowserTab, showingWindow: Bool = false) {
        guard row.microTabID != nil else { return }
        guard let (micro, tab) = application?.microPage(for: row) else {
            row.microTabID = nil
            browser.activate(row)
            return
        }
        if showingWindow {
            micro.showBrowser()
        } else {
            micro.giveToMainWindow(tab, activate: true)
        }
    }

    /// The micro window's page closed, or the window did: the rows regular windows kept for it go too. A pin's row, or a
    /// Favorite's, stays as the unloaded page it always was, only unmarked.
    func releaseMicroPlaceholders(for ids: Set<UUID>) {
        guard isMicro, !ids.isEmpty, let application else { return }
        for window in application.windows where !window.isMicro && window.context === context {
            for row in window.browser.tabs where row.microTabID.map(ids.contains) == true {
                row.microTabID = nil
                if !row.isPinnedForProfile, !row.isFavorite {
                    window.browser.close(row, recordForReopening: false)
                }
            }
        }
    }

    // ponytail: one observation chain per row; a row linked again at a later restore gets a second, which only repeats
    // the same writes. A set of followed rows would dedupe it if rows ever relink often.
    /// The row follows the page's name, address and icon while it stands for it, so the sidebar says what the micro window shows.
    static func mirror(_ tab: BrowserTab, into row: BrowserTab) {
        withObservationTracking {
            _ = tab.pageTitle
            _ = tab.urlString
            _ = tab.favicon
        } onChange: { [weak tab, weak row] in
            Task { @MainActor [weak tab, weak row] in
                guard let tab, let row, row.microTabID == tab.id, !row.isClosed, !tab.isClosed else { return }
                row.pageTitle = tab.pageTitle
                row.urlString = tab.urlString
                row.favicon = tab.favicon
                mirror(tab, into: row)
            }
        }
    }

    /// A micro window with no page left has nothing to show: it closes.
    func closeMicroWindowIfEmpty() {
        guard isMicro, !isClosed, browser.tabs.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.closeWindow()
        }
    }

    // MARK: - The bar

    func makeMicroReveal() -> MicroReveal {
        MicroReveal(
            window: { [weak self] in self?.nativeWindow },
            host: { [weak self] in MicroShell.host(of: self?.browser.activeTab?.urlString) },
            focusToken: { [weak self] in self?.addressBarFocusToken ?? 0 },
            pending: { [weak self] in self?.hasPendingPagePrompt ?? true },
            // A window that is gone, or a state that cannot be read, keeps the bar.
            keeps: { [weak self] in
                guard let self else { return true }
                return MicroShell.keepsBar(
                    browser: browser,
                    coordinator: self,
                    isEditing: MicroShell.isEditing(in: nativeWindow),
                    voiceOver: NSWorkspace.shared.isVoiceOverEnabled
                )
            }
        )
    }

    /// The one flag for "a page is asking something of the person", which keeps the bar down so the real address shows: a
    /// sheet or a popover open on the window (every JavaScript dialog, sign-in, certificate question, app hand-off and
    /// passkey step is one), a permission prompt, a password or passkey save offer.
    var hasPendingPagePrompt: Bool {
        if isMicro, microReveal.openPrompts > 0 {
            return true
        }
        guard let tab = browser.activeTab else { return false }
        return !tab.permissions.pendingAsks.isEmpty || tab.permissions.isPopoverPresented
            || tab.autofillSave.current != nil || tab.autofillSave.websiteOffer != nil || tab.autofillSave.isPopoverPresented
    }
}

extension BrowserApplication {
    /// The micro window that holds the page `row` stands for, and that page, while both are open.
    func microPage(for row: BrowserTab) -> (window: AppCoordinator, tab: BrowserTab)? {
        guard let id = row.microTabID else { return nil }
        for window in windows where window.isMicro && !window.isClosed && window.context === row.context {
            if let tab = window.browser.tabsByID[id] {
                return (window, tab)
            }
        }
        return nil
    }

    /// The row a regular window keeps for `tab` of a micro window, and that window.
    func microPlaceholder(for tab: BrowserTab) -> (window: AppCoordinator, row: BrowserTab)? {
        for window in windows where !window.isMicro && !window.isClosed && !window.isSwitchingProfile
            && window.context === tab.context {
            if let row = window.browser.microPlaceholder(for: tab.id) {
                return (window, row)
            }
        }
        return nil
    }

    /// After windows open from a saved session: a row whose micro window came back follows its page again, and one whose
    /// micro window did not is an ordinary row, which opens its page where it is. Micro windows open after the regular
    /// ones, so this runs once they all have.
    func relinkMicroPlaceholders() {
        for window in windows where !window.isMicro && !window.isClosed {
            for row in window.browser.tabs where row.microTabID != nil {
                if let page = microPage(for: row) {
                    AppCoordinator.mirror(page.tab, into: row)
                } else {
                    row.microTabID = nil
                }
            }
        }
    }
}
