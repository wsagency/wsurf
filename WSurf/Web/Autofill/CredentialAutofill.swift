// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

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
            return AutofillSuggestion(accountID: row.account.id, title: row.title, detail: detail, origin: origin)
        }
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

    /// A fresh code for `account` at `date`, only when the account explicitly lists `origin`. The seed stays here.
    static func totpCode(for account: CredentialAccount, origin: String, at date: Date) -> String? {
        guard account.origins.contains(origin), let generator = account.totp else { return nil }
        return try? TOTP.code(generator, at: date.timeIntervalSince1970).value
    }

    /// Writes `login` into `snapshot`'s vault only for the account the user was shown (`offered`). Whatever the user
    /// typed, a different target (another stored username, a new username after an update was shown, an account that
    /// appeared since the offer) writes nothing and asks for a fresh review of that exact account instead.
    @MainActor
    static func commitSave(
        _ login: SavedPassword, origin: String, offered: CredentialSavePlan?, loginURL: URL?,
        snapshot: VaultSnapshot, manager: CredentialManager, epoch: UInt64
    ) async throws -> CredentialSaveOutcome {
        let selected: UUID? = if case .update(let id) = offered { id } else { nil }
        let plan = savePlan(for: login, origin: origin, accountID: selected, in: snapshot.accounts)
        guard plan != .unchanged else { return .unchanged }
        guard plan == offered else { return .needsReview }
        let accounts = try applying(plan, login: login, origin: origin, loginURL: loginURL, to: snapshot.accounts)
        _ = try await manager.commit(accounts, expectedRevision: snapshot.revision, authorizedEpoch: epoch)
        return .saved
    }

    private static func normalized(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    private static func title(_ account: CredentialAccount, origin: String) -> String {
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
    init(accountID: UUID, title: String, detail: String, origin: String) {
        id = accountID
        self.title = title
        self.detail = detail
        self.origin = origin
        month = nil
        year = nil
    }
}
