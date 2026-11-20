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
    }

    var profile: UUID?
    var spaces: [UUID: UUID] = [:]
    var slots: [UUID: Slot] = [:]
    var pins: [UUID: UUID] = [:]
    var pinFolders: [UUID: UUID]?
    var skippedPins: Set<UUID>?
}

@Observable
final class CloudSharedSpaces {
    let catalog: SharedCatalogSync
    var onNeedsEngine: (() -> Void)?
    let windows: @MainActor () -> [BrowserModel]
    let spaces: @MainActor (Profile) -> SpaceStore?
    let pins: @MainActor (Profile) -> ProfilePinStore
    var profiles: [UUID: Profile] = [:]
    var applying = false
    var links: [UUID: SharedProfileLinks] {
        didSet { storage.data.links = links }
    }

    private final class Storage {
        struct State: Codable, Equatable {
            var catalog = SharedCatalogState()
            var links: [UUID: SharedProfileLinks] = [:]
            var pausedLinks: [String: [UUID: SharedProfileLinks]]?
        }

        let url: URL
        var data: State
        let readable: Bool
        private var written: State?

        init(_ file: URL) {
            url = file
            do {
                data = try JSONDecoder().decode(State.self, from: Data(contentsOf: file))
                written = data
                readable = true
            } catch {
                data = State()
                readable = !FileManager.default.fileExists(atPath: file.path)
            }
        }

        func write() throws {
            guard readable else { throw SharedCatalogError.storage }
            guard written != data else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(data).write(to: url, options: .atomic)
            written = data
        }
    }

    @ObservationIgnored private let storage: Storage
    @ObservationIgnored private var engine: (any SyncEngine)?
    @ObservationIgnored private var work: Task<Void, Never>?

    init(
        stateFile: URL, profiles: [Profile] = [], windows: @escaping @MainActor () -> [BrowserModel],
        spaces: @escaping @MainActor (Profile) -> SpaceStore? = SpaceStore.shared(for:),
        pins: @escaping @MainActor (Profile) -> ProfilePinStore = { .store(for: BrowserProfileContext.shared(for: $0).database) }
    ) {
        let storage = Storage(stateFile)
        self.storage = storage
        self.windows = windows
        self.spaces = spaces
        self.pins = pins
        self.profiles = Dictionary(profiles.filter { !$0.isPrivate }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        links = storage.data.links
        catalog = SharedCatalogSync(state: storage.data.catalog) { state in
            storage.data.catalog = state
            try storage.write()
        }
        catalog.onAccountChange = { [weak self] oldUser in
            guard let self else { return }
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
    }

    var needsEngine: Bool {
        catalog.needsEngine
    }

    func attach(_ engine: any SyncEngine) {
        self.engine = engine
        catalog.attach(engine)
    }

    func beat() {
        guard needsEngine, work == nil else { return }
        work = Task { [weak self] in
            guard let self else { return }
            await refresh()
            work = nil
        }
    }

    func refresh() async {
        guard needsEngine, await catalog.verifyAccount() else { return }
        for category in SharedCatalogCategory.allCases where catalog.state.enabled[category]?.isEmpty == false {
            try? await catalog.prepare(category)
        }
        guard needsEngine else { return }
        catalog.enqueue()
        try? await engine?.sendNow()
        try? await engine?.fetchNow()
    }

    func isEnabled(_ category: SharedCatalogCategory, for profile: Profile) -> Bool {
        !profile.isPrivate && catalog.enabled(category, for: profile.id)
    }

    func enable(_ category: SharedCatalogCategory, for profile: Profile) async throws {
        guard !profile.isPrivate, storage.readable else { throw SharedCatalogError.unavailable }
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
    }

    func pause(_ category: SharedCatalogCategory, for profile: Profile) {
        catalog.setEnabled(false, category, for: profile.id)
    }

    func cloudProfileID(for localID: UUID) -> UUID? {
        guard catalog.trustedUser != nil, catalog.trustedUser == catalog.state.user else { return nil }
        return links[localID]?.profile
    }

    @discardableResult
    func linkProfile(_ localID: UUID, to cloudID: UUID) -> Bool {
        guard localID != Profile.privateID, cloudID != Profile.privateID, catalog.trustedUser != nil,
              catalog.trustedUser == catalog.state.user,
              links[localID]?.profile == nil || links[localID]?.profile == cloudID,
              !links.contains(where: { $0.key != localID && $0.value.profile == cloudID }) else { return false }
        links[localID, default: .init()].profile = cloudID
        return persistLinks()
    }

    @discardableResult
    func publishProfile(_ profile: Profile) async throws -> UUID {
        try await enable(.profiles, for: profile)
        let id = cloudProfileID(for: profile.id) ?? UUID()
        guard linkProfile(profile.id, to: id) else { throw SharedCatalogError.storage }
        if catalog.item(id, in: .profiles) == nil {
            catalog.stage(.init(id: id, kind: .profile, profileID: id, title: profile.name), for: profile.id)
        }
        return id
    }

    func available(_ category: SharedCatalogCategory, for profile: Profile) -> [SharedSpaceItem] {
        guard isEnabled(category, for: profile), catalog.ready.contains(category) else { return [] }
        let linked = cloudProfileID(for: profile.id)
        return catalog.items(category).filter { !$0.removed && (category == .profiles || linked == nil || $0.profileID == linked) }.sorted {
            ($0.title.localizedLowercase, $0.id.uuidString) < ($1.title.localizedLowercase, $1.id.uuidString)
        }
    }

    func availableSpaces(for profile: Profile) -> [SharedSpaceItem] {
        available(.spaces, for: profile).filter { $0.kind == .space && links[profile.id]?.spaces.values.contains($0.id) != true }
    }

    func availablePins(for profile: Profile) -> [SharedSpaceItem] {
        available(.pins, for: profile).filter { $0.kind == .pin && links[profile.id]?.pins.values.contains($0.id) != true }
    }

    func share(_ space: Space, in profile: Profile) async throws {
        try await enable(.spaces, for: profile)
        let group = try await publishProfile(profile)
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
        guard links[profile.id]?.spaces.values.contains(item.id) != true else { return }
        let local = store.add(name: item.title, symbol: item.symbol ?? Space.defaultSymbol, color: .init(rawValue: item.color ?? ""))
        links[profile.id, default: .init()].spaces[local.id] = item.id
        guard persistLinks() else { throw SharedCatalogError.storage }
        applyCatalog()
    }

    /// Leaves the local and cloud copies intact. Rejoining is an explicit choice.
    func stopSharing(_ space: Space, in profile: Profile) {
        guard let sharedID = links[profile.id]?.spaces.removeValue(forKey: space.id) else { return }
        let slots = links[profile.id]?.slots.filter { $0.value.last?.spaceID == sharedID } ?? [:]
        for id in slots.keys {
            links[profile.id]?.slots[id] = nil
        }
        catalog.discardPending(for: profile.id, ids: Set(slots.values.map(\.cloudID) + [sharedID]), category: .spaces)
        persistLinks()
    }

    func selectPin(_ id: UUID, in profile: Profile) async throws {
        try await enable(.pins, for: profile)
        let group = try await publishProfile(profile)
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
        guard let cloudID = links[profile.id]?.pins.removeValue(forKey: id) else { return }
        var skipped = links[profile.id]?.skippedPins ?? []
        skipped.insert(cloudID)
        links[profile.id]?.skippedPins = skipped
        catalog.discardPending(for: profile.id, ids: [cloudID], category: .pins)
        persistLinks()
    }

    func regularWindows(_ profile: Profile) -> [BrowserModel] {
        windows().filter { !$0.opensPrivately && $0.context.profile.id == profile.id && $0.sessionClosedAt == nil && $0.windowKind == .standard }
    }

    @discardableResult
    func persistLinks() -> Bool {
        do { try storage.write(); return true } catch { return false }
    }
}
