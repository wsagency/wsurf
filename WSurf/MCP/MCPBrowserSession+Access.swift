// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP
import os

/// Sharing tabs with the connection: the access request, the tab list, and navigation.
@MainActor
extension MCPBrowserSession {
    /// What the user said about the access sheet the first time this connection asked for tabs.
    private static let alreadyRequested =
        "Access has already been requested. The user can disconnect and reconnect to share different tabs."

    func requestAccess(development: Bool, developer: Bool = false) async -> CallTool.Result {
        let tabs = browser.splitPanes ?? browser.activeTab.map { [$0] } ?? []
        let candidates = tabs.compactMap { tab -> (page: MCPAccessConsent.Page, standing: MCPAccessConsent.Access?)? in
            guard !tab.isPrivate, let url = webURL(of: tab), tab.assistantAccess.explicitPolicy != .deny else { return nil }
            var page = MCPAccessConsent.Page(id: tab.id, title: tab.title, url: url)
            page.developerEligible = developer && developerTierHolds(at: url)
            return (page, standingAccess(at: url))
        }
        // A paired client's standing grant covers its developer sites without a sheet.
        for (page, standing) in candidates {
            if let standing, (grants[page.id]?.access.rank ?? -1) < standing.rank {
                grants[page.id] = Grant(origin: SitePermissions.origin(for: page.url), access: standing, source: .standing)
            }
        }
        let wanted = developer ? MCPAccessConsent.Access.developer : development ? .development : .control
        let pages = candidates.filter { ($0.standing?.rank ?? -1) < wanted.rank }.map { $0.page }
        let covered = candidates.contains { $0.standing != nil }
        guard !pages.isEmpty else {
            if covered {
                return tabList()
            }
            guard !accessWasRequested else { return failure(Self.alreadyRequested) }
            _ = await consent(clientName, [], development || developer)
            return failure("No shareable webpage is on screen. WSurf showed the user how to open a webpage. Request access again after they have opened it.")
        }
        // At most one sheet per connection; later calls only add what a standing grant covers.
        guard !accessWasRequested else { return covered ? tabList() : failure(Self.alreadyRequested) }
        accessWasRequested = true
        let granted = await consent(clientName, pages, development || developer)
        guard isConnected, available(), !Task.isCancelled else { return failure("Access was not granted.") }
        guard let answer = granted else { return covered ? tabList() : failure("Access was not granted.") }
        for page in pages {
            guard let tab = browser.tabs.first(where: { $0.id == page.id }),
                !tab.isPrivate, webURL(of: tab) == page.url,
                tab.assistantAccess.explicitPolicy != .deny
            else { continue }
            // Only a request that asked for more can be given more, and Developer only where the sheet offered it.
            var access = answer
            if access == .developer, !(developer && page.developerEligible) {
                access = .development
            }
            if access == .development, !(development || developer) {
                access = .control
            }
            if let existing = grants[page.id], existing.access.rank >= access.rank {
                continue
            }
            grants[page.id] = Grant(origin: SitePermissions.origin(for: page.url), access: access)
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
        guard let url = permittedDestination(raw, grant: grant) else {
            return failure("Use an HTTP(S) URL observed in a page link, or ask the user to open and share the page.")
        }
        let previousURL = webURL(of: tab)
        let origin = SitePermissions.origin(for: url)
        // A default grant stays a default grant on its own website. A new website joins it only where the default applies.
        let viaDefault = (origin != grant.origin || grant.source == .appDefault) && followsWebsiteDefault(at: url)
        if origin != grant.origin, !followsDeveloperSites(grant, to: url), !viaDefault {
            guard await openConsent(clientName, url) else { return failure("Navigation was not approved.") }
        }
        guard mayProceed(tab, capability: .control), onScreen(tab), webURL(of: tab) == previousURL else {
            return failure("Page access changed before navigation.")
        }
        guard browser.sitePermissions.assistantRecord(for: origin) != .deny else { return failure("Assistant access is off for this website.") }
        observations[tab.id] = nil
        if followsDeveloperSites(grant, to: url) {
            grants[tab.id] = Grant(origin: origin, access: grant.access, source: grant.source)
        } else if viaDefault {
            grants[tab.id] = Grant(origin: origin, access: .control, source: .appDefault)
        } else {
            grants[tab.id] = moved(grant, to: origin)
        }
        let immediate = tab.load(url, transition: .agent)
        let navigation = await tab.waitForPendingNavigation() ?? immediate
        guard navigation != nil else {
            return failure("Navigation could not be started.")
        }
        return success("Navigation started. Use readPage after the page loads. Redirects to a different website require new sharing.")
    }

    func openNewTab(_ raw: String) async -> CallTool.Result {
        if let url = webDestination(raw), let access = standingAccess(at: url) {
            guard isConnected, available(), !Task.isCancelled else { return failure("Opening the page was not approved.") }
            guard browser.sitePermissions.assistantRecord(for: SitePermissions.origin(for: url)) != .deny else {
                return failure("Assistant access is off for this website.")
            }
            let tab = browser.newTab(url: url, transition: .agent)
            grants[tab.id] = Grant(origin: SitePermissions.origin(for: url), access: access, source: .standing)
            return success("Opened tab \(tab.id.uuidString). Use readPage after it loads.")
        }
        guard grants.keys.contains(where: { sharedTab($0).map { permits($0, capability: .control) } ?? false }),
            let url = permittedDestination(raw)
        else { return failure("Opening a tab requires control access and an allowed HTTP(S) URL.") }
        let viaDefault = followsWebsiteDefault(at: url)
        let approved = viaDefault ? true : await openConsent(clientName, url)
        guard approved, isConnected, available(), !Task.isCancelled else {
            return failure("Opening the page was not approved.")
        }
        guard browser.sitePermissions.assistantRecord(for: SitePermissions.origin(for: url)) != .deny else {
            return failure("Assistant access is off for this website.")
        }
        let tab = browser.newTab(url: url, transition: .agent)
        grants[tab.id] = Grant(origin: SitePermissions.origin(for: url), access: .control, source: viaDefault ? .appDefault : .sheet)
        return success("Opened tab \(tab.id.uuidString). Use readPage after it loads.")
    }

    private func permittedDestination(_ raw: String, grant: Grant? = nil) -> URL? {
        guard let url = webDestination(raw) else { return nil }
        if let grant, followsDeveloperSites(grant, to: url) {
            return url
        }
        guard !hasReadContent || destinations.contains(destinationKey(url)) else { return nil }
        return url
    }

    private func webDestination(_ raw: String) -> URL? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
            url.host() != nil, url.user == nil, url.password == nil
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
            !tab.isPrivate, !tab.isClosed, let url = webURL(of: tab)
        else { return nil }
        let origin = SitePermissions.origin(for: url)
        if origin != grant.origin {
            // A page-initiated move between developer sites keeps the grant; any other move ends it. A standing grant that
            // no longer holds is dropped: the app asks again, and gets it back only where it applies.
            guard followsDeveloperSites(grant, to: url) else {
                dropIfConditional(id)
                return nil
            }
            grants[id] = Grant(origin: origin, access: grant.access, source: grant.source)
        }
        guard let current = grants[id], effectiveAccess(of: current, at: url) != nil else {
            dropIfConditional(id)
            return nil
        }
        tab.assistantAccess.pageChanged(url: url)
        return tab.assistantAccess.explicitPolicy == .deny ? nil : tab
    }

    // MARK: Standing grants and the Developer tier

    /// This connection's paired client as the trust store holds it now: nil when unpaired, revoked, or the store cannot be
    /// read. A snapshot taken at connection time is never trusted.
    var livePairedClient: PairedClient? {
        guard trust.isAvailable else { return nil }
        return pairedClient.flatMap { trust.client(id: $0.id) }
    }

    /// Whether the Developer tier can apply at `url`: a paired client, a developer site and a window of the Developer profile.
    /// Private windows are never bound to a connection, and private browsing can never be the Developer profile.
    func developerTierHolds(at url: URL) -> Bool {
        livePairedClient != nil
            && MCPDeveloperAccess.isDeveloperSite(url, trust: trust)
            && MCPDeveloperAccess.isDeveloperProfile(browser.context, trust: trust)
    }

    /// What the paired client may do at `url` without asking: nil unless the Developer tier holds there and its standing
    /// level is above Off and not paused.
    func standingAccess(at url: URL) -> MCPAccessConsent.Access? {
        developerTierHolds(at: url) ? MCPDeveloperAccess.standingAccess(for: pairedClient, trust: trust) : nil
    }

    /// What `grant` allows at `url` now. A Developer grant that stops qualifying falls back to Development; a standing
    /// grant that stops holding (paused, lowered, the site or profile changed) is nil.
    func effectiveAccess(of grant: Grant, at url: URL) -> MCPAccessConsent.Access? {
        switch grant.source {
        case .sheet:
            guard grant.access == .developer else { return grant.access }
            return developerTierHolds(at: url) ? .developer : .development
        case .standing:
            guard let standing = standingAccess(at: url) else { return nil }
            return grant.access.rank <= standing.rank ? grant.access : standing
        case .appDefault:
            return followsWebsiteDefault(at: url) ? grant.access : nil
        }
    }

    // MARK: The Website access default

    /// Whether this paired app opens `url` under the owner's Website access default. Read from the trust store and the
    /// window's profile now, never from a snapshot: turning it off, pausing the app, or lowering the default ends it.
    func followsWebsiteDefault(at url: URL) -> Bool {
        MCPDefaultAccess.opens(url, client: livePairedClient, in: browser, trust: trust)
    }

    /// A page reached under the default asks before the app controls it when it shows a password or payment field, as it
    /// does for the assistant. Allowing it is the user's answer for this website and connection: the grant then stands like
    /// one from the Open and Share sheet. Nil means the call may go on.
    func sensitivePageRefusal(_ tab: BrowserTab, view: BrowserPage, url: URL) async -> CallTool.Result? {
        guard let grant = grants[tab.id], grant.source == .appDefault, await sensitivePageProbe(view) else { return nil }
        let stillHolds = { [self] in
            isConnected && available() && !Task.isCancelled && webURL(of: tab) == url && grants[tab.id]?.source == .appDefault
        }
        guard stillHolds() else { return failure("Page access changed. Read the page again.") }
        guard await sensitiveConsent(clientName, url), stillHolds() else { return failure("Using this page was not approved.") }
        grants[tab.id] = Grant(origin: grant.origin, access: grant.access)
        return nil
    }

    /// Developer-class grants (standing, or Developer from the sheet) move between developer sites without a sheet and
    /// without the observed-link rule. Anything else, including a move to a site off the list, ends or re-asks.
    func followsDeveloperSites(_ grant: Grant, to url: URL) -> Bool {
        (grant.source == .standing || grant.access == .developer) && developerTierHolds(at: url)
    }

    /// A grant carried to a site the user approved in the Open and Share sheet. That sheet promises control only, so a
    /// standing grant does not bring its Development level along.
    private func moved(_ grant: Grant, to origin: String) -> Grant {
        let access = grant.source == .standing && grant.access.rank > MCPAccessConsent.Access.control.rank ? .control : grant.access
        return Grant(origin: origin, access: access)
    }

    /// Drops a grant that depends on a setting (standing, or from the default), never one the user gave in a sheet.
    private func dropIfConditional(_ id: UUID) {
        guard let source = grants[id]?.source, source != .sheet else { return }
        grants[id] = nil
        observations[id] = nil
    }

    /// Drops standing and default grants that no longer hold and releases the leases they carried. Runs when the trust store
    /// changes.
    func refreshStanding() {
        for (id, grant) in grants where grant.source != .sheet {
            let holds = browser.tabs.first { $0.id == id }.flatMap(webURL(of:)).map { effectiveAccess(of: grant, at: $0) != nil }
            if holds != true {
                grants[id] = nil
                observations[id] = nil
            }
        }
        releaseUnauthorizedDevelopment()
    }

    /// The Developer tier's answer to a consequential-action confirmation: let it through on a developer site while this
    /// connection holds Developer on the tab, and note it. Everywhere else the confirmation stays. Signing in or giving
    /// another website access to the account always asks: the tier covers purchases, transfers, deletions, and posting.
    func developerApproval(for tab: BrowserTab) -> AgentActionConsent.DeveloperApproval {
        .init { [weak self, weak tab] label, category, host in
            guard category != .accountAccess, let self, let tab, self.permits(tab, capability: .developer) else { return false }
            self.developerApprovals.append(self.approvalRecord(label: label, category: category, host: host))
            self.developerApprovals.removeFirst(max(0, self.developerApprovals.count - 100))
            Pipeline.log.notice("mcp: developer access let a \(category.rawValue, privacy: .public) action through without asking")
            return true
        }
    }
}
