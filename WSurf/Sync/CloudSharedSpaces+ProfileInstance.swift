// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
    func hasLink(_ local: UUID, to instance: CloudProfileInstance) -> Bool {
        storageReadable && instance.kind == .shared && catalog.state.user == instance.owner && links[local]?.profile == instance.id
    }

    func membership(of local: UUID) -> CloudProfileInstance? {
        guard let id = links[local]?.profile, let owner = catalog.state.user,
              SharedCatalogCategory.allCases.contains(where: { catalog.enabled($0, for: local) }) else { return nil }
        return .init(.shared, id: id, owner: owner)
    }

    /// Commit fresh IDs for the same selected local objects and their pending values together.
    func replaceInstance(for profile: Profile, with next: CloudProfileInstance, source: ProfilePublicationSource? = nil) throws {
        guard retryOptOuts(), storageReadable else { throw SharedCatalogError.storage }
        guard var link = links[profile.id], let old = link.profile, catalog.state.user == next.owner else { return }
        if old == next.id {
            guard catalog.persistLocalState() else { throw SharedCatalogError.storage }
            return
        }
        var ids = [old: next.id]
        func fresh(_ old: UUID) -> UUID {
            if let id = ids[old] {
                return id
            }
            let id = UUID()
            ids[old] = id
            return id
        }
        var items: [SharedSpaceItem] = []
        if catalog.enabled(.spaces, for: profile.id) {
            let selected = Set(link.spaces.values).union(link.slots.values.map(\.cloudID))
            items = catalog.items(.spaces).filter { $0.profileID == old && selected.contains($0.id) && !$0.removed }
        }
        if catalog.enabled(.pins, for: profile.id), link.sharesPinLibrary {
            items += try libraryItems(pins(profile).readForPublication(), group: old, link: &link).values
        }
        let source = source ?? ProfilePublicationSource(macName: computerName())
        link.publicationOrigin = .published(source)
        if catalog.enabled(.profiles, for: profile.id) {
            items.append(.init(id: old, kind: .profile, profileID: old, title: profile.name, publicationSource: source))
        }
        let copies = items.map { item in
            var copy = item.copy(id: fresh(item.id), profile: next.id, map: fresh)
            if copy.kind == .space {
                copy.spacePublisher = .init(profileID: profile.id, source: source)
            }
            return copy
        }
        link.profile = next.id
        link.spaces = link.spaces.mapValues(fresh)
        link.pins = link.pins.mapValues(fresh)
        link.pinFolders = link.pinFolders?.mapValues(fresh)
        link.skippedPins = nil
        if link.sharesPinLibrary {
            link.pinLibrary = .init(rows: Dictionary(uniqueKeysWithValues: copies.filter { $0.category == .pins }.map { ($0.id, $0) }))
        }
        link.slots = link.slots.mapValues { slot in
            var copy = slot
            copy.cloudID = fresh(slot.cloudID)
            if let last = slot.last {
                copy.last = last.copy(id: copy.cloudID, profile: next.id, map: fresh)
            }
            return copy
        }
        // Keys here are remote reservations, while the values are the local Spaces kept across restart.
        link.joiningSpaces = link.joiningSpaces.map { Dictionary(uniqueKeysWithValues: $0.map { (fresh($0.key), $0.value) }) }
        link.keepingSpaces = link.keepingSpaces.map { Set($0.map(fresh)) }
        links[profile.id] = link
        guard catalog.replacePublication(for: profile.id, with: copies) else { throw SharedCatalogError.storage }
    }
}

private extension SharedSpaceItem {
    func copy(id: UUID, profile: UUID, map: (UUID) -> UUID) -> Self {
        var copy = Self(id: id, kind: kind, profileID: profile, spaceID: spaceID.map(map), parentID: parentID.map(map),
                        order: order, title: title, url: url, customTitle: customTitle, symbol: symbol, color: color, favorite: favorite,
                        removed: removed, publicationSource: publicationSource)
        copy.sharedTabID = sharedTabID.map(map)
        copy.pinFolderAppearance = pinFolderAppearance
        return copy
    }
}
