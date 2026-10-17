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

    func closeTab(_ tab: BrowserTab) -> CallTool.Result {
        guard tab.pinnedURL == nil else { return failure("Pinned tabs must be closed by the user.") }
        browser.close(tab)
        grants[tab.id] = nil
        observations[tab.id] = nil
        return success("Tab closed.")
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
