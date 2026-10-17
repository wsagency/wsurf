// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The review and commit of the passwords saved before Credential Manager, through the real coordinator and a real fixture vault.
// The old list is a `MemoryAutofillStorage`; the fixture builders live in `CredentialExchangeCoordinatorTests`.
@MainActor
extension CredentialExchangeCoordinatorTests {
    private func legacy(_ username: String, _ password: String, website: String = Self.origin) throws -> SavedPassword {
        try SavedPassword(website: website, username: username, password: password)
    }

    private func bytes(_ account: CredentialAccount) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(account)
    }

    /// The old list holding `entries`, and the storage it lives in.
    private func oldList(_ entries: [SavedPassword], for profile: Profile) async throws -> (SecureAutofillVault<SavedPassword>, MemoryAutofillStorage) {
        let storage = MemoryAutofillStorage()
        let vault = SecureAutofillVault<SavedPassword>(profileID: profile.id, kind: "passwords", reason: "Test", storage: storage)
        _ = try await vault.update { _ in entries }
        return (vault, storage)
    }

    private func stage(
        _ f: Fixture, _ entries: [SavedPassword], using coordinator: CredentialExchangeCoordinator? = nil,
        onEnding: @escaping CredentialExchangeCoordinator.Ending = { _ in }
    ) async throws {
        try await (coordinator ?? f.coordinator).beginLegacyImport(entries, into: f.manager, owner: f.owner, onEnding: onEnding)
    }

    /// Decides the review row that came from entry number `entry` of the old list.
    private func decide(_ f: Fixture, _ choice: CredentialImportChoice, entry: Int) throws {
        let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
        let record = try #require(review.candidates.flatMap(\.records).first { $0.csvLine == entry })
        try f.coordinator.choose(choice, for: record.incoming, owner: f.owner)
    }

    @Test func legacyImportCommitsAndARerunFindsEverythingSaved() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(2))
            let list = try [legacy("ada", "pw-1"), legacy("grace", "pw-2", website: "https://other.test")]
            var messages: [CredentialTransferMessage] = []
            f.coordinator.onMessage = { messages.append($0) }

            try await stage(f, list)
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.origin == .legacyPasswords)
            #expect(review.csvReport?.rowsRead == 2 && review.csvReport?.alreadySaved == 0 && review.csvReport?.issues.isEmpty == true)
            #expect(counts(review.outcome) == [2, 0])

            // Entry 2 is left for later: only entry 1 is saved, and it carries nothing the old list did not have.
            try decide(f, .skip, entry: 2)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let afterFirst = try await f.stored().accounts
            let ada = try #require(afterFirst.first { $0.username == "ada" })
            #expect(ada.password == "pw-1" && ada.origins == [Self.origin] && ada.notes == nil)
            #expect(ada.passkeys.isEmpty && ada.totp == nil && ada.exchangeAccountID == nil && ada.exchangeItemID == nil)
            #expect(afterFirst.count == 3)
            #expect(messages.last == .succeeded(CredentialImportOutcome(added: 1, updated: 0), receipt: try #require(messages.last?.receipt), origin: .legacyPasswords))
            #expect(LegacyPasswordMigration.missing(list, in: afterFirst).map(\.username) == ["grace"])

            // Running it again repeats only what is left.
            try await stage(f, list)
            let second = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(second.csvReport?.alreadySaved == 1 && counts(second.outcome) == [1, 0])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let afterSecond = try await f.stored().accounts
            #expect(afterSecond.count == 4 && LegacyPasswordMigration.missing(list, in: afterSecond).isEmpty)

            // Once everything is saved there is nothing left to stage.
            try await stage(f, list)
            let third = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(third.csvReport?.alreadySaved == 2 && third.candidates.isEmpty)
        }
    }

    @Test func cancellingTheLegacyReviewWritesNothingAndKeepsTheList() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(2))
            let before = try f.diskBytes()
            let list = try [legacy("ada", "pw-1")]
            let (vault, storage) = try await oldList(list, for: f.profile)
            var messages: [CredentialTransferMessage] = []
            f.coordinator.onMessage = { messages.append($0) }

            try await stage(f, try await vault.records())
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(f.coordinator.importOrigin(for: f.manager, owner: f.owner) == .legacyPasswords)

            #expect(f.coordinator.cancelImport(for: f.manager, owner: f.owner) == .reviewCancelled)
            #expect(messages == [.discarded(.legacyPasswords)])
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(try f.diskBytes() == before)
            #expect(try await vault.records() == list)
            #expect(storage.itemCount == 1 && storage.eraseCount == 0)
        }
    }

    @Test func lockingDuringTheLegacyReviewDiscardsWithLegacyWording() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(2))
            let before = try f.diskBytes()
            let (vault, storage) = try await oldList([legacy("ada", "pw-1")], for: f.profile)
            var messages: [CredentialTransferMessage] = []
            var windowHeard: [CredentialTransferMessage] = []
            f.coordinator.onMessage = { messages.append($0) }

            try await stage(f, try await vault.records()) { windowHeard.append($0) }
            f.manager.lock(reason: .screenLock)

            #expect(messages == [.discarded(.legacyPasswords)] && windowHeard == messages)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(try f.diskBytes() == before)
            #expect(try await vault.records().count == 1 && storage.eraseCount == 0)
        }
    }

    @Test func aSkippedConflictKeepsTheVaultValueAndCountsAsMissing() async throws {
        try await withFixture { f in
            try await f.seed([account(username: "ada", password: "vault-value")] + neighbours(2))
            let before = try f.diskBytes()
            let list = try [legacy("ada", "list-value")]

            try await stage(f, list)
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.conflicts.count == 1 && !review.isResolved)
            try decide(f, .skip, entry: 1)

            // Everything was skipped: nothing is written, and the removal dialog still has to count the entry as lost.
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .nothingImported)
            #expect(try f.diskBytes() == before)
            let accounts = try await f.stored().accounts
            #expect(accounts.first { $0.username == "ada" }?.password == "vault-value")
            #expect(LegacyPasswordMigration.missing(list, in: accounts).count == 1)
        }
    }

    @Test func replaceSavedOverwritesOnlyTheReviewedAccount() async throws {
        try await withFixture { f in
            let target = account(username: "ada", password: "vault-value")
            let others = neighbours(3)
            try await f.seed([target] + others)
            let neighboursBefore = try others.map(bytes)
            let list = try [legacy("ada", "list-value"), legacy("heidi", "new-value")]

            try await stage(f, list)
            let conflict = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.conflicts.first)
            try f.coordinator.choose(.replace, for: conflict.incoming, owner: f.owner)
            #expect(counts(f.coordinator.importReview(for: f.manager, owner: f.owner)?.outcome) == [1, 1])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            let after = try await f.stored().accounts
            #expect(after.first { $0.id == target.id }?.password == "list-value")
            #expect(after.first { $0.username == "heidi" }?.password == "new-value")
            #expect(after.count == 5)
            let neighboursAfter = try others.map { other in try bytes(try #require(after.first { $0.id == other.id })) }
            #expect(neighboursAfter == neighboursBefore)
            #expect(LegacyPasswordMigration.missing(list, in: after).isEmpty)
        }
    }

    @Test func aLostSessionBeforeCommitLeavesVaultAndListUntouched() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(2))
            let before = try f.diskBytes()
            let list = try [legacy("ada", "pw-1"), legacy("grace", "pw-2")]
            let (vault, storage) = try await oldList(list, for: f.profile)

            try await stage(f, try await vault.records())
            // The session is gone (the app was restarted, or this coordinator was dropped): a new one has no import to commit.
            let fresh = CredentialExchangeCoordinator()
            await #expect(throws: CredentialExchangeCoordinatorError.noStagedImport) {
                _ = try await fresh.commitImport(into: f.manager, owner: f.owner)
            }
            f.coordinator.cancelImport(for: f.manager, owner: f.owner)
            #expect(try f.diskBytes() == before)
            #expect(try await vault.records() == list && storage.eraseCount == 0)

            // Reviewing again stages the same rows, and committing them writes exactly once.
            try await stage(f, try await vault.records(), using: fresh)
            let review = try #require(fresh.importReview(for: f.manager, owner: f.owner))
            #expect(counts(review.outcome) == [2, 0])
            _ = try await fresh.commitImport(into: f.manager, owner: f.owner)
            let after = try await f.stored().accounts
            #expect(after.count == 4 && LegacyPasswordMigration.missing(list, in: after).isEmpty)
            #expect(try await vault.records() == list && storage.eraseCount == 0)
            fresh.cancelImport(for: f.manager, owner: f.owner)
        }
    }

    @Test func aListTooLargeForTheVaultEndsTheReviewWithoutWriting() async throws {
        try await withFixture { f in
            let room = CredentialVaultLimits.accounts
            #expect(room > 2)
            // Staging checks the room before anything is written; a vault already at its limit cannot take a new entry.
            let full = (0..<room).map { account(username: "full-\($0)", password: "pw-\($0)") }
            try await f.seed(full)
            let before = try f.diskBytes()
            var messages: [CredentialTransferMessage] = []
            f.coordinator.onMessage = { messages.append($0) }

            let failure = await #expect(throws: CredentialTransferFailure.self) { try await stage(f, [legacy("ada", "pw-1")]) }
            #expect(failure?.message == .applyFailed(operation: String(localized: "Import"), .legacyPasswords))
            #expect(messages == [failure?.message].compactMap { $0 })
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(try f.diskBytes() == before)
        }
    }
}
