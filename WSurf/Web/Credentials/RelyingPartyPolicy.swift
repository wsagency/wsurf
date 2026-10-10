// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

nonisolated enum RelyingPartyPolicy {
    private enum PolicyError: Error {
        case invalidOrigin
        case invalidRelyingParty
        case suffixListUnavailable
    }

    private struct SuffixRules {
        let exact: Set<String>
        let wildcard: Set<String>
        let exceptions: Set<String>

        func publicSuffixLabelCount(for domain: String) -> Int {
            let lookupDomain = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
            let labels = lookupDomain.split(separator: ".", omittingEmptySubsequences: false)
            var bestMatch = 1 // PSL's implicit "*" rule.
            var exceptionMatch: Int?

            for index in labels.indices {
                let candidate = labels[index...].joined(separator: ".")
                let count = labels.count - index
                if exceptions.contains(candidate) {
                    exceptionMatch = count - 1
                }
                if exact.contains(candidate) {
                    bestMatch = max(bestMatch, count)
                }
                if index > labels.startIndex, wildcard.contains(candidate) {
                    bestMatch = max(bestMatch, count + 1)
                }
            }
            return exceptionMatch ?? bestMatch
        }
    }

    // ponytail: bundled PSL refreshes only with app releases; update the snapshot when refreshing dependencies.
    private static let suffixRules = loadSuffixRules()

    static func validate(rpID: String?, origin: URL) throws -> String {
        guard let rawHost = origin.host,
              let host = canonicalDomain(rawHost),
              let scheme = origin.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && host == "localhost")
        else { throw PolicyError.invalidOrigin }

        let relyingParty: String
        if let rpID {
            guard let canonical = canonicalRelyingParty(rpID) else {
                throw PolicyError.invalidRelyingParty
            }
            relyingParty = canonical
        } else {
            relyingParty = host
        }

        guard let suffixRules else { throw PolicyError.suffixListUnavailable }
        guard relyingParty == host || host.hasSuffix("." + relyingParty) else {
            throw PolicyError.invalidRelyingParty
        }

        // WebAuthn's localhost development exception is limited to the exact loopback name.
        if relyingParty == "localhost" && host == "localhost" {
            return relyingParty
        }

        let rpLabels = domainLabels(relyingParty)
        let suffixLabels = suffixRules.publicSuffixLabelCount(for: relyingParty)
        guard rpLabels.count > suffixLabels else { throw PolicyError.invalidRelyingParty }


        return relyingParty
    }

    private static func canonicalRelyingParty(_ input: String) -> String? {
        guard !input.isEmpty, input.utf8.count <= 1_024,
              input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.contains(where: { ":/?#@\\%".contains($0) || $0.isWhitespace || $0.isNewline })
        else { return nil }
        return canonicalDomain(input)
    }

    static func canonicalDomain(_ input: String) -> String? {
        guard !input.isEmpty, input.utf8.count <= 1_024,
              !input.contains(where: { "/?#@\\%".contains($0) || $0.isWhitespace || $0.isNewline })
        else { return nil }
        guard var components = URLComponents(string: "https://\(input)"),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.port == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty,
              let parsedHost = components.host, !parsedHost.isEmpty
        else { return nil }
        components.host = parsedHost // Re-encode through Foundation's IDNA host path.
        guard let url = components.url,
              let authority = url.absoluteString.dropFirst("https://".count).split(separator: "/").first
        else { return nil }

        let host = String(authority).lowercased()
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard !name.isEmpty, name.utf8.count <= 253,
              name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }),
              !isIPAddress(host)
        else { return nil }
        return host
    }

    private static func isIPAddress(_ host: String) -> Bool {
        guard !host.contains(":") else { return true }
        let addressHost = host.hasSuffix(".") ? String(host.dropLast()) : host
        var address = in_addr()
        return addressHost.withCString { inet_aton($0, &address) == 1 }
    }

    private static func domainLabels(_ domain: String) -> [String] {
        let name = domain.hasSuffix(".") ? String(domain.dropLast()) : domain
        return name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }

    private static func loadSuffixRules() -> SuffixRules? {
        guard let url = Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"),
              let data = try? Data(contentsOf: url), data.count <= 1_000_000,
              let source = String(data: data, encoding: .utf8)
        else { return nil }

        var exact = Set<String>()
        var wildcard = Set<String>()
        var exceptions = Set<String>()
        for line in source.split(whereSeparator: \.isNewline) {
            let rule = line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            guard !rule.isEmpty, !rule.hasPrefix("//") else { continue }
            let kind: Character?
            let domain: Substring
            if rule.hasPrefix("!") {
                kind = "!"
                domain = rule.dropFirst()
            } else if rule.hasPrefix("*.") {
                kind = "*"
                domain = rule.dropFirst(2)
            } else {
                kind = nil
                domain = rule[...]
            }
            guard let canonical = canonicalDomain(String(domain)) else { return nil }
            switch kind {
            case "!": exceptions.insert(canonical)
            case "*": wildcard.insert(canonical)
            default: exact.insert(canonical)
            }
            guard exact.count + wildcard.count + exceptions.count <= 100_000 else { return nil }
        }
        guard !exact.isEmpty, !wildcard.isEmpty, !exceptions.isEmpty else { return nil }
        return SuffixRules(exact: exact, wildcard: wildcard, exceptions: exceptions)
    }
}
