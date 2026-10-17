// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Network

/// Where the Developer tier and a paired client's standing grants apply, and what they allow.
///
/// A standing grant needs all of these at once: a paired client that is not paused, a site on the developer list, and a
/// window of the Developer profile. Every input comes from `MCPTrustStore`, which lives in the keychain. Nothing here reads
/// UserDefaults or a file, so a process with a shell cannot widen the list, choose another profile or raise a level.
nonisolated enum MCPDeveloperAccess {
    /// At most this many user-listed sites.
    static let maximumSites = 64
    /// What "This Mac" covers, on any port. Exact names only: not `*.localhost`, not `127.0.0.2`, not `0.0.0.0`.
    static let thisMacHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]

    /// A listed site. A site without a port means the scheme's default port only (80 for http, 443 for https).
    struct Site: Equatable, Sendable {
        let host: String
        let port: Int?

        /// The stored form: `host` or `host:port`, IPv6 in brackets.
        var text: String {
            let name = host.contains(":") ? "[\(host)]" : host
            return port.map { "\(name):\($0)" } ?? name
        }
    }

    // MARK: Sites

    /// The site named by `text`, or nil unless it is an exact `host` or `host:port`. A pasted http(s) address is reduced
    /// to its host and port. Wildcards, address ranges, paths, queries, credentials and non-ASCII names are refused.
    static func site(from text: String) -> Site? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = text.range(of: "://") {
            guard ["http", "https"].contains(text[..<separator.lowerBound].lowercased()) else { return nil }
            text = String(text[separator.upperBound...])
            if text.hasSuffix("/") { text.removeLast() }
        }
        guard !text.isEmpty, text.utf8.count <= 260,
              text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && !"*/?#@\\%".unicodeScalars.contains($0) })
        else { return nil }
        var host = text
        var port: Int?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let parsed = Self.port(String(rest.dropFirst())) else { return nil }
                port = parsed
            }
            guard host.contains(":") else { return nil }
        } else if let colon = text.firstIndex(of: ":") {
            guard text.firstIndex(of: ":") == text.lastIndex(of: ":"),
                  let parsed = Self.port(String(text[text.index(after: colon)...]))
            else { return nil }
            host = String(text[..<colon])
            port = parsed
        }
        guard let canonical = canonicalHost(host), isAcceptableHost(canonical) else { return nil }
        return Site(host: canonical, port: port)
    }

    /// The stored form of a site the user typed, or nil when it is not acceptable.
    static func normalizedSite(_ text: String) -> String? {
        site(from: text)?.text
    }

    /// Lowercase, no trailing dot; an IPv6 address in its compressed form. Nil when `host` is empty or a malformed address.
    static func canonicalHost(_ host: String) -> String? {
        var host = host.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        guard host.contains(":") else { return host }
        guard let address = IPv6Address(host) else { return nil }
        var bytes = [UInt8](address.rawValue)
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return inet_ntop(AF_INET6, &bytes, &buffer, socklen_t(buffer.count)).map { String(cString: $0) }
    }

    private static func port(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy(\.isASCII), text.allSatisfy(\.isNumber),
              let value = Int(text), (1...65_535).contains(value)
        else { return nil }
        return value
    }

    /// A DNS name, a dotted-quad IPv4 address other than 0.0.0.0, or an IPv6 address. Numeric shorthands such as
    /// `2130706433`, `127.1` and `0x7f.0.0.1` are refused because browsers read them as other addresses.
    private static func isAcceptableHost(_ host: String) -> Bool {
        if host.contains(":") {
            return true
        }
        if host.allSatisfy({ $0.isNumber || $0 == "." }) {
            return host != "0.0.0.0" && isDottedQuad(host)
        }
        guard host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // A name that ends in a number is read as an address.
        if let last = labels.last, last.allSatisfy(\.isNumber) || (last.hasPrefix("0x") && last.dropFirst(2).allSatisfy(\.isHexDigit)) {
            return false
        }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.utf8.allSatisfy { ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }
        }
    }

    /// Exactly four decimal parts of 0 to 255, without leading zeros (which some parsers read as octal).
    private static func isDottedQuad(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4
            && parts.allSatisfy { part in
                (1...3).contains(part.count) && part.allSatisfy(\.isASCII) && (part == "0" || !part.hasPrefix("0"))
                    && (Int(part).map { $0 <= 255 } ?? false)
            }
    }

    /// Whether `url` is an http(s) address without credentials on This Mac (when included) or on a listed site.
    static func matches(_ url: URL, sites: [String], includesThisMac: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let rawHost = url.host(), let host = canonicalHost(rawHost)
        else { return false }
        if includesThisMac, thisMacHosts.contains(host) {
            return true
        }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port ?? defaultPort
        return sites.contains { entry in
            guard let site = site(from: entry), site.host == host else { return false }
            return (site.port ?? defaultPort) == port
        }
    }

    // MARK: Stored settings

    /// Whether `url` is a developer site. False while the trust store is unavailable.
    @MainActor
    static func isDeveloperSite(_ url: URL, trust: MCPTrustStore = .shared) -> Bool {
        trust.isAvailable && matches(url, sites: trust.developerSites, includesThisMac: trust.includesThisMac)
    }

    /// Whether `profile` is the chosen Developer profile. The everyday profile is never one unless it was chosen
    /// explicitly, and private browsing never is.
    @MainActor
    static func isDeveloperProfile(_ profile: Profile, trust: MCPTrustStore = .shared) -> Bool {
        trust.isAvailable && !profile.isPrivate && trust.developerProfileID == profile.id
    }

    @MainActor
    static func isDeveloperProfile(_ context: BrowserProfileContext, trust: MCPTrustStore = .shared) -> Bool {
        isDeveloperProfile(context.profile, trust: trust)
    }

    /// Whether choosing `id` as the Developer profile needs the owner's confirmation: every profile except the one WSurf
    /// created for this purpose.
    @MainActor
    static func needsConfirmation(choosing id: UUID, trust: MCPTrustStore = .shared) -> Bool {
        trust.dedicatedProfileID != id
    }

    /// What `client` may do without asking right now: nil unless it is paired, in the store, not paused and set above Off.
    @MainActor
    static func standingAccess(for client: PairedClient?, trust: MCPTrustStore = .shared) -> MCPAccessConsent.Access? {
        guard trust.isAvailable, let id = client?.id, let live = trust.client(id: id), !live.paused else { return nil }
        switch live.standing {
        case .off:
            return nil
        case .development:
            return .development
        case .developer:
            return .developer
        }
    }

    /// Creates the profile for developer work and chooses it. The only choice that needs no confirmation.
    @MainActor
    @discardableResult
    static func createDeveloperProfile(in catalog: ProfileStore = .shared, trust: MCPTrustStore = .shared) throws -> Profile {
        trust.loadIfNeeded()
        guard trust.isAvailable else { throw MCPTrustStore.Failure.unavailable }
        let profile = catalog.add(name: String(localized: "Developer"), symbol: "hammer", color: .teal)
        try trust.setDeveloperProfile(profile.id, dedicated: true)
        return profile
    }
}

extension MCPAccessConsent.Access {
    /// Read Only < Allow Control < Allow Development < Allow Developer.
    nonisolated var rank: Int {
        switch self {
        case .readOnly:
            0
        case .control:
            1
        case .development:
            2
        case .developer:
            3
        }
    }
}
