// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

extension URL {
    var displayHost: String? {
        guard let host = host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var displayAddress: String? {
        guard let host = displayHost else { return nil }
        let path = path().removingPercentEncoding ?? path()
        guard path != "/", !path.isEmpty else { return host }
        return host + (path.hasSuffix("/") ? String(path.dropLast()) : path)
    }
}

/// A page address as the address bar draws it, rebuilt from the parsed URL so the page cannot choose what it looks like:
/// sign-in details are dropped (`https://bank.com@evil.com` reads as evil.com), the website name is always ASCII
/// (punycode for any non-ASCII name, so no look-alike letter is drawn), and the rest is percent-encoded. An address that
/// does not parse, or whose host is not a plain name, gives nil: the bar shows its placeholder, never the raw text.
nonisolated struct AddressText: Equatable {
    /// `https://`, `file://` or `about:`.
    let scheme: String
    let host: String
    /// Port, path, query and fragment, percent-encoded so no invisible or reordering character is drawn. The bar
    /// shortens this part, never the host.
    let rest: String

    init(scheme: String, host: String, rest: String) {
        self.scheme = scheme
        self.host = host
        self.rest = rest
    }

    init?(_ url: URL?) {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = parts.scheme else {
            return nil
        }
        let host = parts.encodedHost ?? ""
        guard host.unicodeScalars.allSatisfy({ Self.hostCharacters.contains($0) }) else { return nil }
        self.scheme = scheme + (parts.host == nil ? ":" : "://")
        self.host = host
        var rest = parts.port.map { ":\($0)" } ?? ""
        rest += parts.percentEncodedPath
        if let query = parts.percentEncodedQuery {
            rest += "?" + query
        }
        if let fragment = parts.percentEncodedFragment {
            rest += "#" + fragment
        }
        self.rest = Self.visible(rest)
    }

    var text: String {
        scheme + host + rest
    }

    /// The website name without “www.”, or for an address without a host (`about:blank`, a file) the whole of it.
    var name: String {
        guard !host.isEmpty else { return text }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A punycode name, an IPv4 address or a bracketed IPv6 address. Anything else (a percent escape, a space) fails.
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_[]:")

    /// Percent-encodes anything outside printable ASCII that a parser left in place.
    private static func visible(_ text: String) -> String {
        var drawn = ""
        for scalar in text.unicodeScalars {
            if scalar.isASCII, scalar.value > 0x20, scalar.value < 0x7F {
                drawn.unicodeScalars.append(scalar)
            } else {
                drawn += String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            }
        }
        return drawn
    }
}
