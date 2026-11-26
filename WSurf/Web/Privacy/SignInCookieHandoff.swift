// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import os
import WebKit

/// Copies a sign-in flow's own cookies from a profile's Chromium store to its WebKit store when a Chromium tab moves to WebKit for a
/// WebKit-only provider (`SitePermissions.webKitOnlyOrigins`). The sites that started the flow (an app's CSRF cookie, an SSO
/// session) set them in Chromium, and the provider's callback arrives in WebKit, which would otherwise reject it.
/// Only cookies of the flow's own origins move, never the provider's (WebKit owns that session), never a partitioned cookie
/// (WebKit has no partition to keep it in), and only within one profile: the Chromium page must belong to the tab's own context.
@MainActor
enum SignInCookieHandoff {
    private static let log = Logger(subsystem: "io.wsagency.wsurf", category: "signin-handoff")

    /// The cookies of `cookies` that a page of one of `origins` receives, without those of a WebKit-only site.
    nonisolated static func cookies(_ cookies: [SiteCookie], for origins: Set<String>) -> [SiteCookie] {
        let hosts = origins.filter { !SitePermissions.webKitOnlySites.contains(SitePermissions.site(for: $0)) }
            .compactMap { URL(string: $0).flatMap(SiteCookies.host(of:)) }
        let providers = SitePermissions.webKitOnlyOrigins.compactMap { URL(string: $0).flatMap(SiteCookies.host(of:)) }
        return cookies.filter { cookie in
            cookie.partitionKey == nil
                && hosts.contains { SiteCookies.applies(domain: cookie.domain, to: $0) }
                && !providers.contains { SiteCookies.applies(domain: cookie.domain, to: $0) }
        }
    }

    /// `cookie` as WebKit stores it, with every attribute it had in Chromium. A host-only cookie keeps its bare domain (which is what
    /// keeps a `__Host-` cookie valid), a session cookie gets no expiry. An unspecified SameSite stays unspecified, as WebKit would
    /// have stored it had the site set it there.
    nonisolated static func httpCookie(_ cookie: SiteCookie) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path,
        ]
        if let expires = cookie.expiresDate {
            properties[.expires] = expires
        }
        if cookie.isSecure {
            properties[.secure] = "TRUE"
        }
        if cookie.isHTTPOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        switch cookie.sameSite?.lowercased() {
        case "lax":
            properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
        case "strict":
            properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
        default:
            break
        }
        return HTTPCookie(properties: properties)
    }

    /// Copies the Chromium cookies of `origins` into `store`. Reads `page` when it is a live page of `context`, else any live
    /// Chromium page of `context`; it never starts Chromium. Returns how many cookies were copied: none when Chromium cannot be
    /// read, the private session ended, or the task was cancelled (an abandoned navigation writes nothing).
    static func copy(
        origins: Set<String>, context: BrowserProfileContext, preferring page: ChromiumPage?, into store: WKHTTPCookieStore
    ) async -> Int {
        guard !origins.isEmpty, !context.privateSessionEnded else { return 0 }
        let source = page.flatMap { $0.context.contextID == context.contextID && !$0.isClosed && ($0.raw != nil || $0.remote != nil) ? $0 : nil }
            ?? SiteCookies.livePage(context)
        guard let source else { return 0 }
        let all: [SiteCookie]
        do {
            all = try await SiteCookies.chromiumCookies(source)
        } catch {
            log.error("Could not read Chromium cookies for a sign-in: \(error.localizedDescription, privacy: .public)")
            return 0
        }
        var copied = 0
        for cookie in cookies(all, for: origins).compactMap(httpCookie) {
            guard !Task.isCancelled, !context.privateSessionEnded else { break }
            await store.setCookie(cookie)
            copied += 1
        }
        return copied
    }
}
