// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation
import WSurfCore

/// Maps only explicitly selected local objects to the private account catalog. A window's selected Space and tab never enter the map.
nonisolated struct SharedProfileLinks: Codable, Equatable {
    struct Slot: Codable, Equatable {
        var cloudID: UUID
        var window: UUID
        var last: SharedSpaceItem?
        var pinID: UUID?
        /// Keep a close until the window has committed a newer session without this row.
        var closedAfterRevision: Int64?
        /// A local edit captured before the window has committed its next SQLite snapshot.
        var editedAfterRevision: Int64?
    }

    var profile: UUID?
    var spaces: [UUID: UUID] = [:]
    /// Remote Space to reserved local ID until both Spaces.json and the link are committed.
    var joiningSpaces: [UUID: UUID]?
    /// A kept Space can finish its local write even after the restored record was uploaded.
    var keepingSpaces: Set<UUID>?
    var slots: [UUID: Slot] = [:]
    var pins: [UUID: UUID] = [:]
    var pinFolders: [UUID: UUID]?
    var skippedPins: Set<UUID>?
}

@Observable
final class CloudSharedSpaces {
    let catalog: SharedCatalogSync
    var onNeedsEngine: (() -> Void)?
    enum AccountVerification {
        case checking
        case resolved(String?)
    }

    private var settingsAccount: AccountVerification?
    @ObservationIgnored private var lastSettingsAccount: String?
    let windows: @MainActor () -> [BrowserModel]
    let spaces: @MainActor (Profile) -> SpaceStore?
    let pins: @MainActor (Profile) -> ProfilePinStore
    var permitsSharedInstance: ((UUID, String) -> Bool)?
    var permitsSharing: ((UUID) -> Bool)?
    var storageReadable: Bool {
        storage.readable
    }
    private let profileStore: ProfileStore?
    private let liveProfiles: @MainActor () -> [Profile]?
    var profiles: [UUID: Profile] = [:]
    var applying = false
    var links: [UUID: SharedProfileLinks] {
        didSet { storage.data.links = links }
    }

    @ObservationIgnored private let storage: SharedCatalogStorage
    @ObservationIgnored private var engine: (any SyncEngine)?
    @ObservationIgnored private var work: Task<Void, Never>?

    init(
        stateFile: URL, profiles: [Profile]? = nil, profileStore: ProfileStore? = nil, windows: @escaping @MainActor () -> [BrowserModel],
        spaces: @escaping @MainActor (Profile) -> SpaceStore? = SpaceStore.shared(for:),
        pins: @escaping @MainActor (Profile) -> ProfilePinStore = { .store(for: BrowserProfileContext.shared(for: $0).database) }
    ) {
        let store = profileStore ?? (profiles == nil ? .shared : nil)
        self.profileStore = store
        let liveProfiles: @MainActor () -> [Profile]? = {
            if let store {
                return store.verifiedProfiles
            }
            return profiles
        }
        self.liveProfiles = liveProfiles
        let initial = liveProfiles()
        let storage = SharedCatalogStorage(stateFile) { liveProfiles() != nil }
        self.storage = storage
        self.windows = windows
        self.spaces = { profile in
            guard let store = spaces(profile), store.recoverMembership() else { return nil }
            return store
        }
        self.pins = pins
        self.profiles = Self.indexed(initial ?? [])
        links = storage.data.links
        catalog = SharedCatalogSync(state: storage.data.catalog) { state in
            storage.data.catalog = state
            try storage.write()
        }
        catalog.onAccountChange = { [weak self] oldUser in
            guard let self else { return }
            if !storage.applyingOptOuts {
                storage.pendingAccountReset = UUID()
            }
            if let oldUser, !links.isEmpty {
                var paused = storage.data.pausedLinks ?? [:]
                paused[oldUser] = links
                storage.data.pausedLinks = paused
            }
            links = [:]
        }
        catalog.onVerifiedUser = { [weak self] user in
            guard let self, let parked = storage.data.pausedLinks?.removeValue(forKey: user) else { return }
            links.merge(parked) { active, _ in active }
        }
        catalog.onReceive = { [weak self] in self?.applyCatalog() }
        catalog.canUpload = { [weak self] edit in
            guard let self, permitsSharing?(edit.profile) != false, let profile = self.profiles[edit.profile], isLive(edit.profile),
                  links[edit.profile]?.profile == edit.item.profileID || links[edit.profile]?.profile == nil else { return false }
            return edit.item.category != .spaces || self.spaces(profile) != nil
        }
        restoreOptOuts()
    }

    private static func indexed(_ profiles: [Profile]) -> [UUID: Profile] {
        var result = Dictionary(profiles.filter { !$0.isPrivate }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if result[Profile.originalID] == nil {
            result[Profile.originalID] = .original()
        }
        return result
    }

    private func isLive(_ id: UUID) -> Bool {
        id == Profile.originalID || (id != Profile.privateID && liveProfiles()?.contains(where: { $0.id == id }) == true)
    }

    var needsEngine: Bool {
        catalog.needsEngine
    }

    func attach(_ engine: any SyncEngine) {
        self.engine = engine
        catalog.attach(engine)
    }

    func beat() {
        guard retryOptOuts(), needsEngine, work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            await refresh()
            work = nil
        }
    }

    func refresh() async {
        guard retryOptOuts(), needsEngine, await catalog.verifyAccount() else { return }
        for category in SharedCatalogCategory.allCases where catalog.state.enabled[category]?.isEmpty == false {
            try? await catalog.prepare(category)
        }
        guard needsEngine else { return }
        catalog.enqueue()
        try? await engine?.sendNow()
        try? await engine?.fetchNow()
    }

    func isEnabled(_ category: SharedCatalogCategory, for profile: Profile) -> Bool {
        !profile.isPrivate && permitsSharing?(profile.id) != false && catalog.enabled(category, for: profile.id)
    }

    func mayHaveSharedSpaces(in profile: Profile) -> Bool {
        !storage.readable || isEnabled(.spaces, for: profile) || links[profile.id]?.spaces.isEmpty == false
            || storage.data.pausedLinks?.values.contains { $0[profile.id]?.spaces.isEmpty == false } == true
    }

    func enable(_ category: SharedCatalogCategory, for profile: Profile) async throws {
        guard isLive(profile.id), permitsSharing?(profile.id) != false else { throw SharedCatalogError.unavailable }
        guard retryOptOuts(), storage.readable else { throw SharedCatalogError.storage }
        profiles[profile.id] = profile
        spaces(profile)?.sharedSpacesHost = self
        let resumed = !isEnabled(category, for: profile)
        catalog.setEnabled(true, category, for: profile.id)
        if resumed, let link = links[profile.id] {
            if category == .spaces, !link.spaces.isEmpty {
                for model in regularWindows(profile) {
                    capture(model)
                }
            }
            if category == .pins, !link.pins.isEmpty {
                pinsChanged(in: profile, store: pins(profile))
            }
        }
        onNeedsEngine?()
        try await catalog.prepare(category)
        guard isLive(profile.id), isEnabled(category, for: profile) else { throw SharedCatalogError.paused }
    }

    func pause(_ category: SharedCatalogCategory, for profile: Profile) {
        if catalog.enabled(category, for: profile.id) {
            storage.pending.insert(.init(category: category, profile: profile.id))
            catalog.setEnabled(false, category, for: profile.id)
        } else {
            retryOptOuts()
        }
    }

    func hasPendingOptOut(_ category: SharedCatalogCategory, for profile: Profile) -> Bool {
        storage.unreadableJournal || storage.pendingAccountReset != nil || storage.erasingProfiles.contains(profile.id)
            || storage.pending.contains { $0.profile == profile.id && $0.category == category }
    }

    func forgetProfile(_ id: UUID) throws {
        if !storage.readable {
            try storage.requestProfileRemoval(id)
            guard retryOptOuts() else { throw SharedCatalogError.storage }
        }
        let prior = storage.data
        let needsRetry = storage.hasOptOuts || !catalog.storageAvailable
        storage.applyingOptOuts = true
        discardProfile(id)
        storage.applyingOptOuts = false
        if storage.data != prior {
            try storage.requestProfileRemoval(id)
        } else if !needsRetry {
            return
        }
        guard catalog.persistLocalState() else { throw SharedCatalogError.storage }
    }

    private func discardProfile(_ id: UUID) {
        profiles[id] = nil
        links[id] = nil
        storage.data.pausedLinks = storage.data.pausedLinks?.mapValues { parked in
            parked.filter { $0.key != id }
        }
        for category in SharedCatalogCategory.allCases {
            catalog.setEnabled(false, category, for: id)
        }
        catalog.discardEdits(for: id)
    }

    /// The last category can be turned off while offline, before an engine exists.
    @discardableResult
    func retryOptOuts() -> Bool {
        if storage.needsReload {
            guard storage.reload() else { return false }
            links = storage.data.links
            catalog.recoverLocalCheckpoint(storage.data.catalog)
            restoreOptOuts()
            if needsEngine {
                onNeedsEngine?()
            }
        } else if storage.hasOptOuts || !catalog.storageAvailable {
            catalog.persistLocalState()
        }
        return catalog.storageAvailable
    }

    private func restoreOptOuts() {
        if storage.readable, let current = liveProfiles() {
            profiles = Self.indexed(current)
            storage.reconcileProfiles(with: Set(profiles.keys))
        }
        guard storage.hasOptOuts || !storage.readable || !catalog.storageAvailable else { return }
        // Apply every choice before the first write can retire the journal or offer an upload.
        if storage.readable {
            storage.applyingOptOuts = true
            for choice in storage.pending {
                if let id = choice.item {
                    if choice.category == .spaces {
                        stopSharingSpace(id, in: choice.profile)
                    } else if choice.category == .pins {
                        stopSharingPin(id, profileID: choice.profile)
                    }
                } else {
                    catalog.setEnabled(false, choice.category, for: choice.profile)
                }
            }
            for id in storage.erasingProfiles {
                discardProfile(id)
            }
            if storage.pendingAccountReset != nil {
                catalog.resetAccount(to: nil)
            }
            storage.applyingOptOuts = false
        }
        catalog.persistLocalState()
    }

    /// The signed Settings monitor also observes sign-out while every catalog category is off.
    func accountVerificationChanged(_ result: AccountVerification) {
        settingsAccount = result
        guard case .resolved(let user) = result else { return }
        let prior = storage.readable ? catalog.state.user : lastSettingsAccount
        lastSettingsAccount = user
        if (prior != nil && prior != user) || (!storage.readable && user == nil) {
            catalog.resetAccount(to: user)
        }
    }

    func cloudProfileID(for localID: UUID) -> UUID? {
        let account: String?
        if !needsEngine, let settingsAccount {
            switch settingsAccount {
            case .checking:
                account = nil
            case .resolved(let user):
                account = user
            }
        } else {
            account = catalog.trustedUser
        }
        guard let account, account == catalog.state.user else { return nil }
        return links[localID]?.profile
    }

    @discardableResult
    func linkProfile(_ localID: UUID, to cloudID: UUID) -> Bool {
        guard isLive(localID), permitsSharing?(localID) != false, cloudID != Profile.privateID, profiles[localID] != nil, catalog.trustedUser != nil,
              catalog.trustedUser == catalog.state.user,
              links[localID]?.profile == nil || links[localID]?.profile == cloudID,
              !links.contains(where: { $0.key != localID && $0.value.profile == cloudID }) else { return false }
        guard let user = catalog.trustedUser, permitsSharedInstance?(cloudID, user) != false else { return false }
        links[localID, default: .init()].profile = cloudID
        return persistLinks()
    }

    /// Spaces and pins need a shared profile ID. Publishing the profile's name is a separate choice.
    private func linkedProfileID(for profile: Profile) throws -> UUID {
        guard let owner = catalog.trustedUser else { throw SharedCatalogError.unavailable }
        let id = cloudProfileID(for: profile.id) ?? profileStore?.cloudLedger.active[profile.id]?[owner] ?? UUID()
        guard linkProfile(profile.id, to: id) else { throw SharedCatalogError.storage }
        return id
    }

    @discardableResult
    func publishProfile(_ profile: Profile) async throws -> UUID {
        try await enable(.profiles, for: profile)
        let id = try linkedProfileID(for: profile)
        if catalog.item(id, in: .profiles) == nil {
            catalog.stage(.init(id: id, kind: .profile, profileID: id, title: profile.name), for: profile.id)
        }
        return id
    }

    func available(_ category: SharedCatalogCategory, for profile: Profile) -> [SharedSpaceItem] {
        guard isEnabled(category, for: profile), catalog.ready.contains(category), let user = catalog.trustedUser else { return [] }
        let linked = cloudProfileID(for: profile.id)
        return catalog.items(category).filter {
            !$0.removed && permitsSharedInstance?($0.profileID, user) != false && (category == .profiles || linked == nil || $0.profileID == linked)
        }.sorted {
            ($0.title.localizedLowercase, $0.id.uuidString) < ($1.title.localizedLowercase, $1.id.uuidString)
        }
    }

    func availableSpaces(for profile: Profile) -> [SharedSpaceItem] {
        let candidates = available(.spaces, for: profile).filter { $0.kind == .space }
        guard !candidates.isEmpty, let linked = links[profile.id]?.spaces else { return candidates }
        let joined = Set(spaces(profile)?.spaces.compactMap { linked[$0.id] } ?? [])
        return candidates.filter { !joined.contains($0.id) }
    }

    func availablePins(for profile: Profile) -> [SharedSpaceItem] {
        available(.pins, for: profile).filter { $0.kind == .pin && links[profile.id]?.pins.values.contains($0.id) != true }
    }

    func share(_ space: Space, in profile: Profile) async throws {
        try await enable(.spaces, for: profile)
        if let pending = links[profile.id]?.joiningSpaces?.first(where: { $0.value == space.id })?.key {
            if let item = catalog.item(pending, in: .spaces), !item.removed {
                try await join(item, in: profile)
                return
            }
            links[profile.id]?.joiningSpaces?[pending] = nil
        }
        let group = try linkedProfileID(for: profile)
        guard spaces(profile)?.space(id: space.id) != nil else { throw SharedCatalogError.unavailable }
        let sharedID = links[profile.id]?.spaces[space.id] ?? UUID()
        links[profile.id, default: .init()].spaces[space.id] = sharedID
        guard persistLinks() else { throw SharedCatalogError.storage }
        catalog.stage(Self.spaceItem(space, id: sharedID, profile: group), for: profile.id)
        for model in regularWindows(profile) {
            capture(model)
        }
    }

    func join(_ remote: SharedSpaceItem, in profile: Profile) async throws {
        try await enable(.spaces, for: profile)
        guard let item = catalog.item(remote.id, in: .spaces), item.kind == .space, !item.removed,
              let store = spaces(profile) else { throw SharedCatalogError.unavailable }
        guard linkProfile(profile.id, to: item.profileID) else { throw SharedCatalogError.unavailable }
        try materializeJoinedSpace(item, in: profile, store: store)
        applyCatalog()
    }

    /// Reserve the local identity before Spaces.json so either write can be retried after a restart.
    func materializeJoinedSpace(_ item: SharedSpaceItem, in profile: Profile, store: SpaceStore, keepingVersion: Bool = false) throws {
        guard var link = links[profile.id], link.profile == item.profileID else { throw SharedCatalogError.unavailable }
        let linked = link.spaces.first { $0.value == item.id }?.key
        let local = linked ?? link.joiningSpaces?[item.id] ?? UUID()
        if linked == nil {
            var joining = link.joiningSpaces ?? [:]
            joining[item.id] = local
            link.joiningSpaces = joining
            if keepingVersion {
                link.keepingSpaces = (link.keepingSpaces ?? []).union([item.id])
            }
            if link != links[profile.id] {
                links[profile.id] = link
            }
            guard persistLinks() else { throw SharedCatalogError.storage }
        }
        try store.ensureJoinedSpace(id: local, name: item.title, symbol: item.symbol ?? Space.defaultSymbol, color: item.color.flatMap(TabFolderColor.init))
        if linked == nil {
            let pending = link
            link.spaces[local] = item.id
            link.joiningSpaces?[item.id] = nil
            link.keepingSpaces?.remove(item.id)
            links[profile.id] = link
            guard persistLinks() else {
                links[profile.id] = pending
                throw SharedCatalogError.storage
            }
        }
    }

    /// Leaves the local and cloud copies intact. Rejoining is an explicit choice.
    func stopSharing(_ space: Space, in profile: Profile) {
        stopSharingSpace(space.id, in: profile.id)
    }

    private func stopSharingSpace(_ localID: UUID, in profileID: UUID) {
        guard let sharedID = links[profileID]?.spaces.removeValue(forKey: localID) else { return }
        storage.pending.insert(.init(category: .spaces, profile: profileID, item: localID))
        let slots = links[profileID]?.slots.filter { $0.value.last?.spaceID == sharedID } ?? [:]
        for id in slots.keys {
            links[profileID]?.slots[id] = nil
        }
        catalog.discardPending(for: profileID, ids: Set(slots.values.map(\.cloudID) + [sharedID]), category: .spaces)
    }

    func selectPin(_ id: UUID, in profile: Profile) async throws {
        try await enable(.pins, for: profile)
        let group = try linkedProfileID(for: profile)
        guard let pin = pins(profile).pins.first(where: { $0.id == id && $0.kind == .tab }) else { throw SharedCatalogError.unavailable }
        let cloudID = links[profile.id]?.pins[id] ?? (catalog.item(id, in: .pins) == nil ? id : UUID())
        guard var value = Self.pinItem(pin, id: cloudID, profile: group) else { throw SharedCatalogError.unavailable }
        value.sharedTabID = links[profile.id]?.slots.values.first { $0.pinID == id }?.cloudID
        links[profile.id]?.skippedPins?.remove(cloudID)
        links[profile.id, default: .init()].pins[id] = cloudID
        guard persistLinks() else { throw SharedCatalogError.storage }
        catalog.stage(value, for: profile.id)
        pinsChanged(in: profile, store: pins(profile))
    }

    func joinPin(_ remote: SharedSpaceItem, in profile: Profile) async throws {
        try await enable(.pins, for: profile)
        guard let item = catalog.item(remote.id, in: .pins), item.kind == .pin, !item.removed else { throw SharedCatalogError.unavailable }
        guard linkProfile(profile.id, to: item.profileID) else { throw SharedCatalogError.unavailable }
        guard links[profile.id]?.pins.values.contains(item.id) != true else { return }
        let store = pins(profile)
        guard store.isAvailable else { throw SharedCatalogError.unavailable }
        let id = store.pins.contains { $0.id == item.id } ? UUID() : item.id
        links[profile.id]?.skippedPins?.remove(item.id)
        links[profile.id, default: .init()].pins[id] = item.id
        guard persistLinks() else { throw SharedCatalogError.storage }
        applyCatalog()
    }

    func stopSharingPin(_ id: UUID, in profile: Profile) {
        stopSharingPin(id, profileID: profile.id)
    }

    private func stopSharingPin(_ id: UUID, profileID: UUID) {
        guard var link = links[profileID], let cloudID = link.pins.removeValue(forKey: id) else { return }
        storage.pending.insert(.init(category: .pins, profile: profileID, item: id))
        var skipped = link.skippedPins ?? []
        skipped.insert(cloudID)
        link.skippedPins = skipped
        links[profileID] = link
        var unused = Set((link.pinFolders ?? [:]).values)
        for id in link.pins.values {
            var parent = catalog.item(id, in: .pins)?.parentID
            while let folder = parent, unused.remove(folder) != nil {
                parent = catalog.item(folder, in: .pins)?.parentID
            }
        }
        unused.insert(cloudID)
        catalog.discardPending(for: profileID, ids: unused, category: .pins)
    }

    func regularWindows(_ profile: Profile) -> [BrowserModel] {
        windows().filter { !$0.opensPrivately && $0.context.profile.id == profile.id && $0.sessionClosedAt == nil && $0.windowKind == .standard }
    }

    @discardableResult
    func persistLinks() -> Bool {
        catalog.persistLocalState()
    }
}
