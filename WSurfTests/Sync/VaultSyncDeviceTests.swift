// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import WebKit
import WSurfCore

@testable import WSurf
@testable import WSurfVault

// Vault sync through the real stores and managers (spec amendment 2026-10-22): two Macs of one profile id, over one fake cloud. Mac A is
// a hand-built store in its own folder; Mac B is the profile in the process-wide registry, where the app's own adoption runs. The
// passkeys are stubs that answer with the proof a test chooses, and the sync's hooks are called by the test unless a test installs
// `CloudSync.shared`. Serial: real stores, the manager registry and the process-wide `CloudSync.shared`.

@MainActor
@Suite(.serialized)
struct VaultSyncDeviceTests {
    // MARK: Two Macs, one passkey

    @Test func samePasskeyUnlocksAndConvergesBothWays() async throws {
        try await withDevicePair { pair in
            let held = [pair.account("one"), pair.account("two")]
            try await pair.save(held, in: pair.managerA)
            try await pair.enableA()

            try await pair.addToB()
            #expect(pair.statusB == .waitingForUnlock(2))
            try await pair.unlockB()
            try await pair.pump()
            let managerB = try #require(pair.managerB)

            let onB = try await pair.accounts(managerB)
            #expect(Set(onB.keys) == Set(held.map(\.id)) && onB.values.allSatisfy { $0.password == "pw" })
            #expect(pair.passkeysB.assertions.count == 1, "one prompt to add the vault")
            #expect(managerB.lastKeyCheck != nil && managerB.lastKeyCheck == pair.managerA.lastKeyCheck, "the same key on both Macs")
            #expect(pair.statusB == .synced && pair.statusA == .synced)

            // B changes the password: A has it, and its History has the old one as a change from another device.
            let target = held[0].id
            try await pair.edit(managerB, target) { $0.password = "from B" }
            await pair.wrote(pair.syncB, pair.clockB)
            try await pair.converge()
            #expect(try await pair.accounts(pair.managerA)[target]?.password == "from B")
            let history = try await pair.managerA.revisionLog()[target] ?? []
            #expect(history.contains { $0.cause == CredentialChangeCause.sync })

            // A deletes it: it is in B's Trash, with the account.
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let revision = try await pair.managerA.snapshot().revision
            _ = try await pair.managerA.delete(.account(target), expectedRevision: revision, authorizedEpoch: epoch)
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()
            #expect(try await pair.accounts(managerB)[target] == nil)
            #expect(try await managerB.trashPage(after: nil).items.contains { $0.ownerID == target })
            #expect(try await pair.accounts(managerB).count == 1 && pair.statusB == .synced)
        }
    }

    @Test func aMergeOnOneMacReachesTheOtherAsARemovedStateAndASurvivorUpdate() async throws {
        try await withDevicePair { pair in
            let survivor = VaultFixtures.account(username: "ada", password: "newer", origin: "https://one.test")
            let absorbed = VaultFixtures.account(username: "ada", password: "older", origin: "https://one.test")
            try await pair.save([survivor, absorbed], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            #expect(try await pair.accounts(managerB).count == 2)

            // The merge as the Merge sheet commits it: the survivor replaced, the other credential away in the same commit.
            let picks = try #require(CredentialMerge.defaultPicks(for: [survivor, absorbed], survivor: survivor.id))
            let result = try CredentialMerge.merged([survivor, absorbed], picks: picks)
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let revision = try await pair.managerA.snapshot().revision
            _ = try await pair.managerA.commit(
                [result], expectedRevision: revision, authorizedEpoch: epoch, cause: "merge", changing: [survivor.id, absorbed.id],
                merging: [absorbed.id: result.id]
            )
            await pair.wrote(pair.syncA, pair.clockA)

            for _ in 0..<3 {
                try await pair.converge()
                let onB = try await pair.accounts(managerB)
                #expect(onB[absorbed.id] == nil, "the credential merged away does not come back on B")
                #expect(onB[survivor.id]?.mergedFrom?.map(\.accountID) == [absorbed.id], "B’s survivor carries the link")
                #expect(try await managerB.trashPage(after: nil).items.contains { $0.ownerID == absorbed.id }, "and it is in B’s Trash")
                #expect(try await pair.accounts(pair.managerA)[absorbed.id] == nil)
                #expect(pair.statusA == .synced && pair.statusB == .synced)
            }
        }
    }

    @Test func differentPRFLeavesTheMacLockedAndUndamaged() async throws {
        try await withDevicePair { pair in
            try await pair.save([pair.account("one")], in: pair.managerA)
            try await pair.enableA()
            // B already holds an unlocked vault, which authorizes the new one.
            let made = try await VaultManagerFixture.make(profile: pair.profile, passkeys: pair.passkeysB, vaults: [.unlocked])
            try await pair.engineB.fetchNow()
            await pair.syncB.settle()
            let remote = try #require(pair.syncB.remoteVaults(profileID: pair.profile.id).first)
            let other = VaultUnlockProof(credentialID: pair.proof.credentialID, prfInput: pair.proof.prfInput, prf: SymmetricKey(size: .bits256))
            pair.passkeysB.answer = other
            let before = VaultManagerFixture.image(of: pair.profile.supportDirectory)
            var reported: String?

            do {
                _ = try await CredentialManager.adoptSyncedVault(
                    profile: pair.profile, remote: remote, in: VaultManagerFixture.anchor(), native: pair.passkeysB.native
                )
            } catch CredentialManagerError.syncKeyDiffers(let keyCheck) {
                reported = keyCheck
            }

            #expect(reported == CredentialVaultCrypto.keyCheck(prf: other.prf, credentialID: other.credentialID))
            #expect(reported != pair.managerA.lastKeyCheck)
            // SQLite rewrites its shared-memory index (`-shm`) whenever a connection reads; it holds no data.
            @MainActor func image() -> [String: Data] {
                VaultManagerFixture.image(of: pair.profile.supportDirectory).filter { !$0.key.hasSuffix("-shm") }
            }
            #expect(image() == before.filter { !$0.key.hasSuffix("-shm") }, "not one byte of the store changed")
            let store = try CredentialManager.store(for: pair.profile)
            #expect(try await store.listing().count == 1 && made.vaults[0].manager.isUnlocked, "its other vault still unlocks")
            #expect(pair.statusB == .off)
        }
    }

    @Test func aVaultIsNeverAddedToAnotherProfileThanItsZoneNames() async throws {
        try await withDevicePair { pair in
            try await pair.save([pair.account("one")], in: pair.managerA)
            try await pair.enableA()
            try await pair.engineB.fetchNow()
            await pair.syncB.settle()
            let remote = try #require(pair.syncB.remoteVaults(profileID: pair.profile.id).first)
            let stranger = try await VaultManagerFixture.newProfile("Stranger")
            defer { Task { await VaultManagerFixture.cleanup(stranger) } }
            let before = VaultManagerFixture.image(of: stranger.supportDirectory)

            for wrong in [stranger, Profile.privateBrowsing()] {
                do {
                    _ = try await CredentialManager.adoptSyncedVault(
                        profile: wrong, remote: remote, in: VaultManagerFixture.anchor(), native: pair.passkeysB.native
                    )
                    Issue.record("a vault was added to a profile its zone does not name")
                } catch CredentialManagerError.syncedVaultOfAnotherProfile {
                    // Refused before any prompt, so it is never mistaken for a key that differs.
                }
            }

            #expect(pair.passkeysB.assertions.isEmpty)
            #expect(VaultManagerFixture.image(of: stranger.supportDirectory) == before)
            #expect(pair.syncB.remoteVaults(profileID: stranger.id).isEmpty, "the card for that profile lists nothing")
        }
    }

    @Test func addingAProfileKeepsTheIDOfTheZone() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ProfileStore(file: file)
        let zone = UUID()

        let adopted = store.adopt(id: zone, name: "  Work  ", symbol: "no.such.symbol", color: .teal)

        #expect(adopted?.id == zone && adopted?.name == "Work" && adopted?.symbol == "person" && adopted?.color == .teal)
        #expect(store.profiles.contains { $0.id == zone })
        #expect(store.adopt(id: zone, name: "Again", symbol: "person", color: .gray) == nil, "never twice")
        #expect(store.adopt(id: Profile.originalID, name: "Original", symbol: "person", color: .gray) == nil)
        #expect(store.adopt(id: Profile.privateID, name: "Private", symbol: "person", color: .gray) == nil)
        let long = store.adopt(id: UUID(), name: String(repeating: "n", count: 200), symbol: "briefcase", color: .gray)
        #expect(long?.name.count == 64 && long?.symbol == "briefcase")
        #expect(ProfileStore(file: file).profiles.contains { $0.id == zone }, "kept for the next launch")
    }

    // MARK: What stays on each Mac

    @Test func historyTrashAndPurgeStayPerMac() async throws {
        try await withDevicePair { pair in
            let held = [pair.account("one"), pair.account("two")]
            try await pair.save(held, in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            let target = held[0].id

            let epoch = try #require(pair.managerA.authorizationEpoch)
            let revision = try await pair.managerA.snapshot().revision
            _ = try await pair.managerA.delete(.account(target), expectedRevision: revision, authorizedEpoch: epoch)
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()
            let onA = try await pair.managerA.trashPage(after: nil).items.map(\.id)
            let onB = try await managerB.trashPage(after: nil).items
            #expect(onA.count == 1 && onB.count == 1)

            // Emptying A's Trash is A's alone: nothing live changed, so nothing is sent, and B keeps its copy.
            let writes = pair.cloud.writeCount
            _ = try await pair.managerA.purge(entryIDs: onA, emptyAll: false, in: VaultManagerFixture.anchor())
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()

            #expect(try await pair.managerA.trashPage(after: nil).items.isEmpty)
            #expect(try await managerB.trashPage(after: nil).items.count == 1)
            #expect(pair.cloud.writeCount == writes)
            #expect(try await pair.accounts(managerB).count == 1 && pair.statusA == .synced && pair.statusB == .synced)
        }
    }

    /// Case (f) of importing a Passwords export again: a merge and a delete made on A reach B, and an import of the same export on B
    /// brings neither back, also once B emptied its Trash.
    @Test func aMergeAndADeleteSyncedInKeepAnImportOnTheOtherMacFromBringingThemBack() async throws {
        try await withDevicePair { pair in
            let coordinator = CredentialExchangeCoordinator()
            let owner = UUID()
            let file = CredentialCSV.encode([
                ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"],
                ["Ada", "https://ada.test/login", "ada", "pw", "", ""],
                ["Ada", "https://ada.test/login", "ada (1)", "pw", "", ""],
                ["Grace", "https://grace.test/login", "grace", "pw-g", "", ""],
            ])
            try await coordinator.beginCSVImport(file, into: pair.managerA, owner: owner) { _ in }
            _ = try await coordinator.commitImport(into: pair.managerA, owner: owner)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            #expect(try await pair.accounts(managerB).count == 3)

            // A merges the copy into ada and deletes grace.
            let onA = try await pair.managerA.snapshot()
            let ada = try #require(onA.accounts.first { $0.username == "ada" })
            let copy = try #require(onA.accounts.first { $0.username == "ada (1)" })
            let grace = try #require(onA.accounts.first { $0.username == "grace" })
            let picks = try #require(CredentialMerge.defaultPicks(for: [ada, copy], survivor: ada.id))
            let merged = try CredentialMerge.merged([ada, copy], picks: picks)
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let mergedRevision = try await pair.managerA.commit(
                onA.accounts.compactMap { $0.id == copy.id ? nil : ($0.id == ada.id ? merged : $0) }, expectedRevision: onA.revision,
                authorizedEpoch: epoch, cause: "merge", changing: [ada.id, copy.id], merging: [copy.id: ada.id]
            ).revision
            _ = try await pair.managerA.delete(.account(grace.id), expectedRevision: mergedRevision, authorizedEpoch: epoch)
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.converge()
            let onB = try await pair.accounts(managerB)
            #expect(onB.count == 1 && onB[ada.id]?.mergedFrom?.map(\.accountID) == [copy.id], "the merge reached B whole")

            // B imports the same export: nothing comes back, while the entries are in B's Trash and once it is emptied.
            for purged in [false, true] {
                if purged {
                    _ = try await managerB.purge(entryIDs: [], emptyAll: true, in: VaultManagerFixture.anchor())
                }
                try await coordinator.beginCSVImport(file, into: managerB, owner: owner) { _ in }
                let review = try #require(coordinator.importReview(for: managerB, owner: owner))
                #expect(review.isResolved && review.tally.new == 0 && review.tally.writes == 0, "purged: \(purged)")
                #expect(review.candidates.count == 2 && review.candidates.allSatisfy { $0.group == .skipped }, "purged: \(purged)")
                coordinator.cancelImport(for: managerB, owner: owner)
            }
            #expect(try await pair.accounts(managerB).count == 1)
        }
    }

    /// The same for a Mac that adds the vault after the merge and the delete, made before the vault synced at all: it never held the
    /// entries, and still an import there brings neither back.
    @Test func aMacThatAddsTheVaultLaterKeepsAnImportFromBringingBackWhatWasMergedOrDeletedBefore() async throws {
        try await withDevicePair { pair in
            let coordinator = CredentialExchangeCoordinator()
            let owner = UUID()
            let file = CredentialCSV.encode([
                ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"],
                ["Ada", "https://ada.test/login", "ada", "pw", "", ""],
                ["Ada", "https://ada.test/login", "ada (1)", "pw", "", ""],
                ["Grace", "https://grace.test/login", "grace", "pw-g", "", ""],
            ])
            try await coordinator.beginCSVImport(file, into: pair.managerA, owner: owner) { _ in }
            _ = try await coordinator.commitImport(into: pair.managerA, owner: owner)
            let onA = try await pair.managerA.snapshot()
            let ada = try #require(onA.accounts.first { $0.username == "ada" })
            let copy = try #require(onA.accounts.first { $0.username == "ada (1)" })
            let grace = try #require(onA.accounts.first { $0.username == "grace" })
            let picks = try #require(CredentialMerge.defaultPicks(for: [ada, copy], survivor: ada.id))
            let merged = try CredentialMerge.merged([ada, copy], picks: picks)
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let mergedRevision = try await pair.managerA.commit(
                onA.accounts.compactMap { $0.id == copy.id ? nil : ($0.id == ada.id ? merged : $0) }, expectedRevision: onA.revision,
                authorizedEpoch: epoch, cause: "merge", changing: [ada.id, copy.id], merging: [copy.id: ada.id]
            ).revision
            _ = try await pair.managerA.delete(.account(grace.id), expectedRevision: mergedRevision, authorizedEpoch: epoch)

            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            #expect(try await pair.accounts(managerB).keys.sorted() == [ada.id])
            #expect(try await managerB.trashPage(after: nil).items.isEmpty, "B never held them")

            try await coordinator.beginCSVImport(file, into: managerB, owner: owner) { _ in }
            let review = try #require(coordinator.importReview(for: managerB, owner: owner))
            #expect(review.isResolved && review.tally.new == 0 && review.tally.writes == 0)
            #expect(review.candidates.count == 2 && review.candidates.allSatisfy { $0.group == .skipped })
            coordinator.cancelImport(for: managerB, owner: owner)
            #expect(pair.statusA == .synced && pair.statusB == .synced)
        }
    }

    /// What an import remembers about entries merged away or deleted travels to the other Mac inside sealed bytes only: not in a record,
    /// not in a sync file at rest, not in the router’s file, and neither the digests nor the values they stand for.
    @Test func theImportMemoryTravelsAndRestsOnlyInsideSealedBytes() async throws {
        try await withDevicePair { pair in
            let coordinator = CredentialExchangeCoordinator()
            let owner = UUID()
            let file = CredentialCSV.encode([
                ["Title", "URL", "Username", "Password", "Notes", "OTPAuth"],
                ["Ada", "https://ada.test/login", "ada", "pw-ada-4711", "", ""],
                ["Ada", "https://ada.test/login", "ada (1)", "pw-copy-4712", "", ""],
                ["Grace", "https://grace.test/login", "grace", "pw-grace-4713", "note-grace-4714", ""],
            ])
            try await coordinator.beginCSVImport(file, into: pair.managerA, owner: owner) { _ in }
            _ = try await coordinator.commitImport(into: pair.managerA, owner: owner)
            let onA = try await pair.managerA.snapshot()
            let ada = try #require(onA.accounts.first { $0.username == "ada" })
            let copy = try #require(onA.accounts.first { $0.username == "ada (1)" })
            let grace = try #require(onA.accounts.first { $0.username == "grace" })
            let picks = try #require(CredentialMerge.defaultPicks(for: [ada, copy], survivor: ada.id))
            let merged = try CredentialMerge.merged([ada, copy], picks: picks)
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let mergedRevision = try await pair.managerA.commit(
                onA.accounts.compactMap { $0.id == copy.id ? nil : ($0.id == ada.id ? merged : $0) }, expectedRevision: onA.revision,
                authorizedEpoch: epoch, cause: "merge", changing: [ada.id, copy.id], merging: [copy.id: ada.id]
            ).revision
            _ = try await pair.managerA.delete(.account(grace.id), expectedRevision: mergedRevision, authorizedEpoch: epoch)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()

            // The digests the vault holds for what was merged away and deleted, and the values they stand for.
            let managerB = try #require(pair.managerB)
            var traces = try await pair.managerA.removedIdentifiers().items.compactMap(\.trace)
            let survivor = try #require(try await pair.accounts(managerB)[ada.id])
            traces += (survivor.mergedFrom ?? []).compactMap(\.trace)
            var digests: [Data] = []
            for trace in traces {
                digests += trace.logins
                digests += [trace.password, trace.note].compactMap { $0 }
            }
            #expect(digests.count >= 4, "there is something to look for")
            let words = ["pw-ada-4711", "pw-copy-4712", "pw-grace-4713", "note-grace-4714", "ada (1)", "grace"]
            let values: [Data] = words.map { Data($0.utf8) }
            let searched: [Data] = digests + values

            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let records = try #require(pair.cloud.records(in: zone))
            #expect(records.count >= 4)
            for record in records {
                #expect(SyncNeedles.firstFound(of: searched, in: record.payload) == nil, "\(record.type) record \(record.id.name)")
            }
            for sync in [pair.syncA, pair.syncB] {
                let state = try JSONEncoder().encode(SyncRouterState(engineState: Data("engine".utf8), vaults: sync.state))
                #expect(SyncNeedles.firstFound(of: searched, in: state) == nil, "the router’s file")
            }
            for directory in [pair.envA.directory, pair.profile.supportDirectory] {
                let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
                for file in files where file.lastPathComponent.hasPrefix("Credentials.sync") {
                    let bytes = try Data(contentsOf: file)
                    #expect(SyncNeedles.firstFound(of: searched, in: bytes) == nil, Comment(rawValue: file.lastPathComponent))
                }
            }
        }
    }

    @Test func syncNeverPromptsOrExtendsTheLease() async throws {
        try await withDevicePair { pair in
            let target = pair.account("one")
            try await pair.save([target], in: pair.managerA)
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let deadline = try pair.managerA.currentAccess().deadline
            let assertions = pair.passkeysA.assertions.count

            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            try await pair.edit(managerB, target.id) { $0.password = "from B" }
            await pair.wrote(pair.syncB, pair.clockB)
            try await pair.converge()

            #expect(try await pair.accounts(pair.managerA)[target.id]?.password == "from B")
            #expect(pair.passkeysA.assertions.count == assertions, "sync asked A for no passkey")
            #expect(pair.passkeysB.assertions.count == 1, "B was asked once, to add the vault")
            #expect(pair.managerA.authorizationEpoch == epoch)
            #expect(try pair.managerA.currentAccess().deadline == deadline, "no lease was extended or shortened")
        }
    }

    @Test func openEditorSaveAfterASyncedChangeIsRefused() async throws {
        try await withDevicePair { pair in
            let target = pair.account("one")
            try await pair.save([target], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            let epoch = try #require(pair.managerA.authorizationEpoch)
            let opened = try await pair.managerA.snapshot()

            try await pair.edit(managerB, target.id) { $0.password = "from B" }
            await pair.wrote(pair.syncB, pair.clockB)
            try await pair.converge()
            #expect(try await pair.accounts(pair.managerA)[target.id]?.password == "from B")

            var typed = opened.accounts
            typed[0].password = "typed on A"
            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await pair.managerA.commit(typed, expectedRevision: opened.revision, authorizedEpoch: epoch, changing: [target.id])
            }
            #expect(try await pair.accounts(pair.managerA)[target.id]?.password == "from B", "nothing was overwritten")
        }
    }

    @Test func inputHistoryAndFilesStayOnTheMac() async throws {
        try await withDevicePair { pair in
            let source = FileManager.default.temporaryDirectory.appending(path: "scan-\(UUID().uuidString).txt")
            try Data("body-\(UUID().uuidString)".utf8).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            // Input History is a file beside the vault in the profile's folder: sync neither reads nor touches it.
            let history = pair.envA.directory.appending(path: "InputHistory/\(pair.vaultID.uuidString).wih")
            let historyMarker = Data("typed-\(UUID().uuidString)".utf8)
            try FileManager.default.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
            try historyMarker.write(to: history)
            let file = try await pair.managerA.addAttachment(from: source)
            var entry = pair.account("one")
            entry.attachments = [file]
            try await pair.save([entry], in: pair.managerA)

            try await pair.enableA()

            let zone = SyncZone.vault(profileID: pair.profile.id, vaultID: pair.vaultID)
            let record = try #require(pair.cloud.record(SyncRecordID(zone: zone, name: entry.id.uuidString)))
            let opened = try VaultSyncCodec.openItem(record.payload, accountID: entry.id, key: try await pair.managerA.syncKey())
            #expect(opened.account?.attachments == nil && opened.account?.username == entry.username)
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.pump()
            let managerB = try #require(pair.managerB)
            #expect(try await pair.accounts(managerB)[entry.id]?.attachments == nil, "the added vault has no files")
            #expect(try await pair.accounts(pair.managerA)[entry.id]?.attachments == [file], "this Mac keeps its own")
            #expect(pair.statusA == .synced && pair.statusB == .synced)
            for record in pair.cloud.records(in: zone) ?? [] {
                #expect(record.payload.range(of: historyMarker) == nil)
            }
            #expect(try Data(contentsOf: history) == historyMarker, "this Mac's Input History is untouched")
            let onB = VaultManagerFixture.image(of: pair.profile.supportDirectory)
            #expect(onB.keys.allSatisfy { !$0.hasPrefix("InputHistory") }, "and the other Mac got none")
        }
    }

    @Test(arguments: [true, false])
    func reviewChoicesKeepTheOtherVersionRecoverable(keepLocal: Bool) async throws {
        try await withDevicePair { pair in
            let target = pair.account("one")
            try await pair.save([target], in: pair.managerA)
            try await pair.enableA()
            try await pair.addToB()
            try await pair.unlockB()
            try await pair.converge()
            let managerB = try #require(pair.managerB)
            try await pair.edit(pair.managerA, target.id) { $0.password = "from A" }
            await pair.wrote(pair.syncA, pair.clockA)
            try await pair.pump()
            try await pair.edit(managerB, target.id) { $0.password = "from B" }
            await pair.wrote(pair.syncB, pair.clockB)
            try await pair.pump()
            #expect(pair.statusB == .needsReview(1))
            #expect(try await pair.accounts(managerB)[target.id]?.password == "from B", "nothing applied before the choice")

            try await pair.syncB.resolve(profileID: pair.profile.id, vaultID: pair.vaultID, accountIDs: [target.id], keepLocal: keepLocal)
            try await pair.converge()

            let winner = keepLocal ? "from B" : "from A"
            #expect(try await pair.accounts(pair.managerA)[target.id]?.password == winner)
            #expect(try await pair.accounts(managerB)[target.id]?.password == winner)
            // The version not kept is in History on the Mac that had it, as a change from another device.
            let loser = keepLocal ? pair.managerA : managerB
            #expect(try await loser.revisionLog()[target.id]?.contains { $0.cause == CredentialChangeCause.sync } == true)
            #expect(pair.statusA == .synced && pair.statusB == .synced)
        }
    }

    // MARK: The app's wiring

    private static func gate(tabs: Bool, vaults: Bool) -> CloudSyncGate.Inputs {
        let held = CloudTabsTests.Launch.entitlements
        return CloudSyncGate.Inputs(
            tabsFlag: tabs, vaultFlag: vaults, isRunningTests: false, isStaged: false, ownsSession: true, entitlement: { held[$0] }
        )
    }

    @Test func theVaultFlagAloneCreatesTheEngineAndTabsJoinItLater() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cloud = FakeSyncCloud()
        var engines: [FakeSyncEngine] = []
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite(UUID().uuidString))!
        let started = CloudSync.start(
            gate: Self.gate(tabs: true, vaults: true), installIDs: MemoryInstallIDStorage(), stateFile: directory.appending(path: "iCloudSync.json"),
            profiles: [.original()], host: { CredentialVaultSyncHost(profiles: { [] }) }, optInDefaults: { _ in defaults },
            windows: { [] }, clock: TestClock(),
            makeEngine: { delegate, _ in
                let engine = FakeSyncEngine(cloud: cloud, delegate: delegate)
                engines.append(engine)
                return engine
            }
        )
        let cloudSync = try #require(started)
        let tabs = try #require(cloudSync.tabs)
        #expect(engines.count == 1, "the vault flag is the consent to fetch")
        #expect(cloudSync.vaults != nil)

        tabs.setOptIn(true, for: .original())
        try await engines[0].sendNow()

        #expect(engines.count == 1, "one engine for both")
        #expect(cloud.record(SyncRecordID(zone: SyncZone.devices, name: tabs.sync.installID)) != nil, "tabs ride the same engine")
        cloudSync.prepareToTerminate()
    }

    @Test func theVaultsKnowTheAccountTheTabsAlreadySawWhenTheyStart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "iCloudSync.json")
        // The tabs ran before the vault flag was turned on, and know the account; the vaults’ own state does not.
        var tabState = TabSyncState()
        tabState.accountUser = "user-1"
        try JSONEncoder().encode(tabState).write(to: CloudTabs.stateFile(besides: file))
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite(UUID().uuidString))!
        let cloud = FakeSyncCloud()
        var engines: [FakeSyncEngine] = []

        let started = CloudSync.start(
            gate: Self.gate(tabs: true, vaults: true), installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: [.original()],
            host: { CredentialVaultSyncHost(profiles: { [] }) }, optInDefaults: { _ in defaults }, windows: { [] }, clock: TestClock(),
            makeEngine: { delegate, _ in
                let engine = FakeSyncEngine(cloud: cloud, delegate: delegate)
                engines.append(engine)
                return engine
            }
        )

        let cloudSync = try #require(started)
        #expect(cloudSync.vaults?.state.accountUser == "user-1")
        cloudSync.prepareToTerminate()
    }

    @Test func onlyTheFlagsThatAreOnStartAFeature() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "iCloudSync.json")
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite(UUID().uuidString))!
        func start(tabs: Bool, vaults: Bool) -> CloudSync? {
            CloudSync.start(
                gate: Self.gate(tabs: tabs, vaults: vaults), installIDs: MemoryInstallIDStorage(), stateFile: file, profiles: [.original()],
                host: { CredentialVaultSyncHost(profiles: { [] }) }, optInDefaults: { _ in defaults }, windows: { [] }, clock: TestClock(),
                makeEngine: { delegate, _ in FakeSyncEngine(cloud: FakeSyncCloud(), delegate: delegate) }
            )
        }

        #expect(start(tabs: false, vaults: false) == nil)
        let tabsOnly = try #require(start(tabs: true, vaults: false))
        #expect(tabsOnly.tabs != nil && tabsOnly.vaults == nil)
        let vaultsOnly = try #require(start(tabs: false, vaults: true))
        #expect(vaultsOnly.tabs == nil && vaultsOnly.vaults != nil)
    }

    @Test func hooksReachTheSyncAndDeletionsDeleteTheirZones() async throws {
        let profile = try await VaultManagerFixture.newProfile("Hooks")
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        let cloud = FakeSyncCloud()
        var engines: [FakeSyncEngine] = []
        let made: (profile: Profile, passkeys: VaultPasskeys, vaults: [FixtureVault])
        do {
            made = try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked, .unlocked])
        } catch {
            await VaultManagerFixture.cleanup(profile)
            throw error
        }
        let started = CloudSync.start(
            gate: Self.gate(tabs: false, vaults: true), installIDs: MemoryInstallIDStorage(), stateFile: directory.appending(path: "iCloudSync.json"),
            profiles: [profile], host: { CredentialVaultSyncHost(profiles: { [profile] }) }, clock: clock,
            makeEngine: { delegate, _ in
                let engine = FakeSyncEngine(cloud: cloud, delegate: delegate)
                engines.append(engine)
                return engine
            }
        )
        let cloudSync = try #require(started)
        CloudSync.shared = cloudSync
        defer { CloudSync.shared = nil }
        let sync = try #require(cloudSync.vaults)
        let engine = try #require(engines.first)
        let (first, second) = (made.vaults[0], made.vaults[1])
        func zone(_ vault: FixtureVault) -> String {
            SyncZone.vault(profileID: profile.id, vaultID: vault.vaultID)
        }
        func send() async throws {
            for _ in 0..<4 {
                await sync.settle()
                try await engine.sendNow()
            }
        }

        try await sync.enable(profileID: profile.id, vaultID: first.vaultID)
        try await sync.enable(profileID: profile.id, vaultID: second.vaultID)
        try await send()
        #expect(cloud.zones[zone(first)] != nil && cloud.zones[zone(second)] != nil)

        // A write through the manager reaches the sync by itself (the hook in `writing`).
        let waiting = clock.pendingCount
        try await VaultManagerFixture.save([VaultFixtures.account(username: "hooked")], in: first)
        #expect(await waitUntil { clock.pendingCount > waiting }, "the write started the quiet moment")
        clock.advance(by: .seconds(2))
        for _ in 0..<20 {
            await Task.yield()
        }
        try await send()
        #expect(cloud.names(in: zone(first)).count == 2, "the vault record and the entry")

        // Deleting a vault deletes its zone, and only its zone (the hook after the store committed).
        let epoch = try #require(second.manager.authorizationEpoch)
        try await second.manager.deleteVault(authorizedEpoch: epoch, in: VaultManagerFixture.anchor())
        try await send()
        #expect(cloud.zones[zone(second)] == nil && cloud.zones[zone(first)] != nil)
        #expect(sync.status(profileID: profile.id, vaultID: second.vaultID) == .off)

        // Erasing the profile deletes the zones of the vaults it synced. Erasure removes the profile's WebKit data store, and WebKit's
        // removal crashes when it is the first WebKit call of the process (its main run loop is not set up yet): start WebKit first.
        _ = WKWebsiteDataStore.nonPersistent()
        await VaultManagerFixture.erase(profile)
        try await send()
        #expect(cloud.zones[zone(first)] == nil)
    }

    // MARK: The controls

    @Test func syncControlsAreAbsentWithoutSyncAndDrawnWithIt() async throws {
        let profile = try await VaultManagerFixture.newProfile("Controls")
        let made: (profile: Profile, passkeys: VaultPasskeys, vaults: [FixtureVault])
        do {
            made = try await VaultManagerFixture.make(profile: profile, vaults: [.unlocked])
        } catch {
            await VaultManagerFixture.cleanup(profile)
            throw error
        }
        defer { CloudSync.shared = nil }
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vault = made.vaults[0]
        let model = CredentialSettingsModel(profile: profile, manager: vault.manager)
        await model.load()
        func height(_ view: some View) -> CGFloat {
            let host = NSHostingView(rootView: view.frame(width: 600))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        func controls() -> (row: CGFloat, card: CGFloat) {
            (
                height(CloudVaultRow(model: model, run: { _ in })),
                height(VaultSyncCard(model: model, withWindow: { _ in }, showSettings: {}))
            )
        }

        CloudSync.shared = nil
        #expect(controls().row < 1 && controls().card < 1, "flag off: not one control")

        let started = CloudSync.start(
            gate: Self.gate(tabs: false, vaults: true), installIDs: MemoryInstallIDStorage(), stateFile: directory.appending(path: "iCloudSync.json"),
            profiles: [profile], host: { CredentialVaultSyncHost(profiles: { [profile] }) }, clock: TestClock(),
            makeEngine: { delegate, _ in FakeSyncEngine(cloud: FakeSyncCloud(), delegate: delegate) }
        )
        let cloudSync = try #require(started)
        CloudSync.shared = cloudSync
        let sync = try #require(cloudSync.vaults)
        #expect(controls().row > 20 && controls().card < 1, "the switch is there, nothing else yet")

        // Another Mac's vault of this profile is offered, and a synced vault says what it is doing.
        let list = try VaultWrapperList.encode(try SyncVaultFixtures.wrappers(SymmetricKey(size: .bits256), profile: profile.id, vault: UUID()))
        let payload = VaultRecordPayload(
            keyGeneration: 1, profile: VaultProfileCard(name: "Work", symbol: "briefcase", color: "blue"), wrappers: list, sealed: Data(count: 40)
        )
        let remote = SyncRecord(
            id: SyncRecordID(zone: SyncZone.vault(profileID: profile.id, vaultID: UUID()), name: "vault"), type: .vault, schema: 1,
            payload: try JSONEncoder().encode(payload)
        )
        await sync.handle(.fetched(modified: [remote], deleted: []))
        #expect(model.addableSyncedVaults.count == 1)
        #expect(controls().card > 20)
        try await sync.enable(profileID: profile.id, vaultID: vault.vaultID)
        #expect(model.syncStatus != nil && controls().row > 40, "the switch with its Remove from iCloud row")
        let statuses: [VaultSyncStatus] = [
            .off, .synced, .sending(2), .waitingForUnlock(2), .needsReview(1), .holdingRemovals(2), .iCloudFull, .signedOut, .needsUpdate, .rolledBack,
            .removed(.deleted), .removed(.purged), .removed(.encryptedDataReset), .removalFailed, .accountChanged,
        ]
        for status in statuses {
            #expect(!CloudVaultRow.statusText(status, isUnlocked: true).isEmpty)
        }
        // A deletion that waits for the owner is said whatever the status is, so a review does not hide it.
        let none = VaultSyncTally(notSyncable: 0, unreadable: 0, newer: 0)
        let asked = CloudVaultRow.statusText(.holdingRemovals(30), isUnlocked: true)
        for status in [VaultSyncStatus.needsReview(1), .synced, .sending(3), .holdingRemovals(30)] {
            #expect(CloudVaultRow.caption(status: status, held: 30, isUnlocked: true, tally: none).contains(asked))
        }
        #expect(!CloudVaultRow.caption(status: .needsReview(1), held: 0, isUnlocked: true, tally: none).contains(asked))
        await VaultManagerFixture.cleanup(profile)
    }
}
