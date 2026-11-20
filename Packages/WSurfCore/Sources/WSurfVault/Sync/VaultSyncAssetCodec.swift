// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation

/// Only the hash of ciphertext and its exact length are used to locate an immutable asset.
public nonisolated struct VaultAssetRef: Codable, Hashable, Sendable {
    public static let maxBytes = 8 * 1_024 * 1_024
    public let digest: Data
    public let size: Int

    public init(_ ciphertext: Data) throws {
        guard !ciphertext.isEmpty, ciphertext.count <= Self.maxBytes else { throw VaultSyncError.tooLarge }
        digest = Data(SHA256.hash(data: ciphertext))
        size = ciphertext.count
    }

    public var valid: Bool {
        digest.count == 32 && (1...Self.maxBytes).contains(size)
    }

    public var name: String {
        "asset-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    public func matches(_ bytes: Data) -> Bool {
        valid && bytes.count == size && Data(SHA256.hash(data: bytes)) == digest
    }
}

public nonisolated struct VaultAssetAccount: Codable, Sendable {
    public var account: CredentialAccount
    /// Encrypted blob chunks in the order used by the store. Each descriptor has a vault-wide wrapped file key.
    public var chunks: [UUID: [VaultAssetRef]]

    public init(account: CredentialAccount, chunks: [UUID: [VaultAssetRef]]) throws {
        self.account = account
        self.chunks = chunks
        try validate()
    }

    func validate() throws {
        try VaultSyncCodec.checked(account)
        let files = account.attachments ?? []
        guard Set(files.map(\.id)) == Set(chunks.keys) else { throw VaultSyncError.malformed }
        for file in files {
            let parts = chunks[file.id] ?? []
            guard parts.count == Int((file.encryptedSize + Int64(VaultAssetRef.maxBytes - 1)) / Int64(VaultAssetRef.maxBytes)),
                  parts.allSatisfy(\.valid), parts.dropLast().allSatisfy({ $0.size == VaultAssetRef.maxBytes }),
                  parts.reduce(Int64(0), { $0 + Int64($1.size) }) == file.encryptedSize else { throw VaultSyncError.malformed }
        }
    }
}

nonisolated extension VaultSyncCodec {
    public static let assetFormat: UInt8 = 2

    /// A small version-2 Item references one independently sealed logical entry. Earlier clients park it by its format byte.
    public static func sealAssetAccount(
        _ account: VaultAssetAccount, version: UInt64, key: VaultSyncKey
    ) throws -> (envelope: Data, body: Data, reference: VaultAssetRef) {
        try requireGeneration(key)
        guard version > 0 else { throw VaultSyncError.malformed }
        try account.validate()
        let aad = itemAAD(key: key, accountID: account.account.id, format: assetFormat, state: liveState, version: version)
        let body = try seal(CredentialContent.canonicalJSON(account), key: key, aad: aad + Data([1]))
        let reference = try VaultAssetRef(body)
        var header = StoreWriter()
        header.u8(assetFormat)
        header.u8(liveState)
        header.u64(version)
        let pointer = try seal(CredentialContent.canonicalJSON(reference), key: key, aad: aad + Data([0]))
        return (header.data + pointer, body, reference)
    }

    public static func assetReference(_ envelope: Data, accountID: UUID, key: VaultSyncKey) throws -> (UInt64, VaultAssetRef) {
        try requireGeneration(key)
        let version = try assetVersion(envelope)
        let aad = itemAAD(key: key, accountID: accountID, format: assetFormat, state: liveState, version: version)
        let pointer = try open(Data(envelope.dropFirst(headerBytes)), key: key, aad: aad + Data([0]))
        let reference = try JSONDecoder().decode(VaultAssetRef.self, from: pointer)
        guard reference.valid else { throw VaultSyncError.malformed }
        return (version, reference)
    }

    public static func openAssetAccount(_ body: Data, accountID: UUID, version: UInt64, key: VaultSyncKey) throws -> VaultAssetAccount {
        try requireGeneration(key)
        guard body.count <= VaultAssetRef.maxBytes else { throw VaultSyncError.tooLarge }
        let aad = itemAAD(key: key, accountID: accountID, format: assetFormat, state: liveState, version: version)
        let decoded = try open(body, key: key, aad: aad + Data([1]))
        let account = try JSONDecoder().decode(VaultAssetAccount.self, from: decoded)
        guard account.account.id == accountID else { throw VaultSyncError.malformed }
        try account.validate()
        return account
    }

    static func assetVersion(_ envelope: Data) throws -> UInt64 {
        guard (headerBytes + sealOverhead...512).contains(envelope.count), envelope.first == assetFormat, envelope[1] == liveState else {
            throw VaultSyncError.malformed
        }
        let version = envelope.dropFirst(2).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard version > 0 else { throw VaultSyncError.malformed }
        return version
    }
}
