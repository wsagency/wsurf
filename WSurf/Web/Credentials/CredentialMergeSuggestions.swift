// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why two or more credentials look like one.
nonisolated enum CredentialMergeReason: Int, Comparable, Sendable {
    /// The same website and the same username.
    case sameLogin
    /// A password, a passkey and a verification code that were saved apart and belong together.
    case splitParts
    /// The same username on a website that is not the same but is related: the same password, or the same site name.
    case relatedSite

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A group of credentials the vault suggests merging. It names them and the reason, never a value.
nonisolated struct CredentialMergeSuggestion: Equatable, Identifiable, Sendable {
    let id: Int
    let reason: CredentialMergeReason
    /// At least two credentials, in the order the vault lists them.
    let ids: [UUID]
    /// Every member has the same login, no member's code differs, and their websites are on the same sites: merging them loses nothing
    /// and adds no website on another site, so a bulk merge may do it unasked.
    let isIdentical: Bool
}

/// Every suggestion for one revision of a vault. Holds ids only, so it is safe to keep on the page.
nonisolated struct CredentialMergeIndex: Equatable, Sendable {
    let revision: UInt64
    let suggestions: [CredentialMergeSuggestion]

    var identical: [CredentialMergeSuggestion] {
        suggestions.filter(\.isIdentical)
    }

    /// The suggestions that name `id`.
    func suggestions(containing id: UUID) -> [CredentialMergeSuggestion] {
        suggestions.filter { $0.ids.contains(id) }
    }
}

/// Finds credentials that look like one, in one pass over the vault: each credential is indexed by site, username and site name, so
/// it costs a lookup in a handful of small buckets and not a comparison with every other credential. Nothing is decided here: the
/// user reviews every suggestion, and the merge refuses what it must.
nonisolated enum CredentialMergeSuggestions {
    /// A key shared by more than this many credentials says nothing (an address used on every website), so its bucket is ignored.
    /// ponytail: the cap also hides a real run of more than 50 duplicates; raise it, or key on the password too, if that turns up.
    static let bucketLimit = 50

    private typealias Group = (reason: CredentialMergeReason, members: [Int], isIdentical: Bool)

    /// Who a credential is for: its username, else its passkeys' user name, else its code's, as exact bytes. `isAmbiguous` when the
    /// passkeys name more than one person, so there is no telling.
    static func identity(of account: CredentialAccount) -> (name: Data?, isAmbiguous: Bool) {
        if !account.username.isEmpty {
            return (Data(account.username.utf8), false)
        }
        let names = Set(account.passkeys.map { Data($0.userName.utf8) }.filter { !$0.isEmpty })
        if names.count == 1 {
            return (names.first, false)
        }
        if names.count > 1 {
            return (nil, true)
        }
        return (account.totp?.userName.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, false)
    }

    static func index(for accounts: [CredentialAccount], revision: UInt64) -> CredentialMergeIndex {
        var sites = ImportDuplicates.Sites()
        let facts = accounts.map { Facts($0, &sites) }
        var found: [Group] = []
        found += sameLogin(facts)
        found += splitParts(facts)
        found += relatedSite(facts)
        // The strongest reason names a group; the same members are not listed again under a weaker one.
        var seen = Set<[Int]>()
        let suggestions = found.filter { seen.insert($0.members).inserted }
            .sorted { ($0.reason, $0.members.first ?? 0) < ($1.reason, $1.members.first ?? 0) }
            .enumerated()
            .map { position, group in
                CredentialMergeSuggestion(
                    id: position, reason: group.reason, ids: group.members.map { accounts[$0].id }, isIdentical: group.isIdentical
                )
            }
        return CredentialMergeIndex(revision: revision, suggestions: suggestions)
    }

    // MARK: Facts

    private struct Parts: OptionSet {
        let rawValue: Int
        static let login = Parts(rawValue: 1)
        static let passkey = Parts(rawValue: 2)
        static let code = Parts(rawValue: 4)
    }

    /// What the suggestions compare, read once per credential.
    private struct Facts {
        /// The login's username, as exact bytes. `nil` when there is none.
        let loginUsername: Data?
        /// Who the credential is for (`identity(of:)`).
        let identity: Data?
        /// The passkeys name more than one user, so there is no telling who the credential is for.
        let isAmbiguous: Bool
        let password: Data?
        /// The registrable domains of its websites and passkeys, in order, without repeats.
        let sites: [String]
        /// The site names (a domain without its public suffix) and the folded issuer of its code.
        let labels: Set<String>
        let parts: Parts
        /// The code's secret and settings: two credentials with the same one have the same code.
        let code: Data?

        init(_ account: CredentialAccount, _ sites: inout ImportDuplicates.Sites) {
            loginUsername = account.username.isEmpty ? nil : Data(account.username.utf8)
            (identity, isAmbiguous) = CredentialMergeSuggestions.identity(of: account)
            password = account.password.map { Data($0.utf8) }
            var domains = sites.of(account.origins)
            for passkey in account.passkeys {
                let site = sites.site(ofHost: passkey.rpID)
                if !domains.contains(site) {
                    domains.append(site)
                }
            }
            self.sites = domains
            // A short or numeric first label (`t.co`, an address) is no site name.
            var names = Set(domains.compactMap { $0.split(separator: ".").first.map(String.init) }.filter { $0.count >= 3 && !$0.allSatisfy(\.isNumber) })
            if let issuer = account.totp?.issuer, !issuer.isEmpty {
                names.insert(issuer.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
            }
            labels = names
            var parts: Parts = []
            if account.password != nil || !account.username.isEmpty {
                parts.insert(.login)
            }
            if !account.passkeys.isEmpty {
                parts.insert(.passkey)
            }
            if let totp = account.totp {
                parts.insert(.code)
                code = totp.secret + Data("\(totp.algorithm.rawValue)/\(totp.period)/\(totp.digits)".utf8)
            } else {
                code = nil
            }
            self.parts = parts
        }
    }

    /// Groups indexes that edges join, refusing an edge that would put two different usernames in one group.
    private struct Joiner {
        private var parent: [Int]
        private var identity: [Data?]

        init(_ facts: [Facts]) {
            parent = Array(facts.indices)
            identity = facts.map(\.identity)
        }

        private mutating func root(_ index: Int) -> Int {
            var current = index
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        /// Joins the groups of each edge's two ends, in a fixed order so the result never depends on a dictionary's.
        mutating func join(_ edges: [(Int, Int)]) {
            for (lhs, rhs) in edges.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
                let (first, second) = (root(lhs), root(rhs))
                guard first != second else { continue }
                if let a = identity[first], let b = identity[second], a != b {
                    continue
                }
                parent[second] = first
                identity[first] = identity[first] ?? identity[second]
            }
        }

        /// The groups of two or more, each in index order, ordered by their first member.
        mutating func groups() -> [[Int]] {
            var members: [Int: [Int]] = [:]
            for index in parent.indices {
                members[root(index), default: []].append(index)
            }
            return members.values.filter { $0.count > 1 }.sorted { $0[0] < $1[0] }
        }
    }

    private struct LoginKey: Hashable {
        let site: String
        let username: Data
    }

    // MARK: The three reasons

    private static func sameLogin(_ facts: [Facts]) -> [Group] {
        var buckets: [LoginKey: [Int]] = [:]
        for (index, fact) in facts.enumerated() {
            guard let username = fact.loginUsername else { continue }
            for site in fact.sites {
                buckets[LoginKey(site: site, username: username), default: []].append(index)
            }
        }
        var joiner = Joiner(facts)
        let edges = buckets.values.filter { (2...bucketLimit).contains($0.count) }
            .flatMap { members in members.dropFirst().map { (members[0], $0) } }
        joiner.join(edges)
        return joiner.groups().map { members in
            (.sameLogin, members, isIdentical(members.map { facts[$0] }))
        }
    }

    private static func isIdentical(_ group: [Facts]) -> Bool {
        guard let first = group.first, let password = first.password else { return false }
        let sites = Set(first.sites)
        return group.allSatisfy { $0.password == password && Set($0.sites) == sites }
            && Set(group.compactMap(\.code)).count <= 1
    }

    private static func splitParts(_ facts: [Facts]) -> [Group] {
        var buckets: [String: [Int]] = [:]
        for (index, fact) in facts.enumerated() where !fact.parts.isEmpty && !fact.isAmbiguous {
            for site in fact.sites {
                buckets["site:" + site, default: []].append(index)
            }
            for label in fact.labels {
                buckets["name:" + label, default: []].append(index)
            }
        }
        var edges: [(Int, Int)] = []
        for members in buckets.values where (2...bucketLimit).contains(members.count) {
            for (offset, lhs) in members.enumerated() {
                for rhs in members[(offset + 1)...] where isSplit(facts[lhs], facts[rhs]) {
                    edges.append((min(lhs, rhs), max(lhs, rhs)))
                }
            }
        }
        var joiner = Joiner(facts)
        joiner.join(edges)
        return joiner.groups().map { (.splitParts, $0, false) }
    }

    /// Two credentials that hold different kinds of credential for one person.
    private static func isSplit(_ lhs: Facts, _ rhs: Facts) -> Bool {
        guard lhs.parts.isDisjoint(with: rhs.parts) else { return false }
        return lhs.identity == nil || rhs.identity == nil || lhs.identity == rhs.identity
    }

    private static func relatedSite(_ facts: [Facts]) -> [Group] {
        var buckets: [Data: [Int]] = [:]
        for (index, fact) in facts.enumerated() where !fact.sites.isEmpty && !fact.isAmbiguous {
            if let identity = fact.identity {
                buckets[identity, default: []].append(index)
            }
        }
        var edges: [(Int, Int)] = []
        for members in buckets.values where (2...bucketLimit).contains(members.count) {
            for (offset, lhs) in members.enumerated() {
                for rhs in members[(offset + 1)...] where isRelated(facts[lhs], facts[rhs]) {
                    edges.append((min(lhs, rhs), max(lhs, rhs)))
                }
            }
        }
        var joiner = Joiner(facts)
        joiner.join(edges)
        return joiner.groups().map { (.relatedSite, $0, false) }
    }

    /// The same username on a website of another site, with the same password or a site name in common.
    private static func isRelated(_ lhs: Facts, _ rhs: Facts) -> Bool {
        guard Set(lhs.sites).isDisjoint(with: rhs.sites) else { return false }
        if let password = lhs.password, password == rhs.password {
            return true
        }
        return !lhs.labels.isDisjoint(with: rhs.labels)
    }
}
