// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// The key every synced value of one vault is sealed under: HKDF-SHA256 of the vault's key, bound to the profile, the vault and the key
/// generation. It is never the vault's key, and never the store id, which differs per Mac. Only `ProfileVaultStore.syncKey` makes one,
/// only for an unlocked vault, and nothing persists it. The raw key is internal: callers outside this module seal and open through
/// `VaultSyncCodec` and can do nothing else with it.
public nonisolated struct VaultSyncKey: Sendable {
    public let profileID: UUID
    public let vaultID: UUID
    public let generation: UInt64
    let key: SymmetricKey

    /// The label is the HKDF info's own, distinct from the vault's other subkeys (Input History, files).
    static func derive(dek: SymmetricKey, profileID: UUID, vaultID: UUID, generation: UInt64 = VaultSyncCodec.generation) -> VaultSyncKey {
        var info = StoreWriter()
        info.text(VaultSyncCodec.label)
        info.uuid(profileID)
        info.uuid(vaultID)
        info.u64(generation)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: dek, salt: Data(), info: info.data, outputByteCount: 32)
        return VaultSyncKey(profileID: profileID, vaultID: vaultID, generation: generation, key: key)
    }
}

/// A key never prints, in a log line or in a failed assertion.
nonisolated extension VaultSyncKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "VaultSyncKey"
    }

    public var debugDescription: String {
        "VaultSyncKey"
    }
}

/// Why a synced value was not sealed or opened. None of them names a value.
public nonisolated enum VaultSyncError: Error, Equatable, Sendable {
    /// The bytes are not a value of this format, or the entry in them breaks a rule of the vault.
    case malformed
    /// The entry does not fit one record (`VaultSyncCodec.maxItemBytes`).
    case tooLarge
    /// A format this build does not know: a newer WSurf wrote it.
    case unsupportedFormat
    /// A key generation this build does not know.
    case unsupportedGeneration
    /// The bytes do not open under this key and identity: another key, another entry, another version, or altered bytes.
    case authenticationFailed
}

/// One account of a vault as the sync carries it: live (the account without files) or removed (its id and version, and what it left
/// for an import to match: the keyed digests of its logins and its exchange ids).
public nonisolated struct SyncItem: Equatable, Sendable {
    public let accountID: UUID
    public let version: UInt64
    /// `nil`: the removed state.
    public let account: CredentialAccount?
    /// A removed state only: what the entry left (`RemovedMemory`), so a Mac that never held it still keeps an import from bringing it
    /// back. Keyed digests of its logins and its exchange ids, never a value; `nil` when it had nothing an import could match.
    public let memory: RemovedMemory?

    public init(accountID: UUID, version: UInt64, account: CredentialAccount?, memory: RemovedMemory? = nil) {
        self.accountID = accountID
        self.version = version
        self.account = account
        self.memory = account == nil && memory?.isEmpty == false ? memory : nil
    }

    /// The parts an incoming or stored item stands for; a removed one has `SyncParts.removedParts`.
    public func parts() throws -> SyncParts {
        try account.map(SyncParts.of) ?? .removedParts
    }
}

/// A local account as an `Item` can carry it: without its files, and with the parts its sync base is compared by.
public nonisolated struct SyncableAccount: Equatable, Sendable {
    public let account: CredentialAccount
    public let parts: SyncParts
}

/// Sealing and opening of everything the sync writes (spec amendment 2026-10-22): the `Item` envelope, the vault name beside its
/// wrapper list, the sync base kept at rest, and the marker of what was last uploaded. Every value is AES-256-GCM (combined: 12-byte
/// nonce, ciphertext, 16-byte tag) under a `VaultSyncKey`, and its AAD, built with `StoreWriter`, binds the record kind, the profile,
/// the vault, the account, the format, the state, the version and the key generation, so a value opens only as itself and a lower
/// version is rejected.
public nonisolated enum VaultSyncCodec {
    /// The one key generation. The vault's key never rotates (`removeUnlock` keeps it); a record with another generation is left alone.
    public static let generation: UInt64 = 1
    /// The most bytes one `Item` envelope may take.
    public static let maxItemBytes = 786_432

    static let label = "WSurf vault sync v1"
    static let markLabel = "WSurf vault sync mark v1"
    static let itemFormat: UInt8 = 1
    static let liveState: UInt8 = 1
    static let removedState: UInt8 = 2
    /// Format, state and version.
    static let headerBytes = 10
    /// Nonce and tag around an empty plaintext: a removed envelope is `headerBytes + sealOverhead` = 38 bytes.
    static let sealOverhead = 28
    private static let nameBytes = 1_024

    // MARK: Accounts

    /// `account` as an `Item` can carry it, or `nil` when it cannot be one: it holds only files, its metadata or a passkey does not
    /// hash, it breaks a rule of the vault without its files, or it does not fit `maxItemBytes`. Such an entry stays on the Mac and is
    /// never reported as removed.
    public static func syncable(_ account: CredentialAccount) -> SyncableAccount? {
        var stripped = account
        stripped.attachments = nil
        guard (try? checked(stripped)) != nil, let parts = try? SyncParts.of(stripped),
              let encoded = try? CredentialContent.canonicalJSON(stripped), encoded.count + headerBytes + sealOverhead <= maxItemBytes
        else { return nil }
        return SyncableAccount(account: stripped, parts: parts)
    }

    /// The envelope `u8 format ‖ u8 state ‖ u64 version ‖ sealed`. A live item must have no files; a removed one seals its memory, or an
    /// empty plaintext without one, so it carries nothing but its ids, its version, the exchange ids and keyed digests of logins.
    public static func sealItem(_ item: SyncItem, key: VaultSyncKey) throws -> Data {
        try requireGeneration(key)
        guard item.version > 0 else { throw VaultSyncError.malformed }
        let plaintext: Data
        let state: UInt8
        if let account = item.account {
            guard account.id == item.accountID, account.attachments == nil else { throw VaultSyncError.malformed }
            try checked(account)
            plaintext = try encode(account)
            state = liveState
        } else {
            if let memory = item.memory, (try? memory.validate()) == nil {
                throw VaultSyncError.malformed
            }
            plaintext = try item.memory.map { try CredentialContent.canonicalJSON($0) } ?? Data()
            state = removedState
        }
        guard plaintext.count + headerBytes + sealOverhead <= maxItemBytes else { throw VaultSyncError.tooLarge }
        var envelope = StoreWriter()
        envelope.u8(itemFormat)
        envelope.u8(state)
        envelope.u64(item.version)
        let aad = itemAAD(key: key, accountID: item.accountID, format: itemFormat, state: state, version: item.version)
        let sealed = try seal(plaintext, key: key, aad: aad)
        return envelope.data + sealed
    }

    /// Opens `envelope`, the value of the record named `accountID`. Refuses an envelope over `maxItemBytes`, an unknown format or
    /// state, a removed state whose plaintext is not a memory, an account whose id is not the record's, one with files, one that breaks a rule of the
    /// vault, and one over the store's size bounds.
    public static func openItem(_ envelope: Data, accountID: UUID, key: VaultSyncKey) throws -> SyncItem {
        try requireGeneration(key)
        let (state, version, sealed) = try header(of: envelope)
        let aad = itemAAD(key: key, accountID: accountID, format: itemFormat, state: state, version: version)
        let plaintext = try open(sealed, key: key, aad: aad)
        guard state == liveState else {
            guard !plaintext.isEmpty else { return SyncItem(accountID: accountID, version: version, account: nil) }
            guard let memory = try? JSONDecoder().decode(RemovedMemory.self, from: plaintext), (try? memory.validate()) != nil else {
                throw VaultSyncError.malformed
            }
            return SyncItem(accountID: accountID, version: version, account: nil, memory: memory)
        }
        guard let account = try? JSONDecoder().decode(CredentialAccount.self, from: plaintext),
              account.id == accountID, account.attachments == nil
        else { throw VaultSyncError.malformed }
        try checked(account)
        return SyncItem(accountID: accountID, version: version, account: account)
    }

    /// The version in `envelope`, read without a key so a locked Mac can drop a replay. It is not authenticated here; `openItem`
    /// authenticates it through the AAD, so no one can raise it.
    public static func version(of envelope: Data) throws -> UInt64 {
        try header(of: envelope).version
    }

    // MARK: Vault

    /// The vault's name, authenticated together with the exact bytes of its wrapper list.
    public static func sealVault(name: String, wrappers: Data, key: VaultSyncKey) throws -> Data {
        try requireGeneration(key)
        guard isValid(name: name) else { throw VaultSyncError.malformed }
        return try seal(CredentialContent.canonicalJSON(NamePayload(name: name)), key: key, aad: vaultAAD(key: key, wrappers: wrappers))
    }

    public static func openVault(_ sealed: Data, wrappers: Data, key: VaultSyncKey) throws -> String {
        try requireGeneration(key)
        guard sealed.count >= sealOverhead, sealed.count <= nameBytes else { throw VaultSyncError.malformed }
        let plaintext = try open(sealed, key: key, aad: vaultAAD(key: key, wrappers: wrappers))
        guard let payload = try? JSONDecoder().decode(NamePayload.self, from: plaintext), isValid(name: payload.name) else {
            throw VaultSyncError.malformed
        }
        return payload.name
    }

    /// `HMAC-SHA256(markKey, text(name) ‖ bytes(wrappers))`: what was last uploaded, kept on this Mac to see that the name or the
    /// wrapper list changed. It reveals neither. `markKey` is its own HKDF subkey of the sync key, so the sealing key never keys
    /// the HMAC as well.
    public static func vaultMark(name: String, wrappers: Data, key: VaultSyncKey) -> Data {
        var message = StoreWriter()
        message.text(name)
        message.bytes(wrappers)
        return Data(HMAC<SHA256>.authenticationCode(for: message.data, using: markKey(key)))
    }

    /// HKDF-SHA256 of the sync key under its own info label. Never the sealing key itself.
    static func markKey(_ key: VaultSyncKey) -> SymmetricKey {
        var info = StoreWriter()
        info.text(markLabel)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: key.key, salt: Data(), info: info.data, outputByteCount: 32)
    }

    // MARK: Sync base at rest

    /// The parts of an account's sync base, sealed: they are plain SHA-256 of secrets, so they never rest in the clear.
    public static func sealParts(_ parts: SyncParts, accountID: UUID, version: UInt64, key: VaultSyncKey) throws -> Data {
        try requireGeneration(key)
        return try seal(CredentialContent.canonicalJSON(parts), key: key, aad: partsAAD(key: key, accountID: accountID, version: version))
    }

    public static func openParts(_ sealed: Data, accountID: UUID, version: UInt64, key: VaultSyncKey) throws -> SyncParts {
        try requireGeneration(key)
        guard sealed.count >= sealOverhead else { throw VaultSyncError.malformed }
        let plaintext = try open(sealed, key: key, aad: partsAAD(key: key, accountID: accountID, version: version))
        guard let parts = try? JSONDecoder().decode(SyncParts.self, from: plaintext) else { throw VaultSyncError.malformed }
        return parts
    }

    // MARK: AAD

    /// `text(label) ‖ u8(2) ‖ uuid(profile) ‖ uuid(vault) ‖ uuid(account) ‖ u8(format) ‖ u8(state) ‖ u64(version) ‖ u64(generation)`
    static func itemAAD(key: VaultSyncKey, accountID: UUID, format: UInt8, state: UInt8, version: UInt64) -> Data {
        var aad = StoreWriter()
        aad.text(label)
        aad.u8(2)
        aad.uuid(key.profileID)
        aad.uuid(key.vaultID)
        aad.uuid(accountID)
        aad.u8(format)
        aad.u8(state)
        aad.u64(version)
        aad.u64(key.generation)
        return aad.data
    }

    /// `text(label) ‖ u8(1) ‖ uuid(profile) ‖ uuid(vault) ‖ u64(generation) ‖ bytes(SHA-256(wrappers))`
    static func vaultAAD(key: VaultSyncKey, wrappers: Data) -> Data {
        var aad = StoreWriter()
        aad.text(label)
        aad.u8(1)
        aad.uuid(key.profileID)
        aad.uuid(key.vaultID)
        aad.u64(key.generation)
        aad.bytes(Data(SHA256.hash(data: wrappers)))
        return aad.data
    }

    /// `text(label) ‖ u8(3) ‖ uuid(profile) ‖ uuid(vault) ‖ uuid(account) ‖ u64(version) ‖ u64(generation)`
    static func partsAAD(key: VaultSyncKey, accountID: UUID, version: UInt64) -> Data {
        var aad = StoreWriter()
        aad.text(label)
        aad.u8(3)
        aad.uuid(key.profileID)
        aad.uuid(key.vaultID)
        aad.uuid(accountID)
        aad.u64(version)
        aad.u64(key.generation)
        return aad.data
    }

    // MARK: Helpers

    private nonisolated struct NamePayload: Codable {
        let name: String
    }

    private static func requireGeneration(_ key: VaultSyncKey) throws {
        guard key.generation == generation else { throw VaultSyncError.unsupportedGeneration }
    }

    private static func isValid(name: String) -> Bool {
        name == name.trimmingCharacters(in: .whitespacesAndNewlines) && !name.isEmpty && name.count <= StoreFormat.nameLimit
    }

    /// The format, state, version and sealed part of an envelope, with no key.
    private static func header(of envelope: Data) throws -> (state: UInt8, version: UInt64, sealed: Data) {
        guard envelope.count <= maxItemBytes else { throw VaultSyncError.tooLarge }
        guard envelope.count >= headerBytes + sealOverhead else { throw VaultSyncError.malformed }
        let head = Array(envelope.prefix(headerBytes))
        guard head[0] == itemFormat else { throw VaultSyncError.unsupportedFormat }
        guard head[1] == liveState || head[1] == removedState else { throw VaultSyncError.malformed }
        let version = head[2...].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard version > 0 else { throw VaultSyncError.malformed }
        return (head[1], version, Data(envelope.dropFirst(headerBytes)))
    }

    /// The rules of the vault, applied without the files: valid, within the store's bounds for one account.
    private static func checked(_ account: CredentialAccount) throws {
        do {
            try account.validate()
            guard try CredentialVaultCrypto.liveBytes(of: account) <= CredentialVaultLimits.accountBytes,
                  try CredentialVaultCrypto.storedBytes(of: account) <= CredentialVaultLimits.encodedAccountBytes
            else { throw VaultSyncError.tooLarge }
        } catch let error as VaultSyncError {
            throw error
        } catch {
            throw VaultSyncError.malformed
        }
    }

    private static func encode(_ account: CredentialAccount) throws -> Data {
        do {
            return try CredentialContent.canonicalJSON(account)
        } catch {
            throw VaultSyncError.malformed
        }
    }

    private static func seal(_ plaintext: Data, key: VaultSyncKey, aad: Data) throws -> Data {
        guard let sealed = try? AES.GCM.seal(plaintext, using: key.key, authenticating: aad).combined else { throw VaultSyncError.malformed }
        return sealed
    }

    private static func open(_ sealed: Data, key: VaultSyncKey, aad: Data) throws -> Data {
        guard sealed.count >= sealOverhead else { throw VaultSyncError.malformed }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key.key, authenticating: aad)
        } catch {
            throw VaultSyncError.authenticationFailed
        }
    }
}
