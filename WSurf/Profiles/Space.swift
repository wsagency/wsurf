// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import GRDB
import Observation

/// A device-local choice. A vault is identified by both its owning profile and its ID within that profile.
nonisolated struct SpaceVaultReference: Codable, Hashable, Sendable {
    let profileID: UUID
    let vaultID: UUID
}

/// A named set of tabs and folders inside one sign-in profile.
nonisolated struct Space: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var symbol: String
    var color: TabFolderColor
    /// Existing Spaces and new Spaces that use their profile's vault policy have no explicit binding.
    var vault: SpaceVaultReference?

    static let defaultSymbol = "square.grid.2x2"
}

/// The spaces of one profile, in display order. Kept in the profile's own directory, so they go with the profile and no
/// shared file names a profile.
@MainActor
@Observable
final class SpaceStore {
    private static var stores: [UUID: SpaceStore] = [:]

    /// The store of `profile`, loaded once per run. Nil for private browsing, which has no spaces.
    static func shared(for profile: Profile) -> SpaceStore? {
        guard !profile.isPrivate else { return nil }
        if let store = stores[profile.id] {
            return store
        }
        let store = SpaceStore(
            profile: profile, file: AppDatabase.ownsSession ? profile.spacesFile : nil,
            database: BrowserProfileContext.existing(for: profile.id)?.database ?? profile.makeDatabase()
        )
        stores[profile.id] = store
        return store
    }

    static func forget(_ profileID: UUID) {
        stores[profileID] = nil
    }

    /// Publish a new profile only after its first Space and its local vault choice are durable.
    static func createFirst(_ space: Space, for profile: Profile, publish: () throws -> Void) throws {
        let files = FileManager.default
        let directory = profile.supportDirectory
        try files.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try JSONFileStore.writeAtomically([space], to: profile.spacesFile, sortedKeys: true)
            let prepared = SpaceStore(profile: profile, file: profile.spacesFile)
            guard prepared.spaces == [space] else { throw CocoaError(.fileReadUnknown) }
            try publish()
            stores[profile.id] = prepared
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
    }

    let profileID: UUID
    /// A pre-Spaces profile has no saved list when its first Space is created.
    let hadSavedSpaceList: Bool
    private(set) var spaces: [Space]
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private var unreadableFallback: Space?
    @ObservationIgnored private var needsInitialWrite = false
    @ObservationIgnored weak var sharedSpacesHost: CloudSharedSpaces?

    /// `file` nil keeps the spaces in memory only (tests, or a second copy of the app that owns no session).
    init(profile: Profile, file: URL?, database: @autoclosure () -> AppDatabase? = nil) {
        profileID = profile.id
        self.file = file
        let stored: [Space]?
        do {
            stored = try file.map { try Self.readSpaces(from: $0) }
        } catch CocoaError.fileReadNoSuchFile {
            stored = Self.canStartWithNewSpace(in: database()) ? [] : nil
        } catch {
            stored = nil
        }
        hadSavedSpaceList = file != nil && stored?.isEmpty != true
        spaces = stored ?? []
        if spaces.isEmpty {
            let home = Space(id: UUID(), name: profile.name, symbol: profile.symbol, color: profile.color)
            if file != nil && stored == nil {
                unreadableFallback = home
            } else {
                spaces = [home]
                needsInitialWrite = file != nil
                save()
            }
        }
    }

    /// An absent file is a first launch only if no window already belongs to a Space.
    private static func canStartWithNewSpace(in database: AppDatabase?) -> Bool {
        guard let database else { return true }
        guard !database.isEphemeral else { return false }
        return (try? database.writer.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT NOT EXISTS (SELECT 1 FROM sessionTab WHERE spaceID IS NOT NULL)
                   AND NOT EXISTS (SELECT 1 FROM sessionFolder WHERE spaceID IS NOT NULL)
                """)
        }) == true
    }

    func space(id: UUID?) -> Space? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    /// Defer interpreting a window's saved memberships until its real Space IDs are available.
    func recoverMembership() -> Bool {
        guard let home = unreadableFallback, let file else { return true }
        do {
            let saved = try Self.readSpaces(from: file)
            let merged = mergingRecovered(saved, home: home)
            if merged == saved {
                spaces = saved
                unreadableFallback = nil
            } else {
                try persist(merged, to: file)
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func add(name: String, symbol: String = Space.defaultSymbol, color: TabFolderColor? = nil) -> Space {
        let space = Self.makeSpace(id: UUID(), name: name, symbol: symbol, color: color ?? nextColor)
        spaces.append(space)
        save()
        return space
    }

    func ensureJoinedSpace(id: UUID, name: String, symbol: String, color: TabFolderColor?) throws {
        guard let file else { throw CocoaError(.fileWriteNoPermission) }
        var next = try spacesForWriting(to: file)
        let index = next.firstIndex { $0.id == id }
        var joined = Self.makeSpace(id: id, name: name, symbol: symbol, color: color ?? .gray, fallbackName: index.map { next[$0].name })
        if let index {
            joined.vault = next[index].vault
            next[index] = joined
        } else {
            next.append(joined)
        }
        try persist(next, to: file)
    }

    private static func makeSpace(id: UUID, name: String, symbol: String, color: TabFolderColor, fallbackName: String? = nil) -> Space {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Space(id: id, name: trimmed.isEmpty ? fallbackName ?? String(localized: "New Space") : trimmed, symbol: symbol, color: color)
    }

    /// The first color no space of this profile wears yet, as Linen picks it.
    var nextColor: TabFolderColor {
        let used = Set(spaces.map(\.color))
        return TabFolderColor.allCases.first { $0 != .gray && !used.contains($0) } ?? .blue
    }

    /// The sheet commits the whole choice once. A stale sheet cannot overwrite another editor's vault selection.
    func saveEditorChoice(_ choice: SpaceEditor.Choice, editing original: Space? = nil) throws -> Space {
        guard let file else { throw CocoaError(.fileWriteNoPermission) }
        let onDisk: [Space]
        do {
            onDisk = try Self.readSpaces(from: file)
        } catch CocoaError.fileReadNoSuchFile where needsInitialWrite {
            onDisk = spaces
        }
        let recoveringFirstSpace = needsInitialWrite && onDisk.isEmpty
        guard unreadableFallback != nil || onDisk == spaces || recoveringFirstSpace else { throw SpaceEditorError.spaceUnavailable }
        var next = unreadableFallback.map { mergingRecovered(onDisk, home: $0) } ?? spaces
        let saved: Space
        if let original {
            guard let index = next.firstIndex(where: { $0.id == original.id }),
                  next[index] == original else { throw SpaceEditorError.spaceUnavailable }
            var edited = next[index]
            edited.name = choice.name
            edited.symbol = choice.symbol
            edited.vault = choice.vault
            next[index] = edited
            saved = edited
        } else {
            let used = Set(next.map(\.color))
            let color = TabFolderColor.allCases.first { $0 != .gray && !used.contains($0) } ?? .blue
            saved = Space(id: UUID(), name: choice.name, symbol: choice.symbol, color: color, vault: choice.vault)
            next.append(saved)
        }
        try persist(next, to: file)
        if let original {
            if original.vault != saved.vault {
                BrowserProfileContext.existing(for: profileID)?.spaceVaultChanged(saved.id)
            }
            if original.name != saved.name || original.symbol != saved.symbol {
                (sharedSpacesHost ?? CloudSync.shared?.sharedSpaces)?.spaceChanged(saved, in: profileID)
            }
        }
        return saved
    }

    func update(_ space: Space) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        var updated = space
        updated.vault = spaces[index].vault
        let trimmed = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmed.isEmpty ? spaces[index].name : trimmed
        guard updated != spaces[index] else { return }
        spaces[index] = updated
        save()
        (sharedSpacesHost ?? CloudSync.shared?.sharedSpaces)?.spaceChanged(updated, in: profileID)
    }

    /// A profile always keeps one space; removing the profile itself is Settings › Profiles' job.
    func canRemove(_ space: Space) -> Bool {
        spaces.count > 1 && spaces.contains { $0.id == space.id }
    }

    func remove(_ space: Space) {
        guard canRemove(space) else { return }
        spaces.removeAll { $0.id == space.id }
        save()
        (sharedSpacesHost ?? CloudSync.shared?.sharedSpaces)?.spaceChanged(space, in: profileID, removed: true)
    }

    private func save() {
        guard let file else { return }
        try? persist(spacesForWriting(to: file), to: file)
    }

    private func persist(_ next: [Space], to file: URL) throws {
        try JSONFileStore.writeAtomically(next, to: file, sortedKeys: true)
        needsInitialWrite = false
        unreadableFallback = nil
        if spaces != next {
            spaces = next
        }
    }

    private static func readSpaces(from file: URL) throws -> [Space] {
        let saved = try JSONDecoder().decode([Space].self, from: Data(contentsOf: file))
        var seen: Set<UUID> = []
        return saved.filter { seen.insert($0.id).inserted }
    }

    private func spacesForWriting(to file: URL) throws -> [Space] {
        // A failed initial read can hide other Spaces. Recover them before replacing their file.
        guard let home = unreadableFallback else { return spaces }
        return mergingRecovered(try Self.readSpaces(from: file), home: home)
    }

    private func mergingRecovered(_ saved: [Space], home: Space) -> [Space] {
        guard !saved.isEmpty else { return spaces.isEmpty ? [home] : spaces }
        let ids = Set(saved.map(\.id))
        return saved + spaces.filter { !ids.contains($0.id) }
    }
}
