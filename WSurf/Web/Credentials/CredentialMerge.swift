// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Why credentials can't be merged. A fixed vocabulary: it names a rule, never a value.
nonisolated enum CredentialMergeError: Error, Equatable, Sendable {
    case fewerThanTwo
    case usernamesDiffer
    /// A pick names a credential that is not being merged, or one that has none of what it is picked for.
    case invalidPicks
    case websiteLimit
    case noteLimit
    case linkLimit
}

/// What the user chose for a merge. Every pick names one of the credentials being merged.
nonisolated struct MergePicks: Equatable, Sendable {
    /// The credential that stays: its id, name, websites and exchange link carry on. The others move to the Trash.
    var survivor: UUID
    /// Whose name the merged credential has.
    var name: UUID
    /// Whose username, password and field descriptions it has, as one unit.
    var login: UUID
    /// Whose verification code it has.
    var code: UUID
    /// The websites on other sites that the user ticked (stored origins). Passwords and codes fill on these too.
    var extraWebsites: Set<String> = []
}

/// What a merge would do, for the sheet to show. Carries no secret: titles, usernames the credential does not conceal, and counts.
nonisolated struct MergePreview: Equatable, Sendable {
    struct Item: Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        /// The name the credential was given, if it has one.
        let displayName: String?
        let hasLogin: Bool
        /// `nil` when the credential has none or conceals it.
        let username: String?
        let usernameIsConcealed: Bool
        let hasPassword: Bool
        let hasCode: Bool
        let passkeyCount: Int
        let noteCount: Int
        /// The credential's own websites.
        let origins: [String]
    }

    let items: [Item]
    /// The logins differ: they have another username or another password, so the user picks whose to keep.
    let loginsDiffer: Bool
    let codesDiffer: Bool
    let namesDiffer: Bool
    /// The survivor's websites before the merge and the merged credential's after it, as stored origins.
    let websitesBefore: [String]
    let websitesAfter: [String]
    /// The websites of the other credentials that are on another site, which the merge adds only when ticked.
    let otherSite: [String]
    /// The hosts the merged password and code will fill on.
    let fillsOn: [String]
    /// The hosts of the other credentials' websites that the merged credential won't have.
    let notKept: [String]
    let passkeysBefore: Int
    let passkeysAfter: Int
    let notesBefore: Int
    let notesAfter: Int
}

/// Merging credentials into one. Pure: the accounts in, the account out, and nothing is written. A merge never loses a value: the
/// credential that stays is replaced by the merged one and the others are removed in the same commit, so everything either stays or
/// goes to the Trash with its history. It never adds a website on another site unless the user ticks it, and never merges different
/// people.
nonisolated enum CredentialMerge {
    /// The picks a merge starts from. The survivor is `chosen`, else the one with an exchange link, else one with a website, else the
    /// one with the most kinds of credential, else the first by title. The name and code are the survivor's, or the first other
    /// credential's that has one; the login is the first that has a password, so a default never leaves a password behind.
    static func defaultPicks(for accounts: [CredentialAccount], survivor chosen: UUID? = nil) -> MergePicks? {
        guard let survivor = accounts.first(where: { $0.id == chosen }) ?? accounts.enumerated().min(by: precedes)?.element else { return nil }
        func owner(_ has: (CredentialAccount) -> Bool) -> UUID? {
            has(survivor) ? survivor.id : accounts.first(where: has)?.id
        }
        return MergePicks(
            survivor: survivor.id,
            name: owner { !($0.displayName ?? "").isEmpty } ?? survivor.id,
            login: owner { $0.password != nil } ?? owner(CredentialExchangeCodec.hasBasicAuthentication) ?? survivor.id,
            code: owner { $0.totp != nil } ?? survivor.id
        )
    }

    /// Whether `lhs` is the better survivor: it has a link to the other app, else a website, else more kinds of credential, else the
    /// earlier title, else comes first.
    private static func precedes(_ lhs: (offset: Int, element: CredentialAccount), _ rhs: (offset: Int, element: CredentialAccount)) -> Bool {
        func rank(_ account: CredentialAccount) -> (link: Int, website: Int, kinds: Int) {
            let kinds = [
                CredentialExchangeCodec.hasBasicAuthentication(account), !account.passkeys.isEmpty, account.totp != nil, account.notes != nil,
            ].filter { $0 }.count
            return (account.exchangeItemID == nil ? 0 : 1, account.origins.isEmpty ? 0 : 1, kinds)
        }
        let (a, b) = (rank(lhs.element), rank(rhs.element))
        if a != b {
            return a > b
        }
        let order = CredentialSummary(lhs.element).title.localizedStandardCompare(CredentialSummary(rhs.element).title)
        return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
    }

    static func preview(_ accounts: [CredentialAccount], picks: MergePicks) throws -> MergePreview {
        let plan = try Plan(accounts, picks)
        let merged = try plan.merged()
        func distinct(_ hashes: [Data]) -> Bool {
            Set(hashes).count > 1
        }
        let withLogin = accounts.filter(CredentialExchangeCodec.hasBasicAuthentication)
        return MergePreview(
            items: accounts.map { account in
                let summary = CredentialSummary(account)
                return MergePreview.Item(
                    id: account.id, title: summary.title, displayName: summary.displayName, hasLogin: summary.hasLogin,
                    username: summary.username, usernameIsConcealed: summary.usernameIsConcealed,
                    hasPassword: account.password != nil, hasCode: account.totp != nil, passkeyCount: account.passkeys.count,
                    noteCount: account.notes?.count ?? 0, origins: account.origins
                )
            },
            loginsDiffer: distinct(try withLogin.map { try CredentialContent.hash(.password($0)) }),
            codesDiffer: distinct(try accounts.filter { $0.totp != nil }.map { try CredentialContent.hash(.totp($0)) }),
            namesDiffer: Set(accounts.compactMap(\.displayName).filter { !$0.isEmpty }).count > 1,
            websitesBefore: plan.survivor.origins,
            websitesAfter: merged.origins,
            otherSite: plan.offered,
            fillsOn: unique(merged.origins.compactMap(host)),
            notKept: unique(plan.offered.filter { !merged.origins.contains($0) }.compactMap(host)),
            passkeysBefore: plan.survivor.passkeys.count,
            passkeysAfter: merged.passkeys.count,
            notesBefore: plan.survivor.notes?.count ?? 0,
            notesAfter: merged.notes?.count ?? 0
        )
    }

    /// The merged credential: the survivor's account with the picked login, code and name, every passkey and note, and the websites
    /// the rules allow. Its id, exchange link, metadata and dates are the survivor's. The others' links to the other app are kept in
    /// `mergedFrom`, with what was last observed from each, so a later import finds the merged credential and not the Trash.
    static func merged(_ accounts: [CredentialAccount], picks: MergePicks) throws -> CredentialAccount {
        try Plan(accounts, picks).merged()
    }

    private static func host(_ origin: String) -> String? {
        URL(string: origin)?.host
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Plan

    /// A merge's inputs, checked once.
    private struct Plan {
        let survivor: CredentialAccount
        /// The credentials that go, in the order given.
        let others: [CredentialAccount]
        let picked: (name: CredentialAccount, login: CredentialAccount, code: CredentialAccount)
        let picks: MergePicks
        /// The other credentials' origins that the merge may add only when ticked, in order.
        let offered: [String]
        /// The other credentials' origins the merge adds without asking.
        private let included: [String]

        init(_ accounts: [CredentialAccount], _ picks: MergePicks) throws {
            guard accounts.count >= 2, Set(accounts.map(\.id)).count == accounts.count else { throw CredentialMergeError.fewerThanTwo }
            func account(_ id: UUID) throws -> CredentialAccount {
                guard let found = accounts.first(where: { $0.id == id }) else { throw CredentialMergeError.invalidPicks }
                return found
            }
            let survivor = try account(picks.survivor)
            // Different people never merge: two usernames, or passkeys that name more than one person and no username to tell.
            let identities = accounts.map(CredentialMergeSuggestions.identity(of:))
            guard !identities.contains(where: { $0.isAmbiguous }), Set(identities.compactMap { $0.name }).count <= 1 else {
                throw CredentialMergeError.usernamesDiffer
            }
            let (name, login, code) = (try account(picks.name), try account(picks.login), try account(picks.code))
            // A pick that has nothing of its kind would drop what another credential has.
            guard CredentialExchangeCodec.hasBasicAuthentication(login) || !accounts.contains(where: CredentialExchangeCodec.hasBasicAuthentication),
                  code.totp != nil || !accounts.contains(where: { $0.totp != nil }) else { throw CredentialMergeError.invalidPicks }
            let others = accounts.filter { $0.id != survivor.id }

            // The password and code fill on the merged credential's websites. The survivor's stay; another credential's website is
            // added when it is on a site the survivor already has (a website or a passkey's relying party), and is otherwise only
            // offered, unticked (D2), even when the login comes from that credential: the sheet lists where it will fill.
            var sites = ImportDuplicates.Sites()
            let anchor = Set(Self.sites(of: survivor, &sites))
            var included: [String] = []
            var offered: [String] = []
            for origin in others.flatMap(\.origins) where !survivor.origins.contains(origin) && !included.contains(origin) && !offered.contains(origin) {
                if sites.site(ofOrigin: origin).map(anchor.contains) == true {
                    included.append(origin)
                } else {
                    offered.append(origin)
                }
            }
            guard picks.extraWebsites.isSubset(of: offered) else { throw CredentialMergeError.invalidPicks }
            self.survivor = survivor
            self.others = others
            self.picked = (name, login, code)
            self.picks = picks
            self.included = included
            self.offered = offered
        }

        private static func sites(of account: CredentialAccount, _ sites: inout ImportDuplicates.Sites) -> [String] {
            sites.of(account.origins) + account.passkeys.map { sites.site(ofHost: $0.rpID) }
        }

        func merged() throws -> CredentialAccount {
            var result = survivor
            if picked.login.id != survivor.id {
                result.username = picked.login.username
                result.password = picked.login.password
                result.basicAuthenticationMetadata = picked.login.basicAuthenticationMetadata
            }
            result.totp = picked.code.totp
            result.displayName = picked.name.displayName
            result.passkeys += others.flatMap(\.passkeys)

            var notes = survivor.notes ?? []
            for note in others.flatMap({ $0.notes ?? [] }) where !notes.contains(where: { $0.text.utf8.elementsEqual(note.text.utf8) }) {
                notes.append(note)
            }
            guard notes.count <= CredentialAccount.noteLimit else { throw CredentialMergeError.noteLimit }
            result.notes = notes.isEmpty ? nil : notes

            let added = included + offered.filter(picks.extraWebsites.contains)
            result.origins += added
            for other in others {
                result.loginURLs += other.loginURLs.filter { url in
                    CredentialAccount.origin(for: url).map(added.contains) == true && !result.loginURLs.contains(url)
                }
            }
            guard result.origins.count <= CredentialAccount.websiteLimit, result.loginURLs.count <= CredentialAccount.websiteLimit else {
                throw CredentialMergeError.websiteLimit
            }

            // Each absorbed item's identity, with what the other app last sent for it, and the items merged into it before. An identity
            // the survivor already holds (two credentials that claimed one item) is kept once.
            var links = survivor.mergedFrom ?? []
            var held = Set([try CredentialExchangeCodec.externalItemID(for: survivor)] + links.map(\.identity))
            for other in others {
                let identity = try CredentialExchangeCodec.externalItemID(for: other)
                let own = MergedItemLink(
                    accountID: other.id, exchangeAccountID: identity.account, exchangeItemID: identity.item,
                    passwordBase: other.passwordBase, totpBase: other.totpBase
                )
                for link in [own] + (other.mergedFrom ?? []) where held.insert(link.identity).inserted {
                    links.append(link)
                }
            }
            guard links.count <= CredentialAccount.mergedFromLimit else { throw CredentialMergeError.linkLimit }
            result.mergedFrom = links.isEmpty ? nil : links
            try result.validate()
            return result
        }
    }
}
