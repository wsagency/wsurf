// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP

/// Sharing tabs with the connection: the access request, the tab list, and navigation.
@MainActor
extension MCPBrowserSession {
    func requestAccess(development: Bool) async -> CallTool.Result {
        guard !accessWasRequested else {
            return failure("Access has already been requested. The user can disconnect and reconnect to share different tabs.")
        }
        let tabs = browser.splitPanes ?? browser.activeTab.map { [$0] } ?? []
        let pages = tabs.compactMap { tab -> MCPAccessConsent.Page? in
            guard !tab.isPrivate, let url = webURL(of: tab), tab.assistantAccess.effectivePolicy != .deny else { return nil }
            return .init(id: tab.id, title: tab.title, url: url)
        }
        guard !pages.isEmpty else {
            _ = await consent(clientName, [], development)
            return failure("No shareable webpage is on screen. WSurf showed the user how to open a webpage. Request access again after they have opened it.")
        }
        accessWasRequested = true
        var granted = await consent(clientName, pages, development)
        // Development access can only come from a request that asked for it.
        if granted == .development, !development {
            granted = .control
        }
        guard isConnected, available(), !Task.isCancelled, let answer = granted else { return failure("Access was not granted.") }
        for page in pages {
            guard let tab = browser.tabs.first(where: { $0.id == page.id }),
                !tab.isPrivate, webURL(of: tab) == page.url,
                tab.assistantAccess.effectivePolicy != .deny
            else { continue }
            grants[page.id] = Grant(origin: SitePermissions.origin(for: page.url), access: answer)
        }
        return tabList()
    }

    func tabList() -> CallTool.Result {
        let tabs: [Value] = browser.tabs.compactMap { tab in
            guard sharedTab(tab.id) != nil else { return nil }
            return .object([
                "tabID": .string(tab.id.uuidString), "title": .string(tab.title),
                "url": .string(webURL(of: tab)?.absoluteString ?? ""),
                "active": .bool(browser.activeTabID == tab.id),
                "canControl": .bool(permits(tab, capability: .control)),
            ])
        }
        let content: Value = .object(["tabs": .array(tabs)])
        return CallTool.Result(
            content: [.text(text: encoded(content), annotations: nil, _meta: nil)], structuredContent: Optional.some(content), isError: false)
    }

    func navigate(_ raw: String, tab: BrowserTab, grant: Grant) async -> CallTool.Result {
        guard let url = permittedDestination(raw) else {
            return failure("Use an HTTP(S) URL observed in a page link, or ask the user to open and share the page.")
        }
        let previousURL = webURL(of: tab)
        let origin = SitePermissions.origin(for: url)
        if origin != grant.origin {
            guard await openConsent(clientName, url) else { return failure("Navigation was not approved.") }
        }
        guard mayProceed(tab, capability: .control), onScreen(tab), webURL(of: tab) == previousURL else {
            return failure("Page access changed before navigation.")
        }
        guard browser.sitePermissions.assistantAccess(for: origin) != .deny else { return failure("Assistant access is off for this website.") }
        observations[tab.id] = nil
        grants[tab.id] = Grant(origin: origin, access: grant.access)
        let immediate = tab.load(url, transition: .agent)
        let navigation = await tab.waitForPendingNavigation() ?? immediate
        guard navigation != nil else {
            return failure("Navigation could not be started.")
        }
        return success("Navigation started. Use readPage after the page loads. Redirects to a different website require new sharing.")
    }

    func openNewTab(_ raw: String) async -> CallTool.Result {
        guard grants.keys.contains(where: { sharedTab($0).map { permits($0, capability: .control) } ?? false }),
            let url = permittedDestination(raw)
        else { return failure("Opening a tab requires control access and an allowed HTTP(S) URL.") }
        guard await openConsent(clientName, url), isConnected, available(), !Task.isCancelled else {
            return failure("Opening the page was not approved.")
        }
        guard browser.sitePermissions.assistantAccess(for: SitePermissions.origin(for: url)) != .deny else {
            return failure("Assistant access is off for this website.")
        }
        let tab = browser.newTab(url: url, transition: .agent)
        grants[tab.id] = Grant(origin: SitePermissions.origin(for: url), access: .control)
        return success("Opened tab \(tab.id.uuidString). Use readPage after it loads.")
    }

    private func permittedDestination(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            url.host() != nil, url.user == nil, url.password == nil,
            !hasReadContent || destinations.contains(destinationKey(url))
        else { return nil }
        return url
    }

    func destinationKey(_ url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.url?.absoluteString ?? url.absoluteString
    }

    /// Persistent state only: whether this connection still shares `id`. A task's own cancellation is not part of it, because
    /// another connection evaluates this through the owner's `isAuthorized` (lease release) from its own, possibly cancelled, task.
    func sharedTab(_ id: UUID) -> BrowserTab? {
        guard isConnected, available(),
            let grant = grants[id], let tab = browser.tabs.first(where: { $0.id == id }),
            !tab.isPrivate, !tab.isClosed, let url = webURL(of: tab),
            SitePermissions.origin(for: url) == grant.origin
        else { return nil }
        tab.assistantAccess.pageChanged(url: url)
        return tab.assistantAccess.effectivePolicy == .deny ? nil : tab
    }
}
