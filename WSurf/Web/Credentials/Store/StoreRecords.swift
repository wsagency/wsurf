// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

// Plaintext value types of the sealed store and their byte encodings (spec §5 fixed encoding, §7 field order).
// Every reader failure is `CredentialStoreError.malformed`; array counts are bounded before anything is allocated.

nonisolated struct StoreIDs: Equatable, Sendable {
    let storeID: UUID
    let profileID: UUID
}

nonisolated struct VaultLink: Equatable, Sendable {
    let peerVaultID: UUID
    let nonce: Data
}

nonisolated struct LiveEntry: Equatable, Sendable {
    let recordID: UUID
    let version: UInt64
    let digest: Data
}

nonisolated struct HistoryCounts: Equatable, Sendable {
    var revision = 0
    var trashEntry = 0
    var tombstone = 0
}

nonisolated struct VaultHead: Equatable, Sendable {
    var ids: StoreIDs
    var vaultID: UUID
    var role: VaultRole
    var revision: UInt64
    var name: String
    var registryKey: Data?
    /// §7 planning clarification: sorted by UTF-8 bytes, unique, at most 4,096 canonical origins; empty on trash heads.
    var blockedOrigins: [String]
    var link: VaultLink
    var liveCatalog: [LiveEntry]
    var journalSeq: UInt64
    var chainTip: Data
    var historyCounts: HistoryCounts
}

nonisolated struct TransferHeader: Equatable, Sendable {
    var transferID: UUID
    var direction: TransferDirection
    var scope: TransferScope
    var ownerID: UUID
    var subject: RecordSubject?
    var liveRecordID: UUID
    var liveVersion: UInt64
    var entryRecordID: UUID
}

nonisolated struct JournalOp: Equatable, Sendable {
    var op: JournalOpKind
    var recordID: UUID
    var kind: RecordKind
    var ownerID: UUID
    var subject: RecordSubject
    var version: UInt64
    var rowDigest: Data
}

nonisolated struct JournalRow: Equatable, Sendable {
    var seq: UInt64
    var prevChain: Data
    var transfer: TransferHeader?
    var ops: [JournalOp]
}

nonisolated struct RowAAD: Equatable, Sendable {
    var ids: StoreIDs
    var vaultID: UUID
    var recordID: UUID
    var kind: RecordKind
    var ownerID: UUID
    var subject: RecordSubject
    var version: UInt64
}

nonisolated struct RegistryEntry: Equatable, Sendable {
    var vaultID: UUID
    var role: VaultRole
    var ordinal: Int
    var createdAt: Date
    var wrappersDigest: Data
    var keyWrapDigest: Data
    var headRevision: UInt64
    var headDigest: Data
}

nonisolated struct RegistryCatalog: Equatable, Sendable {
    var ids: StoreIDs
    var revision: UInt64
    var vaults: [RegistryEntry]

    /// Fixed field order; vaults sorted by their 16 raw id bytes, so the input order never matters.
    func encode() -> Data {
        var writer = StoreWriter()
        writer.u64(UInt64(StoreFormat.schema))
        ids.write(to: &writer)
        writer.u64(revision)
        writer.array(vaults.sorted { $0.vaultID.rawBytes.lexicographicallyPrecedes($1.vaultID.rawBytes) }) { writer, entry in
            writer.uuid(entry.vaultID)
            writer.u8(entry.role.rawValue)
            writer.u64(UInt64(clamping: entry.ordinal))
            writer.date(entry.createdAt)
            writer.bytes(entry.wrappersDigest)
            writer.bytes(entry.keyWrapDigest)
            writer.u64(entry.headRevision)
            writer.bytes(entry.headDigest)
        }
        return writer.data
    }

    /// Strict inverse of `encode()`: a foreign schema, an unsorted or repeated vault id and trailing bytes are malformed.
    static func decode(_ data: Data) throws -> RegistryCatalog {
        var reader = StoreReader(data)
        guard try reader.u64() == UInt64(StoreFormat.schema) else { throw CredentialStoreError.malformed }
        let ids = try StoreIDs.read(from: &reader)
        let revision = try reader.u64()
        let vaults = try reader.array(maxCount: 2 * StoreFormat.activeVaultLimit) { reader in
            RegistryEntry(
                vaultID: try reader.uuid(),
                role: try reader.tag(VaultRole.self),
                ordinal: try reader.int(),
                createdAt: try reader.date(),
                wrappersDigest: try reader.bytes(),
                keyWrapDigest: try reader.bytes(),
                headRevision: try reader.u64(),
                headDigest: try reader.bytes()
            )
        }
        guard reader.isAtEnd else { throw CredentialStoreError.malformed }
        for (previous, next) in zip(vaults, vaults.dropFirst()) {
            guard previous.vaultID.rawBytes.lexicographicallyPrecedes(next.vaultID.rawBytes) else { throw CredentialStoreError.malformed }
        }
        return RegistryCatalog(ids: ids, revision: revision, vaults: vaults)
    }
}

// MARK: - Encodings

nonisolated extension StoreIDs {
    func write(to writer: inout StoreWriter) {
        writer.uuid(storeID)
        writer.uuid(profileID)
    }

    static func read(from reader: inout StoreReader) throws -> StoreIDs {
        StoreIDs(storeID: try reader.uuid(), profileID: try reader.uuid())
    }
}

nonisolated extension VaultHead {
    /// Plaintext encoding in the §7 block order, `blockedOrigins` directly after `registryKey`. No validation.
    func encode() -> Data {
        var writer = StoreWriter()
        ids.write(to: &writer)
        writer.uuid(vaultID)
        writer.u8(role.rawValue)
        writer.u64(revision)
        writer.text(name)
        writer.optional(registryKey) { $0.bytes($1) }
        writer.array(blockedOrigins) { $0.text($1) }
        writer.uuid(link.peerVaultID)
        writer.bytes(link.nonce)
        writer.array(liveCatalog) { writer, entry in
            writer.uuid(entry.recordID)
            writer.u64(entry.version)
            writer.bytes(entry.digest)
        }
        writer.u64(journalSeq)
        writer.bytes(chainTip)
        writer.u64(UInt64(clamping: historyCounts.revision))
        writer.u64(UInt64(clamping: historyCounts.trashEntry))
        writer.u64(UInt64(clamping: historyCounts.tombstone))
        return writer.data
    }

    /// Structural decode only (bounded counts, known tags, no trailing bytes); the policy is checked by `validatePolicy`.
    static func decode(_ data: Data) throws -> VaultHead {
        var reader = StoreReader(data)
        let ids = try StoreIDs.read(from: &reader)
        let vaultID = try reader.uuid()
        let role = try reader.tag(VaultRole.self)
        let revision = try reader.u64()
        let name = try reader.text()
        let registryKey = try reader.optional { try $0.bytes() }
        let origins = try reader.array(maxCount: StoreFormat.blockedOriginLimit) { try $0.text() }
        let link = VaultLink(peerVaultID: try reader.uuid(), nonce: try reader.bytes())
        let catalog = try reader.array(maxCount: CredentialVaultLimits.accounts) { reader in
            LiveEntry(recordID: try reader.uuid(), version: try reader.u64(), digest: try reader.bytes())
        }
        let journalSeq = try reader.u64()
        let chainTip = try reader.bytes()
        let counts = HistoryCounts(revision: try reader.int(), trashEntry: try reader.int(), tombstone: try reader.int())
        guard reader.isAtEnd else { throw CredentialStoreError.malformed }
        return VaultHead(
            ids: ids,
            vaultID: vaultID,
            role: role,
            revision: revision,
            name: name,
            registryKey: registryKey,
            blockedOrigins: origins,
            link: link,
            liveCatalog: catalog,
            journalSeq: journalSeq,
            chainTip: chainTip,
            historyCounts: counts
        )
    }

    /// §7: count at most 4,096, strictly ascending by UTF-8 bytes (so unique), every entry a canonical origin.
    func validatePolicy() throws {
        guard blockedOrigins.count <= StoreFormat.blockedOriginLimit else { throw CredentialStoreError.malformed }
        for (previous, next) in zip(blockedOrigins, blockedOrigins.dropFirst()) {
            guard previous.utf8.lexicographicallyPrecedes(next.utf8) else { throw CredentialStoreError.malformed }
        }
        for origin in blockedOrigins {
            guard let url = URL(string: origin), CredentialAccount.origin(for: url) == origin else { throw CredentialStoreError.malformed }
        }
    }
}

nonisolated extension JournalRow {
    func encode() -> Data {
        var writer = StoreWriter()
        writer.u64(seq)
        writer.bytes(prevChain)
        writer.optional(transfer) { writer, header in
            writer.uuid(header.transferID)
            writer.u8(header.direction.rawValue)
            writer.u8(header.scope.rawValue)
            writer.uuid(header.ownerID)
            writer.optional(header.subject) { $0.u8($1.rawValue) }
            writer.uuid(header.liveRecordID)
            writer.u64(header.liveVersion)
            writer.uuid(header.entryRecordID)
        }
        writer.array(ops) { writer, op in
            writer.u8(op.op.rawValue)
            writer.uuid(op.recordID)
            writer.u8(op.kind.rawValue)
            writer.uuid(op.ownerID)
            writer.u8(op.subject.rawValue)
            writer.u64(op.version)
            writer.bytes(op.rowDigest)
        }
        return writer.data
    }

    static func decode(_ data: Data) throws -> JournalRow {
        var reader = StoreReader(data)
        let seq = try reader.u64()
        let prevChain = try reader.bytes()
        let transfer = try reader.optional { reader in
            TransferHeader(
                transferID: try reader.uuid(),
                direction: try reader.tag(TransferDirection.self),
                scope: try reader.tag(TransferScope.self),
                ownerID: try reader.uuid(),
                subject: try reader.optional { try $0.tag(RecordSubject.self) },
                liveRecordID: try reader.uuid(),
                liveVersion: try reader.u64(),
                entryRecordID: try reader.uuid()
            )
        }
        let ops = try reader.array(maxCount: StoreFormat.journalOpsPerRow) { reader in
            JournalOp(
                op: try reader.tag(JournalOpKind.self),
                recordID: try reader.uuid(),
                kind: try reader.tag(RecordKind.self),
                ownerID: try reader.uuid(),
                subject: try reader.tag(RecordSubject.self),
                version: try reader.u64(),
                rowDigest: try reader.bytes()
            )
        }
        guard reader.isAtEnd else { throw CredentialStoreError.malformed }
        return JournalRow(seq: seq, prevChain: prevChain, transfer: transfer, ops: ops)
    }
}

// MARK: - Helpers

private nonisolated extension StoreReader {
    mutating func tag<T: RawRepresentable>(_ type: T.Type) throws -> T where T.RawValue == UInt8 {
        guard let value = T(rawValue: try u8()) else { throw CredentialStoreError.malformed }
        return value
    }

    mutating func int() throws -> Int {
        guard let value = Int(exactly: try u64()) else { throw CredentialStoreError.malformed }
        return value
    }
}

private nonisolated extension UUID {
    var rawBytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}
