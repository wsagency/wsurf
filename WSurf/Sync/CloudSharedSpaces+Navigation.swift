// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

struct SharedSpaceChoice: Identifiable {
    enum Destination: Equatable {
        case open(SpaceEntry)
        case join(Profile)
        case addProfile
        case chooseProfile
    }

    let item: SharedSpaceItem
    let owner: String
    let destination: Destination

    var id: UUID {
        item.id
    }
}

extension CloudSharedSpaces {
    /// A shared tab belongs to its saved window even while another profile occupies that window.
    func tabWindows(in entry: SpaceEntry) -> [UUID: UUID] {
        guard let link = links[entry.profile.id], let shared = link.spaces[entry.id] else { return [:] }
        var windows: [UUID: UUID] = [:]
        for (id, slot) in link.slots {
            guard slot.closedAfterRevision == nil, let row = catalog.item(slot.cloudID, in: .spaces),
                  row.kind == .tab, !row.removed, row.profileID == link.profile, row.spaceID == shared else { continue }
            windows[id] = slot.window
        }
        return windows
    }

    func joinedSpace(_ item: SharedSpaceItem, in profile: Profile) -> Space? {
        guard let link = links[profile.id], link.profile == item.profileID,
              let local = link.spaces.first(where: { $0.value == item.id })?.key else { return nil }
        return spaces(profile)?.space(id: local)
    }

    func spaceTitle(_ item: SharedSpaceItem) -> String {
        if let source = item.spacePublisher?.source, source.macName != nil {
            return ProfileSummary.publishedName(item.title, source: source)
        }
        let profile = catalog.item(item.profileID, in: .profiles)
        if let profile, !profile.removed, let mac = profile.publicationSource?.macName {
            return String(localized: "\(item.title) — profile from \(mac)")
        }
        return String(localized: "\(item.title) — Shared Space \(String(item.id.uuidString.prefix(8)))")
    }

    func spaceTitle(for entry: SpaceEntry) -> String {
        guard let group = cloudProfileID(for: entry.profile.id), let id = links[entry.profile.id]?.spaces[entry.id],
              let item = catalog.item(id, in: .spaces), item.profileID == group, !item.removed else { return entry.space.name }
        return spaceTitle(item)
    }

    func unlinkedProfiles(in profiles: [Profile]) -> [Profile] {
        profiles.filter { !$0.isPrivate && permitsSharing?($0.id) != false && links[$0.id]?.profile == nil }
    }

    /// A discovered cloud Space can already belong to another local profile. An explicit link wins over its publication origin.
    func spaceChoices(from current: Profile, profiles: [Profile], adoptableProfiles: Set<UUID> = []) -> [SharedSpaceChoice] {
        guard !current.isPrivate, permitsSharing?(current.id) != false, catalog.ready.contains(.spaces), let owner = catalog.trustedUser else { return [] }
        let discovers = isEnabled(.spaces, for: current)
        let local = profiles.filter { !$0.isPrivate && permitsSharing?($0.id) != false }
        let candidates = unlinkedProfiles(in: local)
        let linked = Dictionary(local.compactMap { profile in
            links[profile.id]?.profile.map { ($0, profile) }
        }, uniquingKeysWith: { first, _ in first })
        return catalog.items(.spaces).compactMap { item -> SharedSpaceChoice? in
            guard item.kind == .space, !item.removed, permitsSharedInstance?(item.profileID, owner) != false else { return nil }
            let origin = item.spacePublisher?.profileID
            let target: SharedSpaceChoice.Destination
            if let profile = linked[item.profileID], let joined = joinedSpace(item, in: profile) {
                target = .open(SpaceEntry(space: joined, profile: profile))
            } else if !discovers {
                return nil
            } else if let profile = linked[item.profileID] {
                target = .join(profile)
            } else if let origin, origin != Profile.originalID, let profile = candidates.first(where: { $0.id == origin }) {
                target = .join(profile)
            } else if let origin, adoptableProfiles.contains(origin) {
                target = .addProfile
            } else if candidates.count == 1, candidates.first?.id == current.id {
                target = .join(current)
            } else {
                target = .chooseProfile
            }
            return SharedSpaceChoice(item: item, owner: owner, destination: target)
        }.sorted {
            ($0.item.title.localizedLowercase, $0.id.uuidString) < ($1.item.title.localizedLowercase, $1.id.uuidString)
        }
    }
}
