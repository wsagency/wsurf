// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// Model-level checks of Trash, restore, permanent delete and earlier versions. Test-only in-memory unlock keys; no native
// ceremony and nothing here is evidence of Apple provider behavior.

@MainActor
struct CredentialSettingsHistoryTests {
    private final class Fixture {
        let profile: Profile
        let passkeys = VaultPasskeys()
        let vault: FixtureVault
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "History", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, passkeys: passkeys, vaults: [.locked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        }

        @MainActor func unlockAndLoad() async throws {
            try await VaultManagerFixture.unlock(vault)
            await model.load()
        }

        @MainActor func save(_ accounts: [CredentialAccount]) async throws {
            try await VaultManagerFixture.save(accounts, in: vault)
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

    private func account(_ username: String, id: UUID = UUID(), password: String? = "pw") -> CredentialAccount {
        CredentialAccount(
            id: id, username: username, displayName: nil, origins: ["https://example.test"],
            loginURLs: [URL(string: "https://example.test/login")!], password: password, passkeys: [], totp: nil,
            exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    @Test func trashPagesAndReportsTheVerifiedTotal() async throws {
        try await withFixture { f in
            let keeper = account("keeper")
            let extra = StoreFormat.historyPage + 10
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([keeper] + (0..<extra).map { account("user\($0)") })
            try await f.save([keeper])
            await f.model.load()

            try await f.model.loadTrash()
            #expect(f.model.trashItems.count == StoreFormat.historyPage)
            #expect(f.model.trashTotal == extra)
            #expect(f.model.trashHasMore)

            try await f.model.loadMoreTrash()
            #expect(f.model.trashItems.count == extra)
            #expect(Set(f.model.trashItems.map(\.id)).count == extra)
            #expect(!f.model.trashHasMore)
            #expect(f.model.trashTotal == extra)
        }
    }

    @Test func purgeConfirmationDoesNotSurviveCancelOrLock() async throws {
        try await withFixture { f in
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([account("a"), account("b")])
            try await f.save([])
            await f.model.load()
            try await f.model.loadTrash()
            #expect(f.model.trashTotal == 2)

            f.model.requestPurge(entryIDs: [], emptyAll: true)
            let pending = try #require(f.model.pendingPurge)
            #expect(pending.emptyAll && pending.count == 2 && pending.warning.logicalOnly)
            f.model.cancelPurge()
            #expect(f.model.pendingPurge == nil)

            // A listed entry only; an unlisted id is refused.
            f.model.requestPurge(entryIDs: [UUID()], emptyAll: false)
            #expect(f.model.pendingPurge == nil)
            f.model.requestPurge(entryIDs: [f.model.trashItems[0].id], emptyAll: false)
            #expect(f.model.pendingPurge?.count == 1)

            f.vault.manager.lock(reason: .manual)
            #expect(f.model.pendingPurge == nil)
            #expect(f.model.trashItems.isEmpty && f.model.trashTotal == nil)
            await f.model.confirmPurge(in: VaultManagerFixture.anchor())
            #expect(f.model.error != nil)

            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()
            try await f.model.loadTrash()
            #expect(f.model.trashTotal == 2)
        }
    }

    @Test func confirmedPurgeEmptiesTheTrashAndIsSingleUse() async throws {
        try await withFixture { f in
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([account("a")])
            try await f.save([])
            await f.model.load()
            try await f.model.loadTrash()

            f.model.requestPurge(entryIDs: [], emptyAll: true)
            await f.model.confirmPurge(in: VaultManagerFixture.anchor())
            #expect(f.model.pendingPurge == nil)
            #expect(f.model.trashTotal == 0 && f.model.trashItems.isEmpty)

            await f.model.confirmPurge(in: VaultManagerFixture.anchor())
            #expect(f.model.error != nil)
        }
    }

    @Test func refusedPurgeKeepsTheConfirmationSoItCanBeRetried() async throws {
        try await withFixture { f in
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([account("a")])
            try await f.save([])
            await f.model.load()
            try await f.model.loadTrash()

            f.model.requestPurge(entryIDs: [], emptyAll: true)
            let pending = try #require(f.model.pendingPurge)

            // A passkey the vault does not enrol: refused. The confirmation and the Trash both stay.
            f.passkeys.answer = VaultFixtures.proof(9)
            await f.model.confirmPurge(in: VaultManagerFixture.anchor())
            #expect(f.model.pendingPurge == pending)
            #expect(f.model.error != nil)
            #expect(try await f.vault.manager.trashPage(after: nil).items.count == 1)

            // The same confirmation, with the enrolled passkey, then purges once and is consumed.
            f.passkeys.answer = nil
            f.model.error = nil
            await f.model.confirmPurge(in: VaultManagerFixture.anchor())
            #expect(f.model.pendingPurge == nil)
            #expect(f.model.error == nil)
            #expect(f.model.trashTotal == 0)
        }
    }

    @Test func blockedRestoreWritesNothingAndOffersTheSameCopyOrDismiss() async throws {
        try await withFixture { f in
            let gone = account("gone")
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([gone])
            try await f.save([])
            // The same account id is live again, so restoring the Trash copy would collide.
            try await f.save([account("replacement", id: gone.id)])
            await f.model.load()
            try await f.model.loadTrash()
            let entry = try #require(f.model.trashItems.first)
            let before = try await f.vault.manager.snapshot()

            await f.model.restore(entryID: entry.id)
            let blocked = try #require(f.model.restoreBlocked)
            #expect(blocked.entryID == entry.id)
            #expect(blocked.actions == [.retrySameCopy, .dismiss])
            #expect(try await f.vault.manager.snapshot().revision == before.revision)
            #expect(f.model.trashTotal == 1)

            // Retrying the same copy is refused the same way; dismissing clears it.
            await f.model.restore(entryID: entry.id)
            #expect(f.model.restoreBlocked == blocked)
            f.model.dismissRestoreBlock()
            #expect(f.model.restoreBlocked == nil)
            #expect(try await f.vault.manager.snapshot().revision == before.revision)
        }
    }

    @Test func restoreBringsBackAnAccountAndLeavesTheTrashEmpty() async throws {
        try await withFixture { f in
            let gone = account("gone", password: "secret")
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([gone])
            try await f.save([])
            await f.model.load()
            try await f.model.loadTrash()
            let entry = try #require(f.model.trashItems.first)

            await f.model.restore(entryID: entry.id)
            #expect(f.model.restoreBlocked == nil && f.model.error == nil)
            #expect(try await f.vault.manager.snapshot().accounts.map(\.id) == [gone.id])
            #expect(f.model.trashTotal == 0)
        }
    }

    @Test func aPasskeyIsNeverRestoredFromAnEarlierVersion() {
        #expect(RecordSubject.password.restoresFromEarlierVersions)
        #expect(RecordSubject.totp.restoresFromEarlierVersions)
        #expect(RecordSubject.metadata.restoresFromEarlierVersions)
        #expect(!RecordSubject.passkey.restoresFromEarlierVersions)
        #expect(!RecordSubject.account.restoresFromEarlierVersions)
    }

    // MARK: History panel

    /// A stored credential whose password was changed once, so one earlier version exists.
    private func seedChangedPassword(_ f: Fixture, id: UUID, notes: [CredentialNote]? = nil) async throws {
        try await VaultManagerFixture.unlock(f.vault)
        var first = account("ada", id: id, password: "old")
        first.notes = notes
        try await f.save([first])
        var second = account("ada", id: id, password: "new")
        second.notes = notes
        try await f.save([second])
        await f.model.load()
    }

    @Test func historyOpensForTheEditedCredential() async throws {
        try await withFixture { f in
            let id = UUID()
            try await seedChangedPassword(f, id: id)
            #expect(f.model.history == nil)

            try await f.model.openHistory(accountID: id)
            #expect(f.model.draft?.accountID == id)
            let history = try #require(f.model.history)
            #expect(history.versions.count == 2)
            #expect(history.versions[0].isCurrent && history.versions[0].account.password == "new")
            #expect(history.versions[1].account.password == "old" && history.versions[1].changed == [.password])
            // The newest earlier version is the one shown first; nothing is unmasked.
            #expect(history.selected == history.versions[1].id)
            #expect(!history.revealsSecrets && history.next == nil)

            // Closing the editor closes History with it.
            f.model.cancelEditing()
            #expect(f.model.history == nil)
        }
    }

    @Test func historyOnAnotherCredentialStartsThatEdit() async throws {
        try await withFixture { f in
            let first = UUID(), second = UUID()
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([account("ada", id: first, password: "a1")])
            try await f.save([account("ada", id: first, password: "a2"), account("grace", id: second, password: "g1")])
            try await f.save([account("ada", id: first, password: "a2"), account("grace", id: second, password: "g2")])
            await f.model.load()

            try await f.model.beginEditing(accountID: first)
            try await f.model.openHistory(accountID: second)
            #expect(f.model.draft?.accountID == second)
            #expect(f.model.history?.accountID == second)
            #expect(f.model.history?.versions[1].account.password == "g1")

            // Opening another draft drops the History of the one it replaces.
            try await f.model.beginEditing(accountID: first)
            #expect(f.model.history == nil)
        }
    }

    @Test func historyRefusesADraftTheVaultHasMovedPast() async throws {
        try await withFixture { f in
            let id = UUID()
            try await seedChangedPassword(f, id: id)
            try await f.model.beginEditing(accountID: id)
            try await f.save([account("ada", id: id, password: "newest")])

            await #expect(throws: CredentialVaultError.staleRevision) { try await f.model.openHistory(accountID: id) }
            #expect(f.model.history == nil)
        }
    }

    @Test func copyToCurrentChangesOnlyTheDraft() async throws {
        try await withFixture { f in
            let id = UUID()
            try await seedChangedPassword(f, id: id)
            try await f.model.openHistory(accountID: id)
            let before = try await f.vault.manager.snapshot()
            let older = try #require(f.model.history?.versions[1].id)

            f.model.copyToDraft(.login, from: older)
            #expect(f.model.draft?.password == "old")
            #expect(f.model.draft?.changesNothing == false)
            // Nothing is stored, and no earlier version is added, until Save.
            let after = try await f.vault.manager.snapshot()
            #expect(after.revision == before.revision && after.accounts == before.accounts)
            #expect(try await f.vault.manager.revisionPage(accountID: id, after: nil).items.count == 1)

            // An id History does not list is ignored.
            f.model.copyToDraft(.name, from: UUID())
            f.model.selectVersion(UUID())
            #expect(f.model.history?.selected == older)
        }
    }

    @Test func savingACopiedPasswordKeepsTheReplacedOneAsAVersion() async throws {
        try await withFixture { f in
            let id = UUID()
            try await seedChangedPassword(f, id: id)
            try await f.model.openHistory(accountID: id)
            f.model.copyToDraft(.login, from: f.model.history?.versions[1].id)

            _ = try await f.model.commitDraft()
            #expect(try await f.vault.manager.snapshot().accounts.first?.password == "old")
            #expect(f.model.history == nil && f.model.draft == nil)

            try await f.model.openHistory(accountID: id)
            let versions = try #require(f.model.history?.versions)
            #expect(versions.map(\.account.password) == ["old", "new", "old"])
        }
    }

    @Test func hidingHistoryDropsTheVersionsButKeepsTheEdit() async throws {
        try await withFixture { f in
            let id = UUID()
            try await seedChangedPassword(f, id: id)
            try await f.model.openHistory(accountID: id)
            try await f.model.revealHistorySecrets()
            f.model.copyToDraft(.login, from: f.model.history?.versions[1].id)

            f.model.closeHistory()
            #expect(f.model.history == nil)
            #expect(f.model.draft?.password == "old", "the copied value stays in the draft")

            // Showing it again reads the stored versions, masked, and leaves the edited draft alone.
            try await f.model.openHistory(accountID: id)
            #expect(f.model.history?.versions.map(\.account.password) == ["new", "old"])
            #expect(f.model.history?.revealsSecrets == false)
            #expect(f.model.draft?.password == "old")
        }
    }

    @Test func aRemovedNoteIsAVersionThatCanBeAddedBack() async throws {
        try await withFixture { f in
            let id = UUID()
            let kept = CredentialNote(text: "kept", field: nil), removed = CredentialNote(text: "removed", field: nil)
            try await VaultManagerFixture.unlock(f.vault)
            var stored = account("ada", id: id)
            stored.notes = [kept, removed]
            try await f.save([stored])
            stored.notes = [kept]
            try await f.save([stored])
            await f.model.load()

            try await f.model.openHistory(accountID: id)
            let older = try #require(f.model.history?.versions[1])
            #expect(older.changed == [.note] && older.account.notes == [kept, removed])
            f.model.copyToDraft(.note(1), from: older.id)
            #expect(f.model.draft?.notes == [kept, removed])
            // Adding it again changes nothing.
            f.model.copyToDraft(.note(1), from: older.id)
            #expect(f.model.draft?.notes.count == 2)

            _ = try await f.model.commitDraft()
            #expect(try await f.vault.manager.snapshot().accounts.first?.notes == [kept, removed])
        }
    }

    @Test func lockDropsTheHistoryAndItsSecrets() async throws {
        try await withFixture { f in
            let id = UUID()
            try await seedChangedPassword(f, id: id)
            try await f.model.openHistory(accountID: id)
            try await f.model.revealHistorySecrets()
            #expect(f.model.history?.revealsSecrets == true)

            f.vault.manager.lock(reason: .manual)
            #expect(f.model.history == nil && f.model.draft == nil)
            await #expect(throws: (any Error).self) { try await f.model.revealHistorySecrets() }

            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()
            #expect(f.model.history == nil && f.model.draft == nil)
        }
    }

    @Test func secretsStayHiddenUntilShownUnderTheCurrentUnlock() async throws {
        try await withFixture { f in
            let id = UUID()
            try await seedChangedPassword(f, id: id)
            await #expect(throws: CredentialVaultError.invalidData) { try await f.model.revealHistorySecrets() }

            try await f.model.openHistory(accountID: id)
            #expect(f.model.history?.revealsSecrets == false)
            try await f.model.revealHistorySecrets()
            #expect(f.model.history?.revealsSecrets == true)
            f.model.hideSecrets()
            #expect(f.model.history?.revealsSecrets == false)
            try await f.model.revealHistorySecrets()
            f.model.hideHistorySecrets()
            #expect(f.model.history?.revealsSecrets == false)

            // A new unlock starts again with everything hidden and nothing loaded.
            try await f.model.revealHistorySecrets()
            f.vault.manager.lock(reason: .manual)
            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()
            #expect(f.model.history == nil)
            try await f.model.openHistory(accountID: id)
            #expect(f.model.history?.revealsSecrets == false)
        }
    }

    @Test func olderVersionsLoadPageByPage() async throws {
        try await withFixture { f in
            let id = UUID()
            let changes = StoreFormat.historyPage + 2
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([account("ada", id: id, password: "pw-0")])
            for index in 1...changes {
                try await f.save([account("ada", id: id, password: "pw-\(index)")])
            }
            await f.model.load()

            try await f.model.openHistory(accountID: id)
            let first = try #require(f.model.history)
            #expect(first.values.count == StoreFormat.historyPage && first.next != nil)
            #expect(first.versions.count == StoreFormat.historyPage + 1)
            #expect(first.versions.last?.account.password == "pw-2")

            try await f.model.loadOlderVersions()
            let all = try #require(f.model.history)
            #expect(all.values.count == changes && all.next == nil)
            #expect(all.versions.count == changes + 1)
            #expect(all.versions.last?.account.password == "pw-0")
            #expect(Set(all.values.map(\.item.id)).count == changes)
            // Nothing follows the last page.
            try await f.model.loadOlderVersions()
            #expect(f.model.history?.values.count == changes)
        }
    }

    @Test func savingAnUnchangedDraftWritesNothing() async throws {
        try await withFixture { f in
            let existing = account("ada", password: "pw")
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([existing])
            await f.model.load()
            try await f.model.beginEditing(accountID: existing.id)
            #expect(f.model.draft?.changesNothing == true)
            let before = try await f.vault.manager.snapshot().revision

            _ = try await f.model.commitDraft()
            #expect(try await f.vault.manager.snapshot().revision == before)
        }
    }

    @Test func lastUnlockPasskeyCannotBeRemoved() async throws {
        try await withFixture { f in
            try await f.unlockAndLoad()
            let only = try #require(f.vault.manager.unlockCredentials.first)
            #expect(f.vault.manager.unlockCredentials.count == 1)
            f.model.requestUnlockRemoval(credentialID: only.credentialID)
            #expect(f.model.pendingUnlockRemoval == nil)
            #expect(f.model.error != nil)
        }
    }

    @Test func refusedUnlockRemovalKeepsTheConfirmationSoItCanBeRetried() async throws {
        try await withFixture { f in
            try await f.unlockAndLoad()
            _ = try await f.vault.manager.addUnlock(in: VaultManagerFixture.anchor())
            let extra = try #require(f.passkeys.registered.last)
            f.model.requestUnlockRemoval(credentialID: extra.credentialID)
            let pending = try #require(f.model.pendingUnlockRemoval)

            f.passkeys.answer = VaultFixtures.proof(9)
            await f.model.confirmUnlockRemoval(pending, in: VaultManagerFixture.anchor())
            #expect(f.model.pendingUnlockRemoval == pending)
            #expect(f.model.error != nil)
            #expect(f.vault.manager.unlockCredentials.count == 2)

            f.passkeys.answer = nil
            f.model.error = nil
            await f.model.confirmUnlockRemoval(pending, in: VaultManagerFixture.anchor())
            #expect(f.model.pendingUnlockRemoval == nil)
            #expect(f.vault.manager.unlockCredentials.count == 1)
        }
    }
}
