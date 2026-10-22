// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Security
import Testing

@testable import WSurf

// The page's side of moving the passwords saved before Credential Manager: when the move counts as imported, when the removal is
// offered, and what the user is told. The coordinator and the vault are real; the old list is a `MemoryAutofillStorage`, the state
// a throwaway defaults suite. Synthetic data only.
@MainActor
struct CredentialSettingsLegacyImportTests {
    private let base = CredentialExchangeCoordinatorTests()

    private final class Page {
        let fixture: CredentialExchangeCoordinatorTests.Fixture
        let model: CredentialSettingsModel
        let storage = MemoryAutofillStorage()
        let vault: SecureAutofillVault<SavedPassword>
        private let suiteName = AppDatabase.defaultsSuite("CredentialSettingsLegacyImportTests.\(UUID().uuidString)")
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        init(_ fixture: CredentialExchangeCoordinatorTests.Fixture) throws {
            self.fixture = fixture
            vault = SecureAutofillVault<SavedPassword>(profileID: fixture.profile.id, kind: "passwords", reason: "Test", storage: storage)
            model = CredentialSettingsModel(profile: fixture.profile, pasteboard: pasteboard, exchange: fixture.coordinator, manager: fixture.manager)
            model.legacy.migration = LegacyPasswordMigration(
                profile: fixture.profile, vault: vault, defaults: try #require(UserDefaults(suiteName: suiteName))
            )
            model.legacy.migration.resetBlockedSites = { _ in }
        }

        var epoch: UInt64 {
            fixture.manager.authorizationEpoch ?? 0
        }

        var storedState: LegacyPasswordMigration.State? {
            model.legacy.migration.storedState
        }

        /// Puts `entries` in the old list and reads the state, the way the page does when it appears.
        func start(with entries: [SavedPassword]) async throws {
            _ = try await vault.update { _ in entries }
            await model.load()
            await model.legacy.refresh()
        }

        /// Saves `accounts` in the vault next to what it holds, the way another window would.
        func addToVault(_ accounts: [CredentialAccount]) async throws {
            let manager = fixture.manager
            let snapshot = try await manager.snapshot()
            _ = try await manager.commit(
                snapshot.accounts + accounts, expectedRevision: snapshot.revision, authorizedEpoch: try #require(manager.authorizationEpoch)
            )
        }

        func cleanUp() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
            pasteboard.releaseGlobally()
        }
    }

    private func with(
        gate: VaultClockGate? = nil, vaultAccounts: [CredentialAccount] = [], _ body: (Page) async throws -> Void
    ) async throws {
        try await base.withFixture(gate: gate) { f in
            try await f.seed(vaultAccounts)
            let page = try Page(f)
            defer { page.cleanUp() }
            try await body(page)
            page.model.cancelImport()
        }
    }

    private func legacy(_ username: String, _ password: String) throws -> SavedPassword {
        try SavedPassword(website: CredentialExchangeCoordinatorTests.origin, username: username, password: password)
    }

    /// Decides every row of the open review.
    private func decideAll(_ page: Page, _ choice: CredentialImportChoice) throws {
        let review = try #require(page.model.importReview)
        for record in review.candidates.flatMap(\.records) {
            page.model.chooseImport(choice, for: record.incoming)
        }
    }

    // MARK: - When the move counts as imported

    @Test func onlyAReceiptMarksImported() async throws {
        try await with(vaultAccounts: [base.account(username: "ada", password: "vault-value")]) { page in
            try await page.start(with: [legacy("ada", "list-value"), legacy("grace", "pw-2")])
            #expect(page.model.legacy.state == .pending && page.storedState == .pending)

            // A review that is cancelled writes nothing and changes nothing.
            await page.model.beginLegacyImport(epoch: page.epoch)
            #expect(page.model.importReview?.origin == .legacyPasswords)
            page.model.cancelImport()
            #expect(page.model.importReview == nil && page.storedState == .pending && page.model.legacy.removal == nil)
            #expect(page.model.transferMessage?.kind == .discarded)

            // A review where every row was skipped imports nothing, and that is not an import either.
            await page.model.beginLegacyImport(epoch: page.epoch)
            try decideAll(page, .skip)
            await page.model.commitImport()
            #expect(page.model.transferMessage?.kind == .nothingImported)
            #expect(page.storedState == .pending && page.model.legacy.state == .pending && page.model.legacy.removal == nil)

            // A receipt is the only thing that completes the import step, and it offers the removal at once.
            page.model.cancelImport()
            await page.model.beginLegacyImport(epoch: page.epoch)
            let review = try #require(page.model.importReview)
            for record in review.candidates.flatMap(\.records) where record.isConflict {
                page.model.chooseImport(.skip, for: record.incoming)
            }
            await page.model.commitImport()
            #expect(page.model.transferMessage?.kind == .succeeded)
            #expect(page.storedState == .imported && page.model.legacy.state == .imported)
            // Ada's list value was skipped on purpose, so one of the two passwords is not in the vault.
            #expect(page.model.legacy.removal == .init(total: 2, missing: 1))
            // Importing never touches the old list.
            #expect(page.storage.itemCount == 1 && page.storage.eraseCount == 0)
        }
    }

    @Test func anImportThatMayHaveLandedDoesNotMarkImported() async throws {
        let gate = VaultClockGate()
        try await with(gate: gate, vaultAccounts: base.neighbours(2)) { page in
            try await page.start(with: [legacy("grace", "pw-2")])
            await page.model.beginLegacyImport(epoch: page.epoch)
            #expect(page.model.importReview != nil)

            // The write is parked inside the vault; the cancel arrives after it started, so only "may have landed" is true.
            gate.holdImportWrite(of: page.fixture.coordinator)
            let committing = Task { @MainActor in await page.model.commitImport() }
            gate.whenParked {
                committing.cancel()
                gate.release()
            }
            await committing.value

            #expect(gate.hasParked)
            #expect(page.model.transferMessage?.kind == .mayHaveLanded)
            #expect(page.storedState == .pending && page.model.legacy.state == .pending && page.model.legacy.removal == nil)
            #expect(page.storage.itemCount == 1 && page.storage.eraseCount == 0)
        }
    }

    @Test func allSkippedContinueMarksImportedWithoutWriting() async throws {
        try await with(vaultAccounts: [base.account(username: "ada", password: "vault-value")] + base.neighbours(2)) { page in
            let before = try page.fixture.diskBytes()
            try await page.start(with: [legacy("ada", "list-value")])

            await page.model.beginLegacyImport(epoch: page.epoch)
            // Not resolved yet: Continue does nothing, and the review stays open.
            await page.model.continueLegacyImport()
            #expect(page.model.importReview != nil && page.storedState == .pending)

            try decideAll(page, .skip)
            await page.model.continueLegacyImport()

            #expect(page.model.importReview == nil)
            // No message: skipping everything is a decision, not a failure.
            #expect(page.model.transferMessage == nil && page.model.error == nil)
            #expect(page.storedState == .imported && page.model.legacy.state == .imported)
            // The dialog still names the password that would be lost.
            #expect(page.model.legacy.removal == .init(total: 1, missing: 1))
            #expect(try page.fixture.diskBytes() == before)
            #expect(page.storage.itemCount == 1 && page.storage.eraseCount == 0)
        }
    }

    @Test func aListTheVaultAlreadyHoldsNeedsNoReview() async throws {
        try await with(vaultAccounts: [base.account(username: "ada", password: "pw-1")]) { page in
            try await page.start(with: [legacy("ada", "pw-1")])
            await page.model.beginLegacyImport(epoch: page.epoch)

            #expect(page.model.importReview == nil && page.model.error == nil)
            #expect(page.storedState == .imported)
            #expect(page.model.legacy.removal == .init(total: 1, missing: 0))
        }
    }

    // MARK: - Removal

    @Test func removalIsOfferedOnlyWhenImported() async throws {
        try await with(vaultAccounts: [base.account(username: "ada", password: "pw-1")]) { page in
            try await page.start(with: [legacy("ada", "pw-1"), legacy("grace", "pw-2")])

            // Pending: there is no way to ask for the removal, and nothing is counted or erased.
            await page.model.requestLegacyRemoval()
            #expect(page.model.legacy.removal == nil && page.storage.eraseCount == 0)

            page.model.legacy.markImported()
            await page.model.requestLegacyRemoval()
            let shown = try #require(page.model.legacy.removal)
            #expect(shown == .init(total: 2, missing: 1))

            // Locked, there is nothing to count against, so nothing is offered.
            page.model.legacy.dismissRemoval()
            page.fixture.manager.lock(reason: .manual)
            await page.model.requestLegacyRemoval()
            #expect(page.model.legacy.removal == nil)
            try await page.fixture.unlock(page.fixture.manager)

            // The vault gained the other password since the dialog was shown: the confirmation no longer describes it, and
            // nothing is erased.
            try await page.addToVault([base.account(username: "grace", password: "pw-2")])
            await page.model.confirmLegacyRemoval(shown)
            #expect(page.model.error != nil)
            #expect(page.storage.itemCount == 1 && page.storage.eraseCount == 0 && page.storedState == .imported)

            // Asking again counts again.
            await page.model.requestLegacyRemoval()
            #expect(page.model.legacy.removal == .init(total: 2, missing: 0))
        }
    }

    @Test func confirmedRemovalDeletesTheListOnce() async throws {
        try await with(vaultAccounts: [base.account(username: "ada", password: "pw-1")]) { page in
            try await page.start(with: [legacy("ada", "pw-1")])
            page.model.legacy.markImported()
            await page.model.requestLegacyRemoval()
            let shown = try #require(page.model.legacy.removal)
            #expect(shown == .init(total: 1, missing: 0))
            // Asking is not removing.
            #expect(page.storage.itemCount == 1 && page.storage.eraseCount == 0)

            await page.model.confirmLegacyRemoval(shown)

            #expect(page.storage.itemCount == 0 && page.storage.eraseCount == 1)
            #expect(page.storedState == .done && page.model.legacy.state == .done && page.model.legacy.didRemove)
            #expect(page.model.legacy.removal == nil && page.model.error == nil)
            // The vault keeps its own copy.
            #expect(try await page.fixture.stored().accounts.contains { $0.password == "pw-1" })
            // Nothing is left to remove: a second request offers nothing.
            await page.model.requestLegacyRemoval()
            #expect(page.model.legacy.removal == nil)
        }
    }

    // MARK: - Reading the list

    @Test func aCanceledOrFailedAuthenticationReadsNothingAndChangesNothing() async throws {
        try await with(vaultAccounts: base.neighbours(1)) { page in
            try await page.start(with: [legacy("ada", "pw-1")])
            let before = try page.fixture.diskBytes()

            page.storage.failReads(with: errSecUserCanceled)
            await page.model.beginLegacyImport(epoch: page.epoch)
            #expect(page.model.error == nil && page.model.importReview == nil && page.model.transferMessage == nil)

            page.storage.failReads(with: errSecAuthFailed)
            await page.model.beginLegacyImport(epoch: page.epoch)
            #expect(page.model.error != nil && page.model.importReview == nil)

            page.storage.failReads(with: nil)
            await page.model.beginLegacyImport(epoch: page.epoch)
            #expect(page.model.importReview != nil && page.model.error == nil)
            #expect(page.storedState == .pending)
            #expect(try page.fixture.diskBytes() == before)
        }
    }

    @Test func aLockDuringTheSystemPromptStagesNothing() async throws {
        try await with(vaultAccounts: base.neighbours(1)) { page in
            try await page.start(with: [legacy("ada", "pw-1")])
            let staleEpoch = page.epoch
            let reads = page.storage.readCount
            page.fixture.manager.lock(reason: .screenLock)
            try await page.fixture.unlock(page.fixture.manager)

            // The page asked under an authorization that no longer exists.
            await page.model.beginLegacyImport(epoch: staleEpoch)
            #expect(page.model.importReview == nil && page.model.error != nil && page.storage.readCount == reads)
        }
    }

    @Test func aPrivateProfileNeverReadsPromptsOrStoresAnything() async throws {
        let suite = AppDatabase.defaultsSuite("CredentialSettingsLegacyImportTests.\(UUID().uuidString)")
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let storage = MemoryAutofillStorage()
        let profile = Profile.privateBrowsing()
        let model = CredentialSettingsModel(profile: profile)
        let defaults = try #require(UserDefaults(suiteName: suite))
        model.legacy.migration = LegacyPasswordMigration(
            profile: profile,
            vault: SecureAutofillVault<SavedPassword>(profileID: profile.id, kind: "passwords", reason: "Test", storage: storage),
            defaults: defaults
        )

        await model.legacy.refresh()
        await model.beginLegacyImport(epoch: 1)
        await model.requestLegacyRemoval()

        #expect(model.legacy.state == .done && model.legacy.removal == nil && model.importReview == nil)
        #expect(storage.existenceCheckCount == 0 && storage.readCount == 0 && storage.writeCount == 0 && storage.eraseCount == 0)
        #expect(defaults.object(forKey: LegacyPasswordMigration.stateKey) == nil)
    }
}
