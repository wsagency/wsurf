// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// AES-256-GCM sealing (combined: 12-byte nonce, ciphertext, tag), SHA-256 digests and the registry MAC.
///
/// Every AAD and MAC input is built with `StoreWriter` from exactly the fields spec §5/§7 list, so a sealed value opens only
/// under the identity it was sealed for. Crypto failures propagate as the CryptoKit error; the caller maps them.
nonisolated enum StoreSeal {
    private static let zeroDigest = Data(count: 32)

    // MARK: Digests and chain

    static func digest(_ stored: Data) -> Data {
        Data(SHA256.hash(data: stored))
    }

    /// An absent stored value (no wrappers, no key wrap) digests as 32 zero bytes.
    static func digestOrZero(_ stored: Data?) -> Data {
        stored.map(digest) ?? zeroDigest
    }

    /// `SHA-256(prev ‖ SHA-256(sealed))`; the chain starts from 32 zero bytes.
    static func chain(_ prev: Data, sealed: Data) -> Data {
        digest(prev + digest(sealed))
    }

    // MARK: Rows

    static func sealRow(_ plaintext: Data, key: SymmetricKey, aad: RowAAD) throws -> Data {
        try seal(plaintext, key: key, aad: rowAAD(aad))
    }

    static func openRow(_ sealed: Data, key: SymmetricKey, aad: RowAAD) throws -> Data {
        try open(sealed, key: key, aad: rowAAD(aad))
    }

    // MARK: Heads

    static func encodeHead(_ head: VaultHead) -> Data {
        head.encode()
    }

    /// Validates the §7 policy, then seals; a head that fails the policy is never written.
    static func sealHead(_ head: VaultHead, key: SymmetricKey, wrappersDigest: Data, keyWrapDigest: Data) throws -> Data {
        try validate(head)
        return try sealHeadPlaintext(
            head.encode(),
            key: key,
            ids: head.ids,
            vaultID: head.vaultID,
            revision: head.revision,
            wrappersDigest: wrappersDigest,
            keyWrapDigest: keyWrapDigest
        )
    }

    /// Seals already-encoded plaintext with no policy check, so tests can produce a validly sealed but policy-violating head.
    static func sealHeadPlaintext(
        _ plaintext: Data,
        key: SymmetricKey,
        ids: StoreIDs,
        vaultID: UUID,
        revision: UInt64,
        wrappersDigest: Data,
        keyWrapDigest: Data
    ) throws -> Data {
        let aad = headAAD(ids: ids, vaultID: vaultID, revision: revision, wrappersDigest: wrappersDigest, keyWrapDigest: keyWrapDigest)
        return try seal(plaintext, key: key, aad: aad)
    }

    /// Authenticates against the stored wrappers, key wrap and head revision, then decodes and enforces the §7 policy.
    static func openHead(
        _ sealed: Data,
        key: SymmetricKey,
        ids: StoreIDs,
        vaultID: UUID,
        revision: UInt64,
        wrappersDigest: Data,
        keyWrapDigest: Data
    ) throws -> VaultHead {
        let aad = headAAD(ids: ids, vaultID: vaultID, revision: revision, wrappersDigest: wrappersDigest, keyWrapDigest: keyWrapDigest)
        let head = try VaultHead.decode(open(sealed, key: key, aad: aad))
        try validate(head)
        return head
    }

    // MARK: Journal

    static func sealJournal(_ row: JournalRow, key: SymmetricKey, ids: StoreIDs, vaultID: UUID) throws -> Data {
        try seal(row.encode(), key: key, aad: journalAAD(ids: ids, vaultID: vaultID, seq: row.seq))
    }

    static func openJournal(_ sealed: Data, key: SymmetricKey, ids: StoreIDs, vaultID: UUID, seq: UInt64) throws -> JournalRow {
        try JournalRow.decode(open(sealed, key: key, aad: journalAAD(ids: ids, vaultID: vaultID, seq: seq)))
    }

    // MARK: Registry

    /// `HMAC-SHA256(rk, text(registryLabel) ‖ bytes(catalog))`, length-prefixed by `StoreWriter`.
    static func registryMAC(rk: Data, catalog: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: registryMessage(catalog), using: SymmetricKey(data: rk)))
    }

    /// Constant-time; any other length or content is simply `false`.
    static func verifyRegistryMAC(rk: Data, catalog: Data, mac: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: registryMessage(catalog), using: SymmetricKey(data: rk))
    }

    // MARK: Trash key wrap

    static func wrapTrashKey(
        _ trash: SymmetricKey,
        under source: SymmetricKey,
        ids: StoreIDs,
        source sourceID: UUID,
        trash trashID: UUID,
        nonce: Data
    ) throws -> Data {
        let keyBytes = trash.withUnsafeBytes { Data($0) }
        return try seal(keyBytes, key: source, aad: wrapAAD(ids: ids, source: sourceID, trash: trashID, nonce: nonce))
    }

    static func unwrapTrashKey(
        _ keyWrap: Data,
        under source: SymmetricKey,
        ids: StoreIDs,
        source sourceID: UUID,
        trash trashID: UUID,
        nonce: Data
    ) throws -> SymmetricKey {
        let keyBytes = try open(keyWrap, key: source, aad: wrapAAD(ids: ids, source: sourceID, trash: trashID, nonce: nonce))
        return SymmetricKey(data: keyBytes)
    }

    // MARK: AAD (spec §5, §7)

    private static func rowAAD(_ aad: RowAAD) -> Data {
        var writer = StoreWriter()
        writer.text(StoreFormat.rowLabel)
        writer.u64(UInt64(StoreFormat.schema))
        aad.ids.write(to: &writer)
        writer.uuid(aad.vaultID)
        writer.uuid(aad.recordID)
        writer.u8(aad.kind.rawValue)
        writer.uuid(aad.ownerID)
        writer.u8(aad.subject.rawValue)
        writer.u64(aad.version)
        return writer.data
    }

    private static func headAAD(ids: StoreIDs, vaultID: UUID, revision: UInt64, wrappersDigest: Data, keyWrapDigest: Data) -> Data {
        var writer = StoreWriter()
        writer.u64(UInt64(StoreFormat.schema))
        ids.write(to: &writer)
        writer.uuid(vaultID)
        writer.u64(revision)
        writer.bytes(wrappersDigest)
        writer.bytes(keyWrapDigest)
        return writer.data
    }

    /// Schema, store, vault and seq only: no profile and no label.
    private static func journalAAD(ids: StoreIDs, vaultID: UUID, seq: UInt64) -> Data {
        var writer = StoreWriter()
        writer.u64(UInt64(StoreFormat.schema))
        writer.uuid(ids.storeID)
        writer.uuid(vaultID)
        writer.u64(seq)
        return writer.data
    }

    private static func wrapAAD(ids: StoreIDs, source: UUID, trash: UUID, nonce: Data) -> Data {
        var writer = StoreWriter()
        writer.u64(UInt64(StoreFormat.schema))
        ids.write(to: &writer)
        writer.uuid(source)
        writer.uuid(trash)
        writer.bytes(nonce)
        return writer.data
    }

    private static func registryMessage(_ catalog: Data) -> Data {
        var writer = StoreWriter()
        writer.text(StoreFormat.registryLabel)
        writer.bytes(catalog)
        return writer.data
    }

    /// §6.1/§7: the origin policy (`validatePolicy`); an active head holds exactly a 32-byte registry key, a trash head holds
    /// neither the key nor any blocked origin.
    private static func validate(_ head: VaultHead) throws {
        try head.validatePolicy()
        switch head.role {
        case .active:
            guard head.registryKey?.count == 32 else { throw CredentialStoreError.malformed }
        case .trash:
            guard head.registryKey == nil, head.blockedOrigins.isEmpty else { throw CredentialStoreError.malformed }
        }
    }

    // MARK: AES-GCM

    private static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else { throw CredentialStoreError.malformed }
        return combined
    }

    private static func open(_ sealed: Data, key: SymmetricKey, aad: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
    }
}
