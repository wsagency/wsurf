// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// The page's Undo: which actions keep a step, how long steps live, and what taking one back does. Test-only in-memory unlock keys,
// a private pasteboard and synthetic credentials.

@MainActor
struct CredentialUndoModelTests {
    private final class Fixture {
        let profile: Profile
        let vault: FixtureVault
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Undo", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        }

        @MainActor func seed(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.save(accounts, in: vault)
            await model.load()
        }

        @MainActor func snapshot() async throws -> StoreSnapshot {
            try await vault.manager.snapshot()
        }

        @MainActor func liveIDs() async throws -> Set<UUID> {
            Set(try await snapshot().accounts.map(\.id))
        }

        @MainActor func trashedOwners() async throws -> Set<UUID> {
            Set(try await vault.manager.trashPage(after: nil).items.map(\.ownerID))
        }

        var kinds: [CredentialUndoStep.Kind] {
            model.live?.undoSteps.map(\.kind) ?? []
        }

        @MainActor func cleanup() async {
            pasteboard.releaseGlobally()
            await VaultManagerFixture.cleanup(profile)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture()
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    private func account(_ username: String, on host: String, password: String = "pw") -> CredentialAccount {
        VaultFixtures.account(username: username, password: password, origin: "https://\(host).example.test")
    }

    // MARK: Recording

    @Test func eachUndoableActionRecordsOneStep() async throws {
        try await withFixture { f in
            let existing = account("ada", on: "a", password: "old")
            let twin = account("ada", on: "a", password: "twin")
            try await f.seed([existing, twin])
            #expect(f.kinds.isEmpty, "opening the page is not an action")

            try await f.model.beginEditing(accountID: nil)
            f.model.draft?.username = "grace"
            f.model.draft?.password = "added"
            f.model.draft?.websites = "https://b.example.test"
            _ = try await f.model.commitDraft()
            #expect(f.kinds == [.add])
            #expect(f.model.notice?.offersUndo == true)
            #expect(f.model.notice?.text == String(localized: "Credential added."))
            let added = try #require(f.model.summaries.first { $0.username == "grace" }).id

            try await f.model.beginEditing(accountID: existing.id)
            f.model.draft?.password = "changed"
            _ = try await f.model.commitDraft()
            #expect(f.kinds == [.add, .edit])
            #expect(f.model.notice?.text == String(localized: "Changes saved."))

            let proposal = try await f.model.mergeProposal(ids: [existing.id, twin.id], survivor: existing.id)
            try await f.model.confirmMerge(proposal)
            #expect(f.kinds == [.add, .edit, .merge])
            #expect(f.model.notice?.offersUndo == true)

            try await f.model.moveToTrash(ids: [added])
            #expect(f.kinds == [.add, .edit, .merge, .moveToTrash])

            try await f.model.loadTrash()
            let entry = try #require(f.model.trashItems.first { $0.ownerID == added })
            await f.model.restore(entryID: entry.id)
            #expect(f.kinds == [.add, .edit, .merge, .moveToTrash, .restore])
            #expect(f.model.notice?.offersUndo == true)
        }
    }

    @Test func savingNothingRecordsNothing() async throws {
        try await withFixture { f in
            let existing = account("ada", on: "a")
            try await f.seed([existing])

            try await f.model.beginEditing(accountID: existing.id)
            _ = try await f.model.commitDraft()

            #expect(f.kinds.isEmpty, "an unchanged save is no write")
            #expect(f.model.notice == nil)
        }
    }

    @Test func theStackKeepsFive() async throws {
        try await withFixture { f in
            let accounts = (0..<7).map { account("user\($0)", on: "site\($0)") }
            try await f.seed(accounts)

            for index in 0..<6 {
                try await f.model.moveToTrash(ids: [accounts[index].id])
            }

            #expect(f.kinds.count == 5)
            let kept = f.model.live?.undoSteps.flatMap(\.returning)
            #expect(kept == (1..<6).map { RemovalScope.account(accounts[$0].id) }, "the oldest action was dropped for the sixth")
        }
    }

    @Test func aLockClearsTheStack() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a"), account("grace", on: "b")]
            try await f.seed(accounts)
            try await f.model.moveToTrash(ids: [accounts[0].id])
            #expect(f.kinds == [.moveToTrash])

            f.vault.manager.lock(reason: .manual)
            #expect(f.model.live == nil)
            #expect(f.model.undoMenuTitle == nil)
            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()

            #expect(f.kinds.isEmpty, "a new unlock starts with nothing to undo")
            await f.model.undo()
            #expect(try await f.trashedOwners() == [accounts[0].id], "and an Undo after it takes nothing back")
        }
    }

    @Test func closingThePageClearsTheStack() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a"), account("grace", on: "b")]
            try await f.seed(accounts)
            try await f.model.moveToTrash(ids: [accounts[0].id])

            f.model.close()
            await f.model.load()

            #expect(f.kinds.isEmpty)
        }
    }

    @Test func anotherVaultClearsTheStack() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let model = CredentialSettingsModel(profile: profile)
            await model.load()
            let first = try #require(model.selectedVaultID)
            let other = try #require(vaults.map(\.vaultID).first { $0 != first })
            let accounts = [account("ada", on: "a"), account("grace", on: "b")]
            let home = try #require(vaults.first { $0.vaultID == first })
            try await VaultManagerFixture.save(accounts, in: home)
            await model.load()
            try await model.moveToTrash(ids: [accounts[0].id])
            #expect(model.live?.undoSteps.count == 1)

            await model.select(vaultID: other)
            #expect(model.live?.undoSteps.isEmpty != false)
            await model.select(vaultID: first)

            #expect(model.live?.undoSteps.isEmpty != false, "coming back does not bring the steps back")
        }
    }

    @Test func aForeignWriteBetweenActionAndReloadRecordsNoStep() async throws {
        try await withFixture { f in
            let existing = account("ada", on: "a")
            try await f.seed([existing])
            let epoch = try #require(f.model.authorizationEpoch)
            let revision = f.model.revision
            let step = CredentialUndoStep(kind: .moveToTrash, returning: [.account(existing.id)])

            // The page reads the vault after its own write at `revision`; a receipt for an earlier write means another one landed.
            let landedBetween = f.model.recordUndo(receipt: VaultCommitReceipt(revision: revision - 1), epoch: epoch) { _ in step }
            #expect(!landedBetween)
            #expect(f.kinds.isEmpty)
            let otherUnlock = f.model.recordUndo(receipt: VaultCommitReceipt(revision: revision), epoch: epoch + 1) { _ in step }
            #expect(!otherUnlock)
            #expect(f.kinds.isEmpty)
            let current = f.model.recordUndo(receipt: VaultCommitReceipt(revision: revision), epoch: epoch) { _ in step }
            #expect(current)
            #expect(f.kinds == [.moveToTrash])
        }
    }

    @Test func importsAndAutofillSavesAreNotUndoable() async throws {
        try await withFixture { f in
            // Imports, autofill saves and passkey updates write through the manager, not through an action of this page.
            let saved = account("ada", on: "a")
            try await f.seed([saved])
            let epoch = try #require(f.vault.manager.authorizationEpoch)
            _ = try await f.vault.manager.commit(
                [saved, account("grace", on: "b")], expectedRevision: f.model.revision, authorizedEpoch: epoch, cause: CredentialChangeCause.import
            )
            await f.model.load()

            #expect(f.kinds.isEmpty)
            #expect(f.model.undoMenuTitle == nil)
            await f.model.undo()
            #expect(try await f.liveIDs().count == 2, "nothing was taken back")
        }
    }

    // MARK: Taking steps back

    @Test func undoTakesBackEachActionInTurnAndNamesIt() async throws {
        try await withFixture { f in
            let existing = account("ada", on: "a", password: "old")
            let twin = account("ada", on: "a", password: "twin")
            try await f.seed([existing, twin])
            try await f.model.beginEditing(accountID: nil)
            f.model.draft?.username = "grace"
            f.model.draft?.password = "added"
            f.model.draft?.websites = "https://b.example.test"
            _ = try await f.model.commitDraft()
            let added = try #require(f.model.summaries.first { $0.username == "grace" }).id
            try await f.model.beginEditing(accountID: existing.id)
            f.model.draft?.password = "changed"
            _ = try await f.model.commitDraft()
            try await f.model.confirmMerge(try await f.model.mergeProposal(ids: [existing.id, twin.id], survivor: existing.id))
            try await f.model.moveToTrash(ids: [added])
            try await f.model.loadTrash()
            await f.model.restore(entryID: try #require(f.model.trashItems.first { $0.ownerID == added }).id)
            #expect(try await f.liveIDs() == [existing.id, added])

            #expect(f.model.undoMenuTitle == String(localized: "Undo Restore"))
            await f.model.undo()
            #expect(try await f.liveIDs() == [existing.id])
            #expect(f.model.notice?.text == String(localized: "Undid Restore."))
            #expect(f.model.error == nil)

            #expect(f.model.undoMenuTitle == String(localized: "Undo Move to Trash"))
            await f.model.undo()
            #expect(try await f.liveIDs() == [existing.id, added])

            #expect(f.model.undoMenuTitle == String(localized: "Undo Merge"))
            await f.model.undo()
            #expect(try await f.liveIDs() == [existing.id, twin.id, added], "the absorbed credential is back")
            #expect(try await f.snapshot().accounts.first { $0.id == existing.id }?.mergedFrom == nil)
            #expect(f.model.error == nil, "the older steps still hold after the account was rewritten")

            #expect(f.model.undoMenuTitle == String(localized: "Undo Edit"))
            await f.model.undo()
            #expect(try await f.snapshot().accounts.first { $0.id == existing.id }?.password == "old")
            #expect(f.model.error == nil)

            #expect(f.model.undoMenuTitle == String(localized: "Undo Add Credential"))
            await f.model.undo()
            #expect(try await f.liveIDs() == [existing.id, twin.id])
            #expect(try await f.trashedOwners() == [added])
            #expect(f.model.error == nil)
            #expect(f.model.undoMenuTitle == nil, "nothing is left to take back")
            #expect(f.kinds.isEmpty)
        }
    }

    @Test func aFailedUndoDropsOnlyThatStepAndSaysWhy() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a"), account("grace", on: "b"), account("linus", on: "c")]
            try await f.seed(accounts)
            try await f.model.moveToTrash(ids: [accounts[0].id])
            try await f.model.moveToTrash(ids: [accounts[1].id])
            // The Trash copy of the second one is deleted for good before it can come back.
            try await f.model.loadTrash()
            let gone = try #require(f.model.trashItems.first { $0.ownerID == accounts[1].id })
            _ = try await f.vault.manager.purge(entryIDs: [gone.id], emptyAll: false, in: VaultManagerFixture.anchor())

            await f.model.undo()

            #expect(f.model.error == String(
                localized: "This can’t be undone: the credential changed since, or its copy in Trash is gone. Nothing was changed."
            ))
            #expect(f.kinds == [.moveToTrash], "only the step that failed is dropped")
            #expect(try await f.liveIDs() == [accounts[2].id], "nothing was changed")

            await f.model.undo()

            #expect(f.model.error == nil)
            #expect(try await f.liveIDs() == [accounts[0].id, accounts[2].id], "the next Undo takes the step before it back")
            #expect(f.kinds.isEmpty)
        }
    }

    @Test func aBlockedUndoExplainsTheBlockAndKeepsTheVault() async throws {
        try await withFixture { f in
            var first = account("ada", on: "a")
            first.passkeys = [try VaultFixtures.passkey()]
            let second = account("grace", on: "b")
            try await f.seed([first, second])
            try await f.model.moveToTrash(ids: [first.id])
            // A live credential now holds the same passkey, so the one in Trash can't come back.
            var thief = second
            thief.passkeys = [try TrashFixtures.clone(of: try #require(first.passkeys.first))]
            try await VaultManagerFixture.save([thief], in: f.vault)
            try await f.model.reloadAfterWrite(epoch: try #require(f.model.authorizationEpoch))

            await f.model.undo()

            let message = try #require(f.model.error)
            #expect(message.contains(String(localized: UndeleteBlock.passkeyCollision.explanation)))
            #expect(try await f.liveIDs() == [second.id])
            #expect(f.kinds.isEmpty)
        }
    }

    @Test func undoWhileTheEditorIsOpenDoesNothing() async throws {
        try await withFixture { f in
            let accounts = [account("ada", on: "a"), account("grace", on: "b")]
            try await f.seed(accounts)
            try await f.model.moveToTrash(ids: [accounts[0].id])
            try await f.model.beginEditing(accountID: accounts[1].id)

            #expect(!f.model.canUndo && f.model.undoMenuTitle == nil)
            await f.model.undo()

            #expect(try await f.liveIDs() == [accounts[1].id])
            #expect(f.kinds == [.moveToTrash])
        }
    }
}
