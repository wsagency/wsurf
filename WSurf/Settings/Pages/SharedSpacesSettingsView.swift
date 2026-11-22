// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfCore

struct SharedProfileLinkSection: View {
    let profile: Profile
    let host: CloudSharedSpaces
    @State private var change = SharedCatalogChange()

    var body: some View {
        SettingsSection(title: "Linked profile", symbol: "person.2") {
            SharedCatalogControl(
                host: host, category: .profiles, title: "Find Profiles", profile: profile, change: change,
                scope: "Publishing or linking combines this profile’s pins and Favorites across your Macs, including any you add later."
            )
            RowSeparator()
            let linkedID = host.cloudProfileID(for: profile.id)
            if let id = linkedID {
                let published = host.catalog.item(id, in: .profiles)
                let name = published.map { ProfileSummary.publishedName($0.title, source: $0.publicationSource) }
                    ?? ProfileSummary.displayName(for: profile, sharedSpaces: host)
                DetailRow(verbatimTitle: profile.name, verbatimCaption: String(localized: "Linked to \(name) in iCloud.")) {
                    if published == nil {
                        publishButton
                    } else {
                        Image(systemName: "link").accessibilityHidden(true)
                    }
                }
            } else {
                DetailRow(title: "Use this profile across Macs") { publishButton }
                ForEach(host.available(.profiles, for: profile)) { item in
                    let linkedHere = host.links.values.contains { $0.profile == item.id }
                    RowSeparator()
                    DetailRow(
                        verbatimTitle: ProfileSummary.publishedName(item.title, source: item.publicationSource),
                        verbatimCaption: linkedHere ? String(localized: "This iCloud profile is already linked on this Mac.") : item.id.uuidString
                    ) {
                        SettingsButton(title: "Link to Profile") { change.run { try await host.joinProfile(item, in: profile) } }
                            .disabled(change.working || linkedHere)
                    }
                }
            }
            if linkedID != nil || host.links[profile.id]?.profile != nil || host.hasPendingOptOut(.pins, for: profile) {
                RowSeparator()
                SharedCatalogControl(
                    host: host, category: .pins, title: "Shared Pins and Favorites", profile: profile, change: change,
                    scope: "Combine all pins and Favorites from this Mac and iCloud, including any you add later."
                )
                if host.isEnabled(.pins, for: profile) {
                    SharedCatalogConflicts(host: host, category: .pins, profile: profile)
                }
            }
            if let message = change.message {
                SettingsNotice(symbol: "exclamationmark.triangle", text: message)
            }
        }
    }

    private var publishButton: some View {
        SettingsButton(title: "Publish Profile") { change.run { _ = try await host.publishProfile(profile) } }
            .disabled(change.working || host.hasPendingOptOut(.profiles, for: profile))
    }
}

struct SharedSpacesSettingsView: View {
    let profile: Profile
    let host: CloudSharedSpaces
    let coordinator: AppCoordinator
    @State private var change = SharedCatalogChange()

    private var choices: [SharedSpaceChoice] {
        let vaults = CloudSync.shared?.vaults
        let profiles = coordinator.profiles.profiles
        let adoptable = vaults?.connectedAccount == host.catalog.trustedUser ? vaults?.remoteProfiles().map(\.id) : nil
        return host.spaceChoices(from: profile, profiles: profiles, adoptableProfiles: Set(adoptable ?? []).subtracting(profiles.map(\.id)))
    }

    var body: some View {
        SettingsSection(title: "Shared Spaces", symbol: "square.grid.2x2") {
            SharedCatalogControl(
                host: host, category: .spaces, title: "Sync Spaces on this Mac", profile: profile, change: change,
                scope: "Sharing or joining a Space syncs its tabs and this profile’s pins and Favorites, including any you add later."
            )
            if host.isEnabled(.spaces, for: profile) {
                ForEach(host.spaces(profile)?.spaces ?? []) { space in
                    RowSeparator()
                    let entry = SpaceEntry(space: space, profile: profile)
                    if host.links[profile.id]?.spaces[space.id] != nil {
                        joinedRow(entry, canStop: true)
                    } else {
                        DetailRow(verbatimTitle: space.name, verbatimCaption: String(localized: "Only on this Mac")) {
                            SettingsButton(title: "Share This Space") { change.run { try await host.share(space, in: profile) } }
                                .disabled(change.working)
                        }
                    }
                }
            }
            ForEach(choices) { choice in
                discoveredRow(choice)
            }
            if host.isEnabled(.spaces, for: profile) {
                SharedCatalogConflicts(host: host, category: .spaces, profile: profile)
            }
            if let message = change.message {
                SettingsNotice(symbol: "exclamationmark.triangle", text: message)
            }
        }
    }

    private func joinedRow(_ entry: SpaceEntry, canStop: Bool) -> some View {
        let profileName = ProfileSummary.displayName(for: entry.profile, sharedSpaces: host)
        return DetailRow(verbatimTitle: host.spaceTitle(for: entry), verbatimCaption: String(localized: "Shared in the \(profileName) profile"), layout: .stacked) {
            ChipFlow(spacing: 8) {
                SettingsButton(title: "Open Space") { coordinator.openSharedSpace(entry) }
                SettingsButton(title: "Space Settings…") { coordinator.showSpaceEditor(for: entry) }
                if canStop {
                    SettingsButton(title: "Stop Sharing") { host.stopSharing(entry.space, in: entry.profile) }
                }
            }
        }
        .disabled(change.working)
    }

    @ViewBuilder
    private func discoveredRow(_ choice: SharedSpaceChoice) -> some View {
        switch choice.destination {
        case .open(let entry):
            if entry.profile.id != profile.id || !host.isEnabled(.spaces, for: profile) {
                RowSeparator()
                joinedRow(entry, canStop: false)
            }
        case .join(let target):
            RowSeparator()
            let name = ProfileSummary.displayName(for: target, sharedSpaces: host)
            DetailRow(verbatimTitle: host.spaceTitle(choice.item), verbatimCaption: String(localized: "Join in the \(name) profile to sync its tabs, pins and Favorites.")) {
                SettingsButton(title: "Join and Open") { join(choice, in: target) }
                .disabled(change.working)
            }
        case .addProfile:
            RowSeparator()
            DetailRow(verbatimTitle: host.spaceTitle(choice.item), verbatimCaption: String(localized: "Add its iCloud profile to this Mac before joining.")) {
                SettingsButton(title: "Show Profiles…") { coordinator.openSettings(.profiles) }
            }
        case .chooseProfile:
            RowSeparator()
            let candidates = host.unlinkedProfiles(in: coordinator.profiles.profiles)
            DetailRow(verbatimTitle: host.spaceTitle(choice.item), verbatimCaption: String(localized: "Choose a profile to join this Space and combine its pins and Favorites.")) {
                if candidates.isEmpty {
                    SettingsButton(title: "Show Profiles…") { coordinator.openSettings(.profiles) }
                } else {
                    Menu("Join in Profile…") {
                        ForEach(candidates) { target in
                            Button(profileLabel(target, among: candidates)) { join(choice, in: target) }
                        }
                    }
                    .disabled(change.working)
                }
            }
        }
    }

    private func profileLabel(_ target: Profile, among profiles: [Profile]) -> String {
        let name = ProfileSummary.displayName(for: target, sharedSpaces: host)
        guard profiles.contains(where: { $0.id != target.id && ProfileSummary.displayName(for: $0, sharedSpaces: host) == name }) else { return name }
        return String(localized: "\(name) — \(String(target.id.uuidString.prefix(8)))")
    }

    private func join(_ choice: SharedSpaceChoice, in target: Profile) {
        change.run {
            let joined = try await host.join(choice.item, in: target, expecting: choice.owner)
            guard coordinator.context.profile.id == profile.id else { return }
            coordinator.openSharedSpace(SpaceEntry(space: joined, profile: target))
        }
    }
}

private struct SharedCatalogConflicts: View {
    let host: CloudSharedSpaces
    let category: SharedCatalogCategory
    let profile: Profile

    var body: some View {
        let edits = host.catalog.state.conflicts.values.filter { $0.profile == profile.id && $0.item.category == category }
        ForEach(edits.sorted { $0.item.id.uuidString < $1.item.id.uuidString }, id: \.item.id) { edit in
            let id = edit.item.recordID
            let local = String(localized: "This Mac: \(version(edit.item))")
            let remote = host.catalog.state.remote[id].map { other in
                other.item.removed ? String(localized: "iCloud: Closed") : String(localized: "iCloud: \(version(other.item))")
            }
            RowSeparator()
            DetailRow(
                verbatimTitle: String(localized: "Review “\(edit.item.title)”"),
                verbatimCaption: [local, remote].compactMap { $0 }.joined(separator: "\n"), layout: .stacked
            ) {
                ChipFlow(spacing: 8) {
                    SettingsButton(title: "Keep This Mac’s Version") { host.catalog.resolve(id, keepingLocal: true) }
                    SettingsButton(title: "Use iCloud Version") { host.catalog.resolve(id, keepingLocal: false) }
                }
            }
        }
    }

    private func version(_ item: SharedSpaceItem) -> String {
        let title = item.customTitle ?? item.title
        guard let url = item.url, url != title else { return title }
        return title.isEmpty ? url : [title, url].joined(separator: " · ")
    }
}

private struct SharedCatalogControl: View {
    let host: CloudSharedSpaces
    let category: SharedCatalogCategory
    let title: LocalizedStringResource
    let profile: Profile
    let change: SharedCatalogChange
    var scope: LocalizedStringResource?

    var body: some View {
        let enabled = host.isEnabled(category, for: profile)
        let pending = host.hasPendingOptOut(category, for: profile)
        let caption = [scopeDescription, status].compactMap { $0 }.map { String(localized: $0) }.joined(separator: "\n")
        DetailRow(verbatimTitle: String(localized: title), verbatimCaption: caption, controlWidth: nil) {
            HStack(spacing: 8) {
                if pending || !host.catalog.storageAvailable {
                    SettingsButton(title: "Try Again") {
                        change.message = nil
                        host.retryOptOuts()
                    }
                } else if enabled && (libraryFailed || host.catalog.failed.contains(category)) {
                    SettingsButton(title: "Try Again", action: enable)
                }
                SettingsToggle(Binding(get: { enabled }, set: { on in
                    if on {
                        enable()
                    } else {
                        change.message = nil
                        host.pause(category, for: profile)
                    }
                }))
                .disabled(pending && !enabled)
            }
        }
    }

    private func enable() {
        if category == .pins {
            change.run { try await host.enable(.pins, for: profile) }
            return
        }
        change.message = nil
        // The catalog exposes its enrollment and storage errors directly in this row.
        Task { try? await host.enable(category, for: profile) }
    }

    private var libraryFailed: Bool {
        category == .pins && host.links[profile.id]?.sharesPinLibrary == true && host.pinLibraryFailures.contains(profile.id)
    }

    private var scopeDescription: LocalizedStringResource? {
        guard let scope else { return nil }
        if category != .pins, host.cloudProfileID(for: profile.id) != nil || host.links[profile.id]?.profile != nil,
           !host.isEnabled(.pins, for: profile) {
            return "Pin and Favorite sync is paused on this Mac."
        }
        return scope
    }

    private var status: LocalizedStringResource {
        if host.hasPendingOptOut(category, for: profile) {
            return "Sync is paused for the settings you turned off. Try again to save this choice."
        }
        if !host.catalog.storageAvailable { return "This Mac couldn’t save its sync changes. Check available storage and try again." }
        if !host.isEnabled(category, for: profile) { return "Off. Existing copies stay on each Mac." }
        if libraryFailed { return "This Mac couldn’t update its pins and Favorites. Try again." }
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
}

@Observable
private final class SharedCatalogChange {
    var message: String?
    private(set) var working = false

    func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }
        working = true
        message = nil
        Task {
            defer { working = false }
            do { try await action() } catch is CancellationError {
                return
            } catch SharedCatalogError.paused {
                return
            } catch SharedCatalogError.storage {
                message = String(localized: "This Mac couldn’t save its sync changes. Check available storage and try again.")
            } catch {
                message = String(localized: "Couldn’t complete the iCloud change. Check the linked profile and try again.")
            }
        }
    }
}
