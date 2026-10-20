// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

/// Blocking an extension on a website: the website's match pattern is denied in the extension's context, which overrides any
/// grant, including `<all_urls>`. Blocks are kept per profile and per extension in `profiles.json`; a private window keeps
/// them in memory for its session. Extensions run only in WebKit tabs, so a Chromium tab has nothing to enforce.
extension ExtensionManager {
    /// The website a page belongs to for blocking: its host, lower case, without one leading `www.`. HTTP(S) only.
    nonisolated static func website(of url: URL?) -> String? {
        guard let url, url.scheme == "https" || url.scheme == "http",
              var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    /// The pattern that covers a website and every subdomain of it.
    nonisolated static func websitePattern(for host: String) -> WKWebExtension.MatchPattern? {
        let literal = host.contains(":") ? "[\(host)]" : host
        return try? WKWebExtension.MatchPattern(string: "*://*.\(literal)/*")
    }

    /// A block on `blocked` covers that host and its subdomains, on a dot boundary: not `notexample.com` for `example.com`.
    nonisolated static func website(_ host: String, isCoveredBy blocked: String) -> Bool {
        host == blocked || host.hasSuffix("." + blocked)
    }

    func blockedHosts(id: String) -> [String] {
        profile?.isPrivate == true ? sessionBlockedHosts[id] ?? [] : library.blockedHosts(for: id)
    }

    func blockingHost(id: String, for host: String) -> String? {
        blockedHosts(id: id).first { Self.website(host, isCoveredBy: $0) }
    }

    func isBlocked(id: String, on url: URL?) -> Bool {
        Self.website(of: url).map { blockingHost(id: id, for: $0) != nil } ?? false
    }

    func requestsAccess(id: String, to url: URL) -> Bool {
        contexts[id]?.webExtension.allRequestedMatchPatterns.contains { $0.matches(url) } == true
    }

    /// Denies every blocked website in `context`. Runs when the extension loads, after an unblock re-grants what it asked for,
    /// and after any runtime grant, so nothing granted later can lift a block.
    func applyBlocks(to context: WKWebExtensionContext, id: String) {
        for host in blockedHosts(id: id) {
            if let pattern = Self.websitePattern(for: host) {
                context.setPermissionStatus(.deniedExplicitly, for: pattern)
            }
        }
    }

    /// The tab an action runs for. Running an action for a tab grants activeTab on its page, so a blocked website gets none.
    func actionTab(_ tab: ExtensionTabAdapter?, id: String) -> ExtensionTabAdapter? {
        isBlocked(id: id, on: tab?.tab.flatMap { URL(string: $0.urlString) }) ? nil : tab
    }

    /// Re-applies the blocks after the controller recorded a runtime grant.
    func reapplyBlocks(id: String) {
        guard let context = contexts[id] else { return }
        applyBlocks(to: context, id: id)
    }

    /// Drops runtime grants on blocked websites before they are recorded. A broader pattern such as `<all_urls>` passes:
    /// the deny on the blocked website still wins over it.
    func withoutBlockedWebsites(_ urls: Set<URL>, id: String) -> Set<URL> {
        urls.filter { !isBlocked(id: id, on: $0) }
    }

    func withoutBlockedWebsites(_ patterns: Set<WKWebExtension.MatchPattern>, id: String) -> Set<WKWebExtension.MatchPattern> {
        patterns.filter { pattern in
            guard let host = pattern.host, !pattern.matchesAllHosts else { return true }
            let bare = host.hasPrefix("*.") ? String(host.dropFirst(2)) : host
            return blockingHost(id: id, for: bare.lowercased()) == nil
        }
    }

    /// Blocks or allows the extension on `host` and its subdomains, then reloads the WebKit tabs on that website in every window
    /// of this profile, so a content script that already ran is gone or comes back.
    func setAllowed(_ allowed: Bool, on host: String, id: String) {
        var host = host.lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        guard !host.isEmpty else { return }
        if profile?.isPrivate == true {
            var hosts = sessionBlockedHosts[id] ?? []
            hosts.removeAll { $0 == host }
            if !allowed {
                hosts.append(host)
                hosts.sort()
            }
            sessionBlockedHosts[id] = hosts.isEmpty ? nil : hosts
        } else {
            library.setBlocked(!allowed, host: host, id: id)
        }
        if let context = contexts[id], let pattern = Self.websitePattern(for: host) {
            if allowed {
                context.setPermissionStatus(.unknown, for: pattern)
                for requested in context.webExtension.allRequestedMatchPatterns {
                    context.setPermissionStatus(.grantedExplicitly, for: requested)
                }
                // The re-grant may have covered another block; deny those again.
                applyBlocks(to: context, id: id)
            } else {
                context.setPermissionStatus(.deniedExplicitly, for: pattern)
            }
        }
        for tab in windowAdapters.compactMap(\.browser).flatMap(\.tabs)
        where tab.engine == .webKit && tab.isMaterialised {
            guard let website = Self.website(of: URL(string: tab.urlString)), Self.website(website, isCoveredBy: host) else { continue }
            tab.reload()
        }
    }
}
