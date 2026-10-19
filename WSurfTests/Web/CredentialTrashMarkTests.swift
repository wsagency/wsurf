// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

// X in the Trash marks entries for deletion: they are hidden at once, Undo shows them again, and leaving the Trash deletes the whole
// batch with one fresh assertion. A lock, a declined prompt or a closed page deletes nothing. Test-only in-memory unlock keys and
// synthetic credentials.

@MainActor
struct CredentialTrashMarkTests {
    private final class Fixture {
        let profile: Profile
        let passkeys = VaultPasskeys()
        let vault: FixtureVault
        let model: CredentialSettingsModel
        private let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))

        @MainActor init() async throws {
            let profile = Profile(id: UUID(), name: "Marks", symbol: "key", color: .blue)
            vault = try #require(try await VaultManagerFixture.make(profile: profile, passkeys: passkeys, vaults: [.unlocked]).vaults.first)
            self.profile = profile
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: vault.manager)
        }

        /// `count` credentials moved to the Trash and the Trash opened. Returns the Trash entries, oldest first.
        @MainActor func fillTrash(_ count: Int = 3) async throws -> [TrashItem] {
            let accounts = (0..<count).map { VaultFixtures.account(username: "user\($0)", password: "pw", origin: "https://site\($0).example.test") }
            try await VaultManagerFixture.save(accounts, in: vault)
            await model.load()
            for account in accounts {
                try await model.moveToTrash(ids: [account.id])
            }
            try await model.loadTrash()
            return accounts.compactMap { account in model.trashItems.first { $0.ownerID == account.id } }
        }

        @MainActor func storedEntries() async throws -> Int {
            try await vault.manager.trashPage(after: nil).items.count
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

    @Test func xHidesTheEntryAndLowersTheCount() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            #expect(f.model.trashTotal == 3 && f.model.trashItems.count == 3)

            f.model.markForDeletion(entryIDs: [entries[0].id])

            #expect(Set(f.model.trashItems.map(\.id)) == [entries[1].id, entries[2].id])
            #expect(f.model.trashTotal == 2)
            #expect(f.model.markedCount == 1)
            #expect(try await f.storedEntries() == 3, "nothing is deleted yet")
            #expect(f.kinds.last == .markForDeletion)
            #expect(f.model.notice?.offersUndo == true)
        }
    }

    @Test func undoUnmarksInOrderUpToFive() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash(7)
            let revision = try await f.vault.manager.snapshot().revision
            for entry in entries.prefix(6) {
                f.model.markForDeletion(entryIDs: [entry.id])
            }
            #expect(f.model.markedCount == 6)
            #expect(f.kinds.count == 5 && f.kinds.allSatisfy { $0 == .markForDeletion }, "the oldest steps were dropped")

            for position in stride(from: 5, through: 1, by: -1) {
                await f.model.undo()
                #expect(f.model.trashItems.contains { $0.id == entries[position].id }, "the newest mark is undone first")
                #expect(f.model.error == nil)
            }

            #expect(f.model.markedCount == 1)
            #expect(f.model.trashItems.count == 6)
            #expect(try await f.vault.manager.snapshot().revision == revision, "marking and unmarking write nothing")
            #expect(try await f.storedEntries() == 7)
        }
    }

    @Test func leavingTrashPurgesTheBatchWithOneAssertion() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            f.model.markForDeletion(entryIDs: [entries[0].id])
            f.model.markForDeletion(entryIDs: [entries[2].id])
            let assertions = f.passkeys.assertions.count

            await f.model.commitMarked(in: VaultManagerFixture.anchor())

            #expect(f.passkeys.assertions.count == assertions + 1, "one prompt for the whole batch")
            #expect(try await f.vault.manager.trashPage(after: nil).items.map(\.id) == [entries[1].id])
            #expect(f.model.trashItems.map(\.id) == [entries[1].id])
            #expect(f.model.trashTotal == 1)
            #expect(f.model.markedCount == 0)
            #expect(!f.kinds.contains(.markForDeletion))
            #expect(f.model.notice?.text == String(localized: "Deleted 2 items permanently."))
            #expect(f.model.error == nil)
        }
    }

    @Test func deleteNowDeletesTheBatchAndTheTrashStaysOpen() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            f.model.markForDeletion(entryIDs: entries.map(\.id))
            #expect(f.model.trashTotal == 0 && f.model.trashItems.isEmpty)

            await f.model.commitMarked(in: VaultManagerFixture.anchor())

            #expect(try await f.storedEntries() == 0)
            #expect(f.model.trashTotal == 0)
            #expect(f.model.isUnlocked && f.model.markedCount == 0)
        }
    }

    @Test func aDeclinedAssertionDeletesNothingAndClearsTheMarks() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            f.model.markForDeletion(entryIDs: [entries[0].id, entries[1].id])
            f.passkeys.beforeAssert = { throw PasskeyUnlockError.appCancelled }

            await f.model.commitMarked(in: VaultManagerFixture.anchor())

            #expect(try await f.storedEntries() == 3, "nothing was deleted")
            #expect(f.model.markedCount == 0)
            #expect(f.model.trashItems.count == 3, "the entries show again")
            #expect(f.model.notice?.text == String(localized: "Nothing was deleted."))
            #expect(f.model.error == nil, "a cancelled prompt is not an error")
        }
    }

    @Test func anAssertionOfAnotherPasskeyDeletesNothing() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            f.model.markForDeletion(entryIDs: [entries[0].id])
            f.passkeys.answer = VaultFixtures.proof(9)

            await f.model.commitMarked(in: VaultManagerFixture.anchor())

            #expect(try await f.storedEntries() == 3)
            #expect(f.model.markedCount == 0)
            #expect(f.model.error == CredentialSettingsModel.message(for: CredentialVaultError.authenticationFailed))
            #expect(f.model.notice?.text == String(localized: "Nothing was deleted."))
        }
    }

    @Test func aLockBeforeLeavingDeletesNothing() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            f.model.markForDeletion(entryIDs: entries.map(\.id))
            f.vault.manager.lock(reason: .manual)
            #expect(f.model.markedCount == 0, "the marks went with the session")

            try await VaultManagerFixture.unlock(f.vault)
            await f.model.load()
            await f.model.commitMarked(in: VaultManagerFixture.anchor())

            #expect(try await f.storedEntries() == 3)
            #expect(f.passkeys.assertions.isEmpty, "no prompt was ever asked for")
        }
    }

    @Test func closingThePageDeletesNothing() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            f.model.markForDeletion(entryIDs: [entries[0].id])

            f.model.close()
            await f.model.load()
            try await f.model.loadTrash()

            #expect(f.model.markedCount == 0)
            #expect(f.model.trashItems.count == 3)
            #expect(try await f.storedEntries() == 3)
            #expect(f.passkeys.assertions.isEmpty)
        }
    }

    @Test func emptyingTheTrashEndsTheMarks() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            f.model.markForDeletion(entryIDs: [entries[0].id])
            f.model.requestPurge(entryIDs: [], emptyAll: true)

            await f.model.confirmPurge(in: VaultManagerFixture.anchor())

            #expect(try await f.storedEntries() == 0)
            #expect(f.model.markedCount == 0)
            #expect(!f.kinds.contains(.markForDeletion))
        }
    }

    @Test func marksSurviveAReloadOfTheTrashAndIgnoreWhatIsNotListed() async throws {
        try await withFixture { f in
            let entries = try await f.fillTrash()
            f.model.markForDeletion(entryIDs: [entries[0].id, UUID()])
            let stack = f.kinds

            try await f.model.loadTrash()
            f.model.markForDeletion(entryIDs: [UUID()])
            f.model.markForDeletion(entryIDs: [entries[0].id])

            #expect(f.model.markedCount == 1)
            #expect(Set(f.model.trashItems.map(\.id)) == [entries[1].id, entries[2].id])
            #expect(f.kinds == stack, "an entry that is not listed, or already marked, makes no step")
        }
    }
}
