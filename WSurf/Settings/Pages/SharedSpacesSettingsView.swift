// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfCore

/// A profile link can be used for website and model settings even when this Mac shares no Spaces or pins.
struct SharedProfileLinkSection: View {
    let profile: Profile
    let cloud: CloudSync?
    @State private var message: String?

    var body: some View {
        if let host = cloud?.sharedSpaces, !profile.isPrivate {
            SettingsSection(title: "Linked profile", symbol: "person.2") {
                if let id = host.cloudProfileID(for: profile.id) {
                    let name = host.catalog.item(id, in: .profiles)?.title ?? profile.name
                    DetailRow(verbatimTitle: profile.name, verbatimCaption: String(localized: "Linked to \(name) in iCloud.")) {
                        Image(systemName: "link")
                    }
                } else {
                    DetailRow(title: "Use this profile across Macs", caption: "Publish this profile’s name, or choose an existing iCloud profile.") {
                        Button("Find Profiles") { run { try await host.enable(.profiles, for: profile) } }
                        Button("Publish Profile") { run { _ = try await host.publishProfile(profile) } }
                    }
                    ForEach(host.available(.profiles, for: profile)) { item in
                        DetailRow(verbatimTitle: item.title, verbatimCaption: item.id.uuidString) {
                            Button("Link to Profile") {
                                if !host.linkProfile(profile.id, to: item.id) {
                                    message = String(localized: "This iCloud profile is already linked on this Mac.")
                                }
                            }
                        }
                    }
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action(); message = nil } catch { message = String(localized: "Couldn’t load the iCloud profiles. Try again when this Mac is online.") }
        }
    }
}

struct SharedSpacesSettingsView: View {
    let profile: Profile
    let cloud: CloudSync?
    @State private var message: String?

    var body: some View {
        if let host = cloud?.sharedSpaces, !profile.isPrivate {
            SettingsSection(title: "Shared Spaces", symbol: "square.grid.2x2") {
                control(host, category: .spaces)
                if host.isEnabled(.spaces, for: profile) {
                    ForEach(host.spaces(profile)?.spaces ?? []) { space in
                        let shared = host.links[profile.id]?.spaces[space.id] != nil
                        HStack {
                            Label(space.name, systemImage: space.symbol)
                            Spacer()
                            if shared {
                                Button("Stop Sharing") { host.stopSharing(space, in: profile) }
                            } else {
                                Button("Share This Space") { run { try await host.share(space, in: profile) } }
                            }
                        }
                    }
                    ForEach(host.availableSpaces(for: profile)) { item in
                        HStack {
                            Label(item.title, systemImage: "icloud")
                            Spacer()
                            Button("Join Shared Space") { run { try await host.join(item, in: profile) } }
                        }
                    }
                    conflicts(host, category: .spaces)
                }
            }
            SettingsSection(title: "Shared pins and Favorites", symbol: "pin") {
                control(host, category: .pins)
                if host.isEnabled(.pins, for: profile) {
                    ForEach(host.pins(profile).pins.filter { $0.kind == .tab }, id: \.id) { pin in
                        HStack {
                            Label(pin.customTitle ?? pin.title, systemImage: pin.isFavorite ? "star" : "pin")
                            Spacer()
                            if host.links[profile.id]?.pins[pin.id] != nil {
                                Button("Stop Sharing") { host.stopSharingPin(pin.id, in: profile) }
                            } else {
                                Button("Share Pin") { run { try await host.selectPin(pin.id, in: profile) } }
                            }
                        }
                    }
                    ForEach(host.availablePins(for: profile)) { item in
                        HStack {
                            Label(item.title, systemImage: "icloud")
                            Spacer()
                            Button("Add to This Mac") { run { try await host.joinPin(item, in: profile) } }
                        }
                    }
                    conflicts(host, category: .pins)
                }
            }
            if let message {
                Text(message).foregroundStyle(.secondary)
            }
        }
    }

    private func control(_ host: CloudSharedSpaces, category: SharedCatalogCategory) -> some View {
        DetailRow(title: "Sync on this Mac", caption: status(host, category: category)) {
            SettingsToggle(Binding(
                get: { host.isEnabled(category, for: profile) },
                set: { enabled in
                    if enabled {
                        run { try await host.enable(category, for: profile) }
                    } else {
                        host.pause(category, for: profile)
                    }
                }
            ))
            if host.catalog.failed.contains(category) {
                Button("Try Again") { run { try await host.enable(category, for: profile) } }
            }
        }
    }

    private func status(_ host: CloudSharedSpaces, category: SharedCatalogCategory) -> LocalizedStringResource {
        if !host.catalog.storageAvailable { return "This Mac couldn’t save its sync changes. Check available storage and try again." }
        if !host.isEnabled(category, for: profile) { return "Off. Existing copies stay on each Mac." }
        if host.catalog.failed.contains(category) { return "Waiting for iCloud. Local changes are saved." }
        if !host.catalog.ready.contains(category) { return "Reading the iCloud catalog…" }
        if host.catalog.state.pending.values.contains(where: { $0.profile == profile.id && $0.item.category == category }) {
            return "Changes are waiting to upload."
        }
        if let date = host.catalog.state.lastSynced?[category] {
            return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))."
        }
        return "Ready to sync."
    }

    private func conflicts(_ host: CloudSharedSpaces, category: SharedCatalogCategory) -> some View {
        let edits = host.catalog.state.conflicts.values.filter { $0.profile == profile.id && $0.item.category == category }.sorted { $0.item.id.uuidString < $1.item.id.uuidString }
        return ForEach(edits, id: \.item.id) { edit in
            let id = edit.item.recordID
            VStack(alignment: .leading) {
                Text("Review “\(edit.item.title)”")
                Text("This Mac: \(edit.item.url ?? edit.item.title)")
                if let other = host.catalog.state.remote[id]?.item {
                    Text(other.removed ? String(localized: "iCloud: Closed") : String(localized: "iCloud: \(other.url ?? other.title)"))
                }
                HStack {
                    Button("Keep This Mac’s Version") { host.catalog.resolve(id, keepingLocal: true) }
                    Button("Use iCloud Version") { host.catalog.resolve(id, keepingLocal: false) }
                }
            }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action(); message = nil } catch { message = String(localized: "Couldn’t complete the iCloud change. Check the linked profile and try again.") }
        }
    }
}
