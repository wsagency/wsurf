// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation

/// The predecessor of an account switch remains replayable until this engine serializes its new state.
nonisolated struct TabAccountEvents: Codable, Equatable, Sendable {
    struct Switch: Codable, Equatable {
        let from: String
        let to: String
        let id: UUID
        var engineCheckpointed = false
        var deliveredToTabs = false
    }

    struct Delivery: Codable, Equatable {
        let change: SyncAccountChange
        var previousUser: String?
        var predecessorID: UUID?

        var user: String? {
            switch change {
            case .signIn(let user), .switchAccounts(let user):
                user
            case .signOut:
                nil
            }
        }
    }

    /// Older checkpoints omit the inbox. New checkpoints encode an empty inbox once all changes reach Personal.
    private(set) var deferred: [Delivery]? = []
    var checkpointID: UUID?
    var pending: Switch?
    var currentID: UUID? {
        pending?.id ?? checkpointID
    }

    mutating func receive(from: String, to: String, newlyVerified: Bool) {
        deferred = []
        if let pending, !newlyVerified, !pending.engineCheckpointed, pending.from == from, pending.to == to {
            return
        }
        checkpointID = currentID
        pending = Switch(from: from, to: to, id: UUID())
    }

    mutating func checkpoint() {
        pending?.engineCheckpointed = true
        retireIfComplete()
    }

    mutating func deliveredToTabs() {
        pending?.deliveredToTabs = true
        retireIfComplete()
    }

    private mutating func retireIfComplete() {
        guard let pending, pending.engineCheckpointed && pending.deliveredToTabs else { return }
        checkpointID = pending.id
        self.pending = nil
    }

    var switchDelivery: Delivery? {
        pending.map { Delivery(change: .switchAccounts(user: $0.to), previousUser: $0.from, predecessorID: checkpointID) }
    }

    /// Retire the engine's replay authority. A switch still owed to the tab store has an independent lifetime.
    mutating func retireReplay() {
        if pending?.deliveredToTabs == false, let switchDelivery {
            deferred = [switchDelivery]
        }
        pending = nil
        checkpointID = UUID()
    }

    /// With no tab store there can be no intervening opt-in. Keep the first arrival and the last pause/resume.
    /// A subsequent different account is a real switch and supersedes that whole sequence.
    mutating func deferChange(_ change: SyncAccountChange) {
        let next = Delivery(change: change)
        var waiting = deferred ?? []
        let arrival = waiting.firstIndex { $0.user != nil }
        switch change {
        case .signOut:
            if let arrival {
                waiting.removeSubrange((arrival + 1)..<waiting.endIndex)
            }
            if waiting.last != next {
                waiting.append(next)
            }
        case .signIn(let user):
            if let arrival, waiting[arrival].user != user {
                waiting = [Delivery(change: .switchAccounts(user: user))]
            } else if waiting.last != next {
                waiting.append(next)
            }
        case .switchAccounts:
            waiting = [next]
        }
        deferred = waiting
    }

    mutating func didDeliverFirst() {
        deferred?.removeFirst()
    }

    /// The older router recorded tab delivery and its installation in separate fields, before it had a deferred inbox.
    mutating func migrateDeliveredSwitch(in removal: inout TabRemovalCheckpoint?) {
        guard deferred == nil else { return }
        deferred = []
        guard let pending, pending.deliveredToTabs, !pending.engineCheckpointed,
              let observed = removal?.observations, observed.account == pending.to, observed.verifiedSwitch == nil,
              let installation = observed.publication?.installID else { return }
        removal?.observations?.verifiedSwitch = .init(previousUser: pending.from, installID: installation, accountEventID: checkpointID)
    }
}

/// What the router keeps between runs, in the app-level `iCloudSync.json`: the engine's own state, and the vault sync's cache of the
/// account's private database. It holds no key, no entry and nothing from a private window.
nonisolated public struct SyncRouterState: Codable, Equatable, Sendable {
    public var engineState: Data?
    public var vaults = VaultSyncAppState()
    var tabRemoval: TabRemovalCheckpoint?
    var tabAccountEvents = TabAccountEvents()
    /// Earlier native checkpoints can contain zone changes without a per-vault owner. The first new engine starts with a clean queue.
    private let explicitVaultChanges = true

    private enum CodingKeys: String, CodingKey { case engineState, vaults, explicitVaultChanges, tabRemoval, tabAccountEvents }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        vaults = try values.decode(VaultSyncAppState.self, forKey: .vaults)
        tabRemoval = try values.decodeIfPresent(TabRemovalCheckpoint.self, forKey: .tabRemoval)
        tabAccountEvents = try values.decodeIfPresent(TabAccountEvents.self, forKey: .tabAccountEvents) ?? .init()
        tabAccountEvents.migrateDeliveredSwitch(in: &tabRemoval)
        if try values.decodeIfPresent(Bool.self, forKey: .explicitVaultChanges) == true {
            engineState = try values.decodeIfPresent(Data.self, forKey: .engineState)
        }
    }

    public init(engineState: Data? = nil, vaults: VaultSyncAppState = VaultSyncAppState()) {
        self.engineState = engineState
        self.vaults = vaults
    }
}

extension TabSync: SyncZoneHandler {
    public func accountSwitched(from previousUser: String, to user: String) {
        let receipt = switchReceipt(from: previousUser, after: accountEventID)
        let handled = hasApplied(receipt, to: user)
        discardAccountSwitchEvidence()
        applyAccount(handled ? .signIn(user: user) : .switchAccounts(user: user))
    }

    func apply(_ delivery: TabAccountEvents.Delivery) {
        guard case .switchAccounts(let user) = delivery.change, let from = delivery.previousUser else {
            discardAccountSwitchEvidence()
            applyAccount(delivery.change)
            return
        }
        let receipt = switchReceipt(from: from, after: delivery.predecessorID)
        if hasApplied(receipt, to: user) {
            applyAccount(.signIn(user: user))
        } else {
            // Persist the same proof whether the lookup or CKSyncEngine first applied the switch.
            applyAccount(delivery.change, receipt: receipt)
        }
    }

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
    @ObservationIgnored private var receivedSwitch = false
    @ObservationIgnored public var isLiveVaultProfile: ((UUID) -> Bool)?
    @ObservationIgnored public var accountChanged: ((SyncAccountChange) -> Void)?

    public init(
        state: SyncRouterState, persist: @escaping (SyncRouterState) -> Void,
        tabs: TabSync?, vaults: VaultSync?, additional: [any SyncZoneHandler] = []
    ) {
        self.state = state
        self.persist = persist
        handlers = additional
        vaultHandler = vaults
        if let tabs {
            routeTabs(to: tabs)
        }
    }

    private var tabs: TabSync? {
        handlers.lazy.compactMap { $0 as? TabSync }.first
    }

    public func allowsZoneCreation(_ zone: String) -> Bool {
        // A restored first-upload queue may outlive the profile that owned the zone.
        if let ids = SyncZone.vaultIDs(zone), isLiveVaultProfile?(ids.profileID) == false {
            return false
        }
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

    public func accountSwitched(from previousUser: String, to user: String) async {
        let newlyVerified = tabs.map { $0.hasApplied($0.switchReceipt(from: previousUser, after: state.tabAccountEvents.currentID), to: user) } ?? false
        state.tabAccountEvents.receive(from: previousUser, to: user, newlyVerified: newlyVerified)
        receivedSwitch = true
        persist(state)
        await route(.account(.switchAccounts(user: user))) { tabs, _ in
            self.deliverSwitch(to: tabs)
        }
    }

    private func deliverSwitch(to tabs: TabSync) {
        guard let delivery = state.tabAccountEvents.switchDelivery else { return }
        tabs.accountEventID = state.tabAccountEvents.currentID
        tabs.apply(delivery)
        state.tabAccountEvents.deliveredToTabs()
        persist(state)
    }

    private func deliverDeferred(to tabs: TabSync) {
        tabs.accountEventID = state.tabAccountEvents.currentID
        while let next = state.tabAccountEvents.deferred?.first {
            tabs.apply(next)
            state.tabAccountEvents.didDeliverFirst()
            persist(state)
        }
    }

    public func discardAccountSwitchEvidence() {
        receivedSwitch = false
        state.tabAccountEvents.retireReplay()
        if let tabs {
            deliverDeferred(to: tabs)
            tabs.discardAccountSwitchEvidence()
        }
        persist(state)
    }

    public func handle(_ event: SyncEvent) async {
        if case .account(let change) = event {
            receivedSwitch = false
            state.tabAccountEvents.retireReplay()
            state.tabAccountEvents.deferChange(change)
            persist(state)
            await route(event) { tabs, _ in self.deliverDeferred(to: tabs) }
            return
        }
        if case .state(let data) = event {
            // Only a new serialization following delivery in this engine can acknowledge the switch.
            if receivedSwitch, data != state.engineState {
                state.tabAccountEvents.checkpoint()
                tabs?.accountEventID = state.tabAccountEvents.currentID
                receivedSwitch = false
            }
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
        tabs.bindRemovalCheckpoint(state.tabRemoval) { [weak self, weak tabs] checkpoint in
            guard let self, self.tabs === tabs, state.tabRemoval != checkpoint else { return }
            state.tabRemoval = checkpoint
            persist(state)
        }
        deliverDeferred(to: tabs)
        // Apply the last switch seen by another category before this installation can replay or send.
        if state.tabAccountEvents.pending?.deliveredToTabs == false {
            deliverSwitch(to: tabs)
        }
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
