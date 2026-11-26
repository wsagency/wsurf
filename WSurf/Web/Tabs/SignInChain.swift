// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

/// The HTTP(S) main-frame origins a tab passed through on its way to a WebKit-only sign-in provider, such as
/// `app.example` -> `sso.example` -> `accounts.google.com`, and the engine that served each. Those sites keep the flow's state
/// (a CSRF cookie, the SSO session) in that engine, and the provider's callback must find it.
/// Bounded and short-lived: only the last `limit` distinct origins visited within `lifetime` of the provider hop count, and a
/// navigation the person starts begins it again.
nonisolated struct SignInChain: Sendable {
    static let limit = 6
    static let lifetime: TimeInterval = 120

    private var visits: [(origin: String, engine: BrowserEngine, at: Date)] = []

    var isEmpty: Bool {
        visits.isEmpty
    }

    /// `origin` becomes the latest visit, served by `engine`. Non-web addresses and the providers themselves are not kept.
    mutating func note(_ origin: String, engine: BrowserEngine, now: Date = Date()) {
        guard !origin.isEmpty, !SitePermissions.webKitOnlyOrigins.contains(origin) else { return }
        visits.removeAll { $0.origin == origin }
        visits.append((origin, engine, now))
        if visits.count > Self.limit {
            visits.removeFirst(visits.count - Self.limit)
        }
    }

    /// The sites a hop to the provider at `url` belongs to: the recent chain plus the HTTP(S) origin of its `redirect_uri`,
    /// without any WebKit-only provider. With `engine`, only the visits that engine actually served: the page chooses
    /// `redirect_uri`, so it may keep the sign-in going but never names a site whose cookies move.
    func origins(leadingTo url: URL, servedBy engine: BrowserEngine? = nil, now: Date = Date()) -> Set<String> {
        let recent = visits.filter { now.timeIntervalSince($0.at) <= Self.lifetime }
        var result = Set(recent.filter { engine == nil || $0.engine == engine }.map(\.origin))
        if engine == nil, let callback = Self.redirectOrigin(in: url) {
            result.insert(callback)
        }
        return result.subtracting(SitePermissions.webKitOnlyOrigins)
    }

    /// The HTTP(S) origin of an OAuth `redirect_uri` query parameter, such as `https://auth.example` for
    /// `redirect_uri=https%3A%2F%2Fauth.example%2Fcallback`. Nil when absent or not a web address.
    static func redirectOrigin(in url: URL) -> String? {
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "redirect_uri" }?.value
        let origin = SitePermissions.webOrigin(for: value.flatMap(URL.init(string:)))
        return origin.isEmpty ? nil : origin
    }
}
