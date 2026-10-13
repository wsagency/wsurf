// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Darwin
import Foundation
import GRDB
import SQLite3
import Testing

@testable import WSurf

// MARK: - Helpers

private nonisolated func threeAccounts() -> [CredentialAccount] {
    [
        VaultFixtures.account(username: "ada", origin: "https://a.example"),
        VaultFixtures.account(username: "grace", origin: "https://b.example"),
        VaultFixtures.account(username: "edsger", origin: "https://c.example"),
    ]
}

private nonisolated let blocked = ["https://a.example", "https://b.example"]

/// `verify` must fail with `integrityFailure` (any ordinal): not succeed, not throw anything else.
private nonisolated func expectIntegrityFailure(sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("verification succeeded on a tampered store", sourceLocation: sourceLocation)
    } catch CredentialStoreError.integrityFailure {
    } catch {
        Issue.record("expected integrityFailure, got \(error)", sourceLocation: sourceLocation)
    }
}

private nonisolated func scratchContents(_ directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
}

private nonisolated func posixMode(_ url: URL) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    return (attributes[.posixPermissions] as? NSNumber)?.intValue
}

private nonisolated func setMode(_ url: URL, _ mode: Int) {
    try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
}

private nonisolated func attachedDatabases(_ writer: DatabasePool) throws -> [String] {
    try writer.writeWithoutTransaction { db in
        try Row.fetchAll(db, sql: "PRAGMA database_list").map { row -> String in
            let name: String = row["name"]
            return name
        }
    }
}

private nonisolated final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        stored.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

nonisolated func residentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    // A silent 0 would make every "bounded growth" benchmark pass vacuously (and `precondition` is the only failure that works from a
    // detached sampler), so an unreadable or zero size stops the run.
    precondition(result == KERN_SUCCESS && info.resident_size > 0, "task_info(MACH_TASK_BASIC_INFO) failed: \(result)")
    return Int64(info.resident_size)
}

/// A support directory whose `Credentials.scratch` is a symlink to a directory OUTSIDE it that holds one SENTINEL file. The
/// outside directory and the sentinel carry unusual modes, so a `chmod` through the link is visible too.
private nonisolated struct LinkedScratchRoot {
    static let sentinelBytes = Data("SENTINEL: never deleted, never rewritten".utf8)

    let support: VaultTestEnvironment
    let outside: VaultTestEnvironment
    let sentinel: URL

    var root: URL {
        VerificationScratch.directory(in: support.directory)
    }

    init() throws {
        support = try VaultTestEnvironment.make()
        outside = try VaultTestEnvironment.make()
        sentinel = outside.directory.appendingPathComponent("SENTINEL")
        try Self.sentinelBytes.write(to: sentinel)
        setMode(outside.directory, 0o750)
        setMode(sentinel, 0o640)
        try FileManager.default.createSymbolicLink(
            at: VerificationScratch.directory(in: support.directory), withDestinationURL: outside.directory
        )
    }

    func cleanUp() {
        support.cleanUp()
        outside.cleanUp()
    }

    /// Nothing behind the link was deleted, rewritten, chmod-ed or added to, and the link itself is still a link.
    func expectUntouched(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect((try? Data(contentsOf: sentinel)) == Self.sentinelBytes, sourceLocation: sourceLocation)
        #expect(scratchContents(outside.directory) == ["SENTINEL"], sourceLocation: sourceLocation)
        #expect(posixMode(outside.directory) == 0o750, sourceLocation: sourceLocation)
        #expect(posixMode(sentinel) == 0o640, sourceLocation: sourceLocation)
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) != nil, "the root is still a link",
            sourceLocation: sourceLocation
        )
    }
}

// MARK: - Tamper matrix

/// One adversarial edit of an otherwise valid store, applied with raw SQL or by re-sealing. Every case must make
/// V1-V5 throw `integrityFailure`. Source-vault cases use two MOVEs (delete then undelete) so the journal holds plain
/// rows and transfer rows; Trash and transfer-pair cases use one.
nonisolated enum VaultTamper: CaseIterable, CustomTestStringConvertible {
    // V2 live rows
    case liveFlipped, liveDeleted, liveExtraRow, liveOtherVaultAAD, liveOlderVersion, liveForeignStore, liveWrongDigest, liveSwappedCiphertext
    // V3 journal chain and V4 ledger through the journal
    case journalTruncated, journalReordered, journalForgedChain, journalMissingRow, journalForgedOps, journalAddsExistingID, journalRemovesAbsentID
    // V1 heads
    case headStale, headPlaintextRevision, headLinkNonce, headWrongProfile
    // V4 history rows
    case historyDeleted, historyFlipped, historySwapped, historyVersionReplayed, historyForeignStore, historyExtraRow
    // V5 transfer pairs (each leaves both ledgers internally consistent)
    case transferIDSplit, transferDuplicateOut, transferOwnerMismatch, transferEntryMismatch, transferMovedSetMismatch
    // Header fields and a moved row's identity, edited on the Trash side only (each leaves V1-V4 consistent).
    case transferScopeMismatch, transferSubjectMismatch, transferLiveRecordMismatch, transferLiveVersionMismatch
    case movedRowVersionMismatch, movedRowOwnerMismatch, movedRowSubjectMismatch

    var testDescription: String { "\(self)" }

    var moves: Int {
        switch self {
        case .transferIDSplit, .transferDuplicateOut, .transferOwnerMismatch, .transferEntryMismatch, .transferMovedSetMismatch,
            .transferScopeMismatch, .transferSubjectMismatch, .transferLiveRecordMismatch, .transferLiveVersionMismatch,
            .movedRowVersionMismatch, .movedRowOwnerMismatch, .movedRowSubjectMismatch:
            1
        default:
            2
        }
    }

    func fixture() throws -> VaultStoreFixture {
        try VaultStoreFixture.make(accounts: threeAccounts(), blockedOrigins: blocked, historyRows: 3, moves: moves)
    }

    /// Routes to the per-vulnerability-class appliers; the switch is exhaustive, so a new case cannot be left unrouted.
    func apply(to f: inout VaultStoreFixture) throws {
        switch self {
        case .liveFlipped, .liveDeleted, .liveExtraRow, .liveOtherVaultAAD, .liveOlderVersion, .liveForeignStore, .liveWrongDigest,
            .liveSwappedCiphertext:
            try applyLive(&f)
        case .journalTruncated, .journalReordered, .journalForgedChain, .journalMissingRow, .journalForgedOps, .journalAddsExistingID,
            .journalRemovesAbsentID:
            try applyJournal(&f)
        case .headStale, .headPlaintextRevision, .headLinkNonce, .headWrongProfile:
            try applyHead(&f)
        case .historyDeleted, .historyFlipped, .historySwapped, .historyVersionReplayed, .historyForeignStore, .historyExtraRow:
            try applyHistory(&f)
        case .transferIDSplit, .transferDuplicateOut, .transferOwnerMismatch, .transferEntryMismatch, .transferMovedSetMismatch,
            .transferScopeMismatch, .transferSubjectMismatch, .transferLiveRecordMismatch, .transferLiveVersionMismatch,
            .movedRowVersionMismatch, .movedRowOwnerMismatch, .movedRowSubjectMismatch:
            try applyTransfer(&f)
        }
    }

    private func applyLive(_ f: inout VaultStoreFixture) throws {
        let source = f.vaultID, trash = f.trashID
        let account = f.accounts[1]  // never moved, so its live row is the original seal
        let foreign = StoreIDs(storeID: UUID(), profileID: f.ids.profileID)
        switch self {
        case .liveFlipped:
            let row = try f.storedRecord(source, account.id)
            try Self.put(&f, row, sealed: VaultStoreFixture.flipped(row.sealed))
        case .liveDeleted:
            try f.mutate { try StoreTables.deleteRecord($0, vaultID: source, recordID: account.id) }
        case .liveExtraRow:
            let extra = VaultFixtures.account(username: "extra", origin: "https://extra.example")
            let sealed = try VaultStoreFixture.sealAccount(extra, ids: f.ids, vaultID: source, key: f.dek)
            let row = StoreTables.RecordRow(
                vaultID: source, recordID: extra.id, kind: .account, ownerID: extra.id, subject: .account,
                version: VaultStoreFixture.accountVersion, sealed: sealed
            )
            try f.mutate { try StoreTables.putRecord($0, row) }
        case .liveOtherVaultAAD:
            let row = try f.storedRecord(source, account.id)
            let sealed = try VaultStoreFixture.sealAccount(account, ids: f.ids, vaultID: trash, key: f.dek)
            try Self.put(&f, row, sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .liveOlderVersion:
            var row = try f.storedRecord(source, account.id)
            row.version = 1  // a validly sealed version-1 row; the head still claims version 2
            let sealed = try VaultStoreFixture.sealAccount(account, ids: f.ids, vaultID: source, key: f.dek, version: 1)
            try Self.put(&f, row, sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .liveForeignStore:
            let row = try f.storedRecord(source, account.id)
            let sealed = try VaultStoreFixture.sealAccount(account, ids: foreign, vaultID: source, key: f.dek)
            try Self.put(&f, row, sealed: sealed, catalogDigest: StoreSeal.digest(sealed))
        case .liveWrongDigest:
            try Self.setCatalogDigest(&f, account.id, Data(repeating: 0xEE, count: 32))
        case .liveSwappedCiphertext:
            let row = try f.storedRecord(source, account.id)
            let other = try f.storedRecord(source, f.accounts[2].id)
            try Self.put(&f, row, sealed: other.sealed)  // head catalog digest left alone
        default:
            preconditionFailure("\(self) is not a live-row tamper")
        }
    }

    private func applyJournal(_ f: inout VaultStoreFixture) throws {
        let source = f.vaultID
        let account = f.accounts[1]
        switch self {
        case .journalTruncated:
            let seq = Int64(f.sourceHead.journalSeq)
            try f.mutate { try $0.execute(sql: "DELETE FROM journal WHERE vaultID = ? AND seq = ?", arguments: [source.lowerText, seq]) }
        case .journalReordered:
            try f.mutate { db in
                let one = try #require(try Data.fetchOne(db, sql: "SELECT sealed FROM journal WHERE vaultID = ? AND seq = 1", arguments: [source.lowerText]))
                let two = try #require(try Data.fetchOne(db, sql: "SELECT sealed FROM journal WHERE vaultID = ? AND seq = 2", arguments: [source.lowerText]))
                try db.execute(sql: "UPDATE journal SET sealed = ? WHERE vaultID = ? AND seq = 1", arguments: [two, source.lowerText])
                try db.execute(sql: "UPDATE journal SET sealed = ? WHERE vaultID = ? AND seq = 2", arguments: [one, source.lowerText])
            }
        case .journalForgedChain:
            var row = try f.journalRows(of: source)[1]
            row.prevChain = Data(count: 32)  // validly sealed, but not the running chain value
            let sealed = try StoreSeal.sealJournal(row, key: f.dek, ids: f.ids, vaultID: source)
            try f.mutate { try $0.execute(sql: "UPDATE journal SET sealed = ? WHERE vaultID = ? AND seq = 2", arguments: [sealed, source.lowerText]) }
        case .journalMissingRow:
            try f.mutate { try $0.execute(sql: "DELETE FROM journal WHERE vaultID = ? AND seq = 2", arguments: [source.lowerText]) }
        case .journalForgedOps:
            let forged = Self.addOp(owner: account.id)
            try f.rewriteJournal(of: source) { $0[0].ops.append(forged) }
        case .journalAddsExistingID:
            try f.rewriteJournal(of: source) { $0[0].ops.append($0[0].ops[0]) }
        case .journalRemovesAbsentID:
            var remove = Self.addOp(owner: account.id)
            remove.op = .remove
            try f.rewriteJournal(of: source) { $0.append(JournalRow(seq: 0, prevChain: Data(), transfer: nil, ops: [remove])) }
        default:
            preconditionFailure("\(self) is not a journal tamper")
        }
    }

    private func applyHead(_ f: inout VaultStoreFixture) throws {
        let source = f.vaultID, trash = f.trashID
        switch self {
        case .headStale:
            var old = f.sourceHead  // an older, validly sealed head under the same revision column
            old.liveCatalog = []
            old.journalSeq = 0
            old.chainTip = Data(count: 32)
            old.historyCounts = HistoryCounts()
            let sealed = try StoreSeal.sealHead(old, key: f.dek, wrappersDigest: f.sourceDigests.wrappers, keyWrapDigest: f.sourceDigests.keyWrap)
            try f.putHead(sealed, vault: source, revision: old.revision)
        case .headPlaintextRevision:
            var head = f.sourceHead
            head.revision = 1  // plaintext says 1, the AAD and the column say 2
            let sealed = try f.sealHeadPlaintext(head.encode(), vault: source, revision: f.sourceHead.revision)
            try f.putHead(sealed, vault: source, revision: f.sourceHead.revision)
        case .headLinkNonce:
            try f.editHead(trash) { $0.link = VaultLink(peerVaultID: $0.link.peerVaultID, nonce: Data(repeating: 9, count: 16)) }
        case .headWrongProfile:
            // Opens fine (authenticated under the right AAD ids) but its plaintext names another profile: V1 identity check.
            var head = f.sourceHead
            head.ids = StoreIDs(storeID: head.ids.storeID, profileID: UUID())
            let sealed = try f.sealHeadPlaintext(head.encode(), vault: source, revision: head.revision)
            try f.putHead(sealed, vault: source, revision: head.revision)
        default:
            preconditionFailure("\(self) is not a head tamper")
        }
    }

    private func applyHistory(_ f: inout VaultStoreFixture) throws {
        let source = f.vaultID
        let account = f.accounts[1]
        let foreign = StoreIDs(storeID: UUID(), profileID: f.ids.profileID)
        switch self {
        case .historyDeleted:
            let id = try f.recordIDs(of: source, kind: .revision)[0]
            try f.mutate { try StoreTables.deleteRecord($0, vaultID: source, recordID: id) }
        case .historyFlipped:
            let row = try f.storedRecord(source, try f.recordIDs(of: source, kind: .revision)[0])
            try Self.put(&f, row, sealed: VaultStoreFixture.flipped(row.sealed))
        case .historySwapped:
            let ids = try f.recordIDs(of: source, kind: .revision)
            let first = try f.storedRecord(source, ids[0]), second = try f.storedRecord(source, ids[1])
            try f.mutate { db in
                var one = first, two = second
                one.sealed = second.sealed
                two.sealed = first.sealed
                try StoreTables.putRecord(db, one)
                try StoreTables.putRecord(db, two)
            }
        case .historyVersionReplayed:
            var row = try f.storedRecord(source, try f.recordIDs(of: source, kind: .revision)[0])
            row.version += 1
            try f.mutate { [row] in try StoreTables.putRecord($0, row) }
        case .historyForeignStore:
            var row = try f.storedRecord(source, try f.recordIDs(of: source, kind: .revision)[0])
            row.sealed = try VaultStoreFixture.sealHistory(row, ids: foreign, key: f.dek)
            try f.mutate { [row] in try StoreTables.putRecord($0, row) }
        case .historyExtraRow:
            var row = StoreTables.RecordRow(vaultID: source, recordID: UUID(), kind: .revision, ownerID: account.id, subject: .password, version: 1, sealed: Data())
            row.sealed = try VaultStoreFixture.sealHistory(row, ids: f.ids, key: f.dek)
            try f.mutate { [row] in try StoreTables.putRecord($0, row) }
        default:
            preconditionFailure("\(self) is not a history tamper")
        }
    }

    private func applyTransfer(_ f: inout VaultStoreFixture) throws {
        let source = f.vaultID, trash = f.trashID
        switch self {
        case .transferIDSplit:
            try f.rewriteJournal(of: trash) { $0[0].transfer?.transferID = UUID() }
        case .transferDuplicateOut:
            try f.rewriteJournal(of: source) { rows in
                var duplicate = rows[1]  // the `out` row; the copy moves nothing, so the ledger stays consistent
                duplicate.ops = []
                rows.insert(duplicate, at: 2)
            }
        case .transferOwnerMismatch:
            try f.rewriteJournal(of: trash) { $0[0].transfer?.ownerID = UUID() }
        case .transferEntryMismatch:
            try f.rewriteJournal(of: trash) { $0[0].transfer?.entryRecordID = UUID() }
        case .transferScopeMismatch:
            try f.rewriteJournal(of: trash) { $0[0].transfer?.scope = .credential }
        case .transferSubjectMismatch:
            try f.rewriteJournal(of: trash) { $0[0].transfer?.subject = .password }  // the source says nil
        case .transferLiveRecordMismatch:
            try f.rewriteJournal(of: trash) { $0[0].transfer?.liveRecordID = UUID() }
        case .transferLiveVersionMismatch:
            try f.rewriteJournal(of: trash) { $0[0].transfer?.liveVersion += 1 }
        case .movedRowVersionMismatch:
            try Self.reseatMovedRow(&f) { $0.version += 1 }
        case .movedRowOwnerMismatch:
            try Self.reseatMovedRow(&f) { $0.ownerID = UUID() }
        case .movedRowSubjectMismatch:
            try Self.reseatMovedRow(&f) { $0.subject = .totp }  // moved rows are `.password`
        case .transferMovedSetMismatch:
            // A real extra history row on the Trash side, journalled and counted there, that the source never removed.
            var row = StoreTables.RecordRow(vaultID: trash, recordID: UUID(), kind: .revision, ownerID: f.accounts[0].id, subject: .password, version: 99, sealed: Data())
            row.sealed = try VaultStoreFixture.sealHistory(row, ids: f.ids, key: f.trashDEK)
            let sealed = row.sealed
            try f.mutate { [row] in try StoreTables.putRecord($0, row) }
            let add = JournalOp(op: .add, recordID: row.recordID, kind: .revision, ownerID: row.ownerID, subject: .password, version: 99, rowDigest: StoreSeal.digest(sealed))
            try f.rewriteJournal(of: trash) { $0[0].ops.append(add) }
            try f.editHead(trash) { $0.historyCounts.revision += 1 }
        default:
            preconditionFailure("\(self) is not a transfer tamper")
        }
    }

    /// Re-seals one moved history row on the Trash side with an edited identity and rewrites its journal op to match,
    /// so V3 and V4 stay consistent and only the source's `out` group disagrees (V5).
    private static func reseatMovedRow(_ f: inout VaultStoreFixture, _ edit: (inout StoreTables.RecordRow) -> Void) throws {
        let trash = f.trashID
        let id = try f.recordIDs(of: trash, kind: .revision)[0]
        var row = try f.storedRecord(trash, id)
        edit(&row)
        row.sealed = try VaultStoreFixture.sealHistory(row, ids: f.ids, key: f.trashDEK)
        try f.mutate { [row] in try StoreTables.putRecord($0, row) }
        let op = JournalOp(
            op: .add, recordID: id, kind: .revision, ownerID: row.ownerID, subject: row.subject, version: row.version,
            rowDigest: StoreSeal.digest(row.sealed)
        )
        let index = try #require(try f.journalRows(of: trash)[0].ops.firstIndex { $0.recordID == id })
        try f.rewriteJournal(of: trash) { $0[0].ops[index] = op }
    }

    private static func addOp(owner: UUID) -> JournalOp {
        JournalOp(op: .add, recordID: UUID(), kind: .revision, ownerID: owner, subject: .password, version: 1, rowDigest: Data(repeating: 7, count: 32))
    }

    /// Replaces a stored row; `catalogDigest` also rewrites the head's live-catalog digest so only the row itself is wrong.
    private static func put(_ f: inout VaultStoreFixture, _ row: StoreTables.RecordRow, sealed: Data, catalogDigest: Data? = nil) throws {
        var replaced = row
        replaced.sealed = sealed
        try f.mutate { [replaced] in try StoreTables.putRecord($0, replaced) }
        if let catalogDigest {
            try setCatalogDigest(&f, row.recordID, catalogDigest)
        }
    }

    private static func setCatalogDigest(_ f: inout VaultStoreFixture, _ recordID: UUID, _ digest: Data) throws {
        try f.editHead(f.vaultID) { head in
            guard let index = head.liveCatalog.firstIndex(where: { $0.recordID == recordID }) else { return }
            head.liveCatalog[index] = LiveEntry(recordID: recordID, version: head.liveCatalog[index].version, digest: digest)
        }
    }
}

// MARK: - Tests

struct VaultIntegrityTests {
    // MARK: V1-V5

    @Test func validFixtureVerifies() throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), blockedOrigins: blocked, historyRows: 5)
        defer { f.env.cleanUp() }
        try f.verify()
    }

    @Test func emptyFixtureVerifies() throws {
        let f = try VaultStoreFixture.make()
        defer { f.env.cleanUp() }
        try f.verify()
    }

    @Test(arguments: VaultTamper.allCases)
    func tamperClassesFailVerification(_ tamper: VaultTamper) throws {
        var f = try tamper.fixture()
        defer { f.env.cleanUp() }
        try f.verify()  // the untampered pair verifies, so the failure below is the edit's
        try tamper.apply(to: &f)
        expectIntegrityFailure { try f.verify() }
        #expect(scratchContents(VerificationScratch.directory(in: f.directory)).isEmpty)
    }

    @Test func integrityFailureNamesTheVaultOrdinal() throws {
        var f = try VaultStoreFixture.make(accounts: threeAccounts(), historyRows: 3)
        defer { f.env.cleanUp() }
        try VaultTamper.liveDeleted.apply(to: &f)
        #expect(throws: CredentialStoreError.integrityFailure(vaultOrdinal: 1)) { try f.verify() }
    }

    @Test(arguments: [1, 2, 3])
    func deleteUndeleteDeleteAndLongerAlternationsVerify(_ moves: Int) throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), blockedOrigins: blocked, historyRows: 4, moves: moves)
        defer { f.env.cleanUp() }
        // Odd counts end in Trash: the historical transfer headers say the account left, the current catalog differs per step.
        #expect(f.sourceHead.liveCatalog.count == (moves % 2 == 1 ? 2 : 3))
        #expect(f.trashHead.historyCounts.trashEntry == moves % 2)
        try f.verify()
    }

    @Test(arguments: [1, 2])
    func zeroHistoryAccountMoveVerifiesWithEmptyMovedSet(_ moves: Int) throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), moves: moves)
        defer { f.env.cleanUp() }
        let sourceTransfers = try f.journalRows(of: f.vaultID).filter { $0.transfer != nil }
        let trashTransfers = try f.journalRows(of: f.trashID).filter { $0.transfer != nil }
        #expect(sourceTransfers.count == moves)
        #expect(trashTransfers.count == moves)
        let firstOut = try #require(sourceTransfers.first)
        let firstIn = try #require(trashTransfers.first)
        #expect(firstOut.transfer?.direction == .out && firstOut.ops.isEmpty)
        #expect(firstIn.transfer?.direction == .in && firstIn.ops.map(\.kind) == [.trashEntry])
        try f.verify()
    }

    @Test func movedRowsWithDifferentCiphertextDigestsButEqualKeyVerify() throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), historyRows: 3, moves: 1)
        defer { f.env.cleanUp() }
        let out = try #require(try f.journalRows(of: f.vaultID).last { $0.transfer?.direction == .out }).ops
        let moved = try #require(try f.journalRows(of: f.trashID).first { $0.transfer?.direction == .in }).ops.filter { $0.kind == .revision }
        func key(_ op: JournalOp) -> String { "\(op.recordID)|\(op.kind)|\(op.ownerID)|\(op.subject)|\(op.version)" }
        #expect(out.count == 3 && moved.count == 3)
        #expect(Set(out.map(key)) == Set(moved.map(key)))
        #expect(Set(out.map(\.rowDigest)).isDisjoint(with: Set(moved.map(\.rowDigest))))
        try f.verify()
    }

    @Test func movedGroupLargerThanOneJournalRowSpansRowsWithOneHeader() throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), historyRows: 1_500, moves: 1)
        defer { f.env.cleanUp() }
        for vault in [f.vaultID, f.trashID] {
            let headers = try f.journalRows(of: vault).compactMap(\.transfer)
            #expect(headers.count == 2, "1,500 moved rows (+ the entry on the Trash side) need two rows")
            #expect(Set(headers.map(\.transferID)).count == 1)
        }
        try f.verify()
    }

    // MARK: Scratch lifecycle

    @Test func scratchLivesInTheScratchDirectoryWithRestrictedModesAndIsRemoved() throws {
        var f = try VaultStoreFixture.make(accounts: threeAccounts(), historyRows: 5)
        defer { f.env.cleanUp() }
        let writer = try f.openWriter()
        let directory = VerificationScratch.directory(in: f.directory)
        let fixture = f
        func observeModes() {
            #expect(posixMode(directory) == 0o700)
            let files = scratchContents(directory)
            #expect(files.count == 1 && files[0].hasSuffix(".db"))
            #expect(files.allSatisfy { posixMode(directory.appendingPathComponent($0)) == 0o600 })
        }
        func expectGone() throws {
            #expect(scratchContents(directory).isEmpty)
            #expect(!(try attachedDatabases(writer)).contains("scratch"))
        }

        let warn: @Sendable (URL) -> Void = { Issue.record("cleanup failed: \($0.path)") }

        try VerificationScratch.run(on: writer, supportDirectory: f.directory, cleanupFailed: warn) { db in
            observeModes()
            try fixture.verify(in: db)
        }
        try expectGone()

        var polls = 0
        #expect(throws: CancellationError.self) {
            try VerificationScratch.run(on: writer, supportDirectory: fixture.directory, cleanupFailed: warn) { db in
                observeModes()
                try fixture.verify(in: db, isCancelled: {
                    polls += 1
                    return polls > 1  // after the first row
                })
            }
        }
        try expectGone()

        try VaultTamper.liveDeleted.apply(to: &f)
        let tampered = f
        expectIntegrityFailure {
            try VerificationScratch.run(on: writer, supportDirectory: tampered.directory, cleanupFailed: warn) { db in
                observeModes()
                try tampered.verify(in: db)
            }
        }
        try expectGone()
    }

    @Test func verificationIsOneRolledBackDeferredSnapshotOnOneConnection() throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), historyRows: 3)
        defer { f.env.cleanUp() }
        let writer = try f.openWriter()
        let vault = f.vaultID.lowerText
        func createdAt(_ db: Database) throws -> Double? {
            try Double.fetchOne(db, sql: "SELECT createdAt FROM vault WHERE vaultID = ?", arguments: [vault])
        }
        let original = try #require(try f.read(createdAt))

        try VerificationScratch.run(on: writer, supportDirectory: f.directory, cleanupFailed: { _ in }) { db in
            #expect(db.isInsideTransaction)
            let first = try createdAt(db)
            // Another connection commits while the snapshot is open: later reads on `db` must not see it.
            try f.mutate { try $0.execute(sql: "UPDATE vault SET createdAt = createdAt + 1 WHERE vaultID = ?", arguments: [vault]) }
            let second = try createdAt(db)
            #expect(first == original && second == original)
            // The scratch database is writable in the same transaction and readable by the same connection.
            try db.execute(sql: "CREATE TABLE scratch.probe(x INTEGER)")
            try db.execute(sql: "INSERT INTO scratch.probe VALUES (1)")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scratch.probe") == 1)
            try f.verify(in: db)
        }

        #expect(try f.read(createdAt) == original + 1, "only the other connection wrote main")
        #expect(try writer.writeWithoutTransaction { try $0.tableExists("probe") } == false)
        #expect(!(try attachedDatabases(writer)).contains("scratch"))
        #expect(scratchContents(VerificationScratch.directory(in: f.directory)).isEmpty)
    }

    /// The ledger must reach the scratch database (a positive find of known opaque ids and digests, so an empty or
    /// schema-only image cannot pass) and must hold nothing readable. Rollback empties the ledger, so a closed file proves
    /// nothing (measured, `evidence/task5-serialize-probe`): the image is taken from this same connection, inside `body`,
    /// after `sqlite3_db_cacheflush`, with SQLite's own `sqlite3_serialize` (never a read of the live file).
    @Test func scratchHoldsOnlyOpaqueIds() throws {
        let account = VaultFixtures.account(username: "opaque-username-zz", origin: "https://opaque.example")
        let f = try VaultStoreFixture.make(accounts: [account], historyRows: 3_000, vaultName: "Opaque Vault Name ZZ")
        defer { f.env.cleanUp() }
        let writer = try f.openWriter()
        let bytes: Data = try VerificationScratch.run(on: writer, supportDirectory: f.directory, cleanupFailed: { _ in }) { db in
            try f.verify(in: db)
            let flushed = sqlite3_db_cacheflush(db.sqliteConnection)
            try #require(flushed == SQLITE_OK, "sqlite3_db_cacheflush failed: \(flushed)")
            var size: sqlite3_int64 = 0
            let image = try #require(sqlite3_serialize(db.sqliteConnection, "scratch", &size, 0), "no scratch image")
            // The buffer is SQLite-allocated: hand it to Data without a copy and free it with sqlite3_free.
            return Data(bytesNoCopy: image, count: Int(size), deallocator: .custom { pointer, _ in sqlite3_free(pointer) })
        }
        let ops = try f.journalRows(of: f.vaultID).flatMap(\.ops)
        #expect(ops.count == 3_000)
        func contains(_ needle: Data) -> Bool {
            bytes.range(of: needle) != nil
        }
        let found = ops.filter { op in
            contains(op.rowDigest)  // BLOB
                || contains(Data(op.rowDigest.map { String(format: "%02x", $0) }.joined().utf8))  // hex text
                || contains(Data(op.recordID.lowerText.utf8))  // lower-case text id
                || contains(withUnsafeBytes(of: op.recordID.uuid) { Data($0) })  // raw 16-byte id
        }
        #expect(!found.isEmpty, "no known id or digest reached the scratch file: the privacy scan below proves nothing")
        #expect(!contains(Data("opaque-username-zz".utf8)))
        #expect(!contains(Data("Opaque Vault Name ZZ".utf8)))
        #expect(!contains(Data("https://opaque.example".utf8)))
        let stored = try f.storedRecord(f.vaultID, try f.recordIDs(of: f.vaultID, kind: .revision)[0])
        #expect(!contains(stored.sealed.prefix(32)), "sealed row bytes must not be copied into the scratch ledger")
    }

    @Test func cancellationYieldsNoResultAndRemovesScratch() throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), historyRows: 20)
        defer { f.env.cleanUp() }
        let writer = try f.openWriter()
        #expect(throws: CancellationError.self) {
            try VerificationScratch.run(on: writer, supportDirectory: f.directory, cleanupFailed: { _ in }) { db in
                try f.verify(in: db, isCancelled: { true })
            }
        }
        #expect(scratchContents(VerificationScratch.directory(in: f.directory)).isEmpty)
        #expect(!(try attachedDatabases(writer)).contains("scratch"))
    }

    // MARK: Leftovers and cleanup failure

    @Test func cleanLeftoversRemovesPlantedFilesAndAbsentDirectoryIsEmpty() throws {
        let env = try VaultTestEnvironment.make()
        defer { env.cleanUp() }
        #expect(VerificationScratch.cleanLeftovers(in: env.directory).isEmpty)  // no directory

        let directory = VerificationScratch.directory(in: env.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["a.db", "b.db", "notes"] {
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent(name))
        }
        #expect(VerificationScratch.cleanLeftovers(in: env.directory).isEmpty)
        #expect(scratchContents(directory).isEmpty)
    }

    @Test(.enabled(if: getuid() != 0))
    func cleanLeftoversReturnsWhatItCouldNotRemoveAndAnUnlistableDirectory() throws {
        let env = try VaultTestEnvironment.make()
        defer { env.cleanUp() }
        let directory = VerificationScratch.directory(in: env.directory)
        let stuck = directory.appendingPathComponent("stuck", isDirectory: true)
        try FileManager.default.createDirectory(at: stuck, withIntermediateDirectories: true)
        try Data([1]).write(to: stuck.appendingPathComponent("inner"))
        try Data([2]).write(to: directory.appendingPathComponent("plain.db"))
        setMode(stuck, 0o500)
        defer { setMode(stuck, 0o700) }

        let left = VerificationScratch.cleanLeftovers(in: env.directory)
        #expect(left.map(\.lastPathComponent) == ["stuck"])
        #expect(scratchContents(directory) == ["stuck"])

        setMode(stuck, 0o700)
        #expect(VerificationScratch.cleanLeftovers(in: env.directory).isEmpty)

        // An existing directory that cannot be listed is reported as itself, never as "clean".
        setMode(directory, 0o000)
        defer { setMode(directory, 0o700) }
        let unlistable = VerificationScratch.cleanLeftovers(in: env.directory)
        #expect(unlistable.map(\.lastPathComponent) == [directory.lastPathComponent])
    }

    @Test(.enabled(if: getuid() != 0))
    func cleanupFailureIsAWarningAndNeverTheOutcome() throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), historyRows: 3)
        defer { f.env.cleanUp() }
        let writer = try f.openWriter()
        let directory = VerificationScratch.directory(in: f.directory)
        defer { setMode(directory, 0o700) }

        /// Runs `inner` in `run`'s body with the scratch directory made read-only just before the body ends, so the unlink fails.
        func run<T>(_ collected: Collected, _ inner: (Database) throws -> T) throws -> T {
            try VerificationScratch.run(on: writer, supportDirectory: f.directory, cleanupFailed: { collected.add($0) }) { db in
                defer { setMode(directory, 0o500) }
                return try inner(db)
            }
        }
        func expectWarningThenReset(_ collected: Collected) {
            #expect(collected.urls.count == 1)
            #expect(collected.urls.first?.pathExtension == "db")
            #expect(collected.urls.first?.deletingLastPathComponent().lastPathComponent == directory.lastPathComponent)
            #expect(!((try? attachedDatabases(writer)) ?? ["scratch"]).contains("scratch"), "DETACH and rollback happened first")
            setMode(directory, 0o700)
            #expect(VerificationScratch.cleanLeftovers(in: f.directory).isEmpty)
        }

        // (a) success: the body's value is the result.
        let success = Collected()
        let value = try run(success) { db in
            try f.verify(in: db)
            return 42
        }
        #expect(value == 42)
        expectWarningThenReset(success)

        // (b) the body's own error is rethrown unchanged, not a file error.
        let failure = Collected()
        let refuse: (Database) throws -> Void = { _ in throw CredentialStoreError.integrityFailure(vaultOrdinal: 1) }
        #expect(throws: CredentialStoreError.integrityFailure(vaultOrdinal: 1)) {
            try run(failure, refuse)
        }
        expectWarningThenReset(failure)

        // (c) cancellation stays the primary outcome.
        let cancelled = Collected()
        #expect(throws: CancellationError.self) {
            try run(cancelled) { db in try f.verify(in: db, isCancelled: { true }) }
        }
        expectWarningThenReset(cancelled)
    }

    // MARK: Scratch root trust

    /// A linked root is neither listed nor emptied: it is reported as the one thing that could not be cleaned.
    @Test func cleanLeftoversNeverFollowsALinkedRoot() throws {
        let layout = try LinkedScratchRoot()
        defer { layout.cleanUp() }
        #expect(VerificationScratch.cleanLeftovers(in: layout.support.directory) == [layout.root])
        layout.expectUntouched()
    }

    /// The body is never entered, no scratch file is created behind the link, and the refusal is a file error.
    @Test func runRefusesALinkedRootBeforeCreatingAnything() throws {
        let layout = try LinkedScratchRoot()
        defer { layout.cleanUp() }
        let writer = try DatabaseQueue()
        var entered = false
        #expect(throws: StoreFileError.self) {
            try VerificationScratch.run(on: writer, supportDirectory: layout.support.directory, cleanupFailed: { _ in }) { _ in
                entered = true
            }
        }
        #expect(!entered)
        layout.expectUntouched()
    }

    /// An existing real directory that this process owns is kept but forced to `0700` before the scratch file is created in it.
    @Test func runEnforcesOwnerOnlyModeOnAnExistingRoot() throws {
        let env = try VaultTestEnvironment.make()
        defer { env.cleanUp() }
        let directory = VerificationScratch.directory(in: env.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        setMode(directory, 0o755)
        var observed: Int?
        try VerificationScratch.run(
            on: DatabaseQueue(), supportDirectory: env.directory, cleanupFailed: { Issue.record("cleanup failed: \($0.path)") }
        ) { _ in
            observed = posixMode(directory)
        }
        #expect(observed == 0o700)
        #expect(scratchContents(directory).isEmpty)
    }

    /// Unchanged semantics: a link INSIDE the root is unlinked, never followed.
    @Test func cleanLeftoversUnlinksALeafLinkAndLeavesItsTarget() throws {
        let env = try VaultTestEnvironment.make()
        let outside = try VaultTestEnvironment.make()
        defer {
            env.cleanUp()
            outside.cleanUp()
        }
        let target = outside.directory.appendingPathComponent("SENTINEL")
        try LinkedScratchRoot.sentinelBytes.write(to: target)
        let directory = VerificationScratch.directory(in: env.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("leaf"), withDestinationURL: target)

        #expect(VerificationScratch.cleanLeftovers(in: env.directory).isEmpty)
        #expect(scratchContents(directory).isEmpty)
        #expect(try Data(contentsOf: target) == LinkedScratchRoot.sentinelBytes)
    }

    // MARK: Memory

    @Test func streamingHistoryStaysWithinAMemoryBudget() throws {
        let f = try VaultStoreFixture.make(accounts: threeAccounts(), historyRows: 20_000)
        defer { f.env.cleanUp() }
        let before = residentBytes()
        var peak = before
        try f.verify(isCancelled: {
            peak = max(peak, residentBytes())
            return false
        })
        #expect(peak - before < 64 * 1024 * 1024, "resident size grew by \((peak - before) / 1024 / 1024) MB")
    }
}
