// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WSurfVault

/// How a website is named to the person when it is about to be added to a saved credential, and whether it imitates one of that
/// credential's websites. Pure: hosts in, text out.
nonisolated enum WebsiteLookalike {
    /// An HTTPS origin's host as the address bar draws it (`AddressText`): punycode for any non-ASCII name, never sign-in details,
    /// and the port when it is not 443. nil when the bar would not draw it as a plain name.
    static func displayHost(of origin: String) -> String? {
        guard let text = AddressText(URL(string: origin)), text.scheme == "https://", !text.host.isEmpty else { return nil }
        let port = text.rest.hasPrefix(":") ? String(text.rest.prefix { $0 != "/" }) : ""
        return text.host + port
    }

    // ponytail: a naive check (fold, then edit distance on the registrable domain); a real confusables table (UTS #39 skeleton) if it misses.
    /// The website of `websites` that `origin` imitates, as the bar draws it, or nil. Imitating means another registrable domain
    /// (a sibling of the same domain is the same site) that reads the same once look-alike letters, accents and digit-for-letter
    /// swaps are folded away (`pаypal.com` with a Cyrillic а, `bücher.de`, `paypa1.com`), or that is one letter away from it, two
    /// for a long name (`examp1e.co`, `arnazon.com`).
    static func imitated(by origin: String, among websites: [String]) -> String? {
        guard let mine = site(of: origin) else { return nil }
        for website in websites {
            guard let theirs = site(of: website), theirs.domain != mine.domain else { continue }
            if theirs.folded == mine.folded || isNear(theirs.folded, mine.folded) {
                return displayHost(of: website)
            }
        }
        return nil
    }

    /// The registrable domain of an HTTPS origin (the host itself for an address or a name the suffix list does not know), and the
    /// same name decoded from punycode and folded for comparison.
    private static func site(of origin: String) -> (domain: String, folded: String)? {
        guard let host = URL(string: origin)?.host?.lowercased(), !host.isEmpty else { return nil }
        let domain = RelyingPartyPolicy.registrableDomain(of: host) ?? host
        // URLComponents reads a punycode name back as the letters it stands for.
        let letters = URLComponents(string: "https://" + domain)?.host ?? domain
        return (domain, PageDialogText.leet(PageDialogText.normalized(letters)))
    }

    private static func isNear(_ left: String, _ right: String) -> Bool {
        let shorter = min(left.count, right.count)
        // Short names are a letter apart by chance ("x.com", "y.com"): that is no sign of an imitation.
        guard shorter >= 6 else { return false }
        return distance(Array(left), Array(right)) <= (shorter >= 10 ? 2 : 1)
    }

    /// Levenshtein distance: the fewest single-character insertions, deletions and substitutions from one to the other.
    static func distance(_ left: [Character], _ right: [Character]) -> Int {
        var previous = Array(0...right.count)
        for (row, letter) in left.enumerated() {
            var current = [row + 1]
            for (column, other) in right.enumerated() {
                current.append(min(previous[column + 1] + 1, current[column] + 1, previous[column] + (letter == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[right.count]
    }
}
