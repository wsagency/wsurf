// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The one-time move of the passwords that WSurf kept in its own Keychain list, before Credential Manager existed, into a
/// profile's vault. This type holds the rules; the settings page drives them and the import review shows every step.
///
/// The list is never written again. Its only deletion is `erase`, which needs `State.imported` (an import committed, or nothing
/// left to import) and the counts the user confirmed. The state moves forward only: `pending`, `imported`, `done`. Every step
/// can be repeated after a quit or a crash, and a list that is already gone resolves to `done`.
///
/// Private browsing never had a list, so it never reads, prompts or stores anything here.
@MainActor
struct LegacyPasswordMigration {
    enum State: String, Sendable {
        case pending, imported, done

        fileprivate var rank: Int {
            switch self {
            case .pending:
                0
            case .imported:
                1
            case .done:
                2
            }
        }
    }

    /// Why `erase` refused. Nothing was erased.
    enum Failure: Error, Equatable {
        /// The import is not complete, so the list is still the only copy.
        case notImported
        /// The old list or Credential Manager is not what the confirmation described.
        case changed
    }

    /// What the removal confirmation states about the old list: how many passwords it holds and how many of them no unlocked
    /// vault of the profile holds yet.
    struct Tally: Equatable, Sendable {
        let total: Int
        let missing: Int
    }

    static let stateKey = "autofill.legacyPasswords.state"
    static let promptedKey = "autofill.legacyPasswords.prompted"

    let profile: Profile
    /// The old list, read and erased only: nothing in WSurf writes it.
    var vault: SecureAutofillVault<SavedPassword>
    /// Clears the "never save" digests the old list kept. They are one-way digests of sites, so they can't become the vault's own list.
    var resetBlockedSites: @Sendable (UUID) -> Void = { try? AutofillSaveIndex.resetBlocks(kind: .password, profileID: $0) }
    private let injectedDefaults: UserDefaults?

    init(profile: Profile, vault: SecureAutofillVault<SavedPassword>? = nil, defaults: UserDefaults? = nil) {
        self.profile = profile
        self.vault = vault ?? AutofillVaults.legacyPasswords(for: profile.id)
        injectedDefaults = defaults
    }

    /// The profile's own settings. Resolved only for a profile that can have a list: a private context has no settings domain.
    private var defaults: UserDefaults {
        injectedDefaults ?? ProfileSettingsStore.defaults(for: profile)
    }

    // MARK: State

    /// The stored state, without asking the Keychain.
    var storedState: State? {
        guard !profile.isPrivate else { return .done }
        return defaults.string(forKey: Self.stateKey).flatMap(State.init(rawValue:))
    }

    /// Where the move stands. Asks the Keychain whether the list exists, which reads no secret and never prompts, so it is safe at
    /// launch. A list that is gone means there is nothing to move, whatever was stored. A Keychain error says nothing about the list:
    /// it answers what is stored (or `pending`) and persists nothing.
    func state() async -> State {
        guard !profile.isPrivate else { return .done }
        let stored = storedState
        if stored == .done {
            return .done
        }
        switch try? await vault.hasStoredRecords() {
        case false?:
            advance(to: .done)
            return .done
        case true?:
            let state = stored ?? .pending
            advance(to: state)
            return state
        case nil:
            return stored ?? .pending
        }
    }

    /// Whether the Keychain confirmed that a list exists and the move is not finished. A query error is not a confirmation.
    func hasListToMove() async -> Bool {
        guard !profile.isPrivate, storedState != .done else { return false }
        return (try? await vault.hasStoredRecords()) == true
    }

    /// The import step is complete: every password of the list is in Credential Manager, or the user decided what to skip. The list
    /// stays until `erase`. Never moves a finished migration back.
    func markImported() {
        advance(to: .imported)
    }

    /// Whether the user has been asked about the move in this profile, and records that they now have been.
    func claimPrompt() -> Bool {
        guard !profile.isPrivate, defaults.bool(forKey: Self.promptedKey) == false else { return false }
        defaults.set(true, forKey: Self.promptedKey)
        return true
    }

    private func advance(to next: State) {
        guard !profile.isPrivate, (storedState?.rank ?? -1) < next.rank else { return }
        defaults.set(next.rawValue, forKey: Self.stateKey)
    }

    // MARK: Reading

    /// The whole list. The system asks the user to authenticate once for `session`; callers keep the result for one operation only.
    func records(using session: AutofillAuthenticationSession) async throws -> [SavedPassword] {
        try await vault.records(using: session)
    }

    func makeSession() async -> AutofillAuthenticationSession {
        await vault.makeAuthenticationSession()
    }

    /// The accounts of every unlocked vault of the profile. A vault that locks while it is read fails the read.
    func unlockedAccounts() async throws -> [CredentialAccount] {
        var accounts: [CredentialAccount] = []
        for manager in CredentialManager.unlockedManagers(for: profile) {
            accounts += try await manager.snapshot().accounts
        }
        return accounts
    }

    /// The entries no vault account holds. An entry is held only by an account that lists its website and has exactly its username
    /// and exactly its password, compared as UTF-8 bytes: "é" and "e" with U+0301 are different usernames to a website.
    static func missing(_ legacy: [SavedPassword], in accounts: [CredentialAccount]) -> [SavedPassword] {
        var byOrigin: [String: [CredentialAccount]] = [:]
        for account in accounts where account.password != nil {
            for origin in Set(account.origins) {
                byOrigin[origin, default: []].append(account)
            }
        }
        return legacy.filter { entry in
            !(byOrigin[entry.origin] ?? []).contains {
                $0.username.utf8.elementsEqual(entry.username.utf8) && $0.password?.utf8.elementsEqual(entry.password.utf8) == true
            }
        }
    }

    func tally(using session: AutofillAuthenticationSession) async throws -> Tally {
        let legacy = try await records(using: session)
        return Tally(total: legacy.count, missing: Self.missing(legacy, in: try await unlockedAccounts()).count)
    }

    // MARK: Removal

    /// Deletes the old list after the user confirmed the removal dialog that stated `expectedTotal` and `expectedMissing`. Both are
    /// read again first: if either differs, or the move is not `imported`, nothing is erased.
    func erase(using session: AutofillAuthenticationSession, expectedTotal: Int, expectedMissing: Int) async throws {
        guard !profile.isPrivate else { throw AutofillVaultError.privateBrowsing }
        guard storedState == .imported else { throw Failure.notImported }
        let current = try await tally(using: session)
        guard current == Tally(total: expectedTotal, missing: expectedMissing) else { throw Failure.changed }
        try await vault.erase()
        let reset = resetBlockedSites, profileID = profile.id
        await Task.detached { reset(profileID) }.value
        advance(to: .done)
    }
}
