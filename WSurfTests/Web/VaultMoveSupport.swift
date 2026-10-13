// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import GRDB
import Synchronization
import Testing

@testable import WSurf

// Task 7: plumbing shared by `VaultMoveTests` and `VaultMoveBenchmark`. The helpers read through `StoreTables`, `StoreSeal` and the
// fixture's own keys; only `HiddenHistoryOperation` drives the store's `commit`/`delete`.

/// The MOVE's write transaction cannot be reached from outside the store without a production hook: its pool is opened inside the
/// store, and Apple's SQLite refuses process-wide auto-extensions (`sqlite3_auto_extension` is deprecated and not supported there).
/// So this runs the store's own `transact` (the identical commit/delete/MOVE/`finish` code `perform` runs) inside the same
/// `BEGIN IMMEDIATE` transaction on a test-owned pool, whose connections carry `wsurf_cancel(key)`. A persisted trigger calling it
/// cancels the very task executing the transaction, on the transaction's own thread, once the MOVE has written rows.
/// The lock wait, pool opening and error mapping around `transact` are not part of this path.
nonisolated final class MoveCancelSeam: Sendable {
    private let fired = Mutex(0)

    /// How often the injected cancel ran: asserted, so a trigger that never fired cannot pass as a cancellation.
    var fires: Int {
        fired.withLock { $0 }
    }

    func pool(at file: URL) throws -> DatabasePool {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.add(function: DatabaseFunction("wsurf_cancel", argumentCount: 0, pure: false) { [self] _ in
                withUnsafeCurrentTask { $0?.cancel() }
                fired.withLock { $0 += 1 }
                return 1
            })
        }
        return try DatabasePool(path: file.path, configuration: configuration)
    }

    /// `perform`'s transaction for a removal: the verification scratch attached to the connection, then `transact` inside
    /// `BEGIN IMMEDIATE`, committed unless it throws or writes nothing.
    static func transact(
        on pool: DatabasePool, supportDirectory: URL, _ request: CommitRequest, derive: @escaping ([CredentialAccount]) throws -> Proposal
    ) throws -> CommitOutcome {
        let committed: CommitOutcome? = try VerificationScratch.attached(
            on: pool, supportDirectory: supportDirectory, cleanupFailed: { _ in }
        ) { db in
            var committed: CommitOutcome?
            try db.inTransaction(.immediate) {
                let outcome = try ProfileVaultStore.transact(db, request, derive: derive, ledgerAttached: true)
                committed = outcome
                return outcome.entry == nil ? .rollback : .commit
            }
            return committed
        }
        return try #require(committed)
    }
}

/// A row as the journal and a MOVE identify it: a MOVE keeps every one of these fields.
nonisolated struct MoveRowKey: Hashable, Sendable {
    let recordID: UUID
    let kind: RecordKind
    let ownerID: UUID
    let subject: RecordSubject
    let version: UInt64
}

nonisolated extension MoveRowKey {
    init(_ op: JournalOp) {
        self.init(recordID: op.recordID, kind: op.kind, ownerID: op.ownerID, subject: op.subject, version: op.version)
    }
}

nonisolated extension StoreTables.RecordRow {
    var moveKey: MoveRowKey {
        MoveRowKey(recordID: recordID, kind: kind, ownerID: ownerID, subject: subject, version: version)
    }

    /// The key `VaultStoreFixture.recordAndJournalImage` files this row under.
    var imageKey: String {
        "record/\(vaultID.lowerText)/\(recordID.lowerText)"
    }
}

nonisolated struct MoveTrashEntry: Sendable {
    let row: StoreTables.RecordRow
    let body: TrashEntryBody
}

/// Every journal row of one transfer on one side, in sequence order.
nonisolated struct MoveTransferGroup: Sendable {
    let header: TransferHeader
    let rows: [JournalRow]

    var ops: [JournalOp] {
        rows.flatMap(\.ops)
    }
}

/// What a MOVE's two journal groups must say.
nonisolated struct MoveExpectation: Sendable {
    let scope: TransferScope
    let ownerID: UUID
    let subject: RecordSubject?
    let liveVersion: UInt64
    let movedKeys: Set<MoveRowKey>
}

/// The head revisions of the pair and the registry revision: every successful write bumps each it touches by exactly one.
nonisolated struct MoveRevisions: Equatable, Sendable {
    let source: UInt64
    let trash: UInt64
    let registry: UInt64

    func advanced(by writes: UInt64 = 1, trash trashWrites: UInt64? = nil) -> MoveRevisions {
        MoveRevisions(source: source + writes, trash: trash + (trashWrites ?? writes), registry: registry + writes)
    }
}

nonisolated enum MoveFixtures {
    /// The injected wall clock every `withWallStore` store reads: `modifiedAt`, `deletedAt`.
    static let wall = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let plantedPassword = "planted-pw-9f3a"
    static let oldSecret = "old-secret-7c1d"

    /// username `ada`, a password, a TOTP and two passkeys (distinct ids and credential ids), display name and one origin.
    static func fullAccount(
        id: UUID = UUID(), password: String = "hunter2-correct", displayName: String? = "Work"
    ) throws -> CredentialAccount {
        var account = VaultFixtures.account(
            id: id,
            username: "ada",
            password: password,
            origin: "https://example.test",
            passkeys: [
                try VaultFixtures.passkey(credentialID: Data(repeating: 1, count: 32)),
                try VaultFixtures.passkey(credentialID: Data(repeating: 2, count: 32)),
            ]
        )
        account.displayName = displayName
        account.totp = VaultFixtures.totp()
        return account
    }

    /// A password, TOTP and passkey account whose canonical payload is exactly `CredentialVaultLimits.payloadBytes` (the username
    /// pads it).
    static func payloadCapAccount() throws -> CredentialAccount {
        var account = VaultFixtures.account(username: "", password: "capped", passkeys: [try VaultFixtures.passkey()])
        account.totp = VaultFixtures.totp()
        let base = try VaultFixtures.sortedJSON(account).count
        account.username = String(repeating: "u", count: CredentialVaultLimits.payloadBytes - base)
        try #require(try VaultFixtures.sortedJSON(account).count == CredentialVaultLimits.payloadBytes)
        return account
    }

    static func tinyAccounts(_ count: Int) -> [CredentialAccount] {
        (0..<count).map { VaultFixtures.account(username: "user\($0)") }
    }

    static func occurrences(of needle: String, in data: Data) -> Int {
        let pattern = Data(needle.utf8)
        var count = 0
        var start = data.startIndex
        while let range = data.range(of: pattern, in: start..<data.endIndex) {
            count += 1
            start = range.upperBound
        }
        return count
    }
}

nonisolated extension VaultStoreFixture {
    /// A store on this fixture unlocked on vault A with a fixed wall clock (`MoveFixtures.wall` unless given); closed afterwards.
    func withWallStore(
        at wall: Date = MoveFixtures.wall,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (ProfileVaultStore, VaultAccess) async throws -> Void
    ) async throws {
        let store = ProfileVaultStore(profileID: env.profileID, directory: env.directory, defaults: env.defaults, wall: { wall })
        let access = beginAccess()
        do {
            try await store.unlockInitialized(
                vaultID: vaultID, credentialID: proof.credentialID, prf: proof.prf, access: access, verifying: nil, scratchWarning: nil
            )
            try await body(store, access)
        } catch {
            await store.close()
            throw error
        }
        await store.close()
    }

    // MARK: Rows

    /// Every non-account row (revision, trashEntry, tombstone) of the vault.
    func moveHistoryRows(of vault: UUID) throws -> [StoreTables.RecordRow] {
        try read { db in
            var rows: [StoreTables.RecordRow] = []
            try StoreTables.forEachHistoryRecord(db, vaultID: vault) { rows.append($0) }
            return rows
        }
    }

    func moveLiveRows(of vault: UUID) throws -> [StoreTables.RecordRow] {
        try recordIDs(of: vault, kind: .account).map { try storedRecord(vault, $0) }
    }

    func moveRevisions(in vault: UUID, owner: UUID, subject: RecordSubject? = nil) throws -> [StoreTables.RecordRow] {
        try moveHistoryRows(of: vault).filter { $0.kind == .revision && $0.ownerID == owner && (subject == nil || $0.subject == subject) }
    }

    /// Every row of any kind in `vault` owned by `owner` (the live row included).
    func moveOwnedRowCount(in vault: UUID, owner: UUID) throws -> Int {
        try read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM record WHERE vaultID = ? AND ownerID = ?", arguments: [vault.lowerText, owner.lowerText]
            ) ?? 0
        }
    }

    /// The row's plaintext, opened with the fixture's key for its vault and the row's own AAD.
    func movePlaintext(of row: StoreTables.RecordRow) throws -> Data {
        try StoreSeal.openRow(
            row.sealed,
            key: key(of: row.vaultID),
            aad: RowAAD(
                ids: ids, vaultID: row.vaultID, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject,
                version: row.version
            )
        )
    }

    func moveTrashEntries() throws -> [MoveTrashEntry] {
        try moveHistoryRows(of: trashID).filter { $0.kind == .trashEntry }.map {
            MoveTrashEntry(row: $0, body: try JSONDecoder().decode(TrashEntryBody.self, from: try movePlaintext(of: $0)))
        }
    }

    /// Plaintext plus, for a trash entry, the decoded `credentialValue` (it is base64 inside the body JSON).
    func moveSearchableBytes(of row: StoreTables.RecordRow) throws -> Data {
        var bytes = try movePlaintext(of: row)
        if row.kind == .trashEntry, let value = try JSONDecoder().decode(TrashEntryBody.self, from: bytes).credentialValue {
            bytes.append(value)
        }
        return bytes
    }

    /// Occurrences of `needle` in every reachable record (live, history) and journal row of `vault`.
    func moveSecretCount(of needle: String, in vault: UUID) throws -> Int {
        var count = 0
        for row in try moveLiveRows(of: vault) + moveHistoryRows(of: vault) {
            count += MoveFixtures.occurrences(of: needle, in: try moveSearchableBytes(of: row))
        }
        for row in try journalRows(of: vault) {
            count += MoveFixtures.occurrences(of: needle, in: row.encode())
        }
        return count
    }

    // MARK: Journals, heads, registry

    func moveTransferGroups(of vault: UUID) throws -> [MoveTransferGroup] {
        var order: [UUID] = []
        var rows: [UUID: [JournalRow]] = [:]
        var headers: [UUID: TransferHeader] = [:]
        for row in try journalRows(of: vault) {
            guard let header = row.transfer else { continue }
            if rows[header.transferID] == nil {
                order.append(header.transferID)
                headers[header.transferID] = header
            }
            rows[header.transferID, default: []].append(row)
        }
        return order.compactMap { id in headers[id].map { MoveTransferGroup(header: $0, rows: rows[id] ?? []) } }
    }

    func moveStoredHeads() throws -> (source: VaultHead, trash: VaultHead) {
        try read { try openStoredHeads(in: $0) }
    }

    func moveHeadRevisions() throws -> MoveRevisions {
        MoveRevisions(
            source: try headRevision(of: vaultID), trash: try headRevision(of: trashID), registry: try storedRegistry().revision
        )
    }

    /// The stored registry is signed with RK and lists the pair's current head revisions and digests.
    func expectMoveRegistryMatchesHeads() throws {
        let raw = try #require(try read { try StoreTables.registry($0) })
        #expect(raw.mac == StoreSeal.registryMAC(rk: registryKey, catalog: raw.catalog))
        let catalog = try RegistryCatalog.decode(raw.catalog)
        #expect(catalog.revision == raw.revision)
        for vault in [vaultID, trashID] {
            let stored = try #require(try read { try StoreTables.head($0, vaultID: vault) })
            let entry = try #require(catalog.vaults.first { $0.vaultID == vault })
            #expect(entry.headRevision == stored.revision)
            #expect(entry.headDigest == StoreSeal.digest(stored.sealed))
        }
    }

    /// Every row and journal row of `before` outside `except` is byte-identical in `after`.
    func expectMoveUntouched(before: [String: Data], after: [String: Data], except removed: Set<String>) {
        let changed = before.filter { !removed.contains($0.key) && after[$0.key] != $0.value }.keys.sorted()
        #expect(changed.isEmpty, "rows changed that the MOVE must not touch: \(changed)")
    }

    /// The `in` group in Trash for `entry` and its `out` twin on the source side say exactly what `expected` names.
    func expectMoveTransferPair(for entry: MoveTrashEntry, _ expected: MoveExpectation) throws {
        let inGroups = try moveTransferGroups(of: trashID).filter { $0.header.entryRecordID == entry.row.recordID }
        let outGroups = try moveTransferGroups(of: vaultID).filter { $0.header.entryRecordID == entry.row.recordID }
        #expect(inGroups.count == 1 && outGroups.count == 1)
        let inGroup = try #require(inGroups.first)
        let outGroup = try #require(outGroups.first)
        #expect(inGroup.header.direction == .in)
        #expect(outGroup.header.direction == .out)
        var twin = outGroup.header
        twin.direction = .in
        #expect(twin == inGroup.header)
        let header = inGroup.header
        #expect(header.scope == expected.scope)
        #expect(header.ownerID == expected.ownerID)
        #expect(header.subject == expected.subject)
        #expect(header.liveRecordID == expected.ownerID)
        #expect(header.liveVersion == expected.liveVersion)
        #expect(inGroup.rows.allSatisfy { $0.transfer == inGroup.header })
        #expect(outGroup.rows.allSatisfy { $0.transfer == outGroup.header })
        #expect(inGroup.ops.allSatisfy { $0.op == .add })
        #expect(outGroup.ops.allSatisfy { $0.op == .remove })
        let inKeys = inGroup.ops.map(MoveRowKey.init)
        let outKeys = outGroup.ops.map(MoveRowKey.init)
        #expect(inKeys.count == expected.movedKeys.count + 1)
        #expect(Set(inKeys) == expected.movedKeys.union([entry.row.moveKey]))
        #expect(outKeys.count == expected.movedKeys.count)
        #expect(Set(outKeys) == expected.movedKeys)
    }
}

/// One hidden-history scenario. A commit that never reaches the Trash cannot notice a hidden Trash row, so the Trash rows are only
/// paired with the operations that MOVE.
nonisolated struct HiddenHistoryCase: Sendable, CustomTestStringConvertible {
    let hidden: HiddenHistory
    let operation: HiddenHistoryOperation

    var testDescription: String { "\(hidden) / \(operation)" }

    static let all: [HiddenHistoryCase] = HiddenHistory.allCases.flatMap { hidden in
        HiddenHistoryOperation.allCases
            .filter { !hidden.inTrash || $0 != .commitPasswordChange }
            .map { HiddenHistoryCase(hidden: hidden, operation: $0) }
    }
}

/// A history row made invisible to a scan of its vault after unlock: deleted, or its `vaultID` changed.
nonisolated enum HiddenHistory: CaseIterable, Sendable {
    case sourceOwnedDeleted, sourceBystanderDeleted, sourceOwnedReparented, sourceBystanderReparented, trashDeleted, trashReparented

    var inTrash: Bool {
        self == .trashDeleted || self == .trashReparented
    }

    /// The vault the row is in and the owner of the revision rows to pick from.
    func target(_ f: VaultStoreFixture, victim: UUID, bystander: UUID) -> (vault: UUID, owner: UUID) {
        switch self {
        case .sourceOwnedDeleted, .sourceOwnedReparented:
            (f.vaultID, victim)
        case .sourceBystanderDeleted, .sourceBystanderReparented:
            (f.vaultID, bystander)
        case .trashDeleted, .trashReparented:
            (f.trashID, victim)
        }
    }

    /// Bound to `(vaultID, recordID)`.
    var sql: String {
        switch self {
        case .sourceOwnedDeleted, .sourceBystanderDeleted, .trashDeleted:
            "DELETE FROM record WHERE vaultID = ? AND recordID = ?"
        case .sourceOwnedReparented, .sourceBystanderReparented, .trashReparented:
            "UPDATE record SET vaultID = '\(UUID().lowerText)' WHERE vaultID = ? AND recordID = ?"
        }
    }
}

/// Every route that writes: both removal scopes, and an ordinary commit that only appends a revision.
nonisolated enum HiddenHistoryOperation: CaseIterable, Sendable {
    case deleteAccount, deletePassword, commitPasswordChange

    func run(
        _ store: ProfileVaultStore, _ access: VaultAccess, _ f: VaultStoreFixture, _ snapshot: StoreSnapshot, _ victim: CredentialAccount
    ) async throws -> VaultCommitReceipt {
        switch self {
        case .deleteAccount:
            return try await store.delete(vaultID: f.vaultID, scope: .account(victim.id), expectedRevision: snapshot.revision, using: access)
        case .deletePassword:
            return try await store.delete(
                vaultID: f.vaultID, scope: .credential(ownerID: victim.id, subject: .password, passkeyID: nil),
                expectedRevision: snapshot.revision, using: access
            )
        case .commitPasswordChange:
            let changed = snapshot.accounts.map { account -> CredentialAccount in
                var copy = account
                if copy.id == victim.id {
                    copy.password = "changed-after-hide"
                }
                return copy
            }
            return try await store.commit(vaultID: f.vaultID, changed, expectedRevision: snapshot.revision, cause: nil, using: access)
        }
    }
}
