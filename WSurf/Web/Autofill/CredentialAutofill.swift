// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WSurfVault

/// What a focused field on a login page is asking for.
nonisolated enum CredentialAutofillField: Sendable {
    case password, totp
}

nonisolated enum CredentialSavePlan: Equatable, Sendable {
    case create, update(UUID), unchanged, ambiguous
}

nonisolated enum CredentialSaveOutcome: Equatable, Sendable {
    case saved, unchanged, needsReview
}

/// What the password dropdown opens with, decided before any secret is read.
nonisolated enum CredentialDropdown: Equatable, Sendable {
    /// The default list: the accounts associated with the page's exact origin.
    case accounts
    /// Nothing for the exact origin, but accounts (for a code field: verification codes) for other websites of its registrable
    /// domain: one row that lists them.
    case siblings(site: String)
    /// Nothing to offer: the dropdown stays closed.
    case empty

    /// Sibling websites are a fallback, for a password field and for a verification-code field alike (the owner's rule: no match here
    /// but other websites of the same domain, offer "Check other logins for *.example.com"). They never extend a list that already has
    /// an exact match, and they are only listed once that row is chosen. `field` decides which siblings were counted (`siblings`).
    static func plan(exact: Int, siblings: Int, origin: String, field: CredentialAutofillField) -> CredentialDropdown {
        if exact > 0 {
            return .accounts
        }
        guard siblings > 0, let site = CredentialAccountSelection.site(of: origin) else { return .empty }
        return .siblings(site: site)
    }
}

/// Account choices for the credential manager. Everything is pure except `commitSave`, the one vault write: callers
/// pass a snapshot taken after an explicit unlock, and a chosen account's secret is only looked up again at delivery.
nonisolated enum CredentialAccountSelection {
    /// The one origin both the autofill session and the vault agree on, or `nil` when they canonicalize differently.
    static func origin(for url: URL) -> String? {
        guard let origin = CredentialAccount.origin(for: url), origin == SavedPassword.origin(for: url) else { return nil }
        return origin
    }

    /// Accounts the user may pick for `field` on `origin`, best first. Only an explicit origin association
    /// qualifies an account; a login URL or TOTP issuer never widens that. Usernames are compared exactly, so
    /// case-distinct and duplicate accounts stay separate choices; the case-insensitive prefix below only filters
    /// what is shown while the user types.
    static func candidates(
        in accounts: [CredentialAccount], origin: String, pageURL: URL?, entered: String?,
        field: CredentialAutofillField, pinned: UUID? = nil
    ) -> [CredentialAccount] {
        let typed = entered.flatMap { $0.isEmpty ? nil : $0 }
        let path = pageURL.flatMap { CredentialAccount.origin(for: $0) == origin ? normalized($0.path) : nil }
        func rank(_ account: CredentialAccount) -> Int {
            let exact = typed != nil && account.username == typed
            let relevant = path.map { path in
                account.loginURLs.contains { CredentialAccount.origin(for: $0) == origin && normalized($0.path) == path }
            } == true
            return (exact ? 0 : 2) + (relevant ? 0 : 1)
        }
        return accounts.filter { account in
            guard account.origins.contains(origin), pinned == nil || account.id == pinned else { return false }
            switch field {
            case .totp:
                return account.totp != nil
            case .password:
                guard account.password != nil || !account.username.isEmpty else { return false }
                guard let typed, pinned == nil else { return true }
                return account.username.range(of: typed, options: [.anchored, .caseInsensitive]) != nil
            }
        }
        .sorted { left, right in
            let (leftRank, rightRank) = (rank(left), rank(right))
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            if left.username != right.username {
                return left.username < right.username
            }
            return left.id.uuidString < right.id.uuidString
        }
    }

    /// The registrable domain two websites must share to be siblings (`example.com` for `https://login.example.com`). `nil` for
    /// an origin that is not HTTPS, an address, a bare public suffix, or when the suffix list can't be read: such a page has none.
    static func site(of origin: String) -> String? {
        guard let url = URL(string: origin), CredentialAccount.origin(for: url) == origin, let host = url.host else { return nil }
        return RelyingPartyPolicy.registrableDomain(of: host)
    }

    /// Accounts saved for another HTTPS website of `origin`'s registrable domain and not for `origin` itself, each with the first
    /// such website: for a password field the ones with a login, for a code field the ones with a verification code. Public suffix
    /// rules decide the domain, so `a.github.io` and `b.github.io` (or a look-alike such as `paypa1.com` of `paypal.com`) are never
    /// siblings. Typing filters as in `candidates`. Only identity is used here: a chosen account's secret is read again at delivery.
    static func siblings(
        in accounts: [CredentialAccount], origin: String, entered: String?, field: CredentialAutofillField = .password
    ) -> [(account: CredentialAccount, website: String)] {
        guard let site = site(of: origin) else { return [] }
        let typed = entered.flatMap { $0.isEmpty ? nil : $0 }
        var sites = ImportDuplicates.Sites()
        var result: [(account: CredentialAccount, website: String)] = []
        for account in accounts where field == .totp ? account.totp != nil : account.password != nil || !account.username.isEmpty {
            if let typed, account.username.range(of: typed, options: [.anchored, .caseInsensitive]) == nil {
                continue
            }
            if let website = siblingWebsite(of: account, for: origin, site: site, sites: &sites) {
                result.append((account: account, website: website))
            }
        }
        return result.sorted { left, right in
            if left.account.username != right.account.username {
                return left.account.username < right.account.username
            }
            if left.website != right.website {
                return left.website < right.website
            }
            return left.account.id.uuidString < right.account.id.uuidString
        }
    }

    /// Whether `account`, chosen from the sibling list, still belongs there when its secret is read.
    static func isSibling(_ account: CredentialAccount, of origin: String) -> Bool {
        guard let site = site(of: origin) else { return false }
        var sites = ImportDuplicates.Sites()
        return siblingWebsite(of: account, for: origin, site: site, sites: &sites) != nil
    }

    /// Whether `origin` may be added to `account`: an account of a sibling website (or, with `anySite`, one the person picked by hand
    /// for this page in Pick Credential…), not saved for `origin` yet, with room under `CredentialAccount.websiteLimit`. `origin` must
    /// be a normalized HTTPS origin. A full account is never made room in by dropping another website.
    static func canAddWebsite(_ origin: String, to account: CredentialAccount, anySite: Bool = false) -> Bool {
        guard account.origins.count < CredentialAccount.websiteLimit else { return false }
        guard anySite else { return isSibling(account, of: origin) }
        return !account.origins.contains(origin) && URL(string: origin).flatMap(CredentialAccount.origin(for:)) == origin
    }

    /// The accounts with `origin` added to the account `id`, and nothing else changed.
    static func addingWebsite(
        _ origin: String, to id: UUID, in accounts: [CredentialAccount], anySite: Bool = false
    ) throws -> [CredentialAccount] {
        guard let index = accounts.firstIndex(where: { $0.id == id }), canAddWebsite(origin, to: accounts[index], anySite: anySite) else {
            throw CredentialVaultError.invalidData
        }
        var accounts = accounts
        accounts[index].origins.append(origin)
        return accounts
    }

    private static func siblingWebsite(
        of account: CredentialAccount, for origin: String, site: String, sites: inout ImportDuplicates.Sites
    ) -> String? {
        guard !account.origins.contains(origin) else { return nil }
        for website in account.origins where website.hasPrefix("https://") && sites.site(ofOrigin: website) == site {
            return website
        }
        return nil
    }

    /// Native picker rows. Each row carries enough context to tell similar accounts apart.
    static func suggestions(
        _ accounts: [CredentialAccount], origin: String, pageURL: URL?, entered: String?,
        field: CredentialAutofillField, pinned: UUID? = nil
    ) -> [AutofillSuggestion] {
        let rows = candidates(in: accounts, origin: origin, pageURL: pageURL, entered: entered, field: field, pinned: pinned)
            .map { (account: $0, title: title($0, origin: origin), detail: detail($0, origin: origin, field: field)) }
        var totals: [String: Int] = [:]
        for row in rows { totals[row.title + "\n" + row.detail, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return rows.map { row in
            let key = row.title + "\n" + row.detail
            seen[key, default: 0] += 1
            let detail = totals[key, default: 1] > 1
                ? [row.detail, String(localized: "Account \(seen[key, default: 1])")].filter { !$0.isEmpty }.joined(separator: " · ")
                : row.detail
            return AutofillSuggestion(id: row.account.id, title: row.title, detail: detail, origin: origin)
        }
    }

    /// `rows` with the one whose credential was used last on this website first, and the others in their order. `usedAt` answers only
    /// for a credential saved for the website (`AutofillLastUsed`); of two equal dates the earlier row wins. Nothing is added or removed.
    static func lastUsedFirst<Row>(_ rows: [Row], usedAt: (Row) -> Date?) -> [Row] {
        var latest: (index: Int, date: Date)?
        for (index, row) in rows.enumerated() {
            if let date = usedAt(row), date > (latest?.date ?? .distantPast) {
                latest = (index, date)
            }
        }
        guard let index = latest?.index, index > 0 else { return rows }
        var rows = rows
        rows.insert(rows.remove(at: index), at: 0)
        return rows
    }

    /// What saving `login` would do. An explicitly selected account only applies to the same username; otherwise
    /// the exact username on this origin decides, and more than one match is never guessed between.
    static func savePlan(
        for login: SavedPassword, origin: String, accountID: UUID?, in accounts: [CredentialAccount]
    ) -> CredentialSavePlan {
        func plan(_ account: CredentialAccount) -> CredentialSavePlan {
            account.password == login.password ? .unchanged : .update(account.id)
        }
        if let accountID, let selected = accounts.first(where: { $0.id == accountID }),
           selected.origins.contains(origin), selected.username == login.username {
            return plan(selected)
        }
        let matches = accounts.filter { $0.origins.contains(origin) && $0.username == login.username }
        switch matches.count {
        case 0:
            return .create
        case 1:
            return plan(matches[0])
        default:
            return .ambiguous
        }
    }

    /// The accounts after `plan`. An update replaces one account's password and nothing else, so neighbours,
    /// passkeys and verification codes are untouched.
    static func applying(
        _ plan: CredentialSavePlan, login: SavedPassword, origin: String, loginURL: URL?, to accounts: [CredentialAccount]
    ) throws -> [CredentialAccount] {
        switch plan {
        case .unchanged:
            return accounts
        case .ambiguous:
            throw CredentialVaultError.invalidData
        case .update(let id):
            guard let index = accounts.firstIndex(where: { $0.id == id }) else { throw CredentialVaultError.invalidData }
            var accounts = accounts
            accounts[index].password = login.password
            return accounts
        case .create:
            guard accounts.count < CredentialVaultLimits.accounts else { throw CredentialVaultError.oversized }
            return accounts + [
                CredentialAccount(
                    id: UUID(), username: login.username, displayName: nil, origins: [origin],
                    loginURLs: loginURL.map { [$0] } ?? [], password: login.password, passkeys: [], totp: nil,
                    exchangeAccountID: nil, exchangeItemID: nil
                ),
            ]
        }
    }

    /// The observed page address reduced to HTTPS host and path, or `nil` when it can't belong to `origin`.
    static func loginURL(for url: URL, origin: String) -> URL? {
        guard let sanitized = try? CredentialAccount.sanitizedLoginURL(url),
              CredentialAccount.origin(for: sanitized) == origin else { return nil }
        return sanitized
    }

    /// A fresh code for `account` at `date`, only when the account explicitly lists `origin`, or (`sibling`, a row the person chose
    /// from "Check other logins") still holds a sibling website of it. The seed stays here.
    static func totpCode(for account: CredentialAccount, origin: String, at date: Date, sibling: Bool = false) -> String? {
        guard account.origins.contains(origin) || sibling && isSibling(account, of: origin), let generator = account.totp else { return nil }
        return try? TOTP.code(generator, at: date.timeIntervalSince1970).value
    }

    /// Writes `login` into `snapshot`'s vault only for the account the user was shown (`offered`). Whatever the user
    /// typed, a different target (another stored username, a new username after an update was shown, an account that
    /// appeared since the offer) writes nothing and asks for a fresh review of that exact account instead.
    @MainActor
    static func commitSave(
        _ login: SavedPassword, origin: String, offered: CredentialSavePlan?, loginURL: URL?,
        snapshot: StoreSnapshot, manager: CredentialManager, epoch: UInt64
    ) async throws -> CredentialSaveOutcome {
        let selected: UUID? = if case .update(let id) = offered { id } else { nil }
        let plan = savePlan(for: login, origin: origin, accountID: selected, in: snapshot.accounts)
        guard plan != .unchanged else { return .unchanged }
        guard plan == offered else { return .needsReview }
        let accounts = try applying(plan, login: login, origin: origin, loginURL: loginURL, to: snapshot.accounts)
        // Only the offered account changes; a new one is not stored yet.
        _ = try await manager.commit(
            accounts, expectedRevision: snapshot.revision, authorizedEpoch: epoch, changing: Set([selected].compactMap { $0 })
        )
        return .saved
    }

    private static func normalized(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    static func title(_ account: CredentialAccount, origin: String) -> String {
        if !account.username.isEmpty {
            return account.username
        }
        if let name = account.displayName, !name.isEmpty {
            return name
        }
        return origin
    }

    private static func detail(_ account: CredentialAccount, origin: String, field: CredentialAutofillField) -> String {
        var parts: [String] = []
        if let name = account.displayName, !name.isEmpty, name != account.username {
            parts.append(name)
        }
        if let path = account.loginURLs.first(where: { CredentialAccount.origin(for: $0) == origin })?.path,
           path != "", path != "/" {
            parts.append(path)
        }
        switch field {
        case .totp:
            parts.append(String(localized: "Verification code"))
        case .password:
            if !account.passkeys.isEmpty { parts.append(String(localized: "Passkey")) }
            if account.password == nil { parts.append(String(localized: "No saved password")) }
        }
        return parts.joined(separator: " · ")
    }
}

nonisolated extension AutofillSuggestion {
    init(id: UUID, title: String, detail: String, origin: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.origin = origin
        month = nil
        year = nil
    }
}
