// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation

/// What the router keeps between runs, in the app-level `iCloudSync.json`: the engine's own state, and the vault sync's cache of the
/// account's private database. It holds no key, no entry and nothing from a private window.
nonisolated public struct SyncRouterState: Codable, Equatable, Sendable {
    public var engineState: Data?
    public var vaults = VaultSyncAppState()
    /// Earlier native checkpoints can contain zone changes without a per-vault owner. The first new engine starts with a clean queue.
    private let accountBoundVaultChanges = true

    private enum CodingKeys: String, CodingKey { case engineState, vaults, accountBoundVaultChanges }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vaults = try values.decode(VaultSyncAppState.self, forKey: .vaults)
        if try values.decodeIfPresent(Bool.self, forKey: .accountBoundVaultChanges) == true {
            engineState = try values.decodeIfPresent(Data.self, forKey: .engineState)
        }
    }

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
    @ObservationIgnored private var handlers: [any SyncZoneHandler]
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

    private var tabs: TabSync? {
        handlers.lazy.compactMap { $0 as? TabSync }.first
    }

    public func allowsZoneCreation(_ zone: String) -> Bool {
        guard zone == SyncZone.devices || SyncZone.profileID(zone) != nil else {
            return handlers.first { $0.owns(zone: zone) }?.allowsZoneCreation(zone) ?? true
        }
        return tabs?.allowsZoneCreation(zone) == true
    }

    public func beginFetch() -> SyncFetchDelivery {
        let start = tabs?.markFetchStart()
        var receivers: [ObjectIdentifier: SyncFetchDelivery] = [:]
        for handler in handlers where !(handler is TabSync) {
            receivers[ObjectIdentifier(handler)] = handler.beginFetch()
        }
        return { [weak self, receivers] event in
            await self?.route(event, fetchReceivers: receivers) { tabs, owned in await tabs.receive(owned, from: start) }
        }
    }

    public func handle(_ event: SyncEvent) async {
        if case .state(let data) = event {
            state.engineState = data
            persist(state)
            return
        }
        await route(event)
    }

    private func route(
        _ event: SyncEvent, fetchReceivers: [ObjectIdentifier: SyncFetchDelivery] = [:],
        tabDelivery: ((TabSync, SyncEvent) async -> Void)? = nil
    ) async {
        let active = vaultHandler.map { handlers + [$0] } ?? handlers
        if case .account(let change) = event {
            accountChanged?(change)
        }
        for handler in active {
            guard let owned = event.filtered(to: handler.owns) else { continue }
            if let tabs = handler as? TabSync, let tabDelivery {
                await tabDelivery(tabs, owned)
            } else if let deliver = fetchReceivers[ObjectIdentifier(handler)] {
                await deliver(owned)
            } else {
                await handler.handle(owned)
            }
        }
    }

    public func routeTabs(to tabs: TabSync) {
        handlers.removeAll { $0 is TabSync }
        handlers.append(tabs)
    }

    public func routeVaults(to vaults: VaultSync?) {
        vaultHandler = vaults
    }

    public func acceptsUploadAccount(_ user: String) -> Bool {
        let results = handlers.map { $0.acceptsUploadAccount(user) }
        let vaultApproved = vaultHandler?.acceptsUploadAccount(user) ?? true
        if !vaultApproved {
            accountChanged?(.switchAccounts(user: user))
        }
        return vaultApproved && !results.contains(false)
    }

    public func wantsRecordDeletion(_ id: SyncRecordID) -> Bool {
        handlers.first { $0.owns(zone: id.zone) }?.wantsRecordDeletion(id) ?? false
    }

    public func recordForUpload(_ id: SyncRecordID) async -> SyncRecord? {
        if SyncZone.isVault(id.zone) {
            return await vaultHandler?.recordForUpload(id)
        }
        return await handlers.first { $0.owns(zone: id.zone) }?.recordForUpload(id)
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

extension SyncRouter: VaultZoneReading {
    var enrolledVaultZones: Set<String> {
        vaultHandler?.enrolledVaultZones ?? []
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
