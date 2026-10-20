// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP

/// Tab-level actions on a tab the connection already shares.
@MainActor
extension MCPBrowserSession {
    func switchTab(_ tab: BrowserTab) -> CallTool.Result {
        browser.activate(tab)
        return success("Tab activated. Use readPage for fresh controls.")
    }

    /// Keeps a shared tab that is not on screen attached to this connection's window, parked out of sight, so its page loads
    /// (Chromium needs a window), renders and is not throttled while the person keeps their own tab. Never changes the
    /// selection, the key window or the first responder.
    func keepInWindow(_ tab: BrowserTab) {
        tab.realizeDeferredSession()
        let page = tab.page
        page.ignoresWindowOcclusion = true
        guard page.window == nil, !onScreen(tab), let window = consentWindow?.nativeWindow else { return }
        // A page that was never shown has the engine's default size; it gets the size of the page the window shows instead.
        let shown = browser.activeTab?.liveView?.bounds.size
        WebViewParking.park(page, in: window, size: shown.flatMap { $0.width > 1 && $0.height > 1 ? $0 : nil })
    }

    /// The person took `tab` over: this connection loses its grant, development lease, observation and dialog claim there,
    /// and a standing grant does not share the tab again for as long as the connection lasts. Its other tabs are untouched,
    /// and the tab is no longer one it opened, so it never closes it without asking.
    func handBack(_ tab: BrowserTab) {
        tab.dialogs.handBack(connection: id)
        if let held = developmentTabs.removeValue(forKey: tab.id) {
            held.tab.releaseDevelopment(held.owner, reason: .grantDowngrade)
        }
        grants[tab.id] = nil
        observations[tab.id] = nil
        secretFields[tab.id] = nil
        openedTabs.remove(tab.id)
        if let pair = comparison, [pair.webKit, pair.chromium].contains(tab.id) {
            comparison = nil
        }
        takenBack.insert(tab.id)
    }

    /// Records on each tab whether this connection holds a grant for it: the tab's AI mark and its protection from unloading
    /// follow the grants exactly, whichever path changed them. A tab nobody controls any more pauses again while covered.
    func markControlledTabs(previous: [UUID: Grant]) {
        let changed = Set(previous.keys).symmetricDifference(grants.keys)
        guard !changed.isEmpty else { return }
        for tab in browser.tabs where changed.contains(tab.id) {
            tab.processState.setExternalController(id, holds: grants[tab.id] != nil)
            if tab.processState.externalControllers.isEmpty {
                tab.liveView?.ignoresWindowOcclusion = false
            }
        }
    }

    /// Closes a shared tab. Pinned tabs never close. An ordinary tab closes only after the person says yes in WSurf, unless
    /// this connection opened it or holds Developer access on it (see `closesWithoutAsking`).
    func closeTab(_ tab: BrowserTab) async -> CallTool.Result {
        guard !tab.isPinnedForProfile else { return failure("Pinned tabs must be closed by the user.") }
        if !closesWithoutAsking(tab) {
            let answer = await AgentTabClosing.ask(title: tab.title, isPrivate: tab.isPrivate)
            // Stop or a disconnect ends the question: the tab stays, whatever the sheet said.
            guard isConnected, available(), !Task.isCancelled else { return failure("The tab was not closed.") }
            switch answer {
            case .keepOpen:
                return failure("The user chose to keep this tab open. Do not ask again unless they ask for it to be closed.")
            case .closeAndStopAsking:
                closingWasConfirmed = true
            case .close:
                break
            }
            // The question took time: the access and the tab can have changed while it was open.
            guard mayProceed(tab, capability: .control), sharedTab(tab.id) === tab, !tab.isPinnedForProfile else {
                return failure("Page access changed before the tab was closed.")
            }
        }
        browser.close(tab)
        grants[tab.id] = nil
        observations[tab.id] = nil
        openedTabs.remove(tab.id)
        return success("Tab closed.")
    }

    /// Whether this connection may close `tab` without the person being asked. Never from the profile's own Assistant
    /// settings, which a process with a shell can edit: only what this connection did itself, or the Keychain-backed trust
    /// store, which holds Developer access (a paired app, a developer site and the Developer profile).
    private func closesWithoutAsking(_ tab: BrowserTab) -> Bool {
        openedTabs.contains(tab.id) || closingWasConfirmed || permits(tab, capability: .developer)
    }

    /// The refusal for a `goBack` that would leave the granted website, or nil when the previous page may be loaded.
    func goBackRefusal(_ tab: BrowserTab, grant: Grant) -> CallTool.Result? {
        guard let destination = tab.page.backForwardList.backList.last?.url else {
            return failure("There is no page to go back to.")
        }
        guard SitePermissions.origin(for: destination) == grant.origin else {
            return failure("The previous page belongs to another website. Ask the user to open and share it.")
        }
        return nil
    }
}
