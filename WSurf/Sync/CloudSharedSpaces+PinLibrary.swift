// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

extension CloudSharedSpaces {
    func choosePinLibrary(for id: UUID) {
        guard var link = links[id], !link.sharesPinLibrary else { return }
        // Mapped pins may still await their first import. Only rows actually present establish a local baseline.
        link.pinLibrary = .init()
        link.skippedPins = nil
        links[id] = link
    }

    func prepareLinkedPinLibrary(in profile: Profile) async throws {
        guard isEnabled(.pins, for: profile), links[profile.id]?.sharesPinLibrary == true else { return }
        if !catalog.ready.contains(.pins) || pinLibraryFailures.contains(profile.id) {
            try await enable(.pins, for: profile)
        }
    }

    /// The last committed projection distinguishes a local edit from a remote row waiting to be written.
    func capturePinLibrary(_ local: [ProfilePin], in profile: Profile, group: UUID) throws {
        guard var link = links[profile.id], link.profile == group, var library = link.pinLibrary else { throw SharedCatalogError.unavailable }
        let base = library.rows
        let rows = libraryItems(local, group: group, link: &link)
        var edits = rows.values.filter { item in
            library.rows[item.id] != item && library.applying?[item.id] != item
        }
        for (id, prior) in library.rows where rows[id] == nil && library.applying?[id]?.removed != true {
            edits.append(prior.tombstone)
        }
        // A pin can be edited to a device-only URL. Retire its cloud copy and keep the actual local pin.
        for pin in local where pin.kind == .tab {
            if let id = link.pins[pin.id], rows[id] == nil {
                link.pins[pin.id] = nil
            }
        }
        library.rows = rows
        link.pinLibrary = library
        if link == links[profile.id], edits.isEmpty, catalog.storageAvailable {
            return
        }
        if link != links[profile.id] {
            links[profile.id] = link
        }
        catalog.stage(edits, for: profile.id, comparingWith: base)
        guard persistLinks() else { throw SharedCatalogError.storage }
    }

    /// Local UUIDs survive a join. Two independent records with the same URL keep distinct cloud IDs.
    func libraryItems(_ local: [ProfilePin], group: UUID, link: inout SharedProfileLinks, applyingRemote: Bool = false) -> [UUID: SharedSpaceItem] {
        var folders = link.pinFolders ?? [:]
        var assigned = Set(link.pins.values).union(folders.values)
        func availableID(_ localID: UUID, kind: SharedSpaceItem.Kind) -> UUID {
            if assigned.contains(localID) {
                return UUID()
            }
            guard let existing = catalog.item(localID, in: .pins) else { return localID }
            return existing.profileID == group && existing.kind == kind && !existing.removed ? localID : UUID()
        }
        for folder in local where folder.kind == .folder && folders[folder.id] == nil {
            let id = availableID(folder.id, kind: .pinFolder)
            folders[folder.id] = id
            assigned.insert(id)
        }
        link.pinFolders = folders
        let tabs = Dictionary(link.slots.values.compactMap { slot in slot.pinID.map { ($0, slot.cloudID) } },
                              uniquingKeysWith: { first, _ in first })
        var items: [UUID: SharedSpaceItem] = [:]
        for pin in local {
            let parent = pin.parentID.flatMap { folders[$0] }
            if pin.kind == .folder, let id = folders[pin.id] {
                items[id] = .init(id: id, kind: .pinFolder, profileID: group, parentID: parent,
                                  order: pin.orderKey, title: pin.title, symbol: pin.symbol, color: pin.color?.rawValue)
                items[id]?.pinFolderAppearance = .init(customColor: pin.customColor, sizeFactor: pin.sizeFactor, tintsIcons: pin.tintsIcons == true)
            } else if pin.kind == .tab {
                let id = link.pins[pin.id] ?? availableID(pin.id, kind: .pin)
                guard var item = Self.pinItem(pin, id: id, profile: group) else { continue }
                assigned.insert(id)
                link.pins[pin.id] = id
                item.parentID = parent
                let previous = link.pinLibrary?.rows[id] ?? link.pinLibrary?.applying?[id]
                let association = applyingRemote || previous == nil ? catalog.item(id, in: .pins) : previous
                item.sharedTabID = tabs[pin.id] ?? association?.sharedTabID
                items[id] = item
            }
        }
        return items
    }

    /// Reserve incoming identities and both sides of the SQLite write in the checkpoint. After a crash,
    /// either side can be on disk without looking like a user deletion or an edit back to the older value.
    func commitPinLibrary(
        _ next: [ProfilePin], replacing old: [ProfilePin], store: ProfilePinStore, profile: Profile, link: inout SharedProfileLinks, beforeNotify: () -> Void
    ) throws {
        guard let group = link.profile, var library = link.pinLibrary else { throw SharedCatalogError.unavailable }
        let target = libraryItems(next, group: group, link: &link, applyingRemote: true)
        var changed = target.filter { library.rows[$0.key] != $0.value }
        for (id, prior) in library.rows where target[id] == nil {
            changed[id] = prior.tombstone
        }
        library.applying = changed.isEmpty ? nil : changed
        link.pinLibrary = library
        if links[profile.id] != link {
            links[profile.id] = link
            guard persistLinks() else { throw SharedCatalogError.storage }
        }
        guard store.publish(next, replacing: old, beforeNotify: beforeNotify) else { throw SharedCatalogError.storage }
        library.rows = target
        library.applying = nil
        link.pinLibrary = library
        if links[profile.id] != link {
            links[profile.id] = link
            guard persistLinks() else { throw SharedCatalogError.storage }
        }
    }
}
