// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

@testable import WSurf
@testable import WSurfVault

// What an import is kept from bringing back on a Mac that never held the entry, through the real stores and managers of two Macs
// (`DevicePair`): after an old blank tombstone, with the ids a Passwords-app transfer used, and without the digest of a password or a
// note. Serial: real stores and the manager registry.

@MainActor
@Suite(.serialized)
struct VaultSyncMemoryDeviceTests {
    private static let rows = [
        ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"],
        ["Ada", "https://ada.test/login", "ada", "pw-ada-4711", "", ""],
        ["Grace", "https://grace.test/login", "grace", "pw-grace-4713", "note-grace-4714", ""],
    ]

    private func importOnA(_ pair: DevicePair, _ coordinator: CredentialExchangeCoordinator, owner: UUID) async throws -> [String: CredentialAccount] {
        try await coordinator.beginCSVImport(CredentialCSV.encode(Self.rows), into: pair.managerA, owner: owner) { _ in }
        _ = try await coordinator.commitImport(into: pair.managerA, owner: owner)
        let accounts = try await pair.managerA.snapshot().accounts
        return Dictionary(accounts.map { ($0.username, $0) }) { first, _ in first }
    }

    private func delete(_ account: CredentialAccount, on manager: CredentialManager) async throws {
        let epoch = try #require(manager.authorizationEpoch)
        let revision = try await manager.snapshot().revision
        _ = try await manager.delete(.account(account.id), expectedRevision: revision, authorizedEpoch: epoch)
    }

    /// The tombstones of `manager`'s vault for the entry `id`.
    private func tombstones(_ manager: CredentialManager, of id: UUID) async throws -> [RemovedIdentifier] {
        try await manager.removedIdentifiers().items.filter { $0.isTombstone && $0.accountID == id && $0.passkeyCredentialID == nil }
    }

    // MARK: A blank tombstone

    /// B has a tombstone for the entry from before imports remembered anything: it knows the entry and no login. The removal that A
    /// sends teaches it, so a CSV import on B does not bring the entry back.
    @Test func anOldBlankTombstoneDoesNotLetAnImportBringBackAnEntryDeletedOnTheOtherMac() async throws {
        try await withDevicePair { pair in
            let coordinator = CredentialExchangeCoordinator()
            let owner = UUID()
            let onA = try await importOnA(pair, coordinator, owner: owner)
            let grace = try #require(onA["grace"])
            try await delete(grace, on: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            let managerB = try #require(pair.managerB)
            try await pair.unlockBWithoutSync()
            try await pair.rememberBlank(grace.id, in: managerB)
            #expect(try await tombstones(managerB, of: grace.id).allSatisfy { $0.trace?.logins.isEmpty == true }, "it kept no login")
            pair.syncB.vaultUnlocked(profileID: pair.profile.id, vaultID: pair.vaultID)
            await pair.syncB.settle()
            try await pair.converge()

            let learned = try await tombstones(managerB, of: grace.id).flatMap { $0.trace?.logins ?? [] }
            #expect(learned.count == 1, "the removal taught it the login")
            try await coordinator.beginCSVImport(CredentialCSV.encode(Self.rows), into: managerB, owner: owner) { _ in }
            let review = try #require(coordinator.importReview(for: managerB, owner: owner))
            #expect(review.isResolved && review.tally.new == 0 && review.tally.writes == 0)
            #expect(review.tally.skipped == 1 && review.candidates.map(\.group) == [.skipped], "grace is left out, and ada, which B holds, needs no row")
            coordinator.cancelImport(for: managerB, owner: owner)
            #expect(try await pair.accounts(managerB).count == 1 && pair.statusA == .synced && pair.statusB == .synced)
        }
    }

    // MARK: A Passwords-app transfer

    /// A brought an item in from the Passwords app and deleted it before the vault synced. B joins and never held it, and a transfer of
    /// the same item on B is not brought back: the two ids it was exported under came with the removed state.
    @Test func aPasswordsAppImportOnAMacThatNeverHeldTheEntryDoesNotBringItBack() async throws {
        try await withDevicePair { pair in
            let coordinator = CredentialExchangeCoordinator()
            let owner = UUID()
            let exchange = CredentialExchangeCoordinatorTests()
            let transfer = exchange.handBuilt([exchange.item(id: 1, scoped: true, [exchange.password("pw-passwords-app-4715")])])
            try await pair.stageTransfer(transfer, with: coordinator, into: pair.managerA, owner: owner)
            _ = try await coordinator.commitImport(into: pair.managerA, owner: owner)
            let imported = try #require(try await pair.managerA.snapshot().accounts.first)
            let ids = (try #require(imported.exchangeAccountID), try #require(imported.exchangeItemID))
            try await delete(imported, on: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()

            let managerB = try #require(pair.managerB)
            let (heldOnB, trashOnB) = (try await pair.accounts(managerB), try await managerB.trashPage(after: nil))
            #expect(heldOnB.isEmpty && trashOnB.items.isEmpty, "B never held it")
            let kept = try #require(try await tombstones(managerB, of: imported.id).first)
            #expect(kept.exchangeAccountID == ids.0 && kept.exchangeItemID == ids.1, "the ids came with the removed state")

            try await pair.stageTransfer(transfer, with: coordinator, into: managerB, owner: owner)
            let review = try #require(coordinator.importReview(for: managerB, owner: owner))
            #expect(review.candidates.flatMap(\.records).allSatisfy { $0.destination == .skipped } && review.tally.new == 0)
            coordinator.cancelImport(for: managerB, owner: owner)
            #expect(pair.statusA == .synced && pair.statusB == .synced)
        }
    }

    // MARK: Digests

    /// A deletes an entry that has a password and a note, and empties its Trash. What A leaves, and what B keeps for an entry it never
    /// held, are the digests of the logins and no more; and an import on B still does not bring either entry back.
    @Test func aDeletedEntryLeavesNoPasswordOrNoteDigestOnEitherMac() async throws {
        try await withDevicePair { pair in
            let coordinator = CredentialExchangeCoordinator()
            let owner = UUID()
            let onA = try await importOnA(pair, coordinator, owner: owner)
            let grace = try #require(onA["grace"])
            let ada = try #require(onA["ada"])
            let before = try #require(grace.importTrace)
            #expect(before.password != nil && before.note != nil, "the import recorded them")
            try await delete(grace, on: pair.managerA)
            try await delete(ada, on: pair.managerA)
            let trashed = try await pair.managerA.trashPage(after: nil).items
            let adaEntry = try #require(trashed.first { $0.ownerID == ada.id })
            _ = try await pair.managerA.purge(entryIDs: [adaEntry.id], emptyAll: false, in: VaultManagerFixture.anchor())

            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)

            for (manager, name) in [(pair.managerA, "A"), (managerB, "B")] {
                for entry in [grace, ada] {
                    let rows = try await tombstones(manager, of: entry.id)
                    for trace in rows.compactMap(\.trace) {
                        #expect(trace.logins.count == 1 && trace.password == nil && trace.note == nil, "\(name): \(entry.username)")
                    }
                }
            }
            let (purgedOnA, graceOnB, adaOnB) = (
                try await tombstones(pair.managerA, of: ada.id), try await tombstones(managerB, of: grace.id),
                try await tombstones(managerB, of: ada.id)
            )
            #expect(purgedOnA.count == 1, "A purged ada, so it has a tombstone for it")
            #expect(graceOnB.count == 1 && adaOnB.count == 1, "B never held either")

            try await coordinator.beginCSVImport(CredentialCSV.encode(Self.rows), into: managerB, owner: owner) { _ in }
            let review = try #require(coordinator.importReview(for: managerB, owner: owner))
            #expect(review.tally.new == 0 && review.tally.writes == 0 && review.tally.skipped == 2)
            coordinator.cancelImport(for: managerB, owner: owner)
        }
    }
}
