// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation
import Testing
import WSurfCore

@testable import WSurfVault

// What a removed entry leaves for a Mac that never held it (`RemovedMemory`): the keyed digests of its logins and the ids its exporter
// gave it, never the digest of a password or a note; and when a removal that arrives is kept in addition to what this Mac's own
// tombstone already knows. Nothing here touches CloudKit, the Keychain or a real vault.

private typealias Rig = VaultSyncRig

@MainActor
struct VaultSyncMemoryTests {
    private static let exchangeAccount = Data([0xA0, 0x01])
    private static let exchangeItem = Data([0xB0, 0x07])

    private func key(_ rig: Rig) -> ImportMemoryKey {
        ImportMemoryKey.derive(dek: rig.dek, profileID: rig.profile, vaultID: rig.vaultID)
    }

    private func exchanged(_ account: CredentialAccount, item: UInt8) -> CredentialAccount {
        var result = account
        result.exchangeAccountID = Self.exchangeAccount
        result.exchangeItemID = Data([0xB0, item])
        return result
    }

    // MARK: Which removals are kept

    /// A tombstone from before imports remembered anything knows the entry and nothing it stood for, so the removal that arrives later
    /// still teaches it the logins: a CSV import there would otherwise bring the entry back.
    @Test func anOldBlankTombstoneLearnsTheLoginsFromARemovalThatArrivesLater() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let entries = syncAccounts(3)
        let (a, va) = try rig.mac(holding: entries)
        va.remove(entries[0].id)
        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()

        let (d, vd) = try await rig.addedMac(unlock: false)
        vd.addOldTombstone(entries[0].id)
        await d.unlock(vd)
        try await converge([a, d])

        let login = key(rig).login(origin: "https://site0.test", username: "user0")
        #expect(vd.tombstoneKept[entries[0].id]?.trace?.logins == [login], "the removal taught the old tombstone's entry its login")
        #expect(Set(vd.accounts.keys) == [entries[1].id, entries[2].id] && vd.trash.isEmpty)
        #expect(rig.status(a) == .synced && rig.status(d) == .synced)
    }

    /// The decision on its own: a removal is kept unless this Mac's removals of the entry already keep its logins and its ids.
    @Test func aRemovalIsKeptOnlyForWhatTheMacsOwnRemovalsDoNotKeepYet() throws {
        let id = UUID()
        let login = Data(repeating: 3, count: ImportMemoryKey.digestBytes)
        let memory = RemovedMemory(logins: [login], exchangeAccountID: Self.exchangeAccount, exchangeItemID: Self.exchangeItem)
        let item = SyncItem(accountID: id, version: 1, account: nil, memory: memory)
        let expected = SyncDecision.remember(memory, SyncBase(version: 1, parts: .removedParts))
        func removal(isTombstone: Bool = true, trace: ImportTrace?, ids: Bool) -> RemovedIdentifier {
            RemovedIdentifier(
                entryID: UUID(), isTombstone: isTombstone, accountID: id, exchangeAccountID: ids ? Self.exchangeAccount : nil,
                exchangeItemID: ids ? Self.exchangeItem : nil, passkeyCredentialID: nil, rpID: nil, removedAt: nil, trace: trace
            )
        }
        func decision(_ rows: [RemovedIdentifier]) throws -> SyncDecision {
            try CredentialSyncMerge.decide(item, local: nil, base: nil, index: SyncLocalIndex(accounts: [], removed: RemovedIdentifiers(items: rows)))
        }
        #expect(try decision([]) == expected, "nothing here yet")
        #expect(try decision([removal(trace: nil, ids: false)]) == expected, "an old tombstone: the entry and nothing else")
        #expect(try decision([removal(trace: ImportTrace(logins: []), ids: false)]) == expected, "a blank trace keeps no login")
        #expect(try decision([removal(trace: ImportTrace(logins: [login]), ids: false)]) == expected, "the logins, but not the ids")
        #expect(try decision([removal(trace: ImportTrace(logins: []), ids: true)]) == expected, "the ids, but not the logins")
        let kept = SyncDecision.keep(SyncBase(version: 1, parts: .removedParts))
        #expect(try decision([removal(trace: ImportTrace(logins: [login]), ids: true)]) == kept, "its own tombstone has both")
        #expect(try decision([removal(isTombstone: false, trace: ImportTrace(logins: [login]), ids: true)]) == kept, "so does its Trash entry")
        #expect(try decision([removal(trace: nil, ids: false), removal(trace: ImportTrace(logins: [login]), ids: true)]) == kept)
        // Only logins to keep: the ids are not asked for.
        let loginsOnly = SyncItem(accountID: id, version: 1, account: nil, memory: RemovedMemory(logins: [login]))
        let index = SyncLocalIndex(
            accounts: [], removed: RemovedIdentifiers(items: [removal(trace: ImportTrace(logins: [login]), ids: false)])
        )
        #expect(try CredentialSyncMerge.decide(loginsOnly, local: nil, base: nil, index: index) == kept)
    }

    // MARK: What is kept

    /// The two ids a Passwords-app item was exported under travel with the removed state, sealed, and are kept in the tombstone of a Mac
    /// that never held the entry: before the vault synced, and after.
    @Test func theExchangeIDsOfARemovedEntryReachAMacThatNeverHeldIt() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let plain = syncAccounts(3)
        let entries = [exchanged(plain[0], item: 1), exchanged(plain[1], item: 2), plain[2]]
        let (a, va) = try rig.mac(holding: entries)
        va.remove(entries[0].id)
        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()
        va.remove(entries[1].id)
        await a.wrote(va)
        try await a.pump()

        for entry in entries.prefix(2) {
            let told = try VaultSyncCodec.openItem(#require(rig.item(entry)).payload, accountID: entry.id, key: va.syncKey)
            #expect(told.account == nil && told.memory?.exchangeAccountID == entry.exchangeAccountID)
            #expect(told.memory?.exchangeItemID == entry.exchangeItemID && told.memory?.logins.count == 1)
        }
        let (d, vd) = try await rig.addedMac()
        try await converge([a, d])

        #expect(Set(vd.accounts.keys) == [entries[2].id] && vd.trash.isEmpty, "D never held them")
        for entry in entries.prefix(2) {
            let kept = try #require(vd.tombstoneKept[entry.id])
            #expect(kept.exchangeAccountID == entry.exchangeAccountID && kept.exchangeItemID == entry.exchangeItemID)
            #expect(kept.trace?.logins.count == 1)
        }
        #expect(rig.status(a) == .synced && rig.status(d) == .synced)
    }

    /// A removed entry tells the keyed digests of its logins and no more: not the digest of its password or its note, whether it was
    /// removed before the vault synced or after. (What the stores keep is checked with the real stores, `VaultSyncMemoryDeviceTests`.)
    @Test func aRemovedStateTellsTheLoginsOfTheEntryAndNeverThePasswordOrNoteDigest() async throws {
        let rig = Rig()
        defer { rig.finish() }
        let memory = key(rig)
        var entry = SyncVaultFixtures.account(username: "ada", password: "pw-secret-4711", origin: "https://ada.test", notes: ["note-secret-4712"])
        entry.importTrace = memory.trace(of: entry)
        let trace = try #require(entry.importTrace)
        #expect(trace.password != nil && trace.note != nil, "there is something to look for")
        var later = SyncVaultFixtures.account(username: "grace", password: "pw-secret-4713", origin: "https://grace.test", notes: ["note-secret-4714"])
        later.importTrace = memory.trace(of: later)
        let laterTrace = try #require(later.importTrace)
        let (a, va) = try rig.mac(holding: [entry, later])
        va.remove(entry.id)
        try await a.sync.enable(profileID: rig.profile, vaultID: rig.vaultID)
        try await a.pump()
        va.remove(later.id)
        await a.wrote(va)
        try await a.pump()

        // The first was removed before the vault synced and the second after: the same two things are told for both.
        for (gone, kept) in [(entry, trace), (later, laterTrace)] {
            let told = try VaultSyncCodec.openItem(#require(rig.item(gone)).payload, accountID: gone.id, key: va.syncKey)
            let sealed = try JSONEncoder().encode(#require(told.memory))
            let digests = [try #require(kept.password), try #require(kept.note)]
            #expect(told.memory?.logins == kept.logins, "its logins are told")
            #expect(SyncNeedles.firstFound(of: digests, in: sealed) == nil, "its password and note digests are not")
        }

        // A Mac that never held them keeps those logins.
        let (d, vd) = try await rig.addedMac()
        try await converge([a, d])
        #expect(vd.tombstoneKept[entry.id]?.trace?.logins == trace.logins && vd.tombstoneKept[later.id]?.trace?.logins == laterTrace.logins)
    }

    // MARK: The memory itself

    @Test func aMemoryKeepsOnlyWhatFitsAndOnlyWhatIsValid() throws {
        let long = Data(repeating: 7, count: RemovedMemory.idLimit + 1)
        let fitting = Data(repeating: 7, count: RemovedMemory.idLimit)
        let memory = RemovedMemory(exchangeAccountID: long, exchangeItemID: fitting)
        #expect(memory.exchangeAccountID == nil && memory.exchangeItemID == fitting && !memory.isEmpty)
        #expect(RemovedMemory(exchangeAccountID: long, exchangeItemID: Data()).isEmpty, "an id that does not fit, or is empty, is left out")
        #expect(RemovedMemory().isEmpty && !RemovedMemory(logins: [Data(repeating: 1, count: 32)]).isEmpty)
        let digests = [Data(repeating: 2, count: 32), Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]
        #expect(RemovedMemory(logins: digests).logins == [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)], "sorted, once")

        // A removed state that is not a memory of digests is refused, and an empty memory is no memory.
        let syncKey = VaultSyncKey.derive(dek: SymmetricKey(size: .bits256), profileID: UUID(), vaultID: UUID())
        let id = UUID()
        let bad = SyncItem(accountID: id, version: 2, account: nil, memory: RemovedMemory(logins: [Data([1])]))
        #expect(throws: VaultSyncError.malformed) { try VaultSyncCodec.sealItem(bad, key: syncKey) }
        let blank = SyncItem(accountID: id, version: 2, account: nil, memory: RemovedMemory())
        #expect(blank.memory == nil)
        let sealed = try VaultSyncCodec.sealItem(blank, key: syncKey)
        #expect(sealed.count == VaultSyncCodec.headerBytes + VaultSyncCodec.sealOverhead)
    }
}
