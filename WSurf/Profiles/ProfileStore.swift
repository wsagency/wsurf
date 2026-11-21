// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ProfileStore {
    static let shared = ProfileStore()

    @ObservationIgnored private var catalog: ProfileStore?
    private enum ListStatus { case loaded, missing, unreadable }
    @ObservationIgnored private var listStatus = ListStatus.loaded
    private var storedProfiles: [Profile]
    private(set) var profiles: [Profile] {
        get { catalog?.profiles ?? storedProfiles }
        set {
            if let catalog {
                catalog.profiles = newValue
            } else {
                storedProfiles = newValue
            }
        }
    }

    static func selection(profile: Profile, catalog: ProfileStore = .shared) -> ProfileStore {
        let selection = ProfileStore(file: catalog.file)
        selection.catalog = catalog
        selection.markCurrent(profile)
        return selection
    }

    private(set) var currentID: UUID
    private let file: URL
    let privateBrowsing = Profile.privateBrowsing()
    private(set) var lastPersistentID: UUID

    private var storedLaunchProfileID: UUID?
    private(set) var launchProfileID: UUID? {
        get {
            if let catalog {
                return catalog.launchProfileID
            }
            return storedLaunchProfileID
        }
        set {
            if let catalog {
                catalog.launchProfileID = newValue
            } else {
                storedLaunchProfileID = newValue
            }
        }
    }

    private var storedLastUsed: [UUID: Date] = [:]
    private(set) var lastUsed: [UUID: Date] {
        get { catalog?.lastUsed ?? storedLastUsed }
        set {
            if let catalog {
                catalog.lastUsed = newValue
            } else {
                storedLastUsed = newValue
            }
        }
    }

    var current: Profile {
        if currentID == Profile.privateID {
            return privateBrowsing
        }
        return profiles.first { $0.id == currentID } ?? profiles[0]
    }

    var isPrivate: Bool {
        currentID == Profile.privateID
    }

    var profileToReturnTo: Profile {
        profiles.first { $0.id == lastPersistentID } ?? profiles[0]
    }

    var passwordsProfile: Profile {
        isPrivate ? profileToReturnTo : current
    }

    var hasMultiple: Bool {
        profiles.count > 1
    }

    init(file: URL? = nil) {
        self.file = file ?? Self.defaultFile
        let stored: Stored?
        do {
            stored = try Self.read(self.file)
        } catch CocoaError.fileReadNoSuchFile {
            stored = nil
            listStatus = .missing
        } catch {
            stored = nil
            listStatus = .unreadable
        }
        let loaded = Self.includingPersonal(stored?.profiles ?? [])
        storedProfiles = loaded
        let remembered = stored.map(\.currentID).flatMap { id in
            loaded.contains { $0.id == id } ? id : nil
        }
        let pinned = stored?.launchProfileID.flatMap { id in
            loaded.contains { $0.id == id } ? id : nil
        }
        let opening = pinned ?? remembered ?? Profile.originalID
        storedLaunchProfileID = pinned
        currentID = opening
        lastPersistentID = opening
        storedLastUsed = (stored?.lastUsed ?? [:]).filter { id, _ in loaded.contains { $0.id == id } }
    }

    /// The Personal fallback after an I/O failure cannot establish that a named profile was erased.
    var verifiedProfiles: [Profile]? {
        if let catalog {
            return catalog.verifiedProfiles
        }
        if listStatus != .loaded {
            var saved: Stored
            do {
                saved = try Self.read(file)
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            } catch {
                listStatus = .unreadable
                return nil
            }
            let restored = Self.includingPersonal(saved.profiles)
            let ids = Set(restored.map(\.id))
            let added = storedProfiles.filter { !ids.contains($0.id) }
            saved.profiles = restored + added
            saved.lastUsed = (saved.lastUsed ?? [:]).merging(storedLastUsed) { _, live in live }
            saved.launchProfileID = storedLaunchProfileID ?? saved.launchProfileID.flatMap { ids.contains($0) ? $0 : nil }
            // Commit profiles explicitly added during the outage before sync can use their identities.
            if !added.isEmpty {
                do {
                    try JSONFileStore.writeAtomically(saved, to: file, sortedKeys: true)
                } catch {
                    return nil
                }
            }
            storedProfiles = saved.profiles
            storedLastUsed = saved.lastUsed ?? [:]
            storedLaunchProfileID = saved.launchProfileID
            listStatus = .loaded
        }
        return storedProfiles
    }

    private static func read(_ file: URL) throws -> Stored {
        try JSONDecoder().decode(Stored.self, from: Data(contentsOf: file))
    }

    /// A new installation can create its first list. Existing local owners require the original list before a window may replace it.
    private static func hasNamedProfileHistory(beside file: URL) -> Bool {
        let directory = file.deletingLastPathComponent()
        func existing<T>(_ name: String, read: (URL) throws -> T) throws -> T? {
            do {
                return try read(directory.appending(path: name))
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            }
        }
        do {
            let folders = try existing("Profiles") { try FileManager.default.contentsOfDirectory(atPath: $0.path) }
            if folders?.contains(where: { UUID(uuidString: $0) != nil }) == true {
                return true
            }
            let settings = try existing("iCloudMacSettings.json", read: CloudSettingsSync.State.read(from:))
            if settings?.channels.values.compactMap(\.localProfileID).contains(where: { $0 != Profile.originalID }) == true {
                return true
            }
            let catalog = try existing("iCloudSharedSpaces.json") { try JSONDecoder().decode(SharedCatalogStorage.State.self, from: Data(contentsOf: $0)) }
            return catalog?.localProfileIDs.contains(where: { $0 != Profile.originalID }) == true
        } catch {
            return true
        }
    }

    private static func includingPersonal(_ profiles: [Profile]) -> [Profile] {
        profiles.contains(where: \.isOriginal) ? profiles : [.original()] + profiles
    }

    @discardableResult
    func add(name: String, symbol: String = "person", color: TabFolderColor = .gray) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Profile(
            id: UUID(),
            name: trimmed.isEmpty ? String(localized: "New Profile") : trimmed,
            symbol: symbol,
            color: color
        )
        profiles.append(profile)
        save()
        return profile
    }

    /// Adds the profile another Mac synced, under the same ID, so its synced vaults open here. Nil for the built-in profiles and for an
    /// ID that is already a profile. The name is cut to the length the sync record allows, and a symbol or color this Mac does not
    /// know becomes the default.
    @discardableResult
    func adopt(id: UUID, name: String, symbol: String, color: TabFolderColor) -> Profile? {
        guard id != Profile.originalID, id != Profile.privateID, !profiles.contains(where: { $0.id == id }) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
        let profile = Profile(
            id: id,
            name: trimmed.isEmpty ? String(localized: "New Profile") : String(trimmed.prefix(64)),
            symbol: known ? symbol : "person",
            color: color
        )
        profiles.append(profile)
        save()
        return profile
    }

    func rename(_ profile: Profile, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: profile) else { return }
        profiles[index].name = trimmed
        save()
    }

    func setAppearance(of profile: Profile, symbol: String, color: TabFolderColor) {
        guard let index = index(of: profile) else { return }
        profiles[index].symbol = symbol
        profiles[index].color = color
        save()
    }

    func move(_ profile: Profile, to destination: Int) {
        guard let index = index(of: profile) else { return }
        let bounded = min(max(destination, 0), profiles.count - 1)
        guard bounded != index else { return }
        let moved = profiles.remove(at: index)
        profiles.insert(moved, at: bounded)
        save()
    }

    func setLaunchProfile(_ id: UUID?) {
        let resolved = id.flatMap { candidate in profiles.contains { $0.id == candidate } ? candidate : nil }
        guard resolved != launchProfileID else { return }
        launchProfileID = resolved
        save()
    }

    var deletableProfiles: [Profile] {
        profiles.filter { !$0.isOriginal }
    }

    @discardableResult
    func remove(
        _ profile: Profile, beforeErasing: () async -> Void = {},
        releaseWindows: () async -> Void = {},
        settingsSync: CloudSettingsSync? = CloudSync.shared?.settingsSync,
        sharedSpaces: CloudSharedSpaces? = CloudSync.shared?.sharedSpaces,
        eraseData: (Profile) async -> Void = Profile.erase
    ) async -> Result<Void, Error> {
        guard !profile.isOriginal, !profile.isPrivate else { return .success(()) }
        guard let live = verifiedProfiles else { return .failure(CocoaError(.fileReadUnknown)) }
        guard live.contains(where: { $0.id == profile.id }) else { return .success(()) }
        // An installation without a running iCloud service can still have consent saved by a prior launch.
        let sharedSpaces = sharedSpaces ?? CloudSharedSpaces(
            stateFile: file.deletingLastPathComponent().appending(path: "iCloudSharedSpaces.json"), profileStore: self, windows: { [] }
        )
        func detachSync() throws {
            let catalogResult = Result { try sharedSpaces.forgetProfile(profile.id) }
            try settingsSync?.forgetProfile(profile.id)
            try catalogResult.get()
        }
        do {
            try detachSync()
            await beforeErasing()
            // A different window can enroll the profile again while the active window switches away.
            try detachSync()
        } catch {
            return .failure(error)
        }
        guard let index = index(of: profile) else { return .success(()) }
        var remaining = profiles
        remaining.remove(at: index)
        var dates = lastUsed
        dates[profile.id] = nil
        let opening = isPrivate ? (catalog?.currentID ?? lastPersistentID) : currentID
        let savedCurrent = opening == profile.id ? Profile.originalID : opening
        let launch = launchProfileID == profile.id ? nil : launchProfileID
        do {
            try JSONFileStore.writeAtomically(
                Stored(profiles: remaining, currentID: savedCurrent, launchProfileID: launch, lastUsed: dates),
                to: file, sortedKeys: true
            )
        } catch {
            return .failure(error)
        }
        profiles = remaining
        lastUsed = dates
        launchProfileID = launch
        if currentID == profile.id {
            currentID = Profile.originalID
        }
        if lastPersistentID == profile.id {
            lastPersistentID = Profile.originalID
        }
        if let catalog {
            catalog.currentID = savedCurrent
            if !isPrivate || catalog.lastPersistentID == profile.id {
                catalog.lastPersistentID = savedCurrent
            }
        }
        // A window may leave this profile only after its removal is durable, and before its stores are erased.
        await releaseWindows()
        // Stops the profile's watches and waits for their last write, so nothing lands in the folder the erase removes.
        await BrowserProfileContext.existing(for: profile.id)?.pageWatches?.close()
        BrowserProfileContext.forget(profile.id)
        SpaceStore.forget(profile.id)
        ReaderViewSpare.discard()
        await eraseData(profile)
        return .success(())
    }

    func markCurrent(_ profile: Profile, remember: Bool = true) {
        if profile.isPrivate {
            currentID = Profile.privateID
            return
        }
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        currentID = profile.id
        lastPersistentID = profile.id
        // Moving a background window off an erased profile preserves the front window's launch selection.
        guard remember else { return }
        lastUsed[profile.id] = Date()
        save(creatingList: false)
    }

    private func index(of profile: Profile) -> Int? {
        profiles.firstIndex { $0.id == profile.id }
    }

    private nonisolated struct Stored: Codable, Sendable {
        var profiles: [Profile]
        var currentID: UUID
        var launchProfileID: UUID?
        var lastUsed: [UUID: Date]?
    }

    private func save(creatingList: Bool = true) {
        if let catalog {
            if !isPrivate {
                catalog.currentID = currentID
                catalog.lastPersistentID = lastPersistentID
            }
            catalog.save(creatingList: creatingList)
            return
        }
        guard verifiedProfiles != nil || (creatingList && listStatus == .missing && !Self.hasNamedProfileHistory(beside: file)) else { return }
        let saved = Stored(profiles: profiles, currentID: currentID, launchProfileID: launchProfileID, lastUsed: lastUsed)
        if (try? JSONFileStore.writeAtomically(saved, to: file, sortedKeys: true)) != nil {
            listStatus = .loaded
        }
    }
    private static var defaultFile: URL {
        AppDatabase.supportDirectory.appendingPathComponent("profiles.json")
    }
}
