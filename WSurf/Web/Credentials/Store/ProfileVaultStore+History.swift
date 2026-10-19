// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

nonisolated struct TrashItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let scope: TransferScope
    let ownerID: UUID
    let subject: RecordSubject?
    let label: String
    let revisionCount: Int
}

nonisolated struct RevisionItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let subject: RecordSubject
    let version: UInt64
    let recordedAt: Date
    let cause: String?
}

/// `next` is the cursor of the following page (`nil` on the last). A cursor is the SQLite `rowid` of the last row shown, newest row
/// first: a row written or removed between two pages never repeats or hides a row that existed throughout.
/// ponytail: a `VACUUM` would renumber rowids (WSurf never runs one); the worst outcome is a skipped or repeated line in a listing.
nonisolated struct TrashPage: Sendable {
    let items: [TrashItem]
    let next: Int?
}

nonisolated struct RevisionPage: Sendable {
    let items: [RevisionItem]
    let next: Int?
}

/// A revision with the value it superseded: the canonical JSON of one typed value (`PasswordValue`, `TOTPGenerator`,
/// `[CredentialNote]` or `MetadataProjection`), selected by `item.subject`. It holds a secret; keep it only in an authorized session.
nonisolated struct RevisionValue: Equatable, Sendable {
    let item: RevisionItem
    let value: Data
}

nonisolated struct RevisionValuePage: Sendable {
    let items: [RevisionValue]
    let next: Int?
}

nonisolated extension HistoryCounts {
    /// Whether the stored rows of `vaultID` number exactly what this (head-authenticated) count says: three `COUNT(*)` reads, no row decoded.
    func matchesRows(_ db: Database, vaultID: UUID, ordinal: Int) throws -> Bool {
        for (kind, expected) in [(RecordKind.revision, revision), (.trashEntry, trashEntry), (.tombstone, tombstone)] {
            guard try mapIntegrity(ordinal, { try StoreTables.recordCount(db, vaultID: vaultID, kind: kind) }) == expected else { return false }
        }
        return true
    }
}

nonisolated struct UndeletePreview: Sendable {
    let entry: TrashItem
    let block: UndeleteBlock?
}

/// A Trash entry as a write transaction reads it.
nonisolated struct StoredTrashEntry {
    let row: StoreTables.RecordRow
    let body: TrashEntryBody
}

nonisolated extension StoreTables.RecordRow {
    /// The plaintext, opened under the identity the row's own columns name (so a changed clear column fails the tag).
    func opened(key: SymmetricKey, ids: StoreIDs) throws -> Data {
        try StoreSeal.openRow(
            sealed, key: key,
            aad: RowAAD(ids: ids, vaultID: vaultID, recordID: recordID, kind: kind, ownerID: ownerID, subject: subject, version: version)
        )
    }
}

/// §11.2/§11.3/§11.3a: Trash and earlier-version listings, undelete (a reverse MOVE) and restoring an earlier revision. Reads run
/// under the shared operation lock like every other database read; writes route through `run`, `begin` and `finish`, the one write
/// contract, after `verifyHistories` has bound both ledgers to the rows about to be selected.
extension ProfileVaultStore {
    // MARK: Listings

    func trashPage(vaultID: UUID, after: Int?, using access: VaultAccess) async throws -> TrashPage {
        try await readHistory(vaultID, access) { db, grant, opened in
            let trash = try Self.openTrash(db, grant: grant, opened: opened)
            let page = try Self.pageIDs(db, vaultID: trash.side.vaultID, kind: .trashEntry, ownerID: nil, after: after, ordinal: grant.ordinal)
            let items = try page.ids.map { id in
                try Self.trashItem(db, try Self.storedEntry(db, id, trash: trash, grant: grant), grant: grant)
            }
            return TrashPage(items: items, next: page.next)
        }
    }

    /// How many earlier versions, Trash entries and purge tombstones the vault and its Trash hold, as the authenticated heads count
    /// them. Each head's count is checked against the stored rows (three `COUNT(*)` reads per side, no decoding), so a missing or
    /// extra row is an integrity failure, not a number. Integers only: no content, and not bounded by the page size.
    func historyCounts(vaultID: UUID, using access: VaultAccess) async throws -> (live: HistoryCounts, trash: HistoryCounts) {
        try await readHistory(vaultID, access) { db, grant, opened in
            let trash = try Self.openTrash(db, grant: grant, opened: opened)
            guard try opened.head.historyCounts.matchesRows(db, vaultID: opened.head.vaultID, ordinal: grant.ordinal),
                try trash.side.counts.matchesRows(db, vaultID: trash.side.vaultID, ordinal: grant.ordinal)
            else { throw CredentialStoreError.integrityFailure(vaultOrdinal: grant.ordinal) }
            return (opened.head.historyCounts, trash.side.counts)
        }
    }

    /// The copy kept from before this vault was upgraded, if one is still on disk. It still holds whatever a purge removes from the vault.
    nonisolated func preMigrationBackup() -> URL? {
        let backup = file(StoreAnchors.Names.preV2)
        return StoreAnchors.exists(backup) ? backup : nil
    }

    func revisionPage(vaultID: UUID, accountID: UUID, after: Int?, using access: VaultAccess) async throws -> RevisionPage {
        try await readHistory(vaultID, access) { db, grant, _ in
            let page = try Self.pageIDs(db, vaultID: vaultID, kind: .revision, ownerID: accountID, after: after, ordinal: grant.ordinal)
            let items = try page.ids.map { try Self.revision($0, db, vaultID: vaultID, accountID: accountID, grant: grant).item }
            return RevisionPage(items: items, next: page.next)
        }
    }

    /// `revisionPage` with each row's superseded value, for rebuilding the earlier versions of one credential. Same owner guard and
    /// paging. Only a password, code, notes or details row has a value to apply: any other subject is `malformed`.
    func revisionValuePage(vaultID: UUID, accountID: UUID, after: Int?, using access: VaultAccess) async throws -> RevisionValuePage {
        try await readHistory(vaultID, access) { db, grant, _ in
            let page = try Self.pageIDs(db, vaultID: vaultID, kind: .revision, ownerID: accountID, after: after, ordinal: grant.ordinal)
            let items = try page.ids.map {
                try Self.revision($0, db, vaultID: vaultID, accountID: accountID, grant: grant, appliesToAnAccount: true)
            }
            return RevisionValuePage(items: items, next: page.next)
        }
    }

    /// One revision row of `accountID`, opened. A row of another account or kind is `malformed`, and so is one whose subject
    /// `applying` could not apply when `appliesToAnAccount`.
    nonisolated private static func revision(
        _ id: UUID, _ db: Database, vaultID: UUID, accountID: UUID, grant: VaultGrant, appliesToAnAccount: Bool = false
    ) throws -> RevisionValue {
        try mapIntegrity(grant.ordinal) {
            guard let row = try StoreTables.record(db, vaultID: vaultID, recordID: id), row.kind == .revision, row.ownerID == accountID,
                !appliesToAnAccount || row.subject.restoresFromEarlierVersions
            else { throw CredentialStoreError.malformed }
            let body = try JSONDecoder().decode(RevisionBody.self, from: row.opened(key: grant.dek, ids: grant.ids))
            let item = RevisionItem(id: id, subject: row.subject, version: row.version, recordedAt: body.recordedAt, cause: body.cause)
            return RevisionValue(item: item, value: body.value)
        }
    }

    // MARK: Undelete

    func previewUndelete(vaultID: UUID, entryID: UUID, using access: VaultAccess) async throws -> UndeletePreview {
        try await readHistory(vaultID, access) { db, grant, opened in
            let trash = try Self.openTrash(db, grant: grant, opened: opened)
            let entry = try Self.storedEntry(db, entryID, trash: trash, grant: grant)
            let snapshot = try Self.readSnapshot(db, grant: grant, vaultID: vaultID)
            return UndeletePreview(entry: try Self.trashItem(db, entry, grant: grant), block: try Self.block(entry.body, among: snapshot.accounts))
        }
    }

    /// Throws `.undeleteBlocked(block)` with nothing written when `previewUndelete` names a block. There is no alternative restore.
    func undelete(vaultID: UUID, entryID: UUID, expectedRevision: UInt64, using access: VaultAccess) async throws -> VaultCommitReceipt {
        let intent = CommitIntent(vaultID: vaultID, access: access, expectedRevision: expectedRevision, cause: nil, isCommit: true)
        return try await run(intent, ledgerOnDemand: false) { db, request, _ in
            let (transaction, snapshot) = try Self.begin(db, request)
            try transaction.verifyHistories()
            let entry = try transaction.trashEntry(entryID)
            if let block = try Self.block(entry.body, among: snapshot.accounts) {
                throw CredentialStoreError.undeleteBlocked(block)
            }
            let restored = try Self.restoring(entry.body, into: snapshot.accounts)
            try Self.validate(restored.accounts, blockedOrigins: transaction.opened.head.blockedOrigins)
            try transaction.restore(entry, account: restored.account, stampsModifiedAt: entry.body.scope == .credential)
            return try transaction.finish()
        }.receipt
    }

    // MARK: Earlier versions

    /// The account `restoreRevision` would leave live. Refuses what `restoreRevision` would refuse (a decode failure, an invalid result).
    func previewRestoreRevision(vaultID: UUID, revisionID: UUID, using access: VaultAccess) async throws -> CredentialAccount {
        try await readHistory(vaultID, access) { db, grant, opened in
            let snapshot = try Self.readSnapshot(db, grant: grant, vaultID: vaultID)
            let restored = try Self.restoringRevision(db, revisionID, snapshot: snapshot, grant: grant)
            try Self.validate(restored.accounts, blockedOrigins: opened.head.blockedOrigins)
            guard let account = restored.accounts.first(where: { $0.id == restored.owner }) else { throw CredentialVaultError.invalidData }
            return account
        }
    }

    /// An ordinary semantic commit (§11.1): the current value becomes a new revision, the chosen revision row is untouched.
    func restoreRevision(vaultID: UUID, revisionID: UUID, expectedRevision: UInt64, using access: VaultAccess) async throws -> VaultCommitReceipt {
        let intent = CommitIntent(vaultID: vaultID, access: access, expectedRevision: expectedRevision, cause: nil, isCommit: true)
        return try await run(intent, ledgerOnDemand: false) { db, request, ledgerAttached in
            let (transaction, snapshot) = try Self.begin(db, request)
            try transaction.verifyHistories()  // before the selected row is read or decoded
            let restored = try Self.restoringRevision(db, revisionID, snapshot: snapshot, grant: request.grant)
            return try Self.apply(
                Proposal(accounts: restored.accounts, requires: nil, restoring: restored.owner), snapshot: snapshot, transaction, request,
                ledgerAttached: ledgerAttached
            )
        }.receipt
    }

    // MARK: Removed identifiers

    /// Ids only, one Trash row at a time, never a secret (§13.3). One account-level row per removed account plus one row per passkey
    /// of it; a stored empty exchange id is invalid data, never `nil`.
    func removedIdentifiers(vaultID: UUID, using access: VaultAccess) async throws -> RemovedIdentifiers {
        let items = try await readHistory(vaultID, access) { db, grant, opened -> [RemovedIdentifier] in
            let trash = try Self.openTrash(db, grant: grant, opened: opened)
            var items: [RemovedIdentifier] = []
            try mapIntegrity(grant.ordinal) {
                try StoreTables.forEachHistoryRecord(db, vaultID: trash.side.vaultID) { row in
                    switch row.kind {
                    case .trashEntry:
                        let body = try JSONDecoder().decode(TrashEntryBody.self, from: row.opened(key: trash.side.key, ids: grant.ids))
                        items += try Self.identifiers(of: body, entryID: row.recordID)
                    case .tombstone:
                        let body = try JSONDecoder().decode(TombstoneBody.self, from: row.opened(key: trash.side.key, ids: grant.ids))
                        items.append(
                            RemovedIdentifier(
                                entryID: body.entryID, isTombstone: true, accountID: body.ownerID, exchangeAccountID: body.exchangeAccountID,
                                exchangeItemID: body.exchangeItemID, passkeyCredentialID: body.passkeyCredentialID, rpID: body.rpID,
                                removedAt: body.purgedAt
                            )
                        )
                    case .account, .revision:
                        break
                    }
                }
            }
            return items
        }
        guard !items.contains(where: { $0.exchangeAccountID?.isEmpty == true || $0.exchangeItemID?.isEmpty == true }) else {
            throw CredentialVaultError.invalidData
        }
        return RemovedIdentifiers(items: items)
    }

    nonisolated private static func identifiers(of body: TrashEntryBody, entryID: UUID) throws -> [RemovedIdentifier] {
        func row(accountID: Data?, itemID: Data?, passkey: WebsitePasskey?) -> RemovedIdentifier {
            RemovedIdentifier(
                entryID: entryID, isTombstone: false, accountID: body.ownerID, exchangeAccountID: accountID, exchangeItemID: itemID,
                passkeyCredentialID: passkey?.credentialID, rpID: passkey?.rpID, removedAt: body.deletedAt
            )
        }
        switch (body.scope, body.subject) {
        case (.account, _):
            guard let snapshot = body.snapshot else { throw CredentialStoreError.malformed }
            let ids = (snapshot.exchangeAccountID, snapshot.exchangeItemID)
            return [row(accountID: ids.0, itemID: ids.1, passkey: nil)] + snapshot.passkeys.map { row(accountID: ids.0, itemID: ids.1, passkey: $0) }
        case (.credential, .passkey?):
            guard let value = body.credentialValue else { throw CredentialStoreError.malformed }
            let passkey = try JSONDecoder().decode(WebsitePasskey.self, from: value)
            return [row(accountID: body.exchangeAccountID, itemID: body.exchangeItemID, passkey: passkey)]
        case (.credential, _):
            return [row(accountID: body.exchangeAccountID, itemID: body.exchangeItemID, passkey: nil)]
        }
    }

    // MARK: Shared read path

    /// One read under the operation lock: the grant authorized, the vault opened against the entries the session verified, `body` run
    /// on a consistent snapshot.
    func readHistory<T>(
        _ vaultID: UUID, _ access: VaultAccess, _ body: (Database, VaultGrant, OpenedVault) throws -> T
    ) async throws -> T {
        _ = try authorizedGrant(vaultID, access)
        let clock = now
        return try await withOperation { pool in
            let grant = try authorizedGrant(vaultID, access)  // re-checked after the lock wait
            return try pool.read { (db: Database) throws in
                try body(db, grant, try Self.openVault(db, grant: grant, vaultID: vaultID, access: access, now: clock))
            }
        }
    }

    /// Up to `StoreFormat.historyPage` record ids of `kind` newest first, and the cursor of the next page. At most 51 small rows are
    /// fetched; the sealed rows are then read one at a time.
    nonisolated private static func pageIDs(
        _ db: Database, vaultID: UUID, kind: RecordKind, ownerID: UUID?, after: Int?, ordinal: Int
    ) throws -> (ids: [UUID], next: Int?) {
        var sql = "SELECT rowid, recordID FROM record WHERE vaultID = ? AND kind = ?"
        var arguments: StatementArguments = [vaultID.uuidString.lowercased(), kind.sqlName]
        if let ownerID {
            sql += " AND ownerID = ?"
            arguments += [ownerID.uuidString.lowercased()]
        }
        if let after {
            sql += " AND rowid < ?"
            arguments += [after]
        }
        sql += " ORDER BY rowid DESC LIMIT ?"
        arguments += [StoreFormat.historyPage + 1]
        return try mapIntegrity(ordinal) {
            var found: [(rowid: Int, id: UUID)] = []
            for row in try Row.fetchAll(db, sql: sql, arguments: arguments) {
                guard case .int64(let rawRowID) = (row[0] as DatabaseValue).storage, let rowid = Int(exactly: rawRowID),
                    case .string(let text) = (row[1] as DatabaseValue).storage, let id = UUID(uuidString: text), id.uuidString.lowercased() == text
                else { throw CredentialStoreError.malformed }
                found.append((rowid, id))
            }
            let shown = found.prefix(StoreFormat.historyPage)
            return (shown.map(\.id), found.count > StoreFormat.historyPage ? shown.last?.rowid : nil)
        }
    }

    nonisolated private static func storedEntry(
        _ db: Database, _ entryID: UUID, trash: TrashState, grant: VaultGrant
    ) throws -> StoredTrashEntry {
        guard let row = try mapIntegrity(grant.ordinal, { try StoreTables.record(db, vaultID: trash.side.vaultID, recordID: entryID) }),
            row.kind == .trashEntry
        else { throw CredentialVaultError.invalidData }
        return try mapIntegrity(grant.ordinal) {
            let body = try JSONDecoder().decode(TrashEntryBody.self, from: row.opened(key: trash.side.key, ids: grant.ids))
            guard body.ownerID == row.ownerID, (body.subject ?? .account) == row.subject, (body.subject == nil) == (body.scope == .account) else {
                throw CredentialStoreError.malformed
            }
            return StoredTrashEntry(row: row, body: body)
        }
    }

    nonisolated private static func trashItem(_ db: Database, _ entry: StoredTrashEntry, grant: VaultGrant) throws -> TrashItem {
        let body = entry.body
        return try mapIntegrity(grant.ordinal) {
            var sql = "SELECT COUNT(*) FROM record WHERE vaultID = ? AND kind = ? AND ownerID = ?"
            var arguments: StatementArguments = [entry.row.vaultID.uuidString.lowercased(), RecordKind.revision.sqlName, body.ownerID.uuidString.lowercased()]
            if let subject = body.subject {
                sql += " AND subject = ?"
                arguments += [subject.sqlName]
            }
            let label: String
            if body.scope == .account {
                guard let snapshot = body.snapshot else { throw CredentialStoreError.malformed }
                label = CommitTransaction.label(snapshot) ?? snapshot.username
            } else {
                label = body.label ?? ""
            }
            return TrashItem(
                id: entry.row.recordID, scope: body.scope, ownerID: body.ownerID, subject: body.subject, label: label,
                revisionCount: try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
            )
        }
    }

    // MARK: Collision rules (§11.3)

    /// The first clash restoring `body` into `accounts` would cause, or `nil`. Pure: nothing is read or written.
    ///
    /// `forUndo` is an undo putting back a state the user just had. It keeps every identity rule (the account id, the exporter item,
    /// a live account that holds the entry as a merged item, an occupied slot, the passkey identity, a missing owner) and drops the two
    /// rules that refuse a legal duplicate: the same username on the same website, which an editor or an import may create, and a
    /// live account that only shares the exporter's account id (one export gives every item of it the same one).
    nonisolated static func block(_ body: TrashEntryBody, among accounts: [CredentialAccount], forUndo: Bool = false) throws -> UndeleteBlock? {
        if body.scope == .account {
            guard let removed = body.snapshot else { throw CredentialStoreError.malformed }
            if accounts.contains(where: { $0.id == removed.id }) {
                return .idCollision
            }
            if sharesExchangeID(removed, with: accounts, identityOnly: forUndo) {
                return .exchangeIDCollision
            }
            if !forUndo, overlaps(username: removed.username, origins: removed.origins, with: accounts) {
                return .originUsernameOverlap
            }
            return try passkeyBlock(removed.passkeys, among: accounts)
        }
        guard let owner = accounts.first(where: { $0.id == body.ownerID }) else { return .ownerMissing }
        guard let value = body.credentialValue, let subject = body.subject else { throw CredentialStoreError.malformed }
        // §11.3: the owner is the intended target and is excluded from the exchange-id and origin+username checks of every kind.
        // What the entry carries is what was recorded when it was removed (`TrashEntryBody.exchangeItemID`), never the owner's current ids.
        func otherAccountBlock(itemIDs: [Data?], username: String) -> UndeleteBlock? {
            let items = itemIDs.compactMap { $0 }
            if accounts.contains(where: { $0.id != owner.id && $0.exchangeItemID.map(items.contains) == true }) {
                return .exchangeIDCollision
            }
            if forUndo {
                return nil
            }
            return overlaps(username: username, origins: owner.origins, with: accounts, excluding: owner.id) ? .originUsernameOverlap : nil
        }
        switch subject {
        case .password:
            let password = try Self.decode(PasswordValue.self, from: value)
            // The slot is the password and the username that goes with it: never overwrite a different live one.
            if owner.password != nil || (!owner.username.isEmpty && owner.username != password.username) {
                return .slotOccupied(.password)
            }
            return otherAccountBlock(itemIDs: [body.exchangeItemID], username: password.username)
        case .totp:
            _ = try Self.decode(TOTPGenerator.self, from: value)
            if owner.totp != nil {
                return .slotOccupied(.totp)
            }
            // A one-time code has no username of its own: it belongs to the owner's login.
            return otherAccountBlock(itemIDs: [body.exchangeItemID], username: owner.username)
        case .note:
            _ = try Self.decode([CredentialNote].self, from: value)
            if owner.notes != nil {
                return .slotOccupied(.note)
            }
            // Notes have no username of their own either: they belong to the owner.
            return otherAccountBlock(itemIDs: [body.exchangeItemID], username: owner.username)
        case .passkey:
            let passkey = try Self.decode(WebsitePasskey.self, from: value)
            if let block = try passkeyBlock([passkey], among: accounts) {
                return block
            }
            return otherAccountBlock(itemIDs: [body.exchangeItemID, passkey.base?.itemID], username: passkey.userName)
        case .account, .metadata:
            throw CredentialStoreError.malformed
        }
    }

    /// §11.3: any live `exchangeAccountID` or `exchangeItemID` equal to the entry's blocks a whole account (conservative: one exchange
    /// account owns many items, so this can refuse more than strictly needed; the user removes the live item and retries). So does a
    /// live account the entry was merged into (`MergedItemLink`): it holds the item now.
    ///
    /// `identityOnly` (an undo) asks only whether a live account claims the same exporter item (the pair of exporter account id and
    /// item id, which is what the vault itself keeps unique) or holds the entry as a merged item.
    nonisolated private static func sharesExchangeID(
        _ removed: CredentialAccount, with accounts: [CredentialAccount], identityOnly: Bool = false
    ) -> Bool {
        if identityOnly {
            guard let identity = try? CredentialExchangeCodec.externalItemID(for: removed) else { return true }
            return accounts.contains { $0.holdsMergedItem(of: removed) || (try? CredentialExchangeCodec.externalItemID(for: $0)) == identity }
        }
        return accounts.contains {
            (removed.exchangeAccountID != nil && $0.exchangeAccountID == removed.exchangeAccountID)
                || (removed.exchangeItemID != nil && $0.exchangeItemID == removed.exchangeItemID)
                || $0.holdsMergedItem(of: removed)
        }
    }

    nonisolated private static func overlaps(
        username: String, origins: [String], with accounts: [CredentialAccount], excluding owner: UUID? = nil
    ) -> Bool {
        accounts.contains { $0.id != owner && $0.username == username && !Set($0.origins).isDisjoint(with: origins) }
    }

    /// A live passkey with the same case-folded `rpID` + `credentialID` blocks. Whether it is the same passkey is the §13.3 normalized
    /// cryptographic identity (`CredentialContent.hash(.passkey)`: case-folded rpID, credential id, user handle and the re-encoded
    /// public key, so the same key in another DER encoding is a duplicate): a different public key or user handle is the identity
    /// conflict instead.
    nonisolated private static func passkeyBlock(_ passkeys: [WebsitePasskey], among accounts: [CredentialAccount]) throws -> UndeleteBlock? {
        var block: UndeleteBlock?
        for passkey in passkeys {
            let rpID = passkey.rpID.lowercased()
            var identity: Data?
            for account in accounts {
                for live in account.passkeys where live.credentialID == passkey.credentialID && live.rpID.lowercased() == rpID {
                    let incoming = try identity ?? CredentialContent.hash(.passkey(passkey))
                    identity = incoming
                    if try CredentialContent.hash(.passkey(live)) != incoming {
                        return .passkeyIdentityConflict
                    }
                    block = .passkeyCollision
                }
            }
        }
        return block
    }

    // MARK: Applying typed values

    /// Strict typed decode: the bytes must be the canonical JSON of exactly one `T` (a whole serialized account decodes as a
    /// `PasswordValue` leniently, but never re-encodes to the same bytes). Any failure is `invalidData`.
    nonisolated static func decode<T: Codable>(_ type: T.Type, from data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(T.self, from: data), (try? CredentialContent.canonicalJSON(value)) == data else {
            throw CredentialVaultError.invalidData
        }
        return value
    }

    /// `accounts` with the entry applied: a whole account added unchanged, a credential put into its live owner's slot (only that typed
    /// value; a passkey never replaces an existing key).
    nonisolated static func restoring(
        _ body: TrashEntryBody, into accounts: [CredentialAccount]
    ) throws -> (accounts: [CredentialAccount], account: CredentialAccount) {
        if body.scope == .account {
            guard let removed = body.snapshot else { throw CredentialStoreError.malformed }
            return (accounts + [removed], removed)
        }
        guard let index = accounts.firstIndex(where: { $0.id == body.ownerID }), let value = body.credentialValue, let subject = body.subject else {
            throw CredentialStoreError.malformed
        }
        var owner = accounts[index]
        switch subject {
        case .password:
            let password = try decode(PasswordValue.self, from: value)
            owner.username = password.username
            owner.password = password.password
            owner.basicAuthenticationMetadata = password.basicAuthenticationMetadata
        case .totp:
            owner.totp = try decode(TOTPGenerator.self, from: value)
        case .note:
            owner.notes = try decode([CredentialNote].self, from: value)
        case .passkey:
            owner.passkeys.append(try decode(WebsitePasskey.self, from: value))
        case .account, .metadata:
            throw CredentialStoreError.malformed
        }
        var result = accounts
        result[index] = owner
        return (result, owner)
    }

    /// `account` with one superseded typed value put back in its own slot, the way `restoreRevision` writes it and the History panel
    /// rebuilds an earlier version. `value` must be the canonical JSON of exactly one typed value (`decode` is strict); a passkey and
    /// the account itself are not revision subjects.
    nonisolated static func applying(_ subject: RecordSubject, value: Data, to account: inout CredentialAccount) throws {
        switch subject {
        case .password:
            let login = try decode(PasswordValue.self, from: value)
            account.username = login.username
            account.password = login.password
            account.basicAuthenticationMetadata = login.basicAuthenticationMetadata
        case .totp:
            account.totp = try decode(TOTPGenerator.self, from: value)
        case .note:
            account.notes = try decode([CredentialNote].self, from: value)
        case .metadata:
            let details = try decode(MetadataProjection.self, from: value)
            account.displayName = details.displayName
            account.origins = details.origins
            account.loginURLs = details.loginURLs
            account.exchangeMetadata = details.exchange
            account.exchangeAccountID = details.exchangeAccountID
            account.exchangeItemID = details.exchangeItemID
        case .account, .passkey:
            throw CredentialVaultError.invalidData
        }
    }

    /// The live accounts with the chosen earlier revision applied to its owner (only the typed value of the revision's subject), and
    /// the owner's id.
    nonisolated private static func restoringRevision(
        _ db: Database, _ revisionID: UUID, snapshot: StoreSnapshot, grant: VaultGrant
    ) throws -> (accounts: [CredentialAccount], owner: UUID) {
        guard let row = try mapIntegrity(grant.ordinal, { try StoreTables.record(db, vaultID: snapshot.vaultID, recordID: revisionID) }),
            row.kind == .revision, let index = snapshot.accounts.firstIndex(where: { $0.id == row.ownerID })
        else { throw CredentialVaultError.invalidData }
        let body = try mapIntegrity(grant.ordinal) {
            try JSONDecoder().decode(RevisionBody.self, from: row.opened(key: grant.dek, ids: grant.ids))
        }
        var account = snapshot.accounts[index]
        try applying(row.subject, value: body.value, to: &account)
        var accounts = snapshot.accounts
        accounts[index] = account
        return (accounts, account.id)
    }
}

/// The reverse MOVE: Trash → the source vault, inside the caller's transaction, after `verifyHistories`.
nonisolated extension CommitTransaction {
    func trashEntry(_ entryID: UUID) throws -> StoredTrashEntry {
        guard let trash else { throw integrity }
        guard let row = try mapIntegrity(grant.ordinal, { try StoreTables.record(db, vaultID: trash.side.vaultID, recordID: entryID) }),
            row.kind == .trashEntry
        else { throw CredentialVaultError.invalidData }
        return try mapIntegrity(grant.ordinal) {
            let body = try JSONDecoder().decode(TrashEntryBody.self, from: row.opened(key: trash.side.key, ids: ids))
            guard body.ownerID == row.ownerID, (body.subject ?? .account) == row.subject, (body.subject == nil) == (body.scope == .account) else {
                throw CredentialStoreError.malformed
            }
            return StoredTrashEntry(row: row, body: body)
        }
    }

    /// Puts `account` live, moves the entry's revision rows (one at a time, re-sealed under the source key, same ids, versions and
    /// provenance) from the Trash back to the source, removes the `trashEntry`, and journals the `out` group on the Trash and the `in`
    /// group on the source. A throw rolls the whole transaction back.
    func restore(_ entry: StoredTrashEntry, account: CredentialAccount, stampsModifiedAt: Bool) throws {
        guard var trashState = trash else { throw integrity }
        var source = self.source
        let body = entry.body
        try putLive(account, stampsModifiedAt: stampsModifiedAt)
        guard let liveVersion = live[account.id]?.version else { throw integrity }

        let header = TransferHeader(
            transferID: UUID(), direction: .out, scope: body.scope, ownerID: body.ownerID, subject: body.subject, liveRecordID: account.id,
            liveVersion: liveVersion, entryRecordID: entry.row.recordID
        )
        var inHeader = header
        inHeader.direction = .in
        var out = JournalGroup(transfer: header)
        var into = JournalGroup(transfer: inHeader)

        let entryAAD = RowAAD(
            ids: ids, vaultID: entry.row.vaultID, recordID: entry.row.recordID, kind: .trashEntry, ownerID: entry.row.ownerID,
            subject: entry.row.subject, version: entry.row.version
        )
        try StoreTables.deleteRecord(db, vaultID: entry.row.vaultID, recordID: entry.row.recordID)
        trashState.side.counts.trashEntry -= 1
        try out.add(JournalOp(entryAAD, op: .remove, rowDigest: StoreSeal.digest(entry.row.sealed)), to: &trashState.side, db: db, ids: ids)

        var after: UUID?
        while let row = try mapIntegrity(grant.ordinal, {
            try StoreTables.nextOwnedRevision(db, vaultID: trashState.side.vaultID, ownerID: body.ownerID, subject: body.subject, after: after)
        }) {
            try Task.checkCancellation()
            after = row.recordID
            let from = RowAAD(
                ids: ids, vaultID: row.vaultID, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject, version: row.version
            )
            let plaintext = try mapIntegrity(grant.ordinal) { try StoreSeal.openRow(row.sealed, key: trashState.side.key, aad: from) }
            var to = from
            to.vaultID = source.vaultID
            let sealed = try mapIntegrity(grant.ordinal) { try StoreSeal.sealRow(plaintext, key: source.key, aad: to) }
            try StoreTables.putRecord(db, StoreTables.RecordRow(to, sealed: sealed))
            try StoreTables.deleteRecord(db, vaultID: row.vaultID, recordID: row.recordID)
            trashState.side.counts.revision -= 1
            source.counts.revision += 1
            try out.add(JournalOp(from, op: .remove, rowDigest: StoreSeal.digest(row.sealed)), to: &trashState.side, db: db, ids: ids)
            try into.add(JournalOp(to, op: .add, rowDigest: StoreSeal.digest(sealed)), to: &source, db: db, ids: ids)
        }
        try out.finish(&trashState.side, db: db, ids: ids)
        try into.finish(&source, db: db, ids: ids)
        self.source = source
        trash = trashState
    }
}
