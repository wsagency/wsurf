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
