// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WebKit
import WSurfVault

/// One cookie as Website Settings shows it. Its value is for the inspector and Copy Value only: `description` leaves it out, so
/// a cookie that reaches a log or an error message never carries it.
nonisolated struct SiteCookie: Identifiable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let name: String
    let value: String
    /// As the engine keeps it: a leading dot for a domain cookie, none for a host-only cookie.
    let domain: String
    let path: String
    /// Nil for a session cookie.
    let expiresDate: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let sameSite: String?
    let engine: BrowserEngine
    /// The top-level site of a partitioned (CHIPS) Chromium cookie.
    let partitionKey: String?
    /// Chromium's `hasCrossSiteAncestor` of the partition key, when DevTools gave the key as an object; nil when it gave a string.
    let partitionCrossSite: Bool?

    init(
        name: String, value: String, domain: String, path: String, expiresDate: Date?, isSecure: Bool, isHTTPOnly: Bool,
        sameSite: String?, engine: BrowserEngine, partitionKey: String? = nil, partitionCrossSite: Bool? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresDate = expiresDate
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
        self.engine = engine
        self.partitionKey = partitionKey
        self.partitionCrossSite = partitionCrossSite
    }

    var id: String {
        "\(engine.rawValue)|\(domain)|\(path)|\(name)|\(partitionKey ?? "")"
    }

    var description: String {
        "SiteCookie(\(engine.rawValue) \(name) \(domain)\(path))"
    }

    var debugDescription: String {
        description
    }

    /// The domain without the leading dot of a domain cookie, as the list shows it.
    var displayDomain: String {
        domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
    }
}

@MainActor
enum SiteCookies {
    /// What a listing found. The WebKit cookies are listed whatever Chromium answers.
    struct Listing {
        var cookies: [SiteCookie] = []
        /// Chromium may hold cookies for the profile but could not be asked (out of process with no tab open, or it failed).
        var chromiumUnavailable = false
        /// Chromium may hold cookies for the profile but is not running, and the listing was not allowed to start it.
        var chromiumNotLoaded = false
    }

    /// How Chromium's cookies of a profile can be reached.
    enum ChromiumAccess: Equatable {
        /// Chromium holds nothing for the profile.
        case none
        /// An open tab, or a hidden page (Chromium is running, or may be started).
        case available
        /// Chromium holds data but is not running, and may not be started for this.
        case notLoaded
        /// Chromium holds data, but only a tab could reach it: it runs in its service and none is open.
        case unreachable
    }

    /// The decision alone, on its inputs. Starting Chromium blocks the main thread while CEF loads, so a list that opens with a
    /// panel never does it; an explicit Load or Delete does.
    nonisolated static func chromiumAccess(
        hasLivePage: Bool, mayHoldCookies: Bool, isOutOfProcess: Bool, hasStarted: Bool, allowStartup: Bool
    ) -> ChromiumAccess {
        if hasLivePage {
            return .available
        }
        guard mayHoldCookies else { return .none }
        if isOutOfProcess {
            return .unreachable
        }
        return hasStarted || allowStartup ? .available : .notLoaded
    }

    // MARK: Matching

    /// The host a page's cookies are compared with: lowercase, no trailing dot, an IPv6 address without brackets. Nil without one.
    nonisolated static func host(of url: URL) -> String? {
        url.host().flatMap(canonicalHost)
    }

    nonisolated static func canonicalHost(_ text: String) -> String? {
        var name = text.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("["), name.hasSuffix("]") {
            name = String(name.dropFirst().dropLast())
        }
        return MCPDeveloperAccess.canonicalHost(name)
    }

    /// Whether a cookie of `domain` is sent to `host` (RFC 6265 §5.1.3). A host-only cookie (no leading dot) applies to its own host
    /// only. A domain cookie (`.example.com`) applies to that domain and every name under it, unless the domain is an IP address or a
    /// public suffix (`.com`, `.co.uk`), which no browser lets a site set. `notexample.com` never matches `example.com`.
    nonisolated static func applies(domain: String, to host: String) -> Bool {
        guard let host = canonicalHost(host) else { return false }
        var name = domain.trimmingCharacters(in: .whitespaces)
        let isDomainCookie = name.hasPrefix(".")
        if isDomainCookie {
            name.removeFirst()
        }
        guard let cookieDomain = canonicalHost(name) else { return false }
        if cookieDomain == host {
            return true
        }
        guard isDomainCookie, !isAddress(cookieDomain), !isAddress(host), host.hasSuffix("." + cookieDomain) else { return false }
        return RelyingPartyPolicy.registrableDomain(of: cookieDomain) != nil
    }

    nonisolated private static func isAddress(_ host: String) -> Bool {
        host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
    }

    // MARK: Listing

    /// Every cookie of either engine that applies to `host` in this profile. Chromium is asked only when it may hold some
    /// (`ChromiumRuntime.mayHoldCookies`), and started only when `allowChromiumStartup`.
    static func list(host: String, context: BrowserProfileContext, allowChromiumStartup: Bool = false) async -> Listing {
        var listing = Listing()
        listing.cookies = await webKitCookies(context: context).filter { applies(domain: $0.domain, to: host) }
        switch chromiumAccess(context, allowStartup: allowChromiumStartup) {
        case .available:
            do {
                listing.cookies += try await withChromium(context: context) { page in
                    try await chromiumCookies(page).filter { applies(domain: $0.domain, to: host) }
                } ?? []
            } catch {
                listing.chromiumUnavailable = true
            }
        case .notLoaded:
            listing.chromiumNotLoaded = true
        case .unreachable:
            listing.chromiumUnavailable = true
        case .none:
            break
        }
        listing.cookies.sort { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.engine.rawValue < rhs.engine.rawValue : order == .orderedAscending
        }
        return listing
    }

    /// Removes one cookie from its own engine.
    static func delete(_ cookie: SiteCookie, context: BrowserProfileContext) async throws {
        switch cookie.engine {
        case .webKit:
            let store = context.dataStore.httpCookieStore
            for stored in await store.allCookies() where same(stored, as: cookie) {
                await store.deleteCookie(stored)
            }
        case .chromium:
            try requireReachable(context)
            _ = try await withChromium(context: context) { page in
                try await deleteChromium([cookie], on: page)
            }
            flush(context)
        }
    }

    /// Removes every cookie of either engine that applies to `host`, starting Chromium if it holds data, then the host's cached
    /// favicon. Returns how many cookies went. When Chromium cannot be reached or fails, the WebKit cookies and the favicon are
    /// still cleared and the error is thrown, so the person is not told Chromium's cookies went.
    @discardableResult
    static func deleteAll(host: String, context: BrowserProfileContext) async throws -> Int {
        defer { context.forgetFavicon(host: host) }
        var removed = 0
        let store = context.dataStore.httpCookieStore
        for cookie in await store.allCookies() where applies(domain: cookie.domain, to: host) {
            await store.deleteCookie(cookie)
            removed += 1
        }
        try requireReachable(context)
        defer { flush(context) }
        removed += try await withChromium(context: context) { page in
            let matching = try await chromiumCookies(page).filter { applies(domain: $0.domain, to: host) }
            try await deleteChromium(matching, on: page)
            return matching.count
        } ?? 0
        return removed
    }

    // MARK: WebKit

    private static func webKitCookies(context: BrowserProfileContext) async -> [SiteCookie] {
        await context.dataStore.httpCookieStore.allCookies().map {
            SiteCookie(
                name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expiresDate: $0.expiresDate,
                isSecure: $0.isSecure, isHTTPOnly: $0.isHTTPOnly, sameSite: $0.sameSitePolicy?.rawValue.capitalized,
                engine: .webKit
            )
        }
    }

    private static func same(_ stored: HTTPCookie, as cookie: SiteCookie) -> Bool {
        stored.name == cookie.name && stored.domain == cookie.domain && stored.path == cookie.path
    }

    // MARK: Chromium

    private static func livePage(_ context: BrowserProfileContext) -> ChromiumPage? {
        ChromiumRuntime.shared.livePages.first {
            $0.context.contextID == context.contextID && ($0.raw != nil || $0.remote != nil)
        }
    }

    static func chromiumAccess(_ context: BrowserProfileContext, allowStartup: Bool) -> ChromiumAccess {
        guard !context.privateSessionEnded else { return .none }
        let runtime = ChromiumRuntime.shared
        return chromiumAccess(
            hasLivePage: livePage(context) != nil, mayHoldCookies: runtime.mayHoldCookies(for: context),
            isOutOfProcess: ChromiumOOP.latch.mode == .outOfProcess, hasStarted: runtime.hasStartedChromium,
            allowStartup: allowStartup
        )
    }

    /// Throws when Chromium holds data for the profile that no page can reach, so a deletion does not claim it removed it.
    private static func requireReachable(_ context: BrowserProfileContext) throws {
        guard chromiumAccess(context, allowStartup: true) == .unreachable else { return }
        throw ChromiumError.unavailable(
            String(localized: "Chromium cookies couldn’t be reached. Open this website in a Chromium tab and try again.")
        )
    }

    /// Runs `body` on a page of this profile's Chromium: an open tab's page when there is one, else a hidden page, which starts
    /// Chromium if it is not running. Nil when Chromium holds nothing for the profile or cannot be reached. Callers that must not
    /// start Chromium check `chromiumAccess` first.
    private static func withChromium<T>(
        context: BrowserProfileContext, _ body: (ChromiumPage) async throws -> T
    ) async throws -> T? {
        if let page = livePage(context) {
            return try await body(page)
        }
        guard chromiumAccess(context, allowStartup: true) == .available else { return nil }
        return try await ChromiumRuntime.shared.withHiddenPage(context: context, body)
    }

    private static func chromiumCookies(_ page: ChromiumPage) async throws -> [SiteCookie] {
        let answer = try await page.command("Network.getAllCookies")
        return ((answer["cookies"] as? [[String: Any]]) ?? []).compactMap(chromiumCookie)
    }

    /// One cookie of DevTools' `Network.Cookie`. `expires` is seconds since 1970, -1 for a session cookie.
    nonisolated static func chromiumCookie(_ object: [String: Any]) -> SiteCookie? {
        guard let name = object["name"] as? String, let domain = object["domain"] as? String else { return nil }
        let expires = (object["expires"] as? NSNumber)?.doubleValue ?? -1
        let isSession = (object["session"] as? Bool) ?? (expires <= 0)
        var partition: String?
        var crossSite: Bool?
        if let key = object["partitionKey"] as? [String: Any] {
            partition = key["topLevelSite"] as? String
            crossSite = key["hasCrossSiteAncestor"] as? Bool
        } else {
            partition = object["partitionKey"] as? String
        }
        return SiteCookie(
            name: name, value: object["value"] as? String ?? "", domain: domain, path: object["path"] as? String ?? "/",
            expiresDate: isSession ? nil : Date(timeIntervalSince1970: expires),
            isSecure: object["secure"] as? Bool ?? false, isHTTPOnly: object["httpOnly"] as? Bool ?? false,
            sameSite: object["sameSite"] as? String, engine: .chromium,
            partitionKey: partition?.isEmpty == false ? partition : nil, partitionCrossSite: crossSite
        )
    }

    /// The `Network.deleteCookies` parameters that name exactly `cookie`: its name, domain as Chromium keeps it, path, and the
    /// partition of a partitioned cookie.
    nonisolated static func deleteParameters(for cookie: SiteCookie) -> [String: Any] {
        var params: [String: Any] = ["name": cookie.name, "domain": cookie.domain, "path": cookie.path]
        if let key = cookie.partitionKey {
            if let crossSite = cookie.partitionCrossSite {
                params["partitionKey"] = ["topLevelSite": key, "hasCrossSiteAncestor": crossSite]
            } else {
                params["partitionKey"] = key
            }
        }
        return params
    }

    private static func deleteChromium(_ cookies: [SiteCookie], on page: ChromiumPage) async throws {
        for cookie in cookies {
            _ = try await page.command("Network.deleteCookies", params: deleteParameters(for: cookie))
        }
    }

    /// Writes the profile's Chromium cookie store now, so a removal lasts through a crash; a hidden page's close writes it too.
    private static func flush(_ context: BrowserProfileContext) {
        ChromiumRuntime.shared.flushCookieStore(contextID: context.contextID)
    }
}

extension BrowserProfileContext {
    /// Forgets the cached favicon of `host` in both appearances and clears it from the open tabs on that host, which load it again.
    /// A tab's icon is filed under its page's host as written, so a host with a trailing dot is forgotten in both forms.
    func forgetFavicon(host: String) {
        guard let host = SiteCookies.canonicalHost(host) else { return }
        favicons.forget(host: host)
        favicons.forget(host: host + ".")
        for tab in allTabs where URL(string: tab.urlString).flatMap({ SiteCookies.host(of: $0) }) == host {
            tab.favicon = nil
            tab.refreshFavicon()
        }
    }
}
