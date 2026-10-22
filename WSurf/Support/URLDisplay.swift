// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

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

/// A page address as the address bar draws it, rebuilt from `URLComponents` so the page cannot choose what it looks
/// like: sign-in details are dropped (`https://bank.com@evil.com` reads as evil.com) and a website name that mixes
/// scripts, uses look-alike letters or characters this check does not know is shown as punycode.
nonisolated struct AddressText: Equatable {
    /// `https://`, `file://` or `about:`.
    let scheme: String
    let host: String
    /// Port, path, query and fragment, still percent-encoded so no invisible or reordering character is drawn. The bar
    /// shortens this part, never the host.
    let rest: String

    init(scheme: String, host: String, rest: String) {
        self.scheme = scheme
        self.host = host
        self.rest = rest
    }

    init?(_ value: String) {
        guard let parts = URLComponents(string: value), let scheme = parts.scheme else { return nil }
        let host = Self.host(of: parts)
        self.scheme = scheme + (parts.host == nil ? ":" : "://")
        self.host = host ?? ""
        var rest = parts.port.map { ":\($0)" } ?? ""
        rest += parts.percentEncodedPath
        if let query = parts.percentEncodedQuery {
            rest += "?" + query
        }
        if let fragment = parts.percentEncodedFragment {
            rest += "#" + fragment
        }
        self.rest = rest
    }

    var text: String {
        scheme + host + rest
    }

    /// The website name: Unicode when every label keeps to one script without look-alikes, else its punycode.
    static func host(of parts: URLComponents) -> String? {
        guard let unicode = parts.host else { return nil }
        guard unicode.unicodeScalars.contains(where: { !$0.isASCII }) else { return unicode }
        let readable = unicode.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { isReadable($0) }
        return readable ? unicode : parts.encodedHost ?? parts.percentEncodedHost
    }

    /// One script per label; in Latin no look-alike letter at all, in another script not only look-alikes.
    /// ponytail: block ranges, not the Unicode script property or UTS #39; an unlisted script falls back to punycode.
    private static func isReadable(_ label: Substring) -> Bool {
        var scripts = Set<Script>()
        var letters = 0
        var lookAlikes = 0
        for scalar in label.lowercased().unicodeScalars where scalar != "-" && !("0"..."9").contains(scalar) {
            guard let script = Script(scalar) else { return false }
            scripts.insert(script)
            letters += 1
            if PageDialogText.confusables[scalar] != nil {
                lookAlikes += 1
            }
        }
        guard let script = scripts.first, scripts.count == 1 else { return scripts.isEmpty }
        return script == .latin ? lookAlikes == 0 : lookAlikes < letters
    }

    private nonisolated enum Script {
        case latin, greek, cyrillic, armenian, hebrew, arabic, devanagari, thai, hangul, cjk

        init?(_ scalar: Unicode.Scalar) {
            switch scalar.value {
            case 0x61...0x7A, 0xDF...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF:
                self = .latin
            case 0x370...0x3FF, 0x1F00...0x1FFF:
                self = .greek
            case 0x400...0x52F:
                self = .cyrillic
            case 0x531...0x58F:
                self = .armenian
            case 0x5D0...0x5FF:
                self = .hebrew
            case 0x620...0x6FF, 0x750...0x77F:
                self = .arabic
            case 0x900...0x97F:
                self = .devanagari
            case 0xE00...0xE7F:
                self = .thai
            case 0x1100...0x11FF, 0xAC00...0xD7AF:
                self = .hangul
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF:
                self = .cjk
            default:
                return nil
            }
        }
    }
}
