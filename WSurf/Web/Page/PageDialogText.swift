// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How a page's dialog text reaches a connection, and how WSurf reads it to decide who may answer.
nonisolated enum PageDialogText {
    static let maxScalars = 1_000

    // MARK: What a connection sees

    /// Control characters flattened, link queries, fragments and credentials removed, and the length bounded. The text is
    /// still the page's: callers wrap it as untrusted.
    static func forAgent(_ text: String) -> (text: String, truncated: Bool) {
        let cleaned = text.replacing(/[A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\s<>"'`]+/) { match in
            let link = String(match.output)
            let trimmed = link.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}"))
            return (PageDiagnostics.sanitize(url: trimmed) ?? "[link]") + link.dropFirst(trimmed.count)
        }
        var scalars = String.UnicodeScalarView()
        for scalar in cleaned.unicodeScalars.prefix(maxScalars) {
            scalars.append(scalar.properties.generalCategory == .control && scalar != "\n" ? " " : scalar)
        }
        return (String(scalars), cleaned.unicodeScalars.count > maxScalars)
    }

    static func origin(scheme: String, host: String, port: Int) -> String {
        guard !scheme.isEmpty, !host.isEmpty else { return "" }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme.lowercased())://\(name.lowercased())" + (port > 0 ? ":\(port)" : "")
    }

    static func origin(ofURL string: String) -> String {
        guard let url = URL(string: string), let scheme = url.scheme, let host = url.host(percentEncoded: true) else { return "" }
        return origin(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// An http(s) origin on this Mac: `localhost`, `127.0.0.1` or `[::1]`, any port. Exact hosts only.
    static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
            url.user == nil, url.password == nil, let host = url.host(percentEncoded: false)?.lowercased()
        else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    // MARK: How WSurf reads it

    /// The text as a matcher should see it. A page chooses its characters, so matching on the raw text is evaded by a
    /// zero-width space, a soft hyphen, a full-width letter, a combining accent or a Cyrillic letter that looks Latin:
    /// compatibility-normalize (NFKC), fold case, width and diacritics, drop format, control and filler characters, and
    /// map look-alike letters to ASCII.
    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var scalars = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where !isInvisible(scalar) {
            scalars.append(confusables[scalar] ?? scalar)
        }
        return String(scalars)
    }

    /// `normalized` with digits and symbols that stand in for letters read as those letters: "p4ssw0rd", "0tp".
    private static func leet(_ text: String) -> String {
        String(text.map { substitutions[$0] ?? $0 })
    }

    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .format:
            return true
        case .control:
            return !scalar.properties.isWhitespace
        default:
            // Variation selectors, the combining grapheme joiner and the Hangul and Halfwidth fillers draw nothing.
            return (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
                || [0x034F, 0x115F, 0x1160, 0x3164, 0xFFA0].contains(scalar.value)
        }
    }

    /// Letters from other scripts that look like an ASCII letter, lower case because case folding runs first.
    private static let confusables: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs =
            "а:a е:e о:o р:p с:c х:x у:y і:i ј:j ѕ:s ԁ:d һ:h ӏ:l ԛ:q ԝ:w к:k "
            + "α:a ε:e ι:i κ:k ν:v ο:o ρ:p τ:t υ:u χ:x ω:w ɑ:a ɡ:g ı:i"
        var table: [Unicode.Scalar: Unicode.Scalar] = [:]
        for pair in pairs.split(separator: " ") {
            let scalars = Array(pair.unicodeScalars)
            if let from = scalars.first, let to = scalars.last {
                table[from] = to
            }
        }
        return table
    }()

    private static let substitutions: [Character: Character] = [
        "0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "!": "i",
    ]

    /// A prompt that asks for a password, code, PIN, card number or other secret. Only the user answers it. Long terms match
    /// anywhere, so a separator the page hides ("your\u{7}password") does not help; short ones need word edges, to leave
    /// "pinterest" alone.
    static func looksSecret(_ message: String) -> Bool {
        let longTerms =
            #"pass[- ]?(word|code|phrase)|passwd|two[- ]?factor|(verification|security|authentication|confirmation|login|sign[- ]?in|recovery|backup|reset)[- ]?code"#
            + #"|card[- ]?number|credit[- ]?card|secret|token|social[- ]?security|seed[- ]?phrase|private[- ]?key|api[- ]?key"#
        let shortTerms = #"\b(pin|otp|totp|hotp|mfa|2fa|pwd|cvv|cvc|ssn|auth[- ]?code|one[- ]?time)\b"#
        let text = normalized(message)
        return [text, leet(text)].contains { candidate in
            [longTerms, shortTerms].contains { candidate.range(of: $0, options: .regularExpression) != nil }
        }
    }

    /// The consequence a dialog's decision carries, if the page's wording or the reply names one. `SensitiveAction`
    /// reads whole phrases ("delete account"); a dialog also carries the decision in one word ("Type DELETE to confirm",
    /// "Enter the amount to transfer"), so single words count here.
    static func consequence(of message: String, reply: String? = nil) -> SensitiveAction.Category? {
        let text = normalized(message)
        let answer = reply.map(normalized) ?? ""
        for (text, answer) in [(text, answer), (leet(text), leet(answer))] {
            if let category = SensitiveAction.category(of: text, context: answer) {
                return category
            }
            let words = (text + " " + answer).split { !$0.isLetter && !$0.isNumber }
            if let category = words.lazy.compactMap({ consequentialWords[String($0)] }).first {
                return category
            }
        }
        return nil
    }

    private static let consequentialWords: [String: SensitiveAction.Category] = [
        "delete": .deletion, "remove": .deletion, "erase": .deletion, "destroy": .deletion, "wipe": .deletion,
        "deactivate": .deletion,
        "transfer": .transfer, "wire": .transfer, "amount": .transfer, "money": .transfer,
        "buy": .purchase, "purchase": .purchase, "payment": .purchase, "subscribe": .purchase,
    ]
}
