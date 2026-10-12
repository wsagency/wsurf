// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import GRDB

/// One vault's write cursor inside a transaction: the key its rows seal under, and the journal tip and history counts the head
/// will carry.
nonisolated struct WriteSide {
    let vaultID: UUID
    let key: SymmetricKey
    var journalSeq: UInt64
    var chainTip: Data
    var counts: HistoryCounts
}

extension JournalOp {
    /// The op for the row `aad` names; `rowDigest` is the digest of that row's sealed bytes on this side.
    nonisolated init(_ aad: RowAAD, op: JournalOpKind, rowDigest: Data) {
        self.init(
            op: op, recordID: aad.recordID, kind: aad.kind, ownerID: aad.ownerID, subject: aad.subject, version: aad.version,
            rowDigest: rowDigest
        )
    }
}

/// The journal rows of one group (one MOVE direction, or the revision rows of a commit) on one side. Rows hold at most
/// `StoreFormat.journalOpsPerRow` ops and a chunked group repeats its header. A transfer group always writes at least one row, even
/// with no ops (the verifier pairs the `out` and `in` groups of a transfer), but never an empty continuation row.
nonisolated struct JournalGroup {
    let transfer: TransferHeader?
    private var ops: [JournalOp] = []
    private var rows = 0

    init(transfer: TransferHeader?) {
        self.transfer = transfer
    }

    mutating func add(_ op: JournalOp, to side: inout WriteSide, db: Database, ids: StoreIDs) throws {
        ops.append(op)
        if ops.count == StoreFormat.journalOpsPerRow {
            try flush(&side, db: db, ids: ids)
        }
    }

    mutating func finish(_ side: inout WriteSide, db: Database, ids: StoreIDs) throws {
        if !ops.isEmpty || (transfer != nil && rows == 0) {
            try flush(&side, db: db, ids: ids)
        }
    }

    private mutating func flush(_ side: inout WriteSide, db: Database, ids: StoreIDs) throws {
        let row = JournalRow(seq: side.journalSeq + 1, prevChain: side.chainTip, transfer: transfer, ops: ops)
        let sealed = try StoreSeal.sealJournal(row, key: side.key, ids: ids, vaultID: side.vaultID)
        try StoreTables.putJournal(db, vaultID: side.vaultID, seq: row.seq, sealed: sealed)
        side.journalSeq = row.seq
        side.chainTip = StoreSeal.chain(side.chainTip, sealed: sealed)
        ops.removeAll(keepingCapacity: true)
        rows += 1
    }
}

/// Spec §11.2: MOVE one removal into the linked Trash inside the caller's transaction. The removed account's (or credential's) owned
/// revision rows are re-sealed one at a time under the Trash key, keeping `recordID`, `kind`, `ownerID`, `subject` and the origin
/// `version`; the live row of a whole account is deleted; one `trashEntry` row records what was removed; the `out` group is journalled
/// on the source and the `in` group on the Trash. Nothing here outlives the transaction: any throw rolls the whole commit back.
nonisolated extension CommitTransaction {
    func move(_ scope: RemovalScope) throws {
        let (ownerID, subject, passkeyID) = Self.parts(of: scope)
        guard let removed = previous[ownerID], let liveRow = live[ownerID] else { throw CredentialVaultError.invalidData }
        var trashState = try openedTrash()
        var source = self.source

        let transferID = UUID()
        let entryID = UUID()
        let header = TransferHeader(
            transferID: transferID, direction: .out, scope: subject == nil ? .account : .credential, ownerID: ownerID, subject: subject,
            liveRecordID: ownerID, liveVersion: liveRow.version, entryRecordID: entryID
        )
        var inHeader = header
        inHeader.direction = .in
        var out = JournalGroup(transfer: header)
        var into = JournalGroup(transfer: inHeader)

        // The trashEntry first: it is the cheapest row to refuse (an over-large body is `limit(.historyRow)`).
        let entryAAD = RowAAD(
            ids: ids, vaultID: trashState.side.vaultID, recordID: entryID, kind: .trashEntry, ownerID: ownerID, subject: subject ?? .account,
            version: 1
        )
        let body = TrashEntryBody(
            deletedAt: wall, scope: header.scope, ownerID: ownerID, subject: subject, passkeyID: passkeyID,
            label: subject == nil ? nil : Self.label(removed),
            snapshot: subject == nil ? removed : nil,
            credentialValue: try subject.map { try Self.credentialValue(of: removed, subject: $0, passkeyID: passkeyID) }
        )
        let entryPlaintext = try CredentialContent.canonicalJSON(body)
        guard entryPlaintext.count <= StoreFormat.historyRowBytes else { throw CredentialStoreError.limit(.historyRow) }
        let entrySealed = try StoreSeal.sealRow(entryPlaintext, key: trashState.side.key, aad: entryAAD)
        try StoreTables.putRecord(db, StoreTables.RecordRow(entryAAD, sealed: entrySealed))
        trashState.side.counts.trashEntry += 1
        try into.add(JournalOp(entryAAD, op: .add, rowDigest: StoreSeal.digest(entrySealed)), to: &trashState.side, db: db, ids: ids)

        // The owner's revision rows of the source vault, one statement and one row at a time (`nextOwnedRevision` finishes before the
        // next write, so no cursor ever iterates the table this loop inserts into and deletes from). The clear columns it selects by
        // are trustworthy here: `transact` ran `verifyHistories` (both ledgers) before the first write of this transaction, so every
        // stored row's columns and ciphertext digest are the ones the journal expects, and a row this transaction wrote itself is ours.
        var after: UUID?
        while let row = try mapIntegrity(grant.ordinal, {
            try StoreTables.nextOwnedRevision(db, vaultID: source.vaultID, ownerID: ownerID, subject: subject, after: after)
        }) {
            try Task.checkCancellation()
            after = row.recordID
            let from = RowAAD(
                ids: ids, vaultID: source.vaultID, recordID: row.recordID, kind: row.kind, ownerID: row.ownerID, subject: row.subject,
                version: row.version
            )
            let plaintext = try mapIntegrity(grant.ordinal) { try StoreSeal.openRow(row.sealed, key: source.key, aad: from) }
            var to = from
            to.vaultID = trashState.side.vaultID
            let sealed = try mapIntegrity(grant.ordinal) { try StoreSeal.sealRow(plaintext, key: trashState.side.key, aad: to) }
            try StoreTables.putRecord(db, StoreTables.RecordRow(to, sealed: sealed))
            try StoreTables.deleteRecord(db, vaultID: source.vaultID, recordID: row.recordID)
            source.counts.revision -= 1
            trashState.side.counts.revision += 1
            try out.add(JournalOp(from, op: .remove, rowDigest: StoreSeal.digest(row.sealed)), to: &source, db: db, ids: ids)
            try into.add(JournalOp(to, op: .add, rowDigest: StoreSeal.digest(sealed)), to: &trashState.side, db: db, ids: ids)
        }
        if subject == nil {
            try StoreTables.deleteRecord(db, vaultID: source.vaultID, recordID: ownerID)
            live[ownerID] = nil
        }
        try out.finish(&source, db: db, ids: ids)
        try into.finish(&trashState.side, db: db, ids: ids)
        self.source = source
        trash = trashState
    }

    /// Once per removing transaction, before its first write: the source's and the Trash's stored history must be the rows their own
    /// journals replay to (`StoreVerifier.verifyHistories`). A MOVE selects source rows by clear columns, journals the source digests it
    /// removes and extends the Trash journal, so a valid but superseded ciphertext on either side (same count, same AAD) would otherwise
    /// commit a store whose next unlock fails. Opens the Trash through the same path the MOVE uses and keeps it for the MOVE.
    func verifyHistories() throws {
        let trashState = try openedTrash()
        try mapIntegrity(grant.ordinal) {
            try StoreVerifier(ids: ids).verifyHistories(
                in: db, source: (id: source.vaultID, key: source.key, head: opened.head),
                trash: (id: trashState.side.vaultID, key: trashState.side.key, head: trashState.head), isCancelled: { Task.isCancelled }
            )
        }
        trash = trashState
    }

    /// The linked Trash as this transaction sees it, opened on first use: its key unwrapped under the grant's DEK, and its stored
    /// head checked against the registry entry the session verified before it opens.
    private func openedTrash() throws -> TrashState {
        if let trash {
            return trash
        }
        let trashEntry = opened.trashEntry
        return try mapIntegrity(grant.ordinal) {
            guard let row = try StoreTables.vaultRows(db).first(where: { $0.vaultID == grant.trashID && $0.role == .trash }),
                let keyWrap = row.keyWrap, StoreSeal.digest(keyWrap) == trashEntry.keyWrapDigest,
                StoreSeal.digestOrZero(row.wrappers) == trashEntry.wrappersDigest,
                let stored = try StoreTables.head(db, vaultID: grant.trashID),
                stored.revision == trashEntry.headRevision, StoreSeal.digest(stored.sealed) == trashEntry.headDigest
            else { throw CredentialStoreError.malformed }
            let key = try StoreSeal.unwrapTrashKey(
                keyWrap, under: grant.dek, ids: ids, source: opened.head.vaultID, trash: grant.trashID, nonce: opened.head.link.nonce
            )
            let head = try StoreSeal.openHead(
                stored.sealed, key: key, ids: ids, vaultID: grant.trashID, revision: stored.revision,
                wrappersDigest: trashEntry.wrappersDigest, keyWrapDigest: trashEntry.keyWrapDigest
            )
            guard head.role == .trash, head.link.peerVaultID == opened.head.vaultID, head.link.nonce == opened.head.link.nonce else {
                throw CredentialStoreError.malformed
            }
            return TrashState(
                head: head,
                side: WriteSide(vaultID: head.vaultID, key: key, journalSeq: head.journalSeq, chainTip: head.chainTip, counts: head.historyCounts)
            )
        }
    }

    /// `subject == nil` is a whole account; the passkey id only exists for a passkey.
    private static func parts(of scope: RemovalScope) -> (ownerID: UUID, subject: RecordSubject?, passkeyID: UUID?) {
        switch scope {
        case .account(let id):
            (id, nil, nil)
        case .credential(let ownerID, let subject, let passkeyID):
            (ownerID, subject, passkeyID)
        }
    }

    /// The removed credential's own value, never the account: the `PasswordValue`, `TOTPGenerator` or `WebsitePasskey`.
    private static func credentialValue(of account: CredentialAccount, subject: RecordSubject, passkeyID: UUID?) throws -> Data {
        switch subject {
        case .password:
            return try CredentialContent.canonicalJSON(
                PasswordValue(username: account.username, password: account.password, basicAuthenticationMetadata: account.basicAuthenticationMetadata)
            )
        case .totp:
            guard let totp = account.totp else { throw CredentialVaultError.invalidData }
            return try CredentialContent.canonicalJSON(totp)
        case .passkey:
            guard let passkey = account.passkeys.first(where: { $0.id == passkeyID }) else { throw CredentialVaultError.invalidData }
            return try CredentialContent.canonicalJSON(passkey)
        case .account, .metadata:
            throw CredentialVaultError.invalidData
        }
    }

    /// The owner's display name and first origin, each cut to 256 UTF-8 bytes on a character boundary, so a Trash row is identifiable
    /// without reading the credential value.
    private static func label(_ account: CredentialAccount) -> String? {
        let parts = [account.displayName, account.origins.first].compactMap { $0 }.map { cut($0, bytes: 256) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func cut(_ text: String, bytes limit: Int) -> String {
        var used = 0
        var result = ""
        for character in text {
            used += String(character).utf8.count
            if used > limit {
                break
            }
            result.append(character)
        }
        return result
    }
}
