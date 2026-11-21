// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSync {
    func configureProfileInstances(_ store: ProfileStore) {
        let permits: (UUID) -> Bool = { [weak self] in self?.permitsSharing($0) == true }
        sharedSpaces?.permitsSharedInstance = { [weak self] id, owner in
            self?.verifiedRetirements.contains(.init(.shared, id: id, owner: owner)) == false
        }
        sharedSpaces?.permitsSharing = permits
        settingsSync?.permitsSharing = permits
        router.beforeVaultDelivery = { [weak self] in await self?.checkProfileInstances() }
        router.beforeUpload = { [weak self] in await self?.checkProfileInstances() }
        configureVaultInstances(vaults, store: store)
    }

    func configureVaultInstances(_ sync: VaultSync?, store: ProfileStore) {
        sync?.permitsProfile = { [weak self] in self?.permitsSharing($0) == true }
        sync?.isRetired = { [weak self] copy in self?.verifiedRetirements.contains(copy) == true }
        sync?.profileInstance = { id, user in
            store.cloudLedger.active[id]?[user]
        }
        sync?.adoptInstance = { [weak self] profile, instance, owner in
            guard let self, store.verifiedProfiles?.contains(where: { $0.id == profile && !$0.isOriginal && !$0.isPrivate }) == true,
                  store.cloudLedger.pending[profile] == nil, store.cloudLedger.active[profile]?[owner] == nil,
                  vaults?.enrolledProfileInstances(owner: owner)[profile] == nil else { throw VaultSyncFailure.unavailable }
            try store.updateCloudLedger { $0.active[profile, default: [:]][owner] = instance }
        }
        sync?.checkInstance = { [weak self] profile, user in
            guard let self else { throw VaultSyncFailure.unavailable }
            try await checkEnrollment(profile, owner: user)
        }
    }

    func permitsSharing(_ local: UUID) -> Bool {
        guard let store = profileStore, local != Profile.originalID else { return true }
        return local != Profile.privateID && store.cloudLedger.pending[local] == nil && !unverifiedInstances.contains(local)
    }

    func refreshDormantInstances(_ store: ProfileStore) {
        guard let profiles = store.verifiedProfiles else { return }
        dormantVaultInstances = profiles.reduce(into: [:]) { known, profile in
            guard !profile.isOriginal, !profile.isPrivate,
                  let copies = try? VaultProfileRemoval.memberships(in: profile.supportDirectory, profileID: profile.id), !copies.isEmpty else { return }
            known[profile.id] = copies
        }
    }

    private func memberships(_ profile: UUID, owner: String?, vaults enrolled: [UUID: CloudProfileInstance]) -> Set<CloudProfileInstance> {
        var result = settingsSync?.memberships(of: profile) ?? []
        if let copy = sharedSpaces?.membership(of: profile) {
            result.insert(copy)
        }
        if let copy = enrolled[profile] {
            result.insert(copy)
        }
        if vaults == nil {
            for row in dormantVaultInstances[profile] ?? [] {
                // An offline or locked vault can still carry its previous zone until the next authorized upload.
                let current = profileStore?.cloudLedger.active[profile]?[row.owner]
                result.insert(current.map { .vault(profile: profile, instance: $0, owner: row.owner) } ?? row)
            }
        }
        return result.filter { owner == nil || $0.owner == owner }
    }

    private func checkEnrollment(_ profile: UUID, owner: String) async throws {
        guard profile != Profile.originalID else { return }
        guard let store = profileStore, store.verifiedProfiles?.contains(where: { $0.id == profile && !$0.isPrivate }) == true,
              store.cloudLedger.pending[profile] == nil, let transport = engine as? any CloudProfileRetirementTransport else { throw VaultSyncFailure.unavailable }
        let generation = store.cloudLedger.active[profile]?[owner]
        let copy = CloudProfileInstance.vault(profile: profile, instance: generation, owner: owner)
        let retired = try await transport.isRetired(copy)
        guard store.cloudLedger.active[profile]?[owner] == generation, store.verifiedProfiles?.contains(where: { $0.id == profile }) == true else {
            throw VaultSyncFailure.unavailable
        }
        if retired {
            try hold(profile, for: copy)
            throw VaultSyncFailure.unavailable
        }
        guard permitsSharing(profile) else { throw VaultSyncFailure.unavailable }
    }

    private func hold(_ profile: UUID, for copy: CloudProfileInstance) throws {
        guard let store = profileStore, store.cloudLedger.pending[profile] == nil else { return }
        unverifiedInstances.insert(profile)
        vaults?.invalidateProfileSession(profile)
        try store.updateCloudLedger { $0.pending[profile] = copy }
    }

    /// Positive evidence in the owner's private database is independent of vault-zone absence and of the shared incremental cursor.
    func checkProfileInstances() async {
        guard let store = profileStore, let profiles = store.verifiedProfiles, let transport = engine as? any CloudProfileRetirementTransport else { return }
        let participants = profiles.filter { !$0.isPrivate && !$0.isOriginal }
        let discovery = vaults != nil || sharedSpaces?.catalog.needsEngine == true
        guard !participants.isEmpty || discovery else { return }
        let user = try? await transport.currentAccountUser()
        let enrolled = (user ?? vaults?.state.accountUser).flatMap { vaults?.enrolledProfileInstances(owner: $0) } ?? [:]
        let memberships = participants.map { ($0, self.memberships($0.id, owner: user, vaults: enrolled)) }
        guard let user else {
            unverifiedInstances.formUnion(memberships.filter { !$0.1.isEmpty }.map { $0.0.id })
            return
        }
        guard discovery || memberships.contains(where: { !$0.1.isEmpty }) || !store.cloudLedger.pending.isEmpty else {
            unverifiedInstances.subtract(participants.map(\.id))
            return
        }
        do {
            let retired: Set<CloudProfileInstance>
            if discovery {
                retired = try await transport.retirements(for: user)
            } else {
                var found: Set<CloudProfileInstance> = []
                for copy in Set(memberships.flatMap(\.1)) where try await transport.isRetired(copy) {
                    found.insert(copy)
                }
                retired = found
            }
            guard try await transport.currentAccountUser() == user else { throw VaultSyncFailure.unavailable }
            verifiedRetirements.formUnion(retired)
            let current = vaults?.enrolledProfileInstances(owner: user) ?? [:]
            for (profile, started) in memberships {
                let id = profile.id
                guard store.verifiedProfiles?.contains(where: { $0.id == id }) == true else { continue }
                if let next = store.cloudLedger.creating[id], next.owner == user {
                    try finishNewInstance(profile: profile, next: next)
                } else if store.cloudLedger.pending[id] == nil {
                    let live = self.memberships(id, owner: user, vaults: current)
                    if let proof = started.intersection(live).intersection(verifiedRetirements).first {
                        try hold(id, for: proof)
                    } else {
                        unverifiedInstances.remove(id)
                    }
                }
            }
        } catch {
            unverifiedInstances.formUnion(memberships.filter { !$0.1.isEmpty }.map { $0.0.id })
        }
    }

    func verifyDecision(_ copy: CloudProfileInstance, profile: UUID) async throws {
        guard let store = profileStore, let transport = engine as? any CloudProfileRetirementTransport,
              store.cloudLedger.pending[profile] == copy else { throw VaultSyncFailure.unavailable }
        try await copy.verify(using: transport)
        let belongs: Bool
        switch copy.kind {
        case .vaults:
            belongs = store.cloudLedger.active[profile]?[copy.owner] == nil && profile == copy.id
        case .shared:
            belongs = sharedSpaces?.hasLink(profile, to: copy) == true || settingsSync?.memberships(of: profile).contains(copy) == true
                || store.cloudLedger.active[profile]?[copy.owner] == copy.id || store.cloudLedger.detached[profile]?.contains(copy) == true
        }
        guard belongs, store.cloudLedger.pending[profile] == copy, store.verifiedProfiles?.contains(where: { $0.id == profile && !$0.isOriginal && !$0.isPrivate }) == true else {
            throw VaultSyncFailure.unavailable
        }
    }

    func createNewInstance(of profile: Profile, retiring old: CloudProfileInstance) async throws {
        try await verifyDecision(old, profile: profile.id)
        guard let store = profileStore else { throw VaultSyncFailure.unavailable }
        let next = store.cloudLedger.creating[profile.id] ?? CloudProfileInstance(.shared, id: UUID(), owner: old.owner)
        try store.updateCloudLedger { $0.creating[profile.id] = next }
        try finishNewInstance(profile: profile, next: next)
        beat()
    }

    private func finishNewInstance(profile: Profile, next: CloudProfileInstance) throws {
        guard let store = profileStore, store.cloudLedger.creating[profile.id] == next else { return }
        // Each participant commits one local checkpoint. A restart reuses the same new ID and repeats only unfinished work.
        try sharedSpaces?.replaceInstance(for: profile, with: next)
        try settingsSync?.replaceInstance(for: profile.id, with: next)
        try store.updateCloudLedger {
            $0.active[profile.id, default: [:]][next.owner] = next.id
            $0.creating[profile.id] = nil
            $0.detached[profile.id] = nil
            $0.pending[profile.id] = nil
        }
        unverifiedInstances.remove(profile.id)
        vaults?.invalidateProfileSession(profile.id)
    }

    func sendRetirements(_ store: ProfileStore, transport: any CloudProfileRetirementTransport) {
        for copy in store.cloudLedger.outgoing where sendingRetirements.insert(copy).inserted {
            Task {
                defer { sendingRetirements.remove(copy) }
                do {
                    try await transport.publishRetirement(copy)
                    try store.updateCloudLedger { $0.outgoing.remove(copy) }
                    ensureEngine()
                } catch {
                    // The atomic profile-list checkpoint retains the intended owner and publication for the next heartbeat.
                }
            }
        }
    }
}
