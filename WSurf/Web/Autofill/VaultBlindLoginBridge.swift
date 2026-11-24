// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Browser-owned Vault blind-fill bridge used by external-connection login approval (`requestUserLogin`) and anonymized
/// `vaultHint` presence checks.
///
/// All Vault reads remain inside `WSurf/Web/Autofill/` so `WSurf/MCP/` never touches Vault stores, never loads passwords
/// across module boundaries, and never receives saved credentials. Only human-visible sheet labels leave this type;
/// approved credentials are written directly into the page DOM via `PageDriver.fillVaultLogin`.
@MainActor
enum VaultBlindLoginBridge {
    struct Summary: Equatable, Sendable {
        let id: UUID
        /// Human-visible label shown ONLY in WSurf's native approval sheet (never returned to MCP clients).
        let label: String
        let vaultID: UUID
        let revision: UInt64
        let epoch: UInt64
    }

    /// Returns matching saved-login summaries for `(tab, url)` from unlocked vaults in `tab`'s scope, ordered with any
    /// `accountHint` matches first. Uses `autofillCandidates()` so no secret is decrypted during listing.
    static func savedSummaries(
        in browser: BrowserModel, tab: BrowserTab, url: URL, accountHint: String?
    ) async -> [Summary] {
        guard !tab.isPrivate, let origin = CredentialAccountSelection.origin(for: url) else { return [] }
        let scope = browser.vaultScope(for: tab)
        let listing = (try? await scope.listing()) ?? []
        let unlocked = scope.unlockedManagers
        var results: [(summary: Summary, matchKey: String)] = []
        for vault in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            guard let manager = unlocked.first(where: { $0.vaultID == vault.vaultID }),
                let epoch = manager.authorizationEpoch,
                let projection = try? await manager.autofillCandidates(),
                manager.authorizationEpoch == epoch
            else { continue }
            for candidate in projection.candidates where candidate.hasPassword && candidate.origins.contains(origin) {
                let label: String
                if !candidate.usernameIsConcealed, !candidate.username.isEmpty {
                    label = candidate.username
                } else if let display = candidate.displayName, !display.isEmpty {
                    label = display
                } else {
                    label = url.host() ?? origin
                }
                let summary = Summary(
                    id: candidate.id,
                    label: label,
                    vaultID: manager.vaultID,
                    revision: projection.revision,
                    epoch: epoch)
                let matchKey = (label + " " + (candidate.usernameIsConcealed ? "" : candidate.username)).lowercased()
                results.append((summary, matchKey))
            }
        }
        guard let hint = accountHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !hint.isEmpty else {
            return results.map(\.summary)
        }
        return results.sorted { lhs, rhs in
            let leftMatch = lhs.matchKey.contains(hint)
            let rightMatch = rhs.matchKey.contains(hint)
            return leftMatch && !rightMatch
        }.map(\.summary)
    }

    /// Reads the single user-approved login from its unlocked vault and writes it directly into `view` without returning
    /// credentials to the caller. Calls `registerSecret` with the password before DOM fill; if registration fails (e.g.
    /// the password cannot be scrubbed safely), refuses the fill BEFORE injecting anything into the page.
    static func blindFill(
        account: Summary,
        submit: Bool,
        in browser: BrowserModel,
        tab: BrowserTab,
        view: BrowserPage,
        url: URL,
        registerSecret: @MainActor (String) -> Bool
    ) async -> PageDriver.VaultFillResult? {
        guard !tab.isPrivate, let origin = CredentialAccountSelection.origin(for: url) else { return nil }
        let scope = browser.vaultScope(for: tab)
        guard let manager = scope.unlockedManagers.first(where: { $0.vaultID == account.vaultID }),
            manager.authorizationEpoch == account.epoch,
            let login = try? await manager.autofillLogin(
                accountID: account.id, field: .password, expectedRevision: account.revision),
            manager.authorizationEpoch == account.epoch,
            login.candidate.origins.contains(origin),
            let password = login.password
        else { return nil }
        guard let liveURL = view.url, CredentialAccountSelection.origin(for: liveURL) == origin else {
            return PageDriver.VaultFillResult(
                ok: false, documentID: nil, fieldsFilled: [], submitted: false,
                error: "The page navigated to another origin before credentials could be filled.")
        }
        if !password.isEmpty, !registerSecret(password) {
            return PageDriver.VaultFillResult(
                ok: false, documentID: nil, fieldsFilled: [], submitted: false,
                error: "Could not register the saved password for output scrubbing. Nothing was filled.")
        }
        return await PageDriver.fillVaultLogin(
            username: login.candidate.username,
            password: password,
            submit: submit,
            expectedOrigin: SitePermissions.origin(for: url),
            in: view)
    }
}
