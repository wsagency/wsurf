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

    @Test func restoringAnEarlierPasswordKeepsTheReplacedOneAsAVersion() async throws {
        try await withFixture { f in
            let id = UUID()
            try await VaultManagerFixture.unlock(f.vault)
            try await f.save([account("ada", id: id, password: "old")])
            try await f.save([account("ada", id: id, password: "new")])
            await f.model.load()
            try await f.model.loadVersions(accountID: id)
            let item = try #require(f.model.revisionItems.first { $0.subject == .password })

            await f.model.restoreVersion(revisionID: item.id)
            #expect(f.model.error == nil)
            #expect(try await f.vault.manager.snapshot().accounts.first?.password == "old")
            // The replaced value is itself now an earlier version.
            #expect(f.model.versionsAccountID == id)
            #expect(f.model.revisionItems.count >= 2)
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
