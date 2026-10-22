// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// What the router keeps between runs, in the app-level `iCloudSync.json`: the engine's own state, and the vault sync's cache of the
/// account's private database. It holds no key, no entry and nothing from a private window.
nonisolated public struct SyncRouterState: Codable, Equatable, Sendable {
    public var engineState: Data?
    public var vaults = VaultSyncAppState()

    public init(engineState: Data? = nil, vaults: VaultSyncAppState = VaultSyncAppState()) {
        self.engineState = engineState
        self.vaults = vaults
    }
}

/// The one delegate of the one engine. It owns the engine's state and splits everything else by zone: `v-` zones belong to
/// `VaultSync`, `devices` and `p-` zones to `TabSync`; an account change goes to both. A zone it does not know, or a feature that is
/// not running, is dropped here, so no feature ever sees another's records.
@Observable
public final class SyncRouter: SyncEngineDelegate {
    public private(set) var state: SyncRouterState

    @ObservationIgnored private let persist: (SyncRouterState) -> Void
    @ObservationIgnored private let tabs: TabSync?
    @ObservationIgnored private let vaults: VaultSync?

    public init(state: SyncRouterState, persist: @escaping (SyncRouterState) -> Void, tabs: TabSync?, vaults: VaultSync?) {
        self.state = state
        self.persist = persist
        self.tabs = tabs
        self.vaults = vaults
    }

    public func handle(_ event: SyncEvent) async {
        switch event {
        case .state(let data):
            state.engineState = data
            persist(state)
        case .account:
            await tabs?.handle(event)
            await vaults?.handle(event)
        case .zonesDeleted(let zones):
            let tabZones = zones.filter { isTabZone($0.key) }
            let vaultZones = zones.filter { SyncZone.isVault($0.key) }
            if !tabZones.isEmpty {
                await tabs?.handle(.zonesDeleted(tabZones))
            }
            if !vaultZones.isEmpty {
                await vaults?.handle(.zonesDeleted(vaultZones))
            }
        case .fetched(let modified, let deleted):
            let tabModified = modified.filter { isTabZone($0.id.zone) }
            let tabDeleted = deleted.filter { isTabZone($0.zone) }
            let vaultModified = modified.filter { SyncZone.isVault($0.id.zone) }
            let vaultDeleted = deleted.filter { SyncZone.isVault($0.zone) }
            if !tabModified.isEmpty || !tabDeleted.isEmpty {
                await tabs?.handle(.fetched(modified: tabModified, deleted: tabDeleted))
            }
            if !vaultModified.isEmpty || !vaultDeleted.isEmpty {
                await vaults?.handle(.fetched(modified: vaultModified, deleted: vaultDeleted))
            }
        case .sent(let saved, let deleted, let failed):
            let tabSaved = saved.filter { isTabZone($0.id.zone) }
            let tabDeleted = deleted.filter { isTabZone($0.zone) }
            let tabFailed = failed.filter { isTabZone($0.id.zone) }
            let vaultSaved = saved.filter { SyncZone.isVault($0.id.zone) }
            let vaultDeleted = deleted.filter { SyncZone.isVault($0.zone) }
            let vaultFailed = failed.filter { SyncZone.isVault($0.id.zone) }
            if !tabSaved.isEmpty || !tabDeleted.isEmpty || !tabFailed.isEmpty {
                await tabs?.handle(.sent(saved: tabSaved, deleted: tabDeleted, failed: tabFailed))
            }
            if !vaultSaved.isEmpty || !vaultDeleted.isEmpty || !vaultFailed.isEmpty {
                await vaults?.handle(.sent(saved: vaultSaved, deleted: vaultDeleted, failed: vaultFailed))
            }
        }
    }

    public func record(for id: SyncRecordID) -> SyncRecord? {
        if SyncZone.isVault(id.zone) {
            return vaults?.record(for: id)
        }
        return isTabZone(id.zone) ? tabs?.record(for: id) : nil
    }

    /// `VaultSync` hands its app-level cache here whenever it changes; it rides in this router's file.
    public func setVaults(_ vaults: VaultSyncAppState) {
        guard state.vaults != vaults else { return }
        state.vaults = vaults
        persist(state)
    }

    private func isTabZone(_ zone: String) -> Bool {
        zone == SyncZone.devices || SyncZone.profileID(zone) != nil
    }
}
