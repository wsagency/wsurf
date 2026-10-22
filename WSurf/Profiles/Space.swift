// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Observation

/// A named set of tabs and folders inside one profile. A space shares the profile's sign-ins, history, passwords and
/// pins; it only changes which unpinned tabs and folders a window shows.
nonisolated struct Space: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var symbol: String
    var color: TabFolderColor

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
        let store = SpaceStore(profile: profile, file: AppDatabase.ownsSession ? profile.spacesFile : nil)
        stores[profile.id] = store
        return store
    }

    static func forget(_ profileID: UUID) {
        stores[profileID] = nil
    }

    let profileID: UUID
    private(set) var spaces: [Space]
    @ObservationIgnored private let file: URL?

    /// `file` nil keeps the spaces in memory only (tests, or a second copy of the app that owns no session).
    init(profile: Profile, file: URL?) {
        profileID = profile.id
        self.file = file
        let stored = file
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([Space].self, from: $0) } ?? []
        var seen: Set<UUID> = []
        spaces = stored.filter { seen.insert($0.id).inserted }
        if spaces.isEmpty {
            spaces = [Space(id: UUID(), name: profile.name, symbol: profile.symbol, color: profile.color)]
            save()
        }
    }

    func space(id: UUID?) -> Space? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    @discardableResult
    func add(name: String, symbol: String = Space.defaultSymbol, color: TabFolderColor? = nil) -> Space {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let space = Space(
            id: UUID(),
            name: trimmed.isEmpty ? String(localized: "New Space") : trimmed,
            symbol: symbol,
            color: color ?? nextColor
        )
        spaces.append(space)
        save()
        return space
    }

    /// The first color no space of this profile wears yet, as Linen picks it.
    var nextColor: TabFolderColor {
        let used = Set(spaces.map(\.color))
        return TabFolderColor.allCases.first { $0 != .gray && !used.contains($0) } ?? .blue
    }

    func update(_ space: Space) {
        guard let index = spaces.firstIndex(where: { $0.id == space.id }) else { return }
        var updated = space
        let trimmed = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmed.isEmpty ? spaces[index].name : trimmed
        guard updated != spaces[index] else { return }
        spaces[index] = updated
        save()
    }

    /// A profile always keeps one space; removing the profile itself is Settings › Profiles' job.
    func canRemove(_ space: Space) -> Bool {
        spaces.count > 1 && spaces.contains { $0.id == space.id }
    }

    func remove(_ space: Space) {
        guard canRemove(space) else { return }
        spaces.removeAll { $0.id == space.id }
        save()
    }

    private func save() {
        guard let file else { return }
        JSONFileStore.encodeAndWrite(spaces, to: file, sortedKeys: true)
    }
}
