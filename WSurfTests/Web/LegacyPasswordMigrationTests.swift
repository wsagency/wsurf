// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Synchronization
import Testing

@testable import WSurf

// Synthetic data only: example.test websites, invented usernames and passwords. The old list lives in `MemoryAutofillStorage`, the
// vault accounts in a fixture vault of a throwaway profile, and the state in a throwaway defaults suite. Nothing here reaches the
// Keychain, the real vault or the app's own preferences.
@MainActor
struct LegacyPasswordMigrationTests {
    private final class ResetLog: Sendable {
        let ids = Mutex<[UUID]>([])
    }

    private final class Harness {
        let profile: Profile
        let storage = MemoryAutofillStorage()
        let vault: SecureAutofillVault<SavedPassword>
        let defaults: UserDefaults
        private let suiteName = AppDatabase.defaultsSuite("LegacyPasswordMigrationTests.\(UUID().uuidString)")
        /// The profiles whose "never save" digests were cleared.
        private let log = ResetLog()
        var resets: [UUID] {
            log.ids.withLock { $0 }
        }

        init(profile: Profile = Profile(id: UUID(), name: "Legacy", symbol: "key", color: .blue)) throws {
            self.profile = profile
            vault = SecureAutofillVault<SavedPassword>(profileID: profile.id, kind: "passwords", reason: "Test", storage: storage)
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        func migration() -> LegacyPasswordMigration {
            var migration = LegacyPasswordMigration(profile: profile, vault: vault, defaults: defaults)
            migration.resetBlockedSites = { [log] id in log.ids.withLock { $0.append(id) } }
            return migration
        }

        func cleanUp() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }

        /// Puts `entries` in the old list, the way the previous builds did.
        func seed(_ entries: [SavedPassword]) async throws {
            _ = try await vault.update { _ in entries }
        }
    }

    private func with(_ body: (Harness) async throws -> Void) async throws {
        let harness = try Harness()
        defer { harness.cleanUp() }
        try await body(harness)
    }

    private func entry(_ username: String, _ password: String, website: String = "https://example.test") throws -> SavedPassword {
        try SavedPassword(website: website, username: username, password: password)
    }

    private func account(
        _ username: String, _ password: String?, origins: [String] = ["https://example.test"]
    ) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: nil, origins: origins, loginURLs: [], password: password,
            passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    // MARK: - Detection

    @Test func absentLegacyListIsDoneWithoutReadingSecrets() async throws {
        try await with { h in
            let migration = h.migration()
            #expect(await migration.state() == .done)
            #expect(migration.storedState == .done)
            #expect(h.storage.existenceCheckCount == 1)
            #expect(h.storage.readCount == 0 && h.storage.writeCount == 0 && h.storage.eraseCount == 0)

            // A finished migration is never asked about again.
            #expect(await migration.state() == .done)
            #expect(h.storage.existenceCheckCount == 1)
        }
    }

    @Test func presentLegacyListStaysPendingUntilImported() async throws {
        try await with { h in
            try await h.seed([entry("ada", "pw-1")])
            let reads = h.storage.readCount
            let migration = h.migration()

            #expect(await migration.state() == .pending)
            #expect(migration.storedState == .pending)
            #expect(await migration.hasListToMove())
            // Looking for the list reads none of it.
            #expect(h.storage.readCount == reads)

            migration.markImported()
            #expect(await migration.state() == .imported)
            #expect(await h.migration().state() == .imported)
            // The list itself is untouched by importing: only erasing removes it.
            #expect(h.storage.itemCount == 1 && h.storage.eraseCount == 0)
        }
    }

    @Test func privateProfileIsDoneAndNeverTouchesStorageOrDefaults() async throws {
        let h = try Harness(profile: .privateBrowsing())
        defer { h.cleanUp() }
        let migration = h.migration()

        #expect(await migration.state() == .done)
        #expect(migration.storedState == .done)
        #expect(!(await migration.hasListToMove()))
        #expect(!migration.claimPrompt())
        migration.markImported()
        let session = await migration.makeSession()
        defer { session.invalidate() }
        await #expect(throws: AutofillVaultError.self) { try await migration.records(using: session) }
        await #expect(throws: AutofillVaultError.self) {
            try await migration.erase(using: session, expectedTotal: 0, expectedMissing: 0)
        }

        #expect(h.storage.existenceCheckCount == 0 && h.storage.readCount == 0)
        #expect(h.storage.writeCount == 0 && h.storage.eraseCount == 0)
        #expect(h.defaults.object(forKey: LegacyPasswordMigration.stateKey) == nil)
        #expect(h.defaults.object(forKey: LegacyPasswordMigration.promptedKey) == nil)
        #expect(h.resets.isEmpty)
    }

    @Test func aKeychainQueryErrorStaysPendingAndPersistsNothing() async throws {
        try await with { h in
            try await h.seed([entry("ada", "pw-1")])
            h.storage.failExistenceChecks()
            let migration = h.migration()

            #expect(await migration.state() == .pending)
            #expect(migration.storedState == nil)
            // An error is not a confirmation that a list exists, so nothing prompts the user about it.
            #expect(!(await migration.hasListToMove()))
            #expect(h.defaults.object(forKey: LegacyPasswordMigration.stateKey) == nil)

            // What was stored before the error is still what is reported.
            migration.markImported()
            #expect(await migration.state() == .imported)
        }
    }

    @Test func stateNeverMovesBackFromDone() async throws {
        try await with { h in
            let migration = h.migration()
            #expect(await migration.state() == .done)

            // Even if an item appears again, a finished migration neither asks the Keychain nor moves back.
            try await h.seed([entry("ada", "pw-1")])
            migration.markImported()
            let checks = h.storage.existenceCheckCount
            #expect(await migration.state() == .done)
            #expect(await h.migration().state() == .done)
            #expect(!(await migration.hasListToMove()))
            #expect(h.storage.existenceCheckCount == checks)
            #expect(migration.storedState == .done)
        }
    }

    @Test func thePromptIsClaimedOncePerProfile() async throws {
        try await with { h in
            let migration = h.migration()
            #expect(migration.claimPrompt())
            #expect(!migration.claimPrompt())
            #expect(!h.migration().claimPrompt())
            let other = try Harness()
            defer { other.cleanUp() }
            #expect(other.migration().claimPrompt())
        }
    }

    // MARK: - What is already in Credential Manager

    @Test func missingNeedsExactOriginUsernameAndPassword() throws {
        let nfc = "\u{00E9}"
        let nfd = "e\u{0301}"
        #expect(nfc == nfd)
        let legacy = try [
            entry("ada", "pw-1"),
            entry("ada", "pw-1", website: "https://other.test"),
            entry(nfc, "pw-3"),
            entry("grace", "Pw-4"),
            entry("heidi", "pw-5", website: "https://example.test:8443"),
            entry("ivan", "pw-6"),
        ]
        let accounts = [
            // Present: the same login. An account that lists several websites holds it for each of them.
            account("ada", "pw-1", origins: ["https://example.test", "https://other.test"]),
            // The same text as a different byte sequence is another username.
            account(nfd, "pw-3"),
            // Another password, only case apart.
            account("grace", "pw-4"),
            // The same username and password on another origin (the port differs).
            account("heidi", "pw-5"),
            // No password: it holds nothing of the entry.
            account("ivan", nil),
        ]
        let missing = LegacyPasswordMigration.missing(legacy, in: accounts)
        #expect(missing.map(\.username).sorted() == [nfc, "grace", "heidi", "ivan"].sorted())
        #expect(LegacyPasswordMigration.missing(legacy, in: []).count == legacy.count)
        #expect(LegacyPasswordMigration.missing([], in: accounts).isEmpty)
    }

    // MARK: - Removal

    @Test func emptyLegacyListIsRemovedOnlyAfterConfirmation() async throws {
        try await with { h in
            try await h.seed([])
            let migration = h.migration()
            let session = await migration.makeSession()
            defer { session.invalidate() }

            #expect(await migration.state() == .pending)
            #expect(try await migration.tally(using: session) == .init(total: 0, missing: 0))
            // Nothing to import, but the list still exists until the user confirms its removal.
            migration.markImported()
            #expect(h.storage.itemCount == 1 && h.storage.eraseCount == 0)

            try await migration.erase(using: session, expectedTotal: 0, expectedMissing: 0)
            #expect(h.storage.itemCount == 0 && h.storage.eraseCount == 1)
            #expect(migration.storedState == .done)
        }
    }

    @Test func eraseRefusesWhilePending() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let h = try Harness(profile: profile)
            defer { h.cleanUp() }
            try await h.seed([entry("ada", "pw-1")])
            try await VaultManagerFixture.save([account("ada", "pw-1")], in: vaults[0])
            let migration = h.migration()
            let session = await migration.makeSession()
            defer { session.invalidate() }
            #expect(await migration.state() == .pending)

            // Everything is already in the vault, and still nothing is removed before the import step is complete.
            await #expect(throws: LegacyPasswordMigration.Failure.notImported) {
                try await migration.erase(using: session, expectedTotal: 1, expectedMissing: 0)
            }
            #expect(h.storage.itemCount == 1 && h.storage.eraseCount == 0)
            #expect(migration.storedState == .pending)
        }
    }

    @Test func eraseRefusesWhenTheMissingCountChanged() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let h = try Harness(profile: profile)
            defer { h.cleanUp() }
            try await h.seed([entry("ada", "pw-1"), entry("grace", "pw-2")])
            try await VaultManagerFixture.save([account("ada", "pw-1")], in: vaults[0])
            let migration = h.migration()
            let session = await migration.makeSession()
            defer { session.invalidate() }
            #expect(await migration.state() == .pending)
            migration.markImported()

            let shown = try await migration.tally(using: session)
            #expect(shown == .init(total: 2, missing: 1))

            // The vault gains the other entry after the dialog was shown: the confirmation no longer describes it.
            try await VaultManagerFixture.save([account("ada", "pw-1"), account("grace", "pw-2")], in: vaults[0])
            await #expect(throws: LegacyPasswordMigration.Failure.changed) {
                try await migration.erase(using: session, expectedTotal: shown.total, expectedMissing: shown.missing)
            }
            #expect(h.storage.itemCount == 1 && h.storage.eraseCount == 0)
            #expect(migration.storedState == .imported)

            // The vault loses an account again: still the old numbers, still no erase.
            try await VaultManagerFixture.save([account("ada", "pw-1")], in: vaults[0])
            // The list gains an entry: the total no longer matches either.
            try await h.seed([entry("ada", "pw-1"), entry("grace", "pw-2"), entry("heidi", "pw-3")])
            await #expect(throws: LegacyPasswordMigration.Failure.changed) {
                try await migration.erase(using: session, expectedTotal: shown.total, expectedMissing: shown.missing)
            }
            #expect(h.storage.itemCount == 1 && h.storage.eraseCount == 0)

            // A vault that locked proves nothing about the entries, so they all count as missing and nothing is removed.
            vaults[0].manager.lock(reason: .manual)
            await #expect(throws: LegacyPasswordMigration.Failure.changed) {
                try await migration.erase(using: session, expectedTotal: 3, expectedMissing: 2)
            }
            #expect(h.storage.itemCount == 1 && h.storage.eraseCount == 0)
        }
    }

    @Test func eraseRemovesTheListClearsSavedSiteBlocksAndMarksDone() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let h = try Harness(profile: profile)
            defer { h.cleanUp() }
            try await h.seed([entry("ada", "pw-1"), entry("grace", "pw-2")])
            try await VaultManagerFixture.save([account("ada", "pw-1"), account("grace", "pw-2")], in: vaults[0])
            let migration = h.migration()
            let session = await migration.makeSession()
            defer { session.invalidate() }
            #expect(await migration.state() == .pending)
            migration.markImported()

            let shown = try await migration.tally(using: session)
            #expect(shown == .init(total: 2, missing: 0))
            try await migration.erase(using: session, expectedTotal: shown.total, expectedMissing: shown.missing)

            #expect(h.storage.itemCount == 0 && h.storage.eraseCount == 1)
            #expect(h.resets == [profile.id])
            #expect(migration.storedState == .done)
            #expect(await h.migration().state() == .done)
            // The vault's own accounts are what remains.
            #expect(try await vaults[0].manager.snapshot().accounts.count == 2)
        }
    }

    @Test func aCrashAfterEraseBeforeTheStateWriteResolvesToDone() async throws {
        try await with { h in
            try await h.seed([entry("ada", "pw-1")])
            let migration = h.migration()
            #expect(await migration.state() == .pending)
            migration.markImported()

            // The Keychain delete happened and the app quit before `done` was stored.
            try await h.vault.erase()
            #expect(migration.storedState == .imported)

            let relaunched = h.migration()
            #expect(await relaunched.state() == .done)
            #expect(relaunched.storedState == .done)
        }
    }
}
