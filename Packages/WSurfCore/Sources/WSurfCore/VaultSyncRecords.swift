// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// What a profile looks like on the Mac that added it to iCloud: enough to add the profile on another Mac with the same ID. Not a
/// credential secret. The strings are cut when read, so a record cannot carry a long one into a list.
nonisolated public struct VaultProfileCard: Codable, Equatable, Sendable {
    public static let maxCharacters = 64

    public var name: String
    /// An SF Symbol name; the app falls back to a generic person for one it does not know.
    public var symbol: String
    /// A tab folder color name; the app reads an unknown one as gray.
    public var color: String

    public init(name: String, symbol: String, color: String) {
        self.name = name
        self.symbol = symbol
        self.color = color
    }

    private enum CodingKeys: String, CodingKey {
        case name, symbol, color
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = String(try container.decode(String.self, forKey: .name).prefix(Self.maxCharacters))
        symbol = String(try container.decode(String.self, forKey: .symbol).prefix(Self.maxCharacters))
        color = String(try container.decode(String.self, forKey: .color).prefix(Self.maxCharacters))
    }
}

/// The `Vault` record's encrypted payload (one per zone): the vault's wrapper list, its name sealed with that list, and the profile.
/// The wrappers are public data by design: they open only with the unlock passkey.
nonisolated public struct VaultRecordPayload: Codable, Equatable, Sendable {
    public static let maxBytes = 512 * 1_024
    public static let maxWrapperBytes = 256 * 1_024
    public static let maxSealedBytes = 2_048

    /// `VaultSyncCodec.generation`; any other value leaves the zone alone.
    public var keyGeneration: UInt64
    public var profile: VaultProfileCard
    /// `VaultWrapperList.encode` bytes.
    public var wrappers: Data
    /// `VaultSyncCodec.sealVault`: the vault name, authenticated with `wrappers`.
    public var sealed: Data

    public init(keyGeneration: UInt64, profile: VaultProfileCard, wrappers: Data, sealed: Data) {
        self.keyGeneration = keyGeneration
        self.profile = profile
        self.wrappers = wrappers
        self.sealed = sealed
    }

    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maxBytes else { throw VaultSyncFailure.tooLarge }
        return data
    }

    /// The payload in `data`, or nil unless it is a well-formed payload within its bounds.
    static func decode(_ data: Data) -> VaultRecordPayload? {
        guard data.count <= maxBytes, let payload = try? JSONDecoder().decode(VaultRecordPayload.self, from: data),
              payload.wrappers.count <= maxWrapperBytes, payload.sealed.count <= maxSealedBytes
        else { return nil }
        return payload
    }
}

/// A vault another Mac synced, as its `Vault` record describes it.
nonisolated public struct RemoteVault: Codable, Equatable, Identifiable, Sendable {
    public var profileID: UUID
    public var vaultID: UUID
    public var payload: VaultRecordPayload

    public var id: UUID {
        vaultID
    }

    public init(profileID: UUID, vaultID: UUID, payload: VaultRecordPayload) {
        self.profileID = profileID
        self.vaultID = vaultID
        self.payload = payload
    }
}

/// What `VaultSync` keeps at app level, in the router's file: a cache of the account's private database, cleared on an account
/// change. Wrappers and sealed names only; no key, no entry, no profile data beyond the card.
nonisolated public struct VaultSyncAppState: Codable, Equatable, Sendable {
    /// The `recordName` of the last signed-in user record.
    public var accountUser: String?
    /// Zone name to the vault its `Vault` record describes.
    public var remote: [String: RemoteVault] = [:]

    public init() {}
}

nonisolated public enum VaultSyncStatus: Equatable, Sendable {
    case off
    case synced
    /// Changes (entries, or the vault's name and unlock passkeys) waiting to go up.
    case sending(Int)
    /// Changes from other devices waiting for the vault to be unlocked.
    case waitingForUnlock(Int)
    /// Entries changed here and on another device (or that differ with no common ground) wait for a choice.
    case needsReview(Int)
    /// This many entries were deleted here at once; their deletion waits for the owner.
    case holdingRemovals(Int)
    case iCloudFull
    case signedOut
    /// A newer WSurf wrote this vault's `Vault` record (a key generation this build does not know).
    case needsUpdate
    /// This Mac's store is older than the last state it synced.
    case rolledBack
    case removed(SyncZoneDeletionReason)
    /// The owner removed the vault from iCloud and the engine could not delete the zone: it is still there.
    case removalFailed
    case accountChanged

    /// What survives a relaunch, in `Credentials.sync`. The rest is derived from counts, the lock and the account.
    nonisolated enum Stored: String, Sendable {
        case active, iCloudFull, needsUpdate, rolledBack, removedDeleted, removedPurged, removedEncryptedDataReset, removalFailed, accountChanged

        static func removed(_ reason: SyncZoneDeletionReason) -> Stored {
            switch reason {
            case .deleted:
                .removedDeleted
            case .purged:
                .removedPurged
            case .encryptedDataReset:
                .removedEncryptedDataReset
            }
        }
    }
}

/// What the interface says about entries the vault sync leaves alone, beside the status.
nonisolated public struct VaultSyncTally: Equatable, Sendable {
    /// Entries that stay on this Mac: too large to sync, or only files.
    public var notSyncable: Int
    /// Changes from iCloud that could not be read and were skipped this run.
    public var unreadable: Int
    /// Entries a newer WSurf wrote that this build cannot read yet: they wait, and nothing is sent over them.
    public var newer: Int

    public init(notSyncable: Int, unreadable: Int, newer: Int) {
        self.notSyncable = notSyncable
        self.unreadable = unreadable
        self.newer = newer
    }
}

/// An entry that waits for the person: this Mac's version and iCloud's. Both are opened, so reading one needs the vault unlocked.
nonisolated public struct VaultSyncConflict: Identifiable, Sendable {
    public var id: UUID
    public var kind: SyncConflictKind
    /// The parts both sides changed (or that differ with no base). Empty for a kind that is about the whole entry.
    public var parts: [SyncPart]
    public var local: CredentialAccount?
    public var incoming: CredentialAccount?

    public init(id: UUID, kind: SyncConflictKind, parts: [SyncPart], local: CredentialAccount?, incoming: CredentialAccount?) {
        self.id = id
        self.kind = kind
        self.parts = parts
        self.local = local
        self.incoming = incoming
    }
}

/// Why a `VaultSync` action did not happen.
nonisolated public enum VaultSyncFailure: Error, Equatable, Sendable {
    /// The vault is locked: sync never asks for a passkey.
    case locked
    /// No engine is attached, or the private profile.
    case unavailable
    case signedOut
    /// The `Vault` record does not fit its bounds.
    case tooLarge
}

/// One vault's content as a sync pass reads it, all from one moment. `lease` is the authorization the vault was read under; a
/// commit carries it back, so a lock or a new unlock in between writes nothing.
nonisolated public struct VaultSyncSnapshot: Sendable {
    public var lease: UInt64
    public var revision: UInt64
    public var accounts: [CredentialAccount]
    public var stamps: [UUID: AccountStamp]
    public var removed: RemovedIdentifiers
    public var name: String
    public var wrappers: [CredentialKeyWrapper]

    public init(
        lease: UInt64,
        revision: UInt64,
        accounts: [CredentialAccount],
        stamps: [UUID: AccountStamp],
        removed: RemovedIdentifiers,
        name: String,
        wrappers: [CredentialKeyWrapper]
    ) {
        self.lease = lease
        self.revision = revision
        self.accounts = accounts
        self.stamps = stamps
        self.removed = removed
        self.name = name
        self.wrappers = wrappers
    }
}

/// What the app gives `VaultSync`: the profiles and their folders, the vault's key and content while it is unlocked, and the one
/// way to write. Nothing here prompts, unlocks or touches a lease; the macOS app implements it over its credential managers and tests
/// fake it.
public protocol VaultSyncHost: AnyObject {
    /// The profiles on this Mac.
    func profileIDs() -> [UUID]
    /// The profile's own folder (`Credentials.sync` lives there), or nil when the profile is not on this Mac.
    func syncDirectory(profileID: UUID) -> URL?
    func profileCard(profileID: UUID) -> VaultProfileCard?
    /// The vaults the profile lists now, locked or not; nil when they cannot be listed. A profile always has a vault, so an empty
    /// list is read as unknown too.
    func vaultIDs(profileID: UUID) async -> [UUID]?
    /// The vault's sync key, or nil while it is locked. Never prompts.
    func syncKey(profileID: UUID, vaultID: UUID) async -> VaultSyncKey?
    /// Throws while the vault is locked (`CredentialVaultError.unauthorized` or `expired`).
    func snapshot(profileID: UUID, vaultID: UUID) async throws -> VaultSyncSnapshot
    /// One commit under `lease`, with cause `sync`. Returns the vault's new revision.
    func commit(
        profileID: UUID, vaultID: UUID, lease: UInt64, writes: [AccountWrite], removing: [UUID: AccountStamp]
    ) async throws -> UInt64
    /// Keeps, under `lease`, what entries removed on another device left (`RemovedMemory`, by account), so an import here does not
    /// bring them back. Nothing live changes. Returns the vault's new revision.
    func remember(profileID: UUID, vaultID: UUID, lease: UInt64, memories: [UUID: RemovedMemory]) async throws -> UInt64
}
