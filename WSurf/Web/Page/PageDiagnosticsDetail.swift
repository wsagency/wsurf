// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Opt-in detail for a development capture: request and response headers, text bodies, full console and clear query values.
///
/// Everything here is off unless the client asked for it when it started the capture, and it applies only in the Developer tier
/// and only to a request whose own URL is a developer site (`DetailPolicy`). A request that leaves the developer sites, by
/// redirect or because the page called another host, is recorded as before and carries nothing of this.
///
/// What is never shown, whatever was asked for:
/// - A header named `Authorization`, `Proxy-Authorization`, `Cookie`, `Set-Cookie` or like a token, secret, key, session,
///   password or CSRF header, and any header whose value looks generated (the entropy rule of `looksGenerated`). Only the
///   name stays, with `Redaction.hidden` where the value was. Values are hidden when a header is read, so a cookie or token
///   never sits in a record, not even before it is returned.
/// - A form field, JSON key or `name=value` / `name: value` pair in a text body whose name means a password, token, secret,
///   one-time code, card or the like (`Redaction.isHiddenKey`), at any depth.
/// - A value the connection typed as a secret (`MCPSecretScrubber`), removed from the whole text before it is cut to its
///   limit, so a secret that straddles the limit leaves no fragment.
///
/// Bodies are text only (JSON, form, XML, plain text, GraphQL); anything else is summarized by type and size. Each body is
/// cut to `Redaction.maxBodyBytes`, and the capture as a whole keeps `Redaction.captureBodyBytes` of them.
nonisolated extension PageDiagnostics {
    struct DetailOptions: Equatable, Sendable {
        var headers = false
        var bodies = false
        /// Object previews and stacks for every console call.
        var console = false
        /// Show query values of requests to developer sites instead of tags.
        var clearQueries = false

        var isEnabled: Bool {
            headers || bodies || console || clearQueries
        }

        /// Whether a network record carries anything but metadata.
        var network: Bool {
            headers || bodies
        }
    }

    /// Whether detail may be recorded right now. Rebuilt for every event, so a tier that ended is never used again.
    struct DetailPolicy: Sendable {
        var options = DetailOptions()
        /// The Developer tier holds for the tab's page at this moment.
        var tier = false
        /// Where the WebKit hook may read a request in the page, as a coarse filter: hosts that count on any port, and sites that count
        /// on one. `isDeveloperSite` is the authority and decides again natively.
        var anyPortHosts: [String] = []
        var sites: [HostPort] = []
        var isDeveloperSite: @Sendable (URL) -> Bool = { _ in false }

        static let off = DetailPolicy()

        /// Whether `raw` is a developer site while the tier holds.
        func covers(_ raw: String) -> Bool {
            guard tier, let url = URL(string: raw) else { return false }
            return isDeveloperSite(url)
        }

        /// Whether a network record for `raw` may carry headers or bodies.
        func network(_ raw: String?) -> Bool {
            guard options.network, let raw else { return false }
            return covers(raw)
        }

        var consoleDetail: Bool {
            tier && options.console
        }

        func queryValues(for raw: String, tagged: QueryValues) -> QueryValues {
            options.clearQueries && covers(raw) ? .clear : tagged
        }
    }

    /// A listed developer site: a host and its port, nil meaning the default port of the scheme.
    struct HostPort: Equatable, Sendable {
        let host: String
        let port: Int?
    }

    /// One header after redaction: `value` is `Redaction.hidden` for a header whose value must not be shown.
    struct Header: Equatable, Sendable {
        let name: String
        let value: String
    }

    /// A body as an engine delivered it, before structure hiding, scrubbing and cutting.
    struct RawBody: Equatable, Sendable {
        /// Nil: the engine had no text for it (binary, too large, unavailable); `note` says why.
        var text: String?
        var contentType: String?
        /// Bytes in the whole body, when known.
        var size: Int?
        var binary = false
        /// The engine stopped reading before the end: the text is a prefix of a body whose size is not known.
        var partial = false
        var note: String?
    }

    /// The raw detail of one request, kept only while the record is made. Headers are already redacted.
    struct DetailInput: Equatable, Sendable {
        var url: String
        var requestHeaders: [Header]?
        var responseHeaders: [Header]?
        var requestBody: RawBody?
        var responseBody: RawBody?
    }

    enum Redaction {
        /// What replaces a value that must not be shown.
        static let hidden = "‹hidden›"
        static let maxHeaders = 64
        static let maxHeaderNameBytes = 100
        static let maxHeaderValueBytes = 256
        static let maxHeaderBlockBytes = 8_192
        /// A body is cut to this many bytes in a record.
        static let maxBodyBytes = 32 * 1_024
        /// All the body text one capture keeps.
        static let captureBodyBytes = 2 * 1_048_576
        /// How much of a body is read before it is cut: more than a record keeps, so a secret that straddles the limit is
        /// still whole when it is scrubbed.
        static let maxIntakeBytes = 64 * 1_024
        static let maxPreviewBytes = 2_048

        // MARK: Names

        private static let hiddenHeaderNames: Set<String> = [
            "authorization", "proxy-authorization", "cookie", "set-cookie", "set-cookie2", "www-authenticate", "proxy-authenticate",
            "authentication-info", "proxy-authentication-info",
        ]
        private static let hiddenHeaderFragments = [
            "token", "secret", "key", "auth", "session", "password", "passwd", "pwd", "csrf", "xsrf", "credential", "signature", "jwt",
            "bearer", "cookie", "otp",
        ]
        /// Headers whose value is never a credential and often looks generated (a user agent, a media type with a boundary).
        private static let entropyExempt: Set<String> = [
            "content-type", "content-length", "content-encoding", "content-language", "accept", "accept-encoding", "accept-language",
            "user-agent", "host", "date", "server", "connection", "cache-control", "vary", "origin", "referer", "location", "content-location",
            "access-control-allow-origin", "access-control-allow-methods", "access-control-allow-headers", "access-control-expose-headers",
            "access-control-max-age", "access-control-request-method", "access-control-request-headers", "x-powered-by", "keep-alive", "expires",
            "last-modified", "pragma", "upgrade-insecure-requests", "transfer-encoding", "content-security-policy", "referrer-policy",
        ]
        private static let urlHeaders: Set<String> = ["referer", "location", "content-location", "origin", "x-original-url", "x-rewrite-url"]

        /// Substrings of a name once separators are dropped (`new_password`, `X-Api-Key`, `csrfToken`).
        private static let hiddenKeyFragments = [
            "password", "passwd", "passcode", "passphrase", "secret", "token", "credential", "apikey", "authorization", "cvv", "cvc", "ssn", "iban",
            "creditcard", "cardnumber", "cardno", "privatekey", "sessionid", "csrf", "xsrf", "signature",
        ]
        /// Whole words of a name: short ones that would hide too much as substrings (`pass` in `passengers`).
        private static let hiddenKeyWords: Set<String> = ["pass", "pwd", "otp", "card", "pin", "auth", "session", "cookie", "cvv", "cvc", "ssn"]

        /// Whether a form field, JSON key or header-like name means a credential.
        static func isHiddenKey(_ key: String) -> Bool {
            let compact = String(key.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
            if hiddenKeyFragments.contains(where: { compact.contains($0) }) {
                return true
            }
            return words(of: key).contains { hiddenKeyWords.contains($0) }
        }

        /// Lower-case words of `key`, split at separators and at a lower-to-upper case change (`userPassword` is `user`, `password`).
        private static func words(of key: String) -> [String] {
            var result: [String] = []
            var current = ""
            var previousLower = false
            for character in key.prefix(200) {
                guard character.isLetter || character.isNumber else {
                    if !current.isEmpty {
                        result.append(current.lowercased())
                    }
                    current = ""
                    previousLower = false
                    continue
                }
                if character.isUppercase, previousLower, !current.isEmpty {
                    result.append(current.lowercased())
                    current = ""
                }
                current.append(character)
                previousLower = character.isLowercase
            }
            if !current.isEmpty {
                result.append(current.lowercased())
            }
            return result
        }

        // MARK: Headers

        private static let nameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")

        static func hidesHeader(_ name: String, value: String) -> Bool {
            if hiddenHeaderNames.contains(name) || hiddenHeaderFragments.contains(where: { name.contains($0) }) {
                return true
            }
            guard !entropyExempt.contains(name), !name.hasPrefix("sec-fetch-"), !name.hasPrefix("sec-ch-") else { return false }
            return looksSecret(value)
        }

        /// The value, or any part of it split at spaces, commas, semicolons, equals signs and quotes, looks like a generated token.
        private static func looksSecret(_ value: String) -> Bool {
            if PageDiagnostics.looksGenerated(value) {
                return true
            }
            return value.split(whereSeparator: { " ,;=:\"'<>()[]{}".contains($0) }).contains { PageDiagnostics.looksGenerated(String($0)) }
        }

        /// A request or response header list as a record shows it. Duplicate names are joined; names are lower case; HTTP/2
        /// pseudo-headers are dropped; an address-valued header keeps its query only as `mode` allows. `requestURL` resolves a
        /// relative address.
        static func headers(_ pairs: [(name: String, value: String)], requestURL: String?, mode: (String) -> QueryValues) -> [Header] {
            var order: [String] = []
            var values: [String: String] = [:]
            for pair in pairs.prefix(maxHeaders) {
                let name = pair.name.lowercased()
                guard !name.isEmpty, name.utf8.count <= maxHeaderNameBytes, !name.hasPrefix(":"),
                    name.unicodeScalars.allSatisfy(nameCharacters.contains)
                else { continue }
                let shown = hidesHeader(name, value: pair.value) ? hidden : display(name, pair.value, requestURL: requestURL, mode: mode)
                if let existing = values[name] {
                    values[name] = existing == hidden || shown == hidden ? hidden : existing + ", " + shown
                } else {
                    order.append(name)
                    values[name] = shown
                }
            }
            return order.compactMap { name in values[name].map { Header(name: name, value: $0) } }
        }

        private static func display(_ name: String, _ value: String, requestURL: String?, mode: (String) -> QueryValues) -> String {
            if name == "content-type" {
                return mediaType(value).map { type in
                    let charset = value.range(of: "charset=", options: .caseInsensitive).map { String(value[$0.upperBound...].prefix { !";, ".contains($0) }) }
                    return charset.map { "\(type); charset=\($0)" } ?? type
                } ?? hidden
            }
            if urlHeaders.contains(name) {
                let absolute = URL(string: value, relativeTo: requestURL.flatMap { URL(string: $0) })?.absoluteString ?? value
                guard let clean = PageDiagnostics.sanitize(url: String(absolute.prefix(2_048)), queryValues: mode(absolute)) else { return hidden }
                return clean
            }
            return plain(value, limit: maxHeaderValueBytes)
        }

        /// `text` on one line, control characters blanked, cut to `limit` bytes.
        private static func plain(_ text: String, limit: Int) -> String {
            let flat = String(String.UnicodeScalarView(text.unicodeScalars.prefix(limit).map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
            let cut = PageDiagnostics.clip(flat, bytes: limit)
            return cut.truncated ? cut.text + "…" : cut.text
        }

        /// `name: value` lines in order, within `maxHeaderBlockBytes`.
        static func block(_ headers: [Header]) -> (text: String, truncated: Bool) {
            var lines: [String] = []
            var used = 0
            for header in headers {
                let line = "\(header.name): \(header.value)"
                guard used + line.utf8.count + 1 <= maxHeaderBlockBytes else { return (lines.joined(separator: "\n"), true) }
                used += line.utf8.count + 1
                lines.append(line)
            }
            return (lines.joined(separator: "\n"), false)
        }

        // MARK: Bodies

        /// `type/subtype` of a `Content-Type` value, lower case, without parameters; nil when it is not one.
        static func mediaType(_ value: String?) -> String? {
            guard let value, value.utf8.count <= 512 else { return nil }
            let essence = (value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
            let parts = essence.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty } ? essence : nil
        }

        enum BodyKind {
            case json, form, xml, text
        }

        /// The kind of text a media type is, or nil when it is not text a record may show (images, archives, multipart bodies).
        static func bodyKind(_ type: String) -> BodyKind? {
            switch type {
            case "application/x-www-form-urlencoded":
                return .form
            case "application/json", "application/graphql", "application/x-ndjson", "application/ld+json":
                return .json
            case "application/xml", "application/xhtml+xml", "image/svg+xml":
                return .xml
            default:
                break
            }
            if type.hasSuffix("+json") { return .json }
            if type.hasSuffix("+xml") { return .xml }
            if type.hasPrefix("text/") { return type == "text/xml" || type == "text/html" ? .xml : .text }
            return nil
        }

        /// Whether a response with this `Content-Type` is worth reading as text.
        static func isTextType(_ contentType: String?) -> Bool {
            mediaType(contentType).flatMap(bodyKind) != nil
        }

        /// The fields of one body (`requestBody`, `responseBody`, …): its text with credentials hidden and secrets scrubbed, cut to
        /// the per-body limit and what is left of the capture's `budget`; or a note saying why there is no text.
        static func body(_ raw: RawBody, side: String, budget: inout Int, scrub: (String) -> String) -> (fields: [String: Field], truncated: Bool) {
            var fields: [String: Field] = [:]
            if let size = raw.size { fields["\(side)BodyBytes"] = .number(size) }
            let type = mediaType(raw.contentType)
            let kind = type.flatMap(bodyKind)
            func note(_ text: String) -> ([String: Field], Bool) {
                fields["\(side)BodyNote"] = .text(text)
                return (fields, false)
            }
            if raw.binary || (type != nil && kind == nil) {
                return note("not captured: \(type ?? "binary") body" + (raw.size.map { ", \($0) bytes" } ?? ""))
            }
            guard let text = raw.text else { return note(raw.note ?? "not captured: no text available") }
            guard budget > 0 else { return note("not captured: this capture's \(captureBodyBytes / 1_048_576) MiB body limit is used up") }
            let kept = PageDiagnostics.clip(text, bytes: maxIntakeBytes)
            let cleaned = scrub(hideCredentials(kept.text, kind: kind))
            let limit = min(maxBodyBytes, budget)
            let cut = PageDiagnostics.clip(cleaned, bytes: limit)
            budget -= cut.text.utf8.count
            fields["\(side)Body"] = .text(cut.text)
            let whole = raw.size ?? text.utf8.count
            let truncated = cut.truncated || kept.truncated || whole > text.utf8.count || raw.partial
            if truncated {
                let of = raw.size.map { " of \(max($0, cut.text.utf8.count))" } ?? ""
                fields["\(side)BodyNote"] = .text("truncated: the first \(cut.text.utf8.count)\(of) bytes")
            }
            return (fields, truncated)
        }

        /// `text` with every credential-named value hidden, by the structure of its kind.
        static func hideCredentials(_ text: String, kind: BodyKind?) -> String {
            switch kind {
            case .form:
                return hideForm(text)
            case .json:
                return hideJSON(text) ?? hideText(text)
            case nil:
                let first = text.drop { $0.isWhitespace }.first
                return first == "{" || first == "[" ? hideJSON(text) ?? hideText(text) : hideText(text)
            default:
                return hideText(text)
            }
        }

        static func hideForm(_ text: String) -> String {
            text.split(separator: "&", omittingEmptySubsequences: false).map { pair -> String in
                guard let equals = pair.firstIndex(of: "=") else { return String(pair) }
                let name = String(pair[..<equals])
                let decoded = name.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? name
                return isHiddenKey(decoded) ? name + "=" + hidden : String(pair)
            }.joined(separator: "&")
        }

        /// Nil when `text` is not JSON (a body cut at the intake limit, say); the caller falls back to `hideText`.
        static func hideJSON(_ text: String) -> String? {
            guard let data = text.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                let out = try? JSONSerialization.data(
                    withJSONObject: hiding(object, depth: 0), options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
            else { return nil }
            return String(decoding: out, as: UTF8.self)
        }

        private static let maxDepth = 32

        /// `value` with every credential-named entry replaced, at any depth.
        static func hiding(_ value: Any, depth: Int) -> Any {
            guard depth < maxDepth else { return "[too deep]" }
            switch value {
            case let object as [String: Any]:
                return object.reduce(into: [String: Any]()) { result, entry in
                    result[entry.key] = isHiddenKey(entry.key) ? hidden : hiding(entry.value, depth: depth + 1)
                }
            case let list as [Any]:
                return list.map { hiding($0, depth: depth + 1) }
            case let text as String:
                return looksLikeCredential(text) ? hidden : text
            default:
                return value
            }
        }

        /// A value that is a credential whatever its key: a JWT or a `Bearer …` value.
        static func looksLikeCredential(_ text: String) -> Bool {
            if text.hasPrefix("eyJ"), text.split(separator: ".", omittingEmptySubsequences: false).count == 3, text.utf8.count >= 20 {
                return true
            }
            return text.lowercased().hasPrefix("bearer ") && text.utf8.count > 12
        }

        // Both run over text a page chose, so neither may backtrack without bound: a name is matched only from where it starts and
        // possessively, so a long run of name characters is read once, and every repeat that could run on is capped.
        private static let pair = try? NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])([A-Za-z0-9_][A-Za-z0-9_.\-\[\]]{0,99}+)(["']?[ \t]{0,8}+[:=][ \t]{0,8}+)"#)
        private static let element = try? NSRegularExpression(
            pattern: #"<([A-Za-z_][A-Za-z0-9_:.\-]{0,63}+)((?:\s[^>]{0,255}+)?+)>([^<]{1,4096}+)</\1>"#)

        /// Plain text and XML: a `name=value` or `name: value` pair, an attribute or an element whose name is a credential has its
        /// value hidden; an unquoted value runs to the end of its line, a quote or a separator. Fails closed: if the patterns
        /// cannot run, nothing is shown.
        static func hideText(_ text: String) -> String {
            guard let pair, let element else { return hidden }
            var result = text
            for (expression, group) in [(element, 3), (pair, 0)] {
                let source = result as NSString
                var output = ""
                var cursor = 0
                for match in expression.matches(in: result, range: NSRange(location: 0, length: source.length)) where match.range.location >= cursor {
                    let name = source.substring(with: match.range(at: 1))
                    guard isHiddenKey(name) else { continue }
                    let start = group == 0 ? match.range.upperBound : match.range(at: group).location
                    let end = group == 0 ? valueEnd(in: source, from: start) : match.range(at: group).upperBound
                    guard end >= start else { continue }
                    output += source.substring(with: NSRange(location: cursor, length: start - cursor)) + hidden
                    cursor = end
                }
                result = output + source.substring(from: cursor)
            }
            return result
        }

        /// Where the value that starts at `start` ends: after its closing quote, or at the first line break or separator.
        private static func valueEnd(in text: NSString, from start: Int) -> Int {
            guard start < text.length else { return start }
            let first = text.character(at: start)
            let stops: Set<unichar> = Set("\n&,;\"'<>".utf16)
            var index = start
            if first == 0x22 || first == 0x27 {
                index += 1
                while index < text.length, text.character(at: index) != first, text.character(at: index) != 0x0A {
                    index += 1
                }
                return min(index + 1, text.length)
            }
            while index < text.length, !stops.contains(text.character(at: index)) {
                index += 1
            }
            return index
        }

        // MARK: Previews

        /// A console argument list as bounded JSON with credential-named keys hidden, at most `maxPreviewBytes`. A preview that does
        /// not fit is cut to a shallower depth first, then cut as text.
        static func preview(_ value: Any) -> (text: String, truncated: Bool)? {
            // The list of arguments is one level; an object inside an argument deeper than 3 levels is replaced.
            for depth in [4, 2] {
                let cleaned = limited(hiding(value, depth: 0), depth: depth)
                guard let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
                else { return nil }
                if data.count <= maxPreviewBytes {
                    return (String(decoding: data, as: UTF8.self), depth < 4)
                }
            }
            let full = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]))
                .map { String(decoding: $0, as: UTF8.self) } ?? ""
            let cut = PageDiagnostics.clip(hideText(full), bytes: maxPreviewBytes)
            return (cut.text, true)
        }

        /// A preview string from the WebKit hook: JSON when it parses, else text that is cut and hidden as text.
        static func preview(json text: String) -> (text: String, truncated: Bool) {
            let kept = PageDiagnostics.clip(text, bytes: maxIntakeBytes)
            if let data = kept.text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                let cleaned = preview(object) {
                return cleaned
            }
            let cut = PageDiagnostics.clip(hideText(kept.text), bytes: maxPreviewBytes)
            return (cut.text, true)
        }

        /// `value` with containers deeper than `depth` replaced by a marker.
        private static func limited(_ value: Any, depth: Int) -> Any {
            switch value {
            case let object as [String: Any]:
                return depth == 0 ? "[object]" : object.mapValues { limited($0, depth: depth - 1) }
            case let list as [Any]:
                return depth == 0 ? "[array]" : list.map { limited($0, depth: depth - 1) }
            default:
                return value
            }
        }
    }
}

nonisolated extension PageDiagnostics {
    /// The detail fields of one network record, for a request the policy covers. Callers check `DetailPolicy.network` first and
    /// again after every suspension before they get here.
    static func detailFields(
        _ input: DetailInput, options: DetailOptions, budget: inout Int, scrub: (String) -> String
    ) -> (fields: [String: Field], truncated: Bool) {
        var fields: [String: Field] = [:]
        var truncated = false
        if options.headers {
            for (key, headers) in [("requestHeaders", input.requestHeaders), ("responseHeaders", input.responseHeaders)] {
                guard let headers else { continue }
                let block = Redaction.block(headers)
                fields[key] = .text(scrub(block.text))
                truncated = truncated || block.truncated
            }
        }
        if options.bodies {
            for (side, body) in [("request", input.requestBody), ("response", input.responseBody)] {
                guard let body else { continue }
                let result = Redaction.body(body, side: side, budget: &budget, scrub: scrub)
                fields.merge(result.fields) { $1 }
                truncated = truncated || result.truncated
            }
        }
        return (fields, truncated)
    }
}
