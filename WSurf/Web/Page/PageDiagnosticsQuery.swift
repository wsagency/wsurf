// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// How a recorded URL shows its query. A query can carry a secret in a value (`?token=…`), in a name (`?<jwt>=`) or as a bare
/// item (`?<code>`), and a client that can make the page load URLs of its own choosing must not be able to confirm a guess by
/// comparing what it sees. So the rule is about what is safe to show, not about which parts are secret:
///
/// - A name is shown only when it is plain: an identifier of at most 32 characters (`[A-Za-z_][A-Za-z0-9_.\-\[\]]*`, after
///   percent-decoding) with no run of 12 hex digits and nothing token-shaped. Any other name is concealed like a value.
/// - Every value is concealed. A value that looks like a generated secret (below) becomes `~` and 16 hex digits of its
///   HMAC-SHA256 under the capture's key, which lets one request be matched with another inside the same document. Any other value
///   is guessable, so it shows only a length class (`*short` up to 8 characters, `*medium` up to 32, `*long`), never a tag
///   that a client could test a guess against.
/// - A parameter with no value (`?<code>` or `?<code>=`) is concealed whole, as a value, because its name may be the secret.
///
/// The key is replaced whenever the document changes and whenever an agent navigates, and records are made with the key of the
/// document they belong to, so a tag means nothing in another document and a value the client supplies in one document cannot
/// be matched with one the page used in another. Inside one document an agent that can make the page request a value can still
/// confirm a guess of a value that looks generated; the length, character mix and entropy rules below keep such a guess from
/// being practical for a real token and leave guessable values untagged.
nonisolated extension PageDiagnostics {
    enum QueryValues: Sendable {
        /// Conceal as described above under this document's key.
        case tagged(SymmetricKey)
        /// Names and values stay readable. Reserved for the Developer tier on developer sites; no tool selects it yet.
        case clear
    }

    static let maxQueryParameters = 32
    static let maxQueryNameLength = 32
    static let tagBytes = 8

    static func render(query: String, _ queryValues: QueryValues) -> (text: String, cut: Bool) {
        let parameters = query.split(separator: "&", omittingEmptySubsequences: true)
        guard case .tagged(let key) = queryValues else { return (String(query), false) }
        var shown = parameters.prefix(maxQueryParameters).map { parameter -> String in
            guard let equals = parameter.firstIndex(of: "="), equals != parameter.index(before: parameter.endIndex) else {
                return conceal(parameter.filter { $0 != "=" }, key)
            }
            let name = String(parameter[..<equals])
            let value = String(parameter[parameter.index(after: equals)...])
            return (isPlainName(decoded(name)) ? decoded(name) : conceal(name, key)) + "=" + conceal(value, key)
        }
        if parameters.count > maxQueryParameters { shown.append("…") }
        return (shown.joined(separator: "&"), parameters.count > maxQueryParameters)
    }

    private static func decoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// A tag for something that looks like a generated secret, otherwise only how long it was.
    private static func conceal(_ raw: String, _ key: SymmetricKey) -> String {
        let text = decoded(raw)
        if looksGenerated(text) {
            let code = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
            return "~" + code.prefix(tagBytes).map { String(format: "%02x", $0) }.joined()
        }
        let length = text.unicodeScalars.count
        return length <= 8 ? "*short" : length <= 32 ? "*medium" : "*long"
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        (0x41...0x5A).contains(scalar.value) || (0x61...0x7A).contains(scalar.value)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x30...0x39).contains(scalar.value)
    }

    private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        isDigit(scalar) || (0x41...0x46).contains(scalar.value) || (0x61...0x66).contains(scalar.value)
    }

    private static func isPlainName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars.prefix(maxQueryNameLength + 1))
        guard (1...maxQueryNameLength).contains(scalars.count), let first = scalars.first, isLetter(first) || first == "_",
            scalars.allSatisfy({ isLetter($0) || isDigit($0) || "_.-[]".unicodeScalars.contains($0) })
        else { return false }
        var run = 0
        for scalar in scalars {
            run = isHex(scalar) ? run + 1 : 0
            if run >= 12 {
                return false
            }
        }
        return !looksGenerated(name)
    }

    /// Whether a value looks like a token a program generated, such as a session id, API key, UUID, JWT or base64 blob, rather
    /// than something a person could type or guess. At least 16 characters of the token alphabet (`A-Za-z0-9_-+/=.~:`) with
    /// both letters and digits and at least 10 different characters, at least 3 bits of Shannon entropy per character, and, unless
    /// it is all hex, no run of 6 letters of one case (a word). It is a heuristic with a known ceiling: a long guessable string
    /// with a lucky mix still passes, which is why a tag only ever matches a request in the same document.
    static func looksGenerated(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.prefix(2_049))
        guard (16...2_048).contains(scalars.count) else { return false }
        var counts: [Unicode.Scalar: Int] = [:]
        var digits = false, letters = false, hex = true
        var run = 0, longestRun = 0, lastCase = 0
        for scalar in scalars {
            guard isLetter(scalar) || isDigit(scalar) || "_-+/=.~:".unicodeScalars.contains(scalar) else { return false }
            counts[scalar, default: 0] += 1
            digits = digits || isDigit(scalar)
            letters = letters || isLetter(scalar)
            hex = hex && isHex(scalar)
            let letterCase = isLetter(scalar) ? ((0x41...0x5A).contains(scalar.value) ? 1 : 2) : 0
            run = letterCase != 0 && letterCase == lastCase ? run + 1 : (letterCase != 0 ? 1 : 0)
            lastCase = letterCase
            longestRun = max(longestRun, run)
        }
        let total = Double(scalars.count)
        let entropy = counts.values.reduce(0.0) { $0 - Double($1) / total * log2(Double($1) / total) }
        return digits && letters && counts.count >= 10 && entropy >= 3.0 && (hex || longestRun < 6)
    }
}
