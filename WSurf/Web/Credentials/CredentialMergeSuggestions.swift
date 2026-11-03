// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Why two or more credentials look like one: the same account on the same website. A website is a host and port (`siteKey`), so
/// `www.example.com` is `example.com` but `dev5.example.com` is not `htz.example.com`; the same password alone is never a reason.
nonisolated enum CredentialMergeReason: Int, Comparable, Sendable {
    /// The same website and the same username.
    case sameLogin
    /// The same website and one username with copy numbers, as exports name duplicates: "ada@example.test (1)".
    case numberedCopies
    /// A password, a passkey and a verification code for one person on the same website, saved apart.
    case splitParts

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A group of credentials the vault suggests merging. It names them and the reason, never a value.
nonisolated struct CredentialMergeSuggestion: Equatable, Identifiable, Sendable {
    let reason: CredentialMergeReason
    /// At least two credentials, in the order the vault lists them.
    let ids: [UUID]
    /// Every member has the same login, no member's code differs, and their websites are on the same sites: merging them loses nothing
    /// and adds no website on another site, so a bulk merge may do it unasked.
    let isIdentical: Bool

    /// Its members, in any order, name it: it keeps its identity when the suggestions are computed again after a merge elsewhere,
    /// even if a write moved its members in the vault's order.
    var id: Set<UUID> {
        Set(ids)
    }
}

/// Every suggestion for one revision of a vault. Holds ids only, so it is safe to keep on the page.
nonisolated struct CredentialMergeIndex: Equatable, Sendable {
    let revision: UInt64
    let suggestions: [CredentialMergeSuggestion]
    /// The credentials the person said are not the same (Not the Same), as groups: the live credentials that remembered pairs join,
    /// each in vault order, ordered by their first member. No suggestion puts two credentials of a pair together.
    var dismissed: [[UUID]] = []

    var identical: [CredentialMergeSuggestion] {
        suggestions.filter(\.isIdentical)
    }

    /// The suggestions that name `id`.
    func suggestions(containing id: UUID) -> [CredentialMergeSuggestion] {
        suggestions.filter { $0.ids.contains(id) }
    }
}

/// Finds credentials that look like one, in one pass over the vault: each credential is indexed by website and username, so it costs a
/// lookup in a handful of small buckets and not a comparison with every other credential. Nothing is decided here: the user reviews
/// every suggestion, says Not the Same to any, and the merge refuses what it must.
nonisolated enum CredentialMergeSuggestions {
    /// A key shared by more than this many credentials says nothing (an address used on every website), so its bucket is ignored.
    /// ponytail: the cap also hides a real run of more than 50 duplicates; raise it, or key on the password too, if that turns up.
    static let bucketLimit = 50

    private typealias Group = (reason: CredentialMergeReason, members: [Int], isIdentical: Bool)

    /// Who a credential is for: its username (without a copy number, `baseUsername`), else its passkeys' user name, else its
    /// code's, as exact bytes. `isAmbiguous` when the passkeys name more than one person, so there is no telling.
    static func identity(of account: CredentialAccount) -> (name: Data?, isAmbiguous: Bool) {
        if !account.username.isEmpty {
            return (Data(baseUsername(account.username).utf8), false)
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

    /// `username` without the copy number an export adds to a duplicate: a trailing space and one to four digits in parentheses.
    /// "ada@example.test (2)" is "ada@example.test"; a username that is only a number in parentheses keeps it.
    static func baseUsername(_ username: String) -> String {
        guard username.hasSuffix(")"), let open = username.lastIndex(of: "("), open > username.startIndex else { return username }
        let digits = username[username.index(after: open)..<username.index(before: username.endIndex)]
        let space = username.index(before: open)
        guard (1...4).contains(digits.count), digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber), username[space] == " ",
              space > username.startIndex else { return username }
        return String(username[..<space])
    }

    /// The website a credential is for, as suggestions compare it: the host in lower case without a leading "www.", and the port when
    /// the address names one. `www.example.com` and `example.com` are one website; `dev5.example.com` and `htz.example.com` are two.
    static func siteKey(host: String, port: Int? = nil) -> String {
        var name = host.lowercased()
        if name.hasPrefix("www."), name.dropFirst(4).contains(".") {
            name.removeFirst(4)
        }
        return port.map { "\(name):\($0)" } ?? name
    }

    /// Each credential merged into a live one, by the id it had, mapped to the live one that holds it (`mergedFrom`, which a merge
    /// carries on, so one step is enough).
    static func survivors(in accounts: [CredentialAccount]) -> [UUID: UUID] {
        var survivors: [UUID: UUID] = [:]
        for account in accounts {
            for link in account.mergedFrom ?? [] {
                survivors[link.accountID] = account.id
            }
        }
        return survivors
    }

    static func index(for accounts: [CredentialAccount], revision: UInt64) -> CredentialMergeIndex {
        var domains = ImportDuplicates.Sites()
        let facts = accounts.map { Facts($0, &domains) }
        let apart = Apart(accounts)
        var found: [Group] = []
        found += sameLogin(facts, apart)
        found += splitParts(facts, apart)
        // The strongest reason names a group; the same members are not listed again under a weaker one.
        var seen = Set<[Int]>()
        let suggestions = found.filter { seen.insert($0.members).inserted }
            .sorted { ($0.reason, $0.members.first ?? 0) < ($1.reason, $1.members.first ?? 0) }
            .map { group in
                CredentialMergeSuggestion(reason: group.reason, ids: group.members.map { accounts[$0].id }, isIdentical: group.isIdentical)
            }
        return CredentialMergeIndex(revision: revision, suggestions: suggestions, dismissed: apart.groups(in: accounts))
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
        /// The login's username without a copy number, as exact bytes. `nil` when there is none.
        let loginUsername: Data?
        /// The login's username as stored, so copies with different numbers are told from plain repeats.
        let storedUsername: String
        /// Who the credential is for (`identity(of:)`).
        let identity: Data?
        /// The passkeys name more than one user, so there is no telling who the credential is for.
        let isAmbiguous: Bool
        let password: Data?
        /// Its websites and its passkeys' sites (`siteKey`), in order, without repeats.
        let sites: [String]
        /// The site name of each of its sites (the registrable domain without its public suffix), for a code saved without a website.
        let names: [(name: String, site: String)]
        /// The folded issuer of its code, only when it has no website: all such a code can be matched by.
        let issuer: String?
        let parts: Parts
        /// The code's secret and settings: two credentials with the same one have the same code.
        let code: Data?

        init(_ account: CredentialAccount, _ domains: inout ImportDuplicates.Sites) {
            loginUsername = account.username.isEmpty ? nil : Data(CredentialMergeSuggestions.baseUsername(account.username).utf8)
            storedUsername = account.username
            (identity, isAmbiguous) = CredentialMergeSuggestions.identity(of: account)
            password = account.password.map { Data($0.utf8) }
            var sites: [String] = []
            var names: [(name: String, site: String)] = []
            func add(_ host: String, port: Int?) {
                let site = CredentialMergeSuggestions.siteKey(host: host, port: port)
                guard !sites.contains(site) else { return }
                sites.append(site)
                // A short or numeric first label (`t.co`, an address) is no site name.
                if let name = domains.site(ofHost: host.lowercased()).split(separator: ".").first.map(String.init), name.count >= 3,
                   !name.allSatisfy(\.isNumber) {
                    names.append((name, site))
                }
            }
            for origin in account.origins {
                if let url = URL(string: origin), let host = url.host, !host.isEmpty {
                    add(host, port: url.port)
                }
            }
            for passkey in account.passkeys {
                add(passkey.rpID, port: nil)
            }
            self.sites = sites
            self.names = names
            let issuer = sites.isEmpty ? account.totp?.issuer ?? "" : ""
            self.issuer = issuer.isEmpty ? nil : issuer.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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

    /// Groups indexes that edges join, refusing an edge that would put two different usernames, or two credentials the person said
    /// are not the same, in one group.
    private struct Joiner {
        private var parent: [Int]
        private var identity: [Data?]
        private let apart: Apart
        /// Each group's members by its root, kept only while some pair is apart.
        private var members: [Int: [Int]] = [:]

        init(_ facts: [Facts], _ apart: Apart) {
            parent = Array(facts.indices)
            identity = facts.map(\.identity)
            self.apart = apart
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
                if !apart.isEmpty {
                    let left = members[first] ?? [first], right = members[second] ?? [second]
                    guard !left.contains(where: { one in right.contains { apart.contains(one, $0) } }) else { continue }
                    members[first] = left + right
                    members[second] = nil
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

    // MARK: Not the same

    /// The pairs of live credentials the person said are not the same: each credential's `notSameAs`, an id merged into a live credential
    /// read as that one, so a dismissal outlives a merge of either side. Both orders are kept, so a lookup is one hash.
    struct Apart {
        private struct Pair: Hashable {
            let one: UUID
            let other: UUID
        }

        private var pairs = Set<Pair>()
        /// The credentials' ids by their index in the vault, so the joiner can ask by index.
        private let ids: [UUID]

        init(_ accounts: [CredentialAccount]) {
            ids = accounts.map(\.id)
            guard accounts.contains(where: { $0.notSameAs != nil }) else { return }
            let survivors = CredentialMergeSuggestions.survivors(in: accounts)
            let live = Set(ids)
            for account in accounts {
                for other in account.notSameAs ?? [] {
                    let resolved = survivors[other] ?? other
                    guard resolved != account.id, live.contains(resolved) else { continue }
                    pairs.insert(Pair(one: account.id, other: resolved))
                    pairs.insert(Pair(one: resolved, other: account.id))
                }
            }
        }

        var isEmpty: Bool {
            pairs.isEmpty
        }

        /// Whether the credentials at these two vault indexes were said to be not the same.
        func contains(_ lhs: Int, _ rhs: Int) -> Bool {
            pairs.contains(Pair(one: ids[lhs], other: ids[rhs]))
        }

        /// The groups the pairs join, each in vault order, ordered by their first member.
        func groups(in accounts: [CredentialAccount]) -> [[UUID]] {
            guard !pairs.isEmpty else { return [] }
            var parent: [UUID: UUID] = [:]
            for pair in pairs {
                parent[pair.one] = pair.one
            }
            func root(_ id: UUID) -> UUID {
                var current = id
                while let next = parent[current], next != current {
                    current = next
                }
                return current
            }
            for pair in pairs {
                let (one, other) = (root(pair.one), root(pair.other))
                if one != other {
                    parent[other] = one
                }
            }
            var members: [UUID: [UUID]] = [:]
            var order: [UUID] = []
            for account in accounts where parent[account.id] != nil {
                let group = root(account.id)
                if members[group] == nil {
                    order.append(group)
                }
                members[group, default: []].append(account.id)
            }
            return order.compactMap { members[$0] }
        }
    }

    // MARK: The two rules

    private static func sameLogin(_ facts: [Facts], _ apart: Apart) -> [Group] {
        var buckets: [LoginKey: [Int]] = [:]
        for (index, fact) in facts.enumerated() {
            guard let username = fact.loginUsername else { continue }
            for site in fact.sites {
                buckets[LoginKey(site: site, username: username), default: []].append(index)
            }
        }
        var joiner = Joiner(facts, apart)
        joiner.join(buckets.values.filter { (2...bucketLimit).contains($0.count) }.flatMap { edges(among: $0, apart) })
        return joiner.groups().map { members in
            let numbered = Set(members.map { Data(facts[$0].storedUsername.utf8) }).count > 1
            return (numbered ? .numberedCopies : .sameLogin, members, isIdentical(members.map { facts[$0] }))
        }
    }

    /// Edges that join `members` of one bucket: from the first to each other, or, once some pair is apart, between every two, so a
    /// refused pair does not keep the others of the bucket apart.
    private static func edges(among members: [Int], _ apart: Apart) -> [(Int, Int)] {
        guard !apart.isEmpty else { return members.dropFirst().map { (members[0], $0) } }
        return members.indices.flatMap { lhs in members[(lhs + 1)...].map { (members[lhs], $0) } }
    }

    private static func isIdentical(_ group: [Facts]) -> Bool {
        guard let first = group.first, let password = first.password else { return false }
        let sites = Set(first.sites)
        return group.allSatisfy { $0.password == password && Set($0.sites) == sites }
            && Set(group.compactMap(\.code)).count <= 1
    }

    private static func splitParts(_ facts: [Facts], _ apart: Apart) -> [Group] {
        var bySite: [String: [Int]] = [:]
        var byName: [String: [(index: Int, site: String)]] = [:]
        for (index, fact) in facts.enumerated() where !fact.parts.isEmpty && !fact.isAmbiguous {
            for site in fact.sites {
                bySite[site, default: []].append(index)
            }
            for (name, site) in fact.names {
                byName[name, default: []].append((index, site))
            }
        }
        var edges: [(Int, Int)] = []
        for members in bySite.values where (2...bucketLimit).contains(members.count) {
            for (offset, lhs) in members.enumerated() {
                for rhs in members[(offset + 1)...] where isSplit(facts[lhs], facts[rhs]) {
                    edges.append((min(lhs, rhs), max(lhs, rhs)))
                }
            }
        }
        // A code saved without a website is matched by its issuer, and only when the issuer names one website.
        for (index, fact) in facts.enumerated() where !fact.parts.isEmpty && !fact.isAmbiguous {
            guard let issuer = fact.issuer, let named = byName[issuer], named.count <= bucketLimit else { continue }
            let fits = named.filter { $0.index != index && isSplit(fact, facts[$0.index]) }
            guard Set(fits.map(\.site)).count == 1 else { continue }
            edges += fits.map { (min(index, $0.index), max(index, $0.index)) }
        }
        // A credential that names nobody joins only when everything it fits names one person; else there is no telling whose it is.
        var people: [Int: Set<Data>] = [:]
        for (lhs, rhs) in edges {
            if facts[lhs].identity == nil, let person = facts[rhs].identity {
                people[lhs, default: []].insert(person)
            }
            if facts[rhs].identity == nil, let person = facts[lhs].identity {
                people[rhs, default: []].insert(person)
            }
        }
        edges.removeAll { (people[$0.0]?.count ?? 0) > 1 || (people[$0.1]?.count ?? 0) > 1 }
        var joiner = Joiner(facts, apart)
        joiner.join(edges)
        return joiner.groups().map { (.splitParts, $0, false) }
    }

    /// Two credentials that hold different kinds of credential for one person.
    private static func isSplit(_ lhs: Facts, _ rhs: Facts) -> Bool {
        guard lhs.parts.isDisjoint(with: rhs.parts) else { return false }
        return lhs.identity == nil || rhs.identity == nil || lhs.identity == rhs.identity
    }
}
