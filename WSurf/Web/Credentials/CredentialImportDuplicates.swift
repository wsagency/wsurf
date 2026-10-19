// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated extension CredentialImportReview {
    /// A saved credential that already holds an incoming item that no saved credential is linked to (spec §13.3). The item is an exact
    /// duplicate: the same registrable site, the same username and the same password, or, with no login, a passkey the vault already
    /// holds. Merging it adds only what the saved credential lacks and never replaces a value.
    struct Duplicate: Sendable, Equatable {
        enum Addition: Sendable, Equatable {
            case websites(Int)
            case passkeys(Int)
            case code
            case notes(Int)
        }

        let target: UUID
        let title: String
        /// What the merge adds to the saved credential. Empty: the item is already saved and brings nothing new.
        let additions: [Addition]
        /// Whether Import records that the other app's item is the saved credential (its identity, and the login or code it brought as
        /// the observed base), so the next import finds it unchanged. Not possible when that credential is linked to another item.
        let linksItem: Bool
        /// The choice of each part of the item when it is merged: what the saved credential lacks goes into it, the rest is kept.
        let mergeChoices: [CredentialIdentity: CredentialImportChoice]
        /// The websites the merge adds: the item's that the saved credential does not have yet and that are on the site the two matched
        /// on (the registrable domain of the login's website, or of the saved passkey's relying party). A saved password is filled on
        /// its credential's websites, so the merge never widens that to a site it was not matched on.
        let origins: [String]
        /// The websites the item lists that the merge does not add, because they are on another site.
        let notAdded: [String]

        /// Whether merging does anything: it adds something, or it links the item.
        var isMergeable: Bool {
            !additions.isEmpty || linksItem
        }

        /// Whether the merge would be the default although the item lists websites it leaves out. That is the user's decision: the
        /// item waits in the group of items that need one, and the merge still adds none of those websites.
        var needsDecision: Bool {
            isMergeable && !notAdded.isEmpty
        }

        /// Whether `records` are decided exactly as the merge decides them. Anything else is the user's own decision for the parts.
        func isApplied(by records: [Record]) -> Bool {
            isMergeable && records.allSatisfy { mergeChoices[$0.incoming] == $0.choice }
        }

        func isApplied(by choices: [CredentialIdentity: CredentialImportChoice]) -> Bool {
            isMergeable && mergeChoices.allSatisfy { choices[$0.key] == $0.value }
        }
    }
}

/// Finds the items of a system import that the vault already holds under another identity, in one pass over the vault and one over the
/// transfer: the vault is indexed by site, username and password, so an item costs a lookup and not a search. Exact matches only; a
/// near match (the same site and username with another password) is left as it was.
nonisolated enum ImportDuplicates {
    struct Found {
        var duplicates: [UUID: CredentialImportReview.Duplicate] = [:]
        /// The parts of those items that equal what is saved. They are unchanged, not new.
        var unchanged: Set<CredentialIdentity> = []
    }

    private struct LoginKey: Hashable {
        let site: String
        let username: Data
        let password: Data
    }

    /// What earlier items of the transfer already put into one saved credential, so that two items cannot both fill its code or
    /// overflow its limits.
    private struct Claim {
        var origins = Set<String>()
        var loginURLs = 0
        var notes = 0
        var code = false
        var linked = false
    }

    private struct Plan {
        var additions: [CredentialImportReview.Duplicate.Addition] = []
        var choices: [CredentialIdentity: CredentialImportChoice] = [:]
        var unchanged: Set<CredentialIdentity> = []
        var linksItem = false
        var origins: [String] = []
        var notAdded: [String] = []
        var claim = Claim()
    }

    /// The registrable domain of each website, remembered per host: a library of thousands of items has far fewer hosts. Internal for
    /// the site groups and the merge suggestions, which group by the same domains.
    struct Sites {
        private var known: [String: String] = [:]

        /// The registrable domain of `host`. An address, `localhost` or a bare public suffix has none, so it stands for itself.
        mutating func site(ofHost host: String) -> String {
            if let cached = known[host] {
                return cached
            }
            let site = RelyingPartyPolicy.registrableDomain(of: host) ?? host.lowercased()
            known[host] = site
            return site
        }

        /// The registrable domain of a website, or `nil` when it has no host.
        mutating func site(ofOrigin origin: String) -> String? {
            URL(string: origin)?.host.map { site(ofHost: $0) }
        }

        /// The distinct registrable domains of `origins`.
        mutating func of(_ origins: [String]) -> [String] {
            var result: [String] = []
            for origin in origins {
                if let site = site(ofOrigin: origin), !result.contains(site) {
                    result.append(site)
                }
            }
            return result
        }
    }

    /// - Parameters:
    ///   - candidates: the transfer's items, in transfer order (the order they are placed in, which decides who fills a shared slot first).
    ///   - accounts: the saved credentials.
    ///   - classes: how each incoming part relates to the vault (`CredentialExchangeCodec.classify`).
    ///   - existing: the saved passkey each incoming passkey that the vault already holds is.
    ///   - isLinked: whether some saved credential already holds the item's exporter identity. Such an item is compared by the import
    ///     itself and never a duplicate.
    ///   - title: what a saved credential is called.
    static func find(
        candidates: [CredentialAccount],
        accounts: [CredentialAccount],
        classes: [CredentialIdentity: CredentialImportClass],
        existing: [CredentialIdentity: CredentialIdentity],
        isLinked: (CredentialAccount) -> Bool,
        title: (UUID) -> String
    ) -> Found {
        // A re-import finds every item linked already, and an empty vault has nothing to be a duplicate of: neither pays for an index.
        let unlinked = candidates.filter { !isLinked($0) }
        guard !accounts.isEmpty, !unlinked.isEmpty else { return Found() }
        var sites = Sites()
        var logins: [LoginKey: [Int]] = [:]
        var position: [UUID: Int] = [:]
        for (at, account) in accounts.enumerated() {
            position[account.id] = at
            guard !account.username.isEmpty, let password = account.password else { continue }
            for site in sites.of(account.origins) {
                logins[LoginKey(site: site, username: Data(account.username.utf8), password: Data(password.utf8)), default: []].append(at)
            }
        }

        var found = Found()
        var claims: [Int: Claim] = [:]
        for candidate in unlinked {
            let identities = CredentialExchangeCodec.identities(in: candidate)
            guard !identities.isEmpty, identities.allSatisfy({ isComparable($0, classes: classes, existing: existing) }) else { continue }
            var matches: [Int] = []
            // The sites the item and the saved credential matched on; the websites the merge adds are on these and no others.
            var passkeySites: Set<String>?
            let candidateSites = sites.of(candidate.origins)
            if CredentialExchangeCodec.hasBasicAuthentication(candidate) {
                guard !candidate.username.isEmpty, let password = candidate.password else { continue }
                var seen = Set<Int>()
                for site in candidateSites {
                    let key = LoginKey(site: site, username: Data(candidate.username.utf8), password: Data(password.utf8))
                    for at in logins[key] ?? [] where seen.insert(at).inserted {
                        matches.append(at)
                    }
                }
            } else {
                // Nothing to compare but a passkey the vault already holds, which names the credential it belongs to.
                let holders = Set(identities.compactMap { identity -> UUID? in
                    guard case .passkey = identity, case let .passkey(owner, _)? = existing[identity] else { return nil }
                    return owner
                })
                if holders.count == 1, let holder = holders.first, let at = position[holder] {
                    matches = [at]
                    // The passkey belongs to its relying party's site, whatever websites the item lists.
                    passkeySites = Set(identities.compactMap { identity -> String? in
                        guard case let .passkey(_, passkeyID) = identity, existing[identity] != nil,
                              let relyingParty = candidate.passkeys.first(where: { $0.id == passkeyID })?.rpID else { return nil }
                        return sites.site(ofHost: relyingParty)
                    })
                }
            }
            // The first saved credential that already holds everything, else the first one the item fits into.
            var best: (at: Int, plan: Plan)?
            for at in matches {
                let matched = passkeySites ?? Set(candidateSites).intersection(sites.of(accounts[at].origins))
                guard let plan = mergePlan(
                    for: candidate, identities, in: accounts[at], matchedSites: matched, claim: claims[at] ?? Claim(), sites: &sites,
                    existing: existing
                ) else {
                    continue
                }
                if best == nil || (plan.additions.isEmpty && !best!.plan.additions.isEmpty) {
                    best = (at, plan)
                }
                if best!.plan.additions.isEmpty {
                    break
                }
            }
            guard let (at, plan) = best else { continue }
            var claim = claims[at] ?? Claim()
            claim.origins.formUnion(plan.claim.origins)
            claim.loginURLs += plan.claim.loginURLs
            claim.notes += plan.claim.notes
            claim.code = claim.code || plan.claim.code
            claim.linked = claim.linked || plan.claim.linked
            claims[at] = claim
            found.duplicates[candidate.id] = CredentialImportReview.Duplicate(
                target: accounts[at].id, title: title(accounts[at].id), additions: plan.additions, linksItem: plan.linksItem,
                mergeChoices: plan.choices, origins: plan.origins, notAdded: plan.notAdded
            )
            found.unchanged.formUnion(plan.unchanged)
        }
        return found
    }

    /// A part that is new here, or a passkey that is saved already. Anything else (removed before, a passkey with another key,
    /// ambiguous) is the review's own business, and the item is left as it is.
    private static func isComparable(
        _ identity: CredentialIdentity, classes: [CredentialIdentity: CredentialImportClass], existing: [CredentialIdentity: CredentialIdentity]
    ) -> Bool {
        switch classes[identity] {
        case .new?:
            return true
        case .unchanged?:
            if case .passkey = identity {
                return existing[identity] != nil
            }
            return false
        default:
            return false
        }
    }

    /// How `candidate` merges into `saved`, or `nil` when it can't without replacing something or exceeding a limit: the saved
    /// credential has another code, or it has no room for the notes or websites. Only websites on `matchedSites` are added.
    private static func mergePlan(
        for candidate: CredentialAccount,
        _ identities: [CredentialIdentity],
        in saved: CredentialAccount,
        matchedSites: Set<String>,
        claim: Claim,
        sites: inout Sites,
        existing: [CredentialIdentity: CredentialIdentity]
    ) -> Plan? {
        let target = saved.id
        var plan = Plan()
        var login: CredentialIdentity?
        var passkeys = 0
        var code = false
        var notes = 0
        for identity in identities {
            switch identity {
            case .password:
                login = identity
                plan.unchanged.insert(identity)
            case .passkey:
                if existing[identity] != nil {
                    plan.choices[identity] = .skip
                } else {
                    plan.choices[identity] = .merge(into: target)
                    passkeys += 1
                }
            case .totp:
                if saved.totp == nil {
                    guard !claim.code else { return nil }
                    plan.choices[identity] = .merge(into: target)
                    code = true
                } else {
                    guard let incoming = try? CredentialContent.hash(.totp(candidate)),
                          let held = try? CredentialContent.hash(.totp(saved)), incoming == held else { return nil }
                    plan.choices[identity] = .skip
                    plan.unchanged.insert(identity)
                }
            case .note:
                let held = saved.notes ?? []
                let missing = (candidate.notes ?? []).filter { note in !held.contains { $0.text.utf8.elementsEqual(note.text.utf8) } }
                if missing.isEmpty {
                    plan.choices[identity] = .skip
                    plan.unchanged.insert(identity)
                } else {
                    guard held.count + claim.notes + missing.count <= CredentialAccount.noteLimit else { return nil }
                    plan.choices[identity] = .merge(into: target)
                    notes = missing.count
                    plan.claim.notes = missing.count
                }
            }
        }
        // The websites go with the merge, which exists when there is a login to link or a part to add.
        let carrier = plan.choices.values.contains(.merge(into: target))
        var websites = 0
        if login != nil || carrier {
            let known = Set(saved.origins).union(claim.origins)
            let fresh = candidate.origins.filter { !known.contains($0) }
            // A saved password is filled on its credential's websites: the item's other sites are left out, and the user decides.
            let origins = fresh.filter { origin in sites.site(ofOrigin: origin).map(matchedSites.contains) ?? false }
            let urls = candidate.loginURLs.filter { url in CredentialAccount.origin(for: url).map(origins.contains) ?? false }
            guard saved.origins.count + claim.origins.count + origins.count <= CredentialAccount.websiteLimit,
                  saved.loginURLs.count + claim.loginURLs + urls.count <= CredentialAccount.websiteLimit else { return nil }
            websites = origins.count
            plan.origins = origins
            plan.notAdded = fresh.filter { !origins.contains($0) }
            plan.claim.origins = Set(origins)
            plan.claim.loginURLs = urls.count
        }
        plan.claim.code = code
        var additions: [CredentialImportReview.Duplicate.Addition] = []
        if passkeys > 0 {
            additions.append(.passkeys(passkeys))
        }
        if code {
            additions.append(.code)
        }
        if notes > 0 {
            additions.append(.notes(notes))
        }
        if websites > 0 {
            additions.append(.websites(websites))
        }
        plan.additions = additions
        plan.linksItem = (login != nil || carrier) && !claim.linked && CredentialExchangeCodec.canLinkDuplicate(candidate, to: saved)
        plan.claim.linked = plan.linksItem
        if let login {
            plan.choices[login] = !additions.isEmpty || plan.linksItem ? .merge(into: target) : .skip
        }
        return plan
    }
}
