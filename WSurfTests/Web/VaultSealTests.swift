// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing

@testable import WSurf

/// Fixed values and an independent AAD/MAC builder. The builder spells out spec §5/§7 with `StoreWriter`, so a
/// sealed value that only opens under the documented fields proves the production code binds exactly those.
private nonisolated enum SealFixtures {
    static func id(_ first: UInt8, _ last: UInt8 = 0) -> UUID {
        UUID(uuid: (first, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, last))
    }

    static let ids = StoreIDs(storeID: id(0x01), profileID: id(0x02))
    static let vaultID = id(0x03)
    static let trashID = id(0x04)
    static let recordID = id(0x05)
    static let ownerID = id(0x06)
    static let revision: UInt64 = 7
    static let keyBytes = Data(repeating: 0x11, count: 32)
    static let key = SymmetricKey(data: keyBytes)
    static let otherKey = SymmetricKey(data: Data(repeating: 0x12, count: 32))
    static let registryKey = Data(repeating: 0x22, count: 32)
    static let nonce = Data(repeating: 0x33, count: 16)
    static let wrappersDigest = StoreSeal.digest(Data("wrappers".utf8))
    static let keyWrapDigest = Data(count: 32)
    static let origins = ["https://a.example", "https://b.example"]

    /// The frozen spec §5 constants, spelled out so a change to `StoreFormat` cannot silently change the expected AAD/MAC bytes.
    static let schema: UInt64 = 2
    static let rowLabel = "WSurf credential store"
    static let registryLabel = "WSurf registry v1"

    static func bytes(of key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    // MARK: Fixtures

    static func head(
        role: VaultRole = .active,
        registryKey: Data? = registryKey,
        origins: [String] = origins,
        name: String = "Personal"
    ) -> VaultHead {
        VaultHead(
            ids: ids,
            vaultID: vaultID,
            role: role,
            revision: revision,
            name: name,
            registryKey: registryKey,
            blockedOrigins: origins,
            link: VaultLink(peerVaultID: trashID, nonce: nonce),
            liveCatalog: [LiveEntry(recordID: id(0x31), version: 3, digest: Data(repeating: 0x32, count: 32))],
            journalSeq: 2,
            chainTip: Data(repeating: 0x34, count: 32),
            historyCounts: HistoryCounts(revision: 1, trashEntry: 2, tombstone: 3)
        )
    }

    static func rowAAD() -> RowAAD {
        RowAAD(ids: ids, vaultID: vaultID, recordID: recordID, kind: .revision, ownerID: ownerID, subject: .password, version: 3)
    }

    static func journalRow(seq: UInt64 = 2, prevChain: Data = Data(repeating: 0x44, count: 32), withTransfer: Bool = true) -> JournalRow {
        let transfer = TransferHeader(
            transferID: id(0x51),
            direction: .out,
            scope: .credential,
            ownerID: ownerID,
            subject: .password,
            liveRecordID: id(0x52),
            liveVersion: 4,
            entryRecordID: id(0x53)
        )
        let ops = [
            JournalOp(op: .add, recordID: id(0x61), kind: .revision, ownerID: ownerID, subject: .password, version: 1, rowDigest: Data(repeating: 0x55, count: 32)),
            JournalOp(op: .remove, recordID: id(0x62), kind: .trashEntry, ownerID: ownerID, subject: .account, version: 9, rowDigest: Data(repeating: 0x56, count: 32)),
        ]
        return JournalRow(seq: seq, prevChain: prevChain, transfer: withTransfer ? transfer : nil, ops: withTransfer ? ops : [])
    }

    static func entry(_ first: UInt8, role: VaultRole = .active) -> RegistryEntry {
        RegistryEntry(
            vaultID: id(first),
            role: role,
            ordinal: Int(first),
            createdAt: Date(timeIntervalSinceReferenceDate: 1234.5),
            wrappersDigest: Data(repeating: first, count: 32),
            keyWrapDigest: Data(count: 32),
            headRevision: UInt64(first) + 100,
            headDigest: Data(repeating: first &+ 1, count: 32)
        )
    }

    static func catalog(_ firsts: [UInt8]) -> RegistryCatalog {
        RegistryCatalog(ids: ids, revision: 9, vaults: firsts.map { entry($0) })
    }

    // MARK: Production calls with fixed defaults

    static func sealHead(_ head: VaultHead = head(), key: SymmetricKey = key) throws -> Data {
        try StoreSeal.sealHead(head, key: key, wrappersDigest: wrappersDigest, keyWrapDigest: keyWrapDigest)
    }

    static func sealHeadPlaintext(_ plaintext: Data) throws -> Data {
        try StoreSeal.sealHeadPlaintext(
            plaintext, key: key, ids: ids, vaultID: vaultID, revision: revision, wrappersDigest: wrappersDigest, keyWrapDigest: keyWrapDigest
        )
    }

    static func openHead(
        _ sealed: Data,
        key: SymmetricKey = key,
        ids: StoreIDs = ids,
        vaultID: UUID = vaultID,
        revision: UInt64 = revision,
        wrappersDigest: Data = wrappersDigest,
        keyWrapDigest: Data = keyWrapDigest
    ) throws -> VaultHead {
        try StoreSeal.openHead(
            sealed, key: key, ids: ids, vaultID: vaultID, revision: revision, wrappersDigest: wrappersDigest, keyWrapDigest: keyWrapDigest
        )
    }

    static func sealJournal(_ row: JournalRow = journalRow()) throws -> Data {
        try StoreSeal.sealJournal(row, key: key, ids: ids, vaultID: vaultID)
    }

    static func wrap(_ trash: SymmetricKey) throws -> Data {
        try StoreSeal.wrapTrashKey(trash, under: key, ids: ids, source: vaultID, trash: trashID, nonce: nonce)
    }

    // MARK: Independent AAD (spec §5, §7)

    static func independentRowAAD(_ aad: RowAAD) -> Data {
        var writer = StoreWriter()
        writer.text(rowLabel)
        writer.u64(schema)
        writer.uuid(aad.ids.storeID)
        writer.uuid(aad.ids.profileID)
        writer.uuid(aad.vaultID)
        writer.uuid(aad.recordID)
        writer.u8(aad.kind.rawValue)
        writer.uuid(aad.ownerID)
        writer.u8(aad.subject.rawValue)
        writer.u64(aad.version)
        return writer.data
    }

    static func independentHeadAAD() -> Data {
        var writer = StoreWriter()
        writer.u64(schema)
        writer.uuid(ids.storeID)
        writer.uuid(ids.profileID)
        writer.uuid(vaultID)
        writer.u64(revision)
        writer.bytes(wrappersDigest)
        writer.bytes(keyWrapDigest)
        return writer.data
    }

    /// Journal AAD intentionally has no profileID and no label (§7).
    static func independentJournalAAD(seq: UInt64) -> Data {
        var writer = StoreWriter()
        writer.u64(schema)
        writer.uuid(ids.storeID)
        writer.uuid(vaultID)
        writer.u64(seq)
        return writer.data
    }

    static func independentWrapAAD() -> Data {
        var writer = StoreWriter()
        writer.u64(schema)
        writer.uuid(ids.storeID)
        writer.uuid(ids.profileID)
        writer.uuid(vaultID)
        writer.uuid(trashID)
        writer.bytes(nonce)
        return writer.data
    }

    static func independentMACInput(catalog: Data) -> Data {
        var writer = StoreWriter()
        writer.text(registryLabel)
        writer.bytes(catalog)
        return writer.data
    }

    // MARK: Golden plaintext (spec §5 byte encoding, §7 field order)

    /// Head plaintext in the §7 order; `blockedOrigins` sits directly after the optional registry key. Enum tags come from
    /// `rawValue`, which `persistedSQLNamesAndTagsArePinned` freezes.
    static func goldenHead(_ head: VaultHead) -> Data {
        var writer = StoreWriter()
        writer.uuid(head.ids.storeID)
        writer.uuid(head.ids.profileID)
        writer.uuid(head.vaultID)
        writer.u8(head.role.rawValue)
        writer.u64(head.revision)
        writer.text(head.name)
        if let registryKey = head.registryKey {
            writer.u8(1)
            writer.bytes(registryKey)
        } else {
            writer.u8(0)
        }
        writer.u32(head.blockedOrigins.count)
        for origin in head.blockedOrigins {
            writer.text(origin)
        }
        writer.uuid(head.link.peerVaultID)
        writer.bytes(head.link.nonce)
        writer.u32(head.liveCatalog.count)
        for entry in head.liveCatalog {
            writer.uuid(entry.recordID)
            writer.u64(entry.version)
            writer.bytes(entry.digest)
        }
        writer.u64(head.journalSeq)
        writer.bytes(head.chainTip)
        writer.u64(UInt64(head.historyCounts.revision))
        writer.u64(UInt64(head.historyCounts.trashEntry))
        writer.u64(UInt64(head.historyCounts.tombstone))
        return writer.data
    }

    /// `{seq, prevChain, transfer?, ops}` exactly as spec §7 lists them.
    static func goldenJournal(_ row: JournalRow) -> Data {
        var writer = StoreWriter()
        writer.u64(row.seq)
        writer.bytes(row.prevChain)
        if let transfer = row.transfer {
            writer.u8(1)
            writer.uuid(transfer.transferID)
            writer.u8(transfer.direction.rawValue)
            writer.u8(transfer.scope.rawValue)
            writer.uuid(transfer.ownerID)
            if let subject = transfer.subject {
                writer.u8(1)
                writer.u8(subject.rawValue)
            } else {
                writer.u8(0)
            }
            writer.uuid(transfer.liveRecordID)
            writer.u64(transfer.liveVersion)
            writer.uuid(transfer.entryRecordID)
        } else {
            writer.u8(0)
        }
        writer.u32(row.ops.count)
        for op in row.ops {
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

    /// `{schema, storeID, profileID, registryRevision, vaults:[...]}` for a catalog whose entries are already ascending by id.
    /// Every fixture entry is created at 1234.5 s, whose Float64 bit pattern is written as a literal.
    static func goldenRegistry(_ catalog: RegistryCatalog) -> Data {
        var writer = StoreWriter()
        writer.u64(schema)
        writer.uuid(catalog.ids.storeID)
        writer.uuid(catalog.ids.profileID)
        writer.u64(catalog.revision)
        writer.u32(catalog.vaults.count)
        for entry in catalog.vaults {
            writer.uuid(entry.vaultID)
            writer.u8(entry.role.rawValue)
            writer.u64(UInt64(entry.ordinal))
            writer.u64(0x4093_4A00_0000_0000)
            writer.bytes(entry.wrappersDigest)
            writer.bytes(entry.keyWrapDigest)
            writer.u64(entry.headRevision)
            writer.bytes(entry.headDigest)
        }
        return writer.data
    }

    static func independentSeal(_ plaintext: Data, key: SymmetricKey = key, aad: Data) throws -> Data {
        try #require(try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined)
    }

    static func independentOpen(_ sealed: Data, key: SymmetricKey = key, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
    }

    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

struct VaultSealTests {
    nonisolated enum RowField: CaseIterable, Sendable {
        case storeID, profileID, vaultID, recordID, kind, ownerID, subject, version

        func changing(_ aad: RowAAD) -> RowAAD {
            var changed = aad
            switch self {
            case .storeID:
                changed.ids = StoreIDs(storeID: SealFixtures.id(0x71), profileID: aad.ids.profileID)
            case .profileID:
                changed.ids = StoreIDs(storeID: aad.ids.storeID, profileID: SealFixtures.id(0x72))
            case .vaultID:
                changed.vaultID = SealFixtures.id(0x73)
            case .recordID:
                changed.recordID = SealFixtures.id(0x74)
            case .kind:
                changed.kind = .tombstone
            case .ownerID:
                changed.ownerID = SealFixtures.id(0x75)
            case .subject:
                changed.subject = .totp
            case .version:
                changed.version = aad.version + 1
            }
            return changed
        }
    }

    nonisolated enum HeadField: CaseIterable, Sendable {
        case wrappersDigest, keyWrapDigest, revision, vaultID, storeID, profileID

        func open(_ sealed: Data) throws -> VaultHead {
            switch self {
            case .wrappersDigest:
                try SealFixtures.openHead(sealed, wrappersDigest: Data(repeating: 0x99, count: 32))
            case .keyWrapDigest:
                try SealFixtures.openHead(sealed, keyWrapDigest: Data(repeating: 0x98, count: 32))
            case .revision:
                try SealFixtures.openHead(sealed, revision: SealFixtures.revision + 1)
            case .vaultID:
                try SealFixtures.openHead(sealed, vaultID: SealFixtures.id(0x73))
            case .storeID:
                try SealFixtures.openHead(sealed, ids: StoreIDs(storeID: SealFixtures.id(0x71), profileID: SealFixtures.ids.profileID))
            case .profileID:
                try SealFixtures.openHead(sealed, ids: StoreIDs(storeID: SealFixtures.ids.storeID, profileID: SealFixtures.id(0x72)))
            }
        }
    }

    nonisolated enum PolicyCase: CaseIterable, Sendable {
        case unsortedPair, duplicate, overLimit, pathNotCanonical, uppercaseHost, httpScheme

        var origins: [String] {
            switch self {
            case .unsortedPair:
                ["https://b.example", "https://a.example"]
            case .duplicate:
                ["https://a.example", "https://a.example"]
            case .overLimit:
                (0...StoreFormat.blockedOriginLimit).map { String(format: "https://h%05d.example", $0) }
            case .pathNotCanonical:
                ["https://a.example/path"]
            case .uppercaseHost:
                ["https://A.example"]
            case .httpScheme:
                ["http://a.example"]
            }
        }
    }

    /// Everything that identifies the store, its profile, the vault and the key a value is sealed under.
    nonisolated enum Identity: CaseIterable, Sendable {
        case profile, store, vault, key

        var ids: StoreIDs {
            switch self {
            case .profile:
                StoreIDs(storeID: SealFixtures.ids.storeID, profileID: SealFixtures.id(0x72))
            case .store:
                StoreIDs(storeID: SealFixtures.id(0x71), profileID: SealFixtures.ids.profileID)
            case .vault, .key:
                SealFixtures.ids
            }
        }

        var vaultID: UUID {
            self == .vault ? SealFixtures.id(0x73) : SealFixtures.vaultID
        }

        var sealingKey: SymmetricKey {
            self == .key ? SealFixtures.otherKey : SealFixtures.key
        }
    }

    nonisolated enum WrapMismatch: CaseIterable, Sendable {
        case sourceKey, nonce, trashID, sourceID, storeID, profileID

        func unwrap(_ keyWrap: Data) throws -> SymmetricKey {
            let ids = SealFixtures.ids
            let key = SealFixtures.key
            let source = SealFixtures.vaultID
            let trash = SealFixtures.trashID
            let nonce = SealFixtures.nonce
            return switch self {
            case .sourceKey:
                try StoreSeal.unwrapTrashKey(keyWrap, under: SealFixtures.otherKey, ids: ids, source: source, trash: trash, nonce: nonce)
            case .nonce:
                try StoreSeal.unwrapTrashKey(keyWrap, under: key, ids: ids, source: source, trash: trash, nonce: Data(repeating: 0x34, count: 16))
            case .trashID:
                try StoreSeal.unwrapTrashKey(keyWrap, under: key, ids: ids, source: source, trash: SealFixtures.id(0x76), nonce: nonce)
            case .sourceID:
                try StoreSeal.unwrapTrashKey(keyWrap, under: key, ids: ids, source: SealFixtures.id(0x77), trash: trash, nonce: nonce)
            case .storeID:
                try StoreSeal.unwrapTrashKey(
                    keyWrap, under: key, ids: StoreIDs(storeID: SealFixtures.id(0x71), profileID: ids.profileID), source: source, trash: trash, nonce: nonce
                )
            case .profileID:
                try StoreSeal.unwrapTrashKey(
                    keyWrap, under: key, ids: StoreIDs(storeID: ids.storeID, profileID: SealFixtures.id(0x72)), source: source, trash: trash, nonce: nonce
                )
            }
        }
    }

    // MARK: Round trips

    @Test func headJournalRowAndRegistryRoundTrip() throws {
        let head = SealFixtures.head()
        let opened = try SealFixtures.openHead(SealFixtures.sealHead(head))
        #expect(opened == head)
        #expect(opened.blockedOrigins == ["https://a.example", "https://b.example"])

        for row in [SealFixtures.journalRow(), SealFixtures.journalRow(seq: 5, withTransfer: false)] {
            let sealed = try SealFixtures.sealJournal(row)
            let back = try StoreSeal.openJournal(sealed, key: SealFixtures.key, ids: SealFixtures.ids, vaultID: SealFixtures.vaultID, seq: row.seq)
            #expect(back == row)
        }

        let plaintext = Data("a sealed row body".utf8)
        let aad = SealFixtures.rowAAD()
        let sealedRow = try StoreSeal.sealRow(plaintext, key: SealFixtures.key, aad: aad)
        #expect(try StoreSeal.openRow(sealedRow, key: SealFixtures.key, aad: aad) == plaintext)

        let catalog = SealFixtures.catalog([0x10, 0x20])
        #expect(try RegistryCatalog.decode(catalog.encode()) == catalog)
    }

    @Test func headWithTheLimitOfBlockedOriginsRoundTrips() throws {
        let origins = (0..<StoreFormat.blockedOriginLimit).map { String(format: "https://h%05d.example", $0) }
        let head = SealFixtures.head(origins: origins)
        #expect(try SealFixtures.openHead(SealFixtures.sealHead(head)) == head)
    }

    /// The name limit is 64 characters, not bytes: 64 ZWJ family graphemes are 1,600 UTF-8 bytes, and no byte ceiling applies here.
    @Test func headWithA64CharacterMultiByteNameRoundTrips() throws {
        let name = String(repeating: "👨‍👩‍👧‍👦", count: StoreFormat.nameLimit)
        #expect(name.count == StoreFormat.nameLimit)
        #expect(name.utf8.count > 256)
        let head = SealFixtures.head(name: name)
        #expect(try SealFixtures.openHead(SealFixtures.sealHead(head)) == head)
    }

    // MARK: Wire vectors and role rules

    @Test func headPlaintextFollowsTheSpecFieldOrderWithOriginsRightAfterTheRegistryKey() {
        for head in [SealFixtures.head(), SealFixtures.head(role: .trash, registryKey: nil, origins: [])] {
            #expect(StoreSeal.encodeHead(head) == SealFixtures.goldenHead(head))
        }
    }

    @Test(arguments: [true, false]) func journalPlaintextFollowsTheSpecFieldOrder(_ withTransfer: Bool) {
        let row = SealFixtures.journalRow(withTransfer: withTransfer)
        #expect(row.encode() == SealFixtures.goldenJournal(row))

        // The other tag values: direction `in`, scope `account`, no transfer subject, op `add` only.
        let incoming = JournalRow(
            seq: 3,
            prevChain: Data(repeating: 0x45, count: 32),
            transfer: TransferHeader(
                transferID: SealFixtures.id(0x54),
                direction: .in,
                scope: .account,
                ownerID: SealFixtures.ownerID,
                subject: nil,
                liveRecordID: SealFixtures.id(0x55),
                liveVersion: 1,
                entryRecordID: SealFixtures.id(0x56)
            ),
            ops: [JournalOp(op: .add, recordID: SealFixtures.id(0x63), kind: .account, ownerID: SealFixtures.ownerID, subject: .account, version: 2, rowDigest: Data(repeating: 0x57, count: 32))]
        )
        #expect(incoming.encode() == SealFixtures.goldenJournal(incoming))
    }

    @Test func registryCatalogPlaintextFollowsTheSpecFieldOrder() {
        let catalog = RegistryCatalog(ids: SealFixtures.ids, revision: 9, vaults: [SealFixtures.entry(0x10), SealFixtures.entry(0x20, role: .trash)])
        #expect(catalog.encode() == SealFixtures.goldenRegistry(catalog))
    }

    @Test func validTrashHeadHoldsNoRegistryKeyAndNoBlockedOriginsAndRoundTrips() throws {
        let head = SealFixtures.head(role: .trash, registryKey: nil, origins: [])
        #expect(try SealFixtures.openHead(SealFixtures.sealHead(head)) == head)
    }

    nonisolated enum TrashViolation: CaseIterable, Sendable {
        case registryKey, blockedOrigins

        var head: VaultHead {
            switch self {
            case .registryKey:
                SealFixtures.head(role: .trash, registryKey: SealFixtures.registryKey, origins: [])
            case .blockedOrigins:
                SealFixtures.head(role: .trash, registryKey: nil, origins: SealFixtures.origins)
            }
        }
    }

    @Test(arguments: TrashViolation.allCases) func trashHeadWithARegistryKeyOrBlockedOriginsIsRefusedOnSealAndOpen(_ violation: TrashViolation) throws {
        let head = violation.head
        #expect(throws: CredentialStoreError.malformed) {
            try SealFixtures.sealHead(head)
        }
        let sealed = try SealFixtures.sealHeadPlaintext(StoreSeal.encodeHead(head))
        #expect(throws: CredentialStoreError.malformed) {
            try SealFixtures.openHead(sealed)
        }
    }

    /// §6.1: an active head always holds a 32-byte registry key; nil, empty or any other length is refused.
    @Test(arguments: [nil, Data(), Data(repeating: 0x22, count: 31), Data(repeating: 0x22, count: 33)] as [Data?])
    func activeHeadWithoutAThirtyTwoByteRegistryKeyIsRefusedOnSealAndOpen(_ registryKey: Data?) throws {
        let head = SealFixtures.head(registryKey: registryKey)
        #expect(throws: CredentialStoreError.malformed) {
            try SealFixtures.sealHead(head)
        }
        let sealed = try SealFixtures.sealHeadPlaintext(StoreSeal.encodeHead(head))
        #expect(throws: CredentialStoreError.malformed) {
            try SealFixtures.openHead(sealed)
        }
    }

    // MARK: AAD is exactly the documented fields

    @Test func rowIsAESGCMUnderTheDocumentedAADFields() throws {
        let plaintext = Data("a sealed row body".utf8)
        let aad = SealFixtures.rowAAD()
        let sealed = try StoreSeal.sealRow(plaintext, key: SealFixtures.key, aad: aad)
        #expect(sealed.count == plaintext.count + 28)
        #expect(try SealFixtures.independentOpen(sealed, aad: SealFixtures.independentRowAAD(aad)) == plaintext)
        let independent = try SealFixtures.independentSeal(plaintext, aad: SealFixtures.independentRowAAD(aad))
        #expect(try StoreSeal.openRow(independent, key: SealFixtures.key, aad: aad) == plaintext)
        #expect(try StoreSeal.sealRow(plaintext, key: SealFixtures.key, aad: aad) != sealed)
    }

    @Test func headIsAESGCMUnderTheDocumentedAADFields() throws {
        let head = SealFixtures.head()
        let sealed = try SealFixtures.sealHead(head)
        let plaintext = try SealFixtures.independentOpen(sealed, aad: SealFixtures.independentHeadAAD())
        #expect(plaintext == StoreSeal.encodeHead(head))
        let viaPlaintext = try SealFixtures.sealHeadPlaintext(plaintext)
        #expect(try SealFixtures.independentOpen(viaPlaintext, aad: SealFixtures.independentHeadAAD()) == plaintext)
        let independent = try SealFixtures.independentSeal(plaintext, aad: SealFixtures.independentHeadAAD())
        #expect(try SealFixtures.openHead(independent) == head)
    }

    @Test func journalIsAESGCMUnderSchemaStoreVaultAndSeqOnly() throws {
        let row = SealFixtures.journalRow()
        let sealed = try SealFixtures.sealJournal(row)
        let aad = SealFixtures.independentJournalAAD(seq: row.seq)
        let plaintext = try SealFixtures.independentOpen(sealed, aad: aad)
        let independent = try SealFixtures.independentSeal(plaintext, aad: aad)
        let back = try StoreSeal.openJournal(independent, key: SealFixtures.key, ids: SealFixtures.ids, vaultID: SealFixtures.vaultID, seq: row.seq)
        #expect(back == row)
    }

    @Test func trashKeyWrapIsAESGCMUnderTheDocumentedAADFields() throws {
        let trash = SymmetricKey(data: Data(repeating: 0x44, count: 32))
        let wrapped = try SealFixtures.wrap(trash)
        #expect(wrapped.count == 32 + 28)
        #expect(try SealFixtures.independentOpen(wrapped, aad: SealFixtures.independentWrapAAD()) == SealFixtures.bytes(of: trash))
        let independent = try SealFixtures.independentSeal(SealFixtures.bytes(of: trash), aad: SealFixtures.independentWrapAAD())
        let unwrapped = try StoreSeal.unwrapTrashKey(
            independent, under: SealFixtures.key, ids: SealFixtures.ids, source: SealFixtures.vaultID, trash: SealFixtures.trashID, nonce: SealFixtures.nonce
        )
        #expect(SealFixtures.bytes(of: unwrapped) == SealFixtures.bytes(of: trash))
    }

    @Test func registryMACIsHMACSHA256OfTheLengthPrefixedLabelAndCatalog() {
        let catalog = SealFixtures.catalog([0x10, 0x20]).encode()
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: SealFixtures.independentMACInput(catalog: catalog), using: SymmetricKey(data: SealFixtures.registryKey)
        ))
        #expect(StoreSeal.registryMAC(rk: SealFixtures.registryKey, catalog: catalog) == expected)
    }

    // MARK: Each bound field matters

    @Test(arguments: RowField.allCases) func rowAADBindsEachListedField(_ field: RowField) throws {
        let aad = SealFixtures.rowAAD()
        let sealed = try StoreSeal.sealRow(Data("body".utf8), key: SealFixtures.key, aad: aad)
        #expect(try StoreSeal.openRow(sealed, key: SealFixtures.key, aad: aad) == Data("body".utf8))
        #expect(throws: (any Error).self) {
            try StoreSeal.openRow(sealed, key: SealFixtures.key, aad: field.changing(aad))
        }
    }

    @Test(arguments: HeadField.allCases) func headAADBindsWrappersKeyWrapRevisionAndIdentity(_ field: HeadField) throws {
        let sealed = try SealFixtures.sealHead()
        #expect(try SealFixtures.openHead(sealed) == SealFixtures.head())
        #expect(throws: (any Error).self) {
            try field.open(sealed)
        }
    }

    @Test(arguments: Identity.allCases) func wrongProfileStoreOrVaultFailsOpen(_ identity: Identity) throws {
        let aad = SealFixtures.rowAAD()
        let sealedRow = try StoreSeal.sealRow(Data("body".utf8), key: SealFixtures.key, aad: aad)
        var wrongRow = aad
        wrongRow.ids = identity.ids
        wrongRow.vaultID = identity.vaultID
        #expect(throws: (any Error).self) {
            try StoreSeal.openRow(sealedRow, key: identity.sealingKey, aad: wrongRow)
        }

        let sealedHead = try SealFixtures.sealHead()
        #expect(throws: (any Error).self) {
            try SealFixtures.openHead(sealedHead, key: identity.sealingKey, ids: identity.ids, vaultID: identity.vaultID)
        }

        let wrapped = try SealFixtures.wrap(SymmetricKey(data: Data(repeating: 0x44, count: 32)))
        #expect(throws: (any Error).self) {
            try StoreSeal.unwrapTrashKey(
                wrapped, under: identity.sealingKey, ids: identity.ids, source: identity.vaultID, trash: SealFixtures.trashID, nonce: SealFixtures.nonce
            )
        }

        // §7: the journal AAD is schema, storeID, vaultID, seq; the profile is deliberately not part of it.
        guard identity != .profile else { return }
        let sealedJournal = try SealFixtures.sealJournal()
        #expect(throws: (any Error).self) {
            try StoreSeal.openJournal(sealedJournal, key: identity.sealingKey, ids: identity.ids, vaultID: identity.vaultID, seq: 2)
        }
    }

    @Test func journalOpensOnlyAtItsOwnSeq() throws {
        let sealed = try SealFixtures.sealJournal(SealFixtures.journalRow(seq: 2))
        for wrong in [UInt64(1), 3] {
            #expect(throws: (any Error).self) {
                try StoreSeal.openJournal(sealed, key: SealFixtures.key, ids: SealFixtures.ids, vaultID: SealFixtures.vaultID, seq: wrong)
            }
        }
    }

    // MARK: Head policy

    @Test(arguments: PolicyCase.allCases) func headWithUnsortedDuplicateOversizeOrNonCanonicalOriginsIsMalformed(_ policyCase: PolicyCase) throws {
        let head = SealFixtures.head(origins: policyCase.origins)
        let sealed = try SealFixtures.sealHeadPlaintext(StoreSeal.encodeHead(head))
        #expect(throws: CredentialStoreError.malformed) {
            try SealFixtures.openHead(sealed)
        }
        #expect(throws: CredentialStoreError.malformed) {
            try SealFixtures.sealHead(head)
        }
    }

    @Test func editedPolicyByteFailsTheHeadOpen() throws {
        let head = SealFixtures.head()
        let plaintext = StoreSeal.encodeHead(head)
        let region = try #require(plaintext.range(of: Data("https://a.example".utf8)))
        var sealed = try SealFixtures.sealHead(head)
        // combined = 12-byte nonce, then the ciphertext in plaintext order.
        sealed[sealed.startIndex + 12 + (region.lowerBound - plaintext.startIndex)] ^= 0x01
        #expect(throws: (any Error).self) {
            try SealFixtures.openHead(sealed)
        }
    }

    // MARK: Registry

    @Test func registryMACRejectsAnyCatalogByteChange() {
        let rk = SealFixtures.registryKey
        let catalog = SealFixtures.catalog([0x10, 0x20]).encode()
        let mac = StoreSeal.registryMAC(rk: rk, catalog: catalog)
        #expect(mac.count == 32)
        #expect(StoreSeal.verifyRegistryMAC(rk: rk, catalog: catalog, mac: mac))
        for index in catalog.indices {
            var changed = catalog
            changed[index] ^= 0x01
            #expect(!StoreSeal.verifyRegistryMAC(rk: rk, catalog: changed, mac: mac), "byte \(index)")
        }
        #expect(!StoreSeal.verifyRegistryMAC(rk: rk, catalog: catalog.dropLast(), mac: mac))
        #expect(!StoreSeal.verifyRegistryMAC(rk: Data(repeating: 0x23, count: 32), catalog: catalog, mac: mac))
        var flipped = mac
        flipped[flipped.startIndex] ^= 0x01
        #expect(!StoreSeal.verifyRegistryMAC(rk: rk, catalog: catalog, mac: flipped))
        #expect(!StoreSeal.verifyRegistryMAC(rk: rk, catalog: catalog, mac: mac.dropLast()))
        #expect(!StoreSeal.verifyRegistryMAC(rk: rk, catalog: catalog, mac: Data()))
    }

    @Test func registryCatalogEncodingIsSortedByVaultID() throws {
        // 0x80 and 0xF0 lead bytes catch a signed or text-order comparison.
        let shuffled = SealFixtures.catalog([0xF0, 0x10, 0x80])
        let sorted = SealFixtures.catalog([0x10, 0x80, 0xF0])
        #expect(shuffled.encode() == sorted.encode())
        #expect(try RegistryCatalog.decode(shuffled.encode()) == sorted)
        #expect(try RegistryCatalog.decode(sorted.encode()).vaults.map(\.vaultID) == [SealFixtures.id(0x10), SealFixtures.id(0x80), SealFixtures.id(0xF0)])
    }

    @Test func truncatedRegistryCatalogIsMalformed() {
        let encoded = SealFixtures.catalog([0x10, 0x20]).encode()
        for length in [0, 1, encoded.count / 2, encoded.count - 1] {
            #expect(throws: CredentialStoreError.malformed) {
                try RegistryCatalog.decode(encoded.prefix(length))
            }
        }
    }

    @Test func registryKeyCannotOpenAnythingElse() throws {
        let head = try SealFixtures.openHead(SealFixtures.sealHead())
        let rk = try #require(head.registryKey)
        let asKey = SymmetricKey(data: rk)

        let sealedRow = try StoreSeal.sealRow(Data("body".utf8), key: SealFixtures.key, aad: SealFixtures.rowAAD())
        #expect(throws: (any Error).self) {
            try StoreSeal.openRow(sealedRow, key: asKey, aad: SealFixtures.rowAAD())
        }
        #expect(throws: (any Error).self) {
            try SealFixtures.openHead(SealFixtures.sealHead(), key: asKey)
        }
        let wrapped = try SealFixtures.wrap(SymmetricKey(data: Data(repeating: 0x44, count: 32)))
        #expect(throws: (any Error).self) {
            try StoreSeal.unwrapTrashKey(
                wrapped, under: asKey, ids: SealFixtures.ids, source: SealFixtures.vaultID, trash: SealFixtures.trashID, nonce: SealFixtures.nonce
            )
        }

        let catalog = SealFixtures.catalog([0x10]).encode()
        let macWithDEK = StoreSeal.registryMAC(rk: SealFixtures.keyBytes, catalog: catalog)
        #expect(!StoreSeal.verifyRegistryMAC(rk: rk, catalog: catalog, mac: macWithDEK))
        #expect(StoreSeal.verifyRegistryMAC(rk: rk, catalog: catalog, mac: StoreSeal.registryMAC(rk: rk, catalog: catalog)))
    }

    // MARK: Digests and chain

    @Test func digestsAreSHA256AndAnAbsentValueIsThirtyTwoZeroBytes() {
        let stored = Data("stored sealed bytes".utf8)
        #expect(StoreSeal.digest(stored) == SealFixtures.sha256(stored))
        #expect(StoreSeal.digestOrZero(stored) == SealFixtures.sha256(stored))
        #expect(StoreSeal.digestOrZero(nil) == Data(count: 32))
    }

    @Test func journalChainIsRecomputedFromStoredBytes() throws {
        let zero = Data(count: 32)
        var sealed: [Data] = []
        var running = zero
        for seq in 1...3 {
            let row = SealFixtures.journalRow(seq: UInt64(seq), prevChain: running, withTransfer: seq != 2)
            let bytes = try SealFixtures.sealJournal(row)
            sealed.append(bytes)
            running = StoreSeal.chain(running, sealed: bytes)
        }

        var manual = zero
        for bytes in sealed {
            manual = SealFixtures.sha256(manual + SealFixtures.sha256(bytes))
        }
        #expect(running == manual)
        #expect(StoreSeal.chain(zero, sealed: sealed[0]) == SealFixtures.sha256(zero + SealFixtures.sha256(sealed[0])))

        var reordered = zero
        for bytes in [sealed[1], sealed[0], sealed[2]] {
            reordered = StoreSeal.chain(reordered, sealed: bytes)
        }
        #expect(reordered != running)

        var edited = sealed[0]
        edited[edited.startIndex] ^= 0x01
        #expect(StoreSeal.chain(zero, sealed: edited) != StoreSeal.chain(zero, sealed: sealed[0]))
    }

    // MARK: Trash key wrap

    @Test func trashKeyWrapOpensOnlyUnderTheSourceKeyAndLink() throws {
        let trash = SymmetricKey(data: Data(repeating: 0x44, count: 32))
        let wrapped = try SealFixtures.wrap(trash)
        let unwrapped = try StoreSeal.unwrapTrashKey(
            wrapped, under: SealFixtures.key, ids: SealFixtures.ids, source: SealFixtures.vaultID, trash: SealFixtures.trashID, nonce: SealFixtures.nonce
        )
        #expect(SealFixtures.bytes(of: unwrapped) == SealFixtures.bytes(of: trash))
        for mismatch in WrapMismatch.allCases {
            #expect(throws: (any Error).self, "\(mismatch)") {
                try mismatch.unwrap(wrapped)
            }
        }
    }
}
