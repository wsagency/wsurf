// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

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

extension TabSync: SyncZoneHandler {
    public func owns(zone: String) -> Bool {
        zone == SyncZone.devices || SyncZone.profileID(zone) != nil
    }
}

extension VaultSync: SyncZoneHandler {
    public func owns(zone: String) -> Bool {
        SyncZone.isVault(zone)
    }
}

/// One delegate owns the engine checkpoint. Feature caches and opt-ins have independent lifetimes.
@Observable
public final class SyncRouter: SyncEngineDelegate {
    public private(set) var state: SyncRouterState

    @ObservationIgnored private let persist: (SyncRouterState) -> Void
    @ObservationIgnored private let handlers: [any SyncZoneHandler]
    @ObservationIgnored private var vaultHandler: VaultSync?
    @ObservationIgnored public var accountChanged: ((SyncAccountChange) -> Void)?

    public init(
        state: SyncRouterState, persist: @escaping (SyncRouterState) -> Void,
        tabs: TabSync?, vaults: VaultSync?, additional: [any SyncZoneHandler] = []
    ) {
        self.state = state
        self.persist = persist
        var handlers = additional
        if let tabs {
            handlers.append(tabs)
        }
        vaultHandler = vaults
        self.handlers = handlers
    }

    public func handle(_ event: SyncEvent) async {
        if case .state(let data) = event {
            state.engineState = data
            persist(state)
            return
        }
        let active = vaultHandler.map { handlers + [$0] } ?? handlers
        if case .account(let change) = event {
            accountChanged?(change)
        }
        for handler in active {
            if let owned = event.filtered(to: handler.owns) {
                await handler.handle(owned)
            }
        }
    }

    public func routeVaults(to vaults: VaultSync?) {
        vaultHandler = vaults
    }

    public func record(for id: SyncRecordID) -> SyncRecord? {
        if SyncZone.isVault(id.zone) {
            return vaultHandler?.record(for: id)
        }
        return handlers.first { $0.owns(zone: id.zone) }?.record(for: id)
    }

    public func setVaults(_ vaults: VaultSyncAppState) {
        guard state.vaults != vaults else { return }
        state.vaults = vaults
        persist(state)
    }
}

private extension SyncEvent {
    func filtered(to owns: (String) -> Bool) -> Self? {
        switch self {
        case .state:
            return nil
        case .account:
            return self
        case .zonesDeleted(let all):
            let zones = all.filter { owns($0.key) }
            return zones.isEmpty ? nil : .zonesDeleted(zones)
        case .zoneDeletesFailed(let all):
            let zones = all.filter(owns)
            return zones.isEmpty ? nil : .zoneDeletesFailed(zones)
        case .zoneSavesOverQuota(let all):
            let zones = all.filter(owns)
            return zones.isEmpty ? nil : .zoneSavesOverQuota(zones)
        case .fetched(let all, let removed):
            let records = all.filter { owns($0.id.zone) }
            let deleted = removed.filter { owns($0.zone) }
            return records.isEmpty && deleted.isEmpty ? nil : .fetched(modified: records, deleted: deleted)
        case .sent(let all, let removed, let errors):
            let saved = all.filter { owns($0.id.zone) }
            let deleted = removed.filter { owns($0.zone) }
            let failed = errors.filter { owns($0.id.zone) }
            return saved.isEmpty && deleted.isEmpty && failed.isEmpty ? nil : .sent(saved: saved, deleted: deleted, failed: failed)
        }
    }
}
