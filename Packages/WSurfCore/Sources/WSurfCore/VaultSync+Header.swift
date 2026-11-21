// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// A header whose name and exact wrapper bytes authenticated under this vault's sync key.
nonisolated struct VaultSyncHeader {
    let payload: VaultRecordPayload
    let name: String
    let wrappers: [CredentialKeyWrapper]

    init(_ data: Data?, key: VaultSyncKey) throws {
        guard let data, let payload = VaultRecordPayload.decode(data), payload.keyGeneration == VaultSyncCodec.generation else { throw VaultSyncFailure.unavailable }
        name = try VaultSyncCodec.openVault(payload.sealed, wrappers: payload.wrappers, key: key)
        wrappers = try VaultWrapperList.decode(payload.wrappers)
        self.payload = payload
    }

    static func seal(name: String, wrappers: Data, profile: VaultProfileCard, key: VaultSyncKey) throws -> Data {
        _ = try VaultWrapperList.decode(wrappers)
        let sealed = try VaultSyncCodec.sealVault(name: name, wrappers: wrappers, key: key)
        return try VaultRecordPayload(keyGeneration: VaultSyncCodec.generation, profile: profile, wrappers: wrappers, sealed: sealed).encoded()
    }

    /// A renewed enrollment may carry a queued local rename, but only the freshly authenticated header supplies cloud unlock methods.
    func joinedMark(previous: VaultRow?, name localName: String, wrappers local: Data, mark: Data, key: VaultSyncKey) -> Data {
        guard let previous, let acknowledged = previous.queuedLegacyHeaderBaseline else { return mark }
        let serverNameMark = VaultSyncCodec.vaultMark(name: name, wrappers: local, key: key)
        if let baseline = previous.localWrappers {
            let sameName = VaultSyncCodec.vaultMark(name: localName, wrappers: baseline, key: key) == acknowledged
            return sameName ? mark : serverNameMark
        }
        // Older rows kept only the HMAC. Matching the server name with the local wrappers establishes which field changed.
        return acknowledged == serverNameMark ? serverNameMark : mark
    }

    /// Only changes since this Mac's last acknowledged local state apply to the server. A revoked credential stays absent.
    func merging(_ snapshot: VaultSyncSnapshot, local: Data, row: VaultRow, key: VaultSyncKey) throws -> Data? {
        // Older enrolled rows kept only the HMAC. Their existing local unlock methods cannot establish a change to cloud access.
        let baseline = row.localWrappers ?? local
        let unchangedName = VaultSyncCodec.vaultMark(name: snapshot.name, wrappers: baseline, key: key) == row.uploadedMark
        let newName = unchangedName ? name : snapshot.name
        let newWrappers = baseline == local ? payload.wrappers : try mergingWrappers(from: baseline, to: local)
        guard newName != name || newWrappers != payload.wrappers else { return nil }
        return try Self.seal(name: newName, wrappers: newWrappers, profile: payload.profile, key: key)
    }

    private func mergingWrappers(from baseline: Data, to local: Data) throws -> Data {
        let before = Dictionary(uniqueKeysWithValues: try VaultWrapperList.decode(baseline).map { ($0.credentialID, $0) })
        let after = try VaultWrapperList.decode(local)
        let byID = Dictionary(uniqueKeysWithValues: after.map { ($0.credentialID, $0) })
        let remoteIDs = Set(wrappers.map(\.credentialID))
        var merged: [CredentialKeyWrapper] = []
        for remote in wrappers {
            if let original = before[remote.credentialID] {
                guard let current = byID[remote.credentialID] else { continue }
                let changedHere = try VaultWrapperList.encode([current]) != VaultWrapperList.encode([original])
                merged.append(changedHere ? current : remote)
            } else {
                merged.append(remote)
            }
        }
        merged += after.filter { before[$0.credentialID] == nil && !remoteIDs.contains($0.credentialID) }
        return try VaultWrapperList.encode(merged)
    }
}

extension VaultSync {
    func settleVaultRecord(_ key: VaultKey, snapshot: VaultSyncSnapshot, syncKey: VaultSyncKey, database: VaultSyncDatabase) -> Bool {
        guard let local = try? VaultWrapperList.encode(snapshot.wrappers) else { return false }
        let mark = VaultSyncCodec.vaultMark(name: snapshot.name, wrappers: local, key: syncKey)
        return (try? database.write { tx in
            guard var row = try tx.vault(key.vaultID), row.enabled, !row.needsFetch else { return false }
            let previous = row
            row.lastHeadRevision = max(row.lastHeadRevision, snapshot.revision)
            let queued = prepareHeader(&row, snapshot: snapshot, local: local, mark: mark, syncKey: syncKey)
            if row != previous {
                try tx.save(row)
            }
            return queued
        }) ?? false
    }

    private func prepareHeader(_ row: inout VaultRow, snapshot: VaultSyncSnapshot, local: Data, mark: Data, syncKey: VaultSyncKey) -> Bool {
        // Finish the first create before publishing a later local edit. Its receipt keeps the baseline of that first header.
        if row.uploadedMark == nil, row.pendingVault != nil {
            return false
        }
        if row.uploadedMark == mark {
            row.acknowledgeHeader(mark: mark, local: local)
            return false
        }
        if row.pendingMark == mark, row.pendingLocalWrappers != nil, row.pendingVault != nil {
            return false
        }
        // Nothing from an earlier attempt can be sent if preparing the current edit fails.
        row.pendingVault = nil
        if row.uploadedMark != nil {
            row.pendingMark = mark
            row.pendingLocalWrappers = local
        }
        guard let server = try? VaultSyncHeader(row.serverVault, key: syncKey) else { return false }
        do {
            if row.uploadedMark != nil, let merged = try server.merging(snapshot, local: local, row: row, key: syncKey) {
                row.pendingVault = merged
                return true
            }
            // First unlock after adoption, or the authenticated server already carries the complete change.
            row.acknowledgeHeader(mark: mark, local: local)
        } catch {
            return false
        }
        return false
    }
}

extension VaultRow {
    /// The last acknowledged local header for queued work that predates explicit consent. It cannot authorize an upload.
    nonisolated var queuedLegacyHeaderBaseline: Data? {
        enabled && approvedUser == nil && pendingMark != nil ? uploadedMark : nil
    }

    mutating func acknowledgeHeader(mark: Data?, local: Data?) {
        uploadedMark = mark
        localWrappers = local
        pendingVault = nil
        pendingMark = nil
        pendingLocalWrappers = nil
    }
}
