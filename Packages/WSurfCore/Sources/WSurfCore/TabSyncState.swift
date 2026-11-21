// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CryptoKit
import Foundation

/// Everything `TabSync` keeps between runs. It caches what the account's private database holds, so a launch lists the other
/// devices at once. It holds no profile identity beyond zone names, and nothing from a private window. The engine's own state
/// belongs to `SyncRouter`.
nonisolated public struct TabSyncState: Codable, Equatable, Sendable {
    /// The `recordName` of the last signed-in user record.
    public var accountUser: String?
    public var seq: Int64 = 0
    /// Zone name to the system fields of this device's record there. A key means the record exists on the server.
    public var ownSystemFields: [String: Data] = [:]
    public var publishedDevice: DeviceInfo?
    /// Install ID to another device.
    public var devices: [String: MirroredDevice] = [:]
    /// Zone name to install ID to another device's session.
    public var sessions: [String: [String: MirroredSession]] = [:]

    /// The original account and uninterrupted profile choices that still need a zone-existence check.
    struct RemovalCheck: Codable, Equatable, Sendable {
        var account: String?
        var profiles: Set<UUID>
        var zones: Set<String>
        /// A missing zone ends an established enrollment. A brand-new opt-in may still create its first zone.
        var establishedZones: Set<String>?

        var zonesRequiringExistence: Set<String> {
            establishedZones ?? zones
        }
    }

    struct ZoneObservations: Codable, Equatable, Sendable {
        enum Presence: String, Codable { case absent, present, incomplete }
        let account: String
        /// Existence under the current opt-in. Turning it off forgets these observations.
        var zones: [String: Presence] = [:]
        /// Rows this installation handed to the engine, including a first save whose receipt never arrived.
        var publication: Publication?
        /// Only unfulfilled deletions survive a visit to another account. Each row also belongs to one installation.
        var withdrawals: [String: Publication]?

        func restoringLegacyEvidence(for check: RemovalCheck?) -> Self? {
            guard let check else { return self }
            guard check.account == account else { return nil }
            var result = self
            for zone in check.zones.subtracting(check.zonesRequiringExistence) {
                result.zones[zone] = nil
            }
            return result
        }

        func switching(to user: String, withdrawing zones: Set<String>, installID: String) -> Self {
            var waiting = withdrawals ?? [:]
            if !zones.isEmpty {
                waiting[account] = Publication(installID: installID, zones: zones)
            }
            // An explicit empty publication prevents stale change tags on disk from authorizing a delete in the visiting account.
            let active = waiting.removeValue(forKey: user) ?? Publication(installID: installID, zones: [])
            return Self(account: user, publication: active, withdrawals: waiting.isEmpty ? nil : waiting)
        }
    }

    struct Publication: Codable, Equatable, Sendable {
        let installID: String
        var zones: Set<String>
    }

    var zoneObservations: ZoneObservations?
    var removalCheck: RemovalCheck?
    var removalRevision: Int?

    var removalCheckpoint: TabRemovalCheckpoint? {
        guard removalRevision != nil || removalCheck != nil else { return nil }
        return TabRemovalCheckpoint(revision: removalRevision ?? 0, pending: removalCheck, observations: zoneObservations)
    }

    public init() {}

    /// A pre-observation tab file may already have a removal revision (77b5152f). Neither old format records absence.
    mutating func migrateObservedZones() -> Bool {
        guard zoneObservations == nil, let owner = accountUser else { return false }
        let owned = Set(ownSystemFields.keys)
        var present = owned.union(sessions.compactMap { $0.value.isEmpty ? nil : $0.key })
        if publishedDevice != nil || !devices.isEmpty {
            present.insert(SyncZone.devices)
        }
        let inferred = ZoneObservations(account: owner, zones: Dictionary(uniqueKeysWithValues: present.map { ($0, .present) }))
        guard let compatible = inferred.restoringLegacyEvidence(for: removalCheck), !compatible.zones.isEmpty else { return false }
        zoneObservations = compatible
        removalRevision = removalRevision ?? 0
        return true
    }

    /// Older files kept acknowledged rows only as change tags. Preserve their owner before sign-out clears the tags.
    mutating func migratePublishedRecords(installID: String) {
        guard let owner = accountUser, zoneObservations?.publication == nil, !ownSystemFields.isEmpty else { return }
        var observations = zoneObservations ?? .init(account: owner)
        guard observations.account == owner else { return }
        observations.publication = Publication(installID: installID, zones: Set(ownSystemFields.keys))
        zoneObservations = observations
        removalRevision = removalRevision ?? 0
    }
}

/// Stored alongside the engine cursor too. A newer clear must win over a stale tab file on restart.
nonisolated struct TabRemovalCheckpoint: Codable, Equatable, Sendable {
    let revision: Int
    let pending: TabSyncState.RemovalCheck?
    var observations: TabSyncState.ZoneObservations?
}

/// A saved record carries its encrypted payload but no request ID. Count identical handouts until all their replies arrive.
struct TabSaveHandouts {
    enum Receipt { case current, ambiguous }
    private struct Copies {
        var remaining = 0
        var current = true
        var ambiguous = false
    }
    private var copies: [SHA256.Digest: Copies] = [:]
    private var latest: SHA256.Digest?

    var isEmpty: Bool {
        copies.isEmpty
    }

    mutating func issue(_ payload: Data) {
        let key = SHA256.hash(data: payload)
        var group = copies[key] ?? Copies()
        group.ambiguous = group.remaining > 0
        group.remaining += 1
        group.current = true
        copies[key] = group
        latest = key
    }

    mutating func retire() {
        latest = nil
        for key in copies.keys {
            copies[key]?.current = false
        }
    }

    mutating func finish(_ payload: Data, sharing: Bool) -> Receipt? {
        let key = SHA256.hash(data: payload)
        guard var group = copies[key] else { return nil }
        group.remaining -= 1
        copies[key] = group.remaining == 0 ? nil : group
        guard group.current, !sharing || latest == key else { return nil }
        return group.ambiguous ? .ambiguous : .current
    }
}
