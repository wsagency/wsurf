// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The page's side of Delete Vault: what the first confirmation shows, that the typed name and the vault's own passkey both gate the
// deletion, and that a lock, a declined prompt, the last vault and an open import review each delete nothing. The store, the managers
// and the passkey prompts are real or stubbed exactly as in `VaultDeleteTests`. Synthetic data only.

@MainActor
struct CredentialSettingsVaultDeletionTests {
    /// A profile with `count` locked vaults and the page's own model, opened on the first one.
    private func withPage(
        vaults count: Int = 2,
        exchange: CredentialExchangeCoordinator = CredentialExchangeCoordinator(),
        _ body: (CredentialSettingsModel, VaultPasskeys, [FixtureVault], Profile) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(vaults: Array(repeating: .locked, count: count)) { profile, passkeys, vaults in
            let model = CredentialSettingsModel(profile: profile, exchange: exchange, native: passkeys.native)
            await model.load()
            try await body(model, passkeys, vaults, profile)
        }
    }

    /// Selects `vault` and unlocks it with its own passkey. A vault that holds nothing is deleted without any confirmation, so unless
    /// `seeded` is false it gets one credential first: the tests of the two confirmations need a vault that has something to lose.
    private func open(_ model: CredentialSettingsModel, _ vault: FixtureVault, seeded: Bool = true) async {
        await model.select(vaultID: vault.vaultID)
        await model.unlock(in: VaultManagerFixture.anchor())
        guard seeded else { return }
        do {
            _ = try await model.save(VaultFixtures.account(), expectedRevision: model.revision)
        } catch {
            Issue.record("the vault could not be seeded: \(error)")
        }
    }

    private func pendingDeletion(name: String = "Household") -> PendingVaultDeletion {
        PendingVaultDeletion(
            vaultID: UUID(), epoch: 1, ordinal: 2, name: name,
            counts: .init(credentials: 0, passkeys: 0, codes: 0, inTrash: 0, earlierVersions: 0),
            fallback: nil, preMigrationBackup: nil, hasOwnUnlockPasskey: true
        )
    }

    // MARK: The typed name

    @Test func deleteIsEnabledOnlyWhenTheTypedNameMatches() {
        let pending = pendingDeletion()
        #expect(pending.accepts("Household"))
        #expect(pending.accepts("  Household \n"), "spaces around the name are not part of it")
        for typed in ["", "household", "HOUSEHOLD", "Househol", "Household 2", "House hold", "Vault 2"] {
            #expect(!pending.accepts(typed), "\(typed)")
        }
    }

    @Test func aWrongNameAsksForNoPasskeyAndDeletesNothing() async throws {
        try await withPage { model, passkeys, vaults, profile in
            await open(model, vaults[1])
            await model.renameVault("Household")
            await model.requestVaultDeletion()
            let pending = try #require(model.pendingVaultDeletion)
            #expect(pending.name == "Household" && pending.ordinal == 2 && pending.vaultID == vaults[1].vaultID)
            let asserted = passkeys.assertions.count
            let rows = try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile)

            for typed in ["", "Vault 2", "household"] {
                #expect(await model.confirmVaultDeletion(typedName: typed, in: VaultManagerFixture.anchor()) == false)
            }

            #expect(passkeys.assertions.count == asserted, "the passkey is asked for only after the name matches")
            #expect(model.pendingVaultDeletion == pending, "the sheet stays for another try")
            #expect(model.vaults.count == 2 && model.deletedVault == nil)
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile) == rows)
        }
    }

    // MARK: The counts and the result

    @Test func theSheetCountsWhatGoesAndConfirmingDeletesAndOpensTheDefaultVault() async throws {
        try await withPage { model, passkeys, vaults, profile in
            await open(model, vaults[1], seeded: false)
            await model.renameVault("Household")
            let full = try MoveFixtures.fullAccount()
            let spare = VaultFixtures.account(username: "grace", origin: "https://b.example")
            _ = try await model.save(full, expectedRevision: model.revision)
            _ = try await model.save(spare, expectedRevision: model.revision)
            var changed = full
            changed.password = "another-password"
            _ = try await model.save(changed, expectedRevision: model.revision)
            _ = try await model.remove(accountID: spare.id, expectedRevision: model.revision)

            await model.requestVaultDeletion()

            let pending = try #require(model.pendingVaultDeletion)
            #expect(model.error == nil)
            #expect(pending.counts.credentials == 1 && pending.counts.passkeys == 2 && pending.counts.codes == 1)
            #expect(pending.counts.inTrash == 1)
            #expect(pending.counts.earlierVersions >= 1, "the replaced password is an earlier version")
            #expect(pending.fallback == nil, "the first vault is the default")
            #expect(pending.preMigrationBackup == nil)
            #expect(pending.hasOwnUnlockPasskey)

            let asserted = passkeys.assertions.count
            let deleted = await model.confirmVaultDeletion(typedName: " Household ", in: VaultManagerFixture.anchor())

            #expect(deleted)
            #expect(model.error == nil)
            #expect(Array(passkeys.assertions.dropFirst(asserted)) == [vaults[1].proof.credentialID], "its own passkey, asserted once")
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile).isEmpty)
            #expect(model.vaults.map(\.vaultID) == [vaults[0].vaultID])
            #expect(model.selectedVaultID == vaults[0].vaultID && !model.isUnlocked, "the default vault is opened, still locked")
            #expect(model.deletedVault == DeletedVault(ordinal: 2, leavesUnlockPasskey: true))
            #expect(model.pendingVaultDeletion == nil)
            #expect(model.vaultDeletionBlock == .locked)
            model.dismissDeletedVault()
            #expect(model.deletedVault == nil)
        }
    }

    @Test func theDefaultVaultNamesTheOneAutofillUsesInstead() async throws {
        try await withPage { model, _, vaults, _ in
            await open(model, vaults[0])
            #expect(model.defaultVaultID == vaults[0].vaultID)

            await model.requestVaultDeletion()

            let pending = try #require(model.pendingVaultDeletion)
            #expect(pending.ordinal == 1 && pending.fallback == "Vault 2", "a locked vault is told by its number")
        }
    }

    @Test func aPasskeyAnotherVaultAlsoUsesIsNotLeftOver() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, passkeys, vaults in
            let first = vaults[0]
            let sharing = try await CredentialManager.createVault(
                profile: profile, name: "Shared",
                choice: .existing(sourceVaultID: first.vaultID, credentialID: first.proof.credentialID, prfInput: first.proof.prfInput),
                in: VaultManagerFixture.anchor(), native: passkeys.native
            )
            let model = CredentialSettingsModel(profile: profile, exchange: CredentialExchangeCoordinator(), native: passkeys.native)
            await model.load()
            await model.select(vaultID: sharing)
            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(model.isUnlocked && model.selectedVaultID == sharing)
            _ = try await model.save(VaultFixtures.account(), expectedRevision: model.revision)

            await model.requestVaultDeletion()

            let pending = try #require(model.pendingVaultDeletion)
            #expect(!pending.hasOwnUnlockPasskey)
        }
    }

    // MARK: A vault that holds nothing

    @Test func anEmptyVaultIsDeletedAtOnceWithNoSheetAndNoPasskey() async throws {
        try await withPage { model, passkeys, vaults, profile in
            await open(model, vaults[1], seeded: false)
            await model.renameVault("Household")
            let asserted = passkeys.assertions.count

            await model.requestVaultDeletion()

            #expect(model.error == nil)
            #expect(model.pendingVaultDeletion == nil && !model.showsVaultDeletionSheet, "no sheet")
            #expect(passkeys.assertions.count == asserted, "no passkey prompt")
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile).isEmpty)
            #expect(model.vaults.map(\.vaultID) == [vaults[0].vaultID] && model.selectedVaultID == vaults[0].vaultID)
            #expect(model.deletedVault == DeletedVault(ordinal: 2, leavesUnlockPasskey: true))
        }
    }

    @Test func oneCredentialMakesTheSheetAndBothConfirmationsNecessary() async throws {
        try await withPage { model, passkeys, vaults, profile in
            await open(model, vaults[1], seeded: false)
            _ = try await model.save(VaultFixtures.account(), expectedRevision: model.revision)
            let asserted = passkeys.assertions.count
            let rows = try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile)

            await model.requestVaultDeletion()

            let pending = try #require(model.pendingVaultDeletion)
            #expect(model.showsVaultDeletionSheet && pending.counts.credentials == 1)
            #expect(passkeys.assertions.count == asserted && model.deletedVault == nil && model.vaults.count == 2)
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile) == rows)

            #expect(await model.confirmVaultDeletion(typedName: pending.name, in: VaultManagerFixture.anchor()))
            #expect(passkeys.assertions.count == asserted + 1, "and then the passkey")
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile).isEmpty)
        }
    }

    @Test func aCredentialOnlyInTrashStillNeedsBothConfirmations() async throws {
        try await withPage { model, passkeys, vaults, _ in
            await open(model, vaults[1], seeded: false)
            let account = VaultFixtures.account()
            _ = try await model.save(account, expectedRevision: model.revision)
            _ = try await model.remove(accountID: account.id, expectedRevision: model.revision)
            let asserted = passkeys.assertions.count

            await model.requestVaultDeletion()

            let pending = try #require(model.pendingVaultDeletion)
            #expect(pending.counts.credentials == 0 && pending.counts.inTrash == 1, "nothing live, but the Trash is not empty")
            #expect(passkeys.assertions.count == asserted && model.vaults.count == 2 && model.deletedVault == nil)
        }
    }

    @Test func anOpenImportReviewStillBlocksAnEmptyVault() async throws {
        let exchange = CredentialExchangeCoordinator()
        try await withPage(exchange: exchange) { model, _, vaults, profile in
            await open(model, vaults[1], seeded: false)
            let csv = CredentialCSV.encode([
                ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"],
                ["Example", "https://example.test/login", "ada", "hunter2-correct", "", ""],
            ])
            try await exchange.beginCSVImport(csv, into: try #require(model.manager), owner: model.owner) { _ in }
            let rows = try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile)

            await model.requestVaultDeletion()

            #expect(model.vaultDeletionBlock == .importOpen && model.deletedVault == nil && model.vaults.count == 2)
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile) == rows)
            model.cancelImport()
        }
    }

    // MARK: The passkey prompt

    /// The system's passkey prompt is a sheet of the window, and a window with a sheet already attached shows no second one. So the
    /// delete sheet must be down while the prompt is open, or the prompt waits for the sheet and the sheet for the prompt.
    @Test func theSheetIsDownWhileThePasskeyPromptIsOpenAndComesBackIfItWasDeclined() async throws {
        try await withPage { model, passkeys, vaults, _ in
            await open(model, vaults[1])
            await model.requestVaultDeletion()
            let pending = try #require(model.pendingVaultDeletion)
            #expect(model.showsVaultDeletionSheet)

            var shownDuringPrompt: Bool?
            passkeys.beforeAssert = {
                shownDuringPrompt = model.showsVaultDeletionSheet
                throw PasskeyUnlockError.appCancelled
            }
            #expect(await model.confirmVaultDeletion(typedName: pending.name, in: VaultManagerFixture.anchor()) == false)
            #expect(shownDuringPrompt == false, "the sheet was still up when the prompt opened")
            #expect(model.showsVaultDeletionSheet, "a declined prompt brings the sheet back")

            passkeys.beforeAssert = { shownDuringPrompt = model.showsVaultDeletionSheet }
            shownDuringPrompt = nil
            #expect(await model.confirmVaultDeletion(typedName: pending.name, in: VaultManagerFixture.anchor()))
            #expect(shownDuringPrompt == false)
            #expect(!model.showsVaultDeletionSheet && model.pendingVaultDeletion == nil)
        }
    }

    // MARK: Nothing is deleted

    @Test func aLockBetweenTheConfirmationsDeletesNothing() async throws {
        try await withPage { model, passkeys, vaults, profile in
            await open(model, vaults[1])
            await model.requestVaultDeletion()
            let name = try #require(model.pendingVaultDeletion).name
            let rows = try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile)
            let asserted = passkeys.assertions.count

            // The vault locks while the sheet is open: the session, and the confirmation with it, are gone.
            model.lock()
            #expect(model.pendingVaultDeletion == nil)
            #expect(await model.confirmVaultDeletion(typedName: name, in: VaultManagerFixture.anchor()) == false)
            #expect(model.error != nil)
            #expect(passkeys.assertions.count == asserted)

            // It locks while the passkey prompt is open.
            await model.unlock(in: VaultManagerFixture.anchor())
            await model.requestVaultDeletion()
            let again = try #require(model.pendingVaultDeletion)
            let beforePrompt = passkeys.assertions.count
            passkeys.beforeAssert = { model.lock() }
            #expect(await model.confirmVaultDeletion(typedName: again.name, in: VaultManagerFixture.anchor()) == false)
            passkeys.beforeAssert = nil
            #expect(passkeys.assertions.count == beforePrompt + 1, "the prompt was shown")

            #expect(model.deletedVault == nil && model.pendingVaultDeletion == nil)
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile) == rows)
            #expect(try await CredentialManager.store(for: profile).listing().count == 2)
        }
    }

    @Test func aDeclinedAssertionDeletesNothingAndTheSameDeletionCanBeConfirmedAgain() async throws {
        try await withPage { model, passkeys, vaults, profile in
            await open(model, vaults[1])
            await model.requestVaultDeletion()
            let pending = try #require(model.pendingVaultDeletion)
            let rows = try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile)

            passkeys.beforeAssert = { throw PasskeyUnlockError.appCancelled }
            #expect(await model.confirmVaultDeletion(typedName: pending.name, in: VaultManagerFixture.anchor()) == false)
            passkeys.beforeAssert = nil

            #expect(model.error == nil, "declining says nothing")
            #expect(model.pendingVaultDeletion == pending && model.isUnlocked)
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile) == rows)
            #expect(model.vaults.count == 2 && model.deletedVault == nil)

            #expect(await model.confirmVaultDeletion(typedName: pending.name, in: VaultManagerFixture.anchor()))
            #expect(model.vaults.map(\.vaultID) == [vaults[0].vaultID])
        }
    }

    @Test func theOnlyVaultOffersNoDelete() async throws {
        try await withPage(vaults: 1) { model, _, vaults, profile in
            #expect(model.vaultDeletionBlock == .locked)
            await model.unlock(in: VaultManagerFixture.anchor())
            #expect(model.isUnlocked && model.vaultDeletionBlock == .onlyVault)
            let rows = try VaultManagerFixture.rows(of: vaults[0].vaultID, in: profile)

            await model.requestVaultDeletion()

            #expect(model.pendingVaultDeletion == nil)
            #expect(try VaultManagerFixture.rows(of: vaults[0].vaultID, in: profile) == rows)
        }
    }

    @Test func aLockedVaultOffersNoDelete() async throws {
        try await withPage { model, _, _, _ in
            #expect(model.vaultDeletionBlock == .locked)
            await model.requestVaultDeletion()
            #expect(model.pendingVaultDeletion == nil)
        }
    }

    @Test func anOpenImportReviewBlocksDeletion() async throws {
        let exchange = CredentialExchangeCoordinator()
        try await withPage(exchange: exchange) { model, _, vaults, profile in
            await open(model, vaults[1])
            #expect(model.vaultDeletionBlock == nil)
            let csv = CredentialCSV.encode([
                ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"],
                ["Example", "https://example.test/login", "ada", "hunter2-correct", "", ""],
            ])
            try await exchange.beginCSVImport(csv, into: try #require(model.manager), owner: model.owner) { _ in }
            #expect(model.importReview != nil)
            #expect(model.vaultDeletionBlock == .importOpen)
            let rows = try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile)

            await model.requestVaultDeletion()
            #expect(model.pendingVaultDeletion == nil)
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile) == rows)

            // Once the review is closed the deletion can be shown again.
            model.cancelImport()
            #expect(model.vaultDeletionBlock == nil)
            await model.requestVaultDeletion()
            #expect(model.pendingVaultDeletion != nil)
        }
    }

    @Test func aReviewOpenedAfterTheSheetStillBlocksTheConfirmation() async throws {
        let exchange = CredentialExchangeCoordinator()
        try await withPage(exchange: exchange) { model, passkeys, vaults, profile in
            await open(model, vaults[1])
            await model.requestVaultDeletion()
            let pending = try #require(model.pendingVaultDeletion)
            let csv = CredentialCSV.encode([
                ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"],
                ["Example", "https://example.test/login", "ada", "hunter2-correct", "", ""],
            ])
            try await exchange.beginCSVImport(csv, into: try #require(model.manager), owner: model.owner) { _ in }
            let asserted = passkeys.assertions.count
            let rows = try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile)

            #expect(await model.confirmVaultDeletion(typedName: pending.name, in: VaultManagerFixture.anchor()) == false)

            #expect(passkeys.assertions.count == asserted && model.pendingVaultDeletion == nil)
            #expect(try VaultManagerFixture.rows(of: vaults[1].vaultID, in: profile) == rows)
            model.cancelImport()
        }
    }
}
