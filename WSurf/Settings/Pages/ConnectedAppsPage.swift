// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The apps paired with WSurf, what each may do without asking, and where that applies. Revoking an app ends its
/// connections and its token at once.
struct ConnectedAppsPage: View {
    let server: BrowserMCPServer
    var profiles: ProfileStore = .shared
    let onBack: () -> Void

    @State private var revoking: PairedClient?
    @State private var failure: String?

    private var store: MCPTrustStore {
        server.trustStore
    }

    var body: some View {
        SubPageHeader(backTitle: "Assistant", onBack: onBack)

        SettingsPageHeader(
            title: "Connected apps",
            caption: "Apps you paired with WSurf. Unpaired apps ask each time they connect."
        )

        SettingsCard {
            if store.clients.isEmpty {
                SettingsEmptyState(
                    symbol: "app.connected.to.app.below.fill",
                    title: "No paired apps",
                    caption: store.isAvailable
                        ? "Pair an app under Advanced › External connections."
                        : "Pairing isn’t available because WSurf can’t reach its secure storage."
                )
            } else {
                ForEach(store.clients) { client in
                    if client.id != store.clients.first?.id {
                        RowSeparator()
                    }
                    ConnectedAppRow(
                        client: client, caption: caption(for: client),
                        setStanding: { standing in change { try store.setStanding(standing, for: client.id) } },
                        setPaused: { paused in change { try store.setPaused(paused, for: client.id) } },
                        revoke: { revoking = client }
                    )
                }
            }

            if let failure {
                RowSeparator()
                DetailRow(verbatimTitle: failure) { EmptyView() }
            }
        }
        .padding(.top, 6)
        .task { store.reload() }
        .confirmationDialog(
            revoking.map { Text("Revoke “\($0.name)”?") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })
        ) {
            Button("Revoke", role: .destructive) {
                guard let client = revoking else { return }
                do {
                    try server.revoke(client)
                    failure = nil
                } catch {
                    failure = String(localized: "WSurf couldn’t revoke this app. Try again.")
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It will need your approval each time it connects until you pair it again.")
        }

        if store.isAvailable {
            DeveloperWorkSection(store: store, profiles: profiles)
                .padding(.top, 6)
        }
    }

    /// Runs a change to the trust store and reports a failure in place.
    private func change(_ body: () throws -> Void) {
        do {
            try body()
            failure = nil
        } catch {
            failure = String(localized: "WSurf couldn’t save this change. Try again.")
        }
    }

    private func caption(for client: PairedClient) -> String {
        var parts: [String] = []
        if server.sessions.contains(where: { $0.pairedClient?.id == client.id }) {
            parts.append(String(localized: "Connected now"))
        } else if let lastUsed = client.lastUsed {
            parts.append(String(localized: "Last used \(lastUsed.formatted(.relative(presentation: .named)))"))
        } else {
            parts.append(String(localized: "Not used yet"))
        }
        if client.paused {
            parts.append(String(localized: "Paused"))
        } else if client.standing != .off, store.developerProfileID == nil {
            parts.append(String(localized: "Choose a Developer profile to use this."))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ConnectedAppRow: View {
    let client: PairedClient
    let caption: String
    let setStanding: (PairedClient.Standing) -> Void
    let setPaused: (Bool) -> Void
    let revoke: () -> Void

    var body: some View {
        DetailRow(verbatimTitle: client.name, verbatimCaption: caption, controlWidth: nil) {
            HStack(spacing: 10) {
                if client.paused {
                    SettingsButton(title: "Resume") { setPaused(false) }
                } else {
                    Text("Without asking")
                        .font(Theme.Font.secondary)
                        .foregroundStyle(.secondary)

                    SettingsMenu<PairedClient.Standing>(
                        options: [
                            .init(value: .off, label: String(localized: "Off")),
                            .init(value: .development, label: String(localized: "Development")),
                            .init(value: .developer, label: String(localized: "Developer")),
                        ],
                        selection: Binding(get: { client.standing }, set: setStanding)
                    )
                    .frame(width: 140)
                }

                SettingsButton(title: "Revoke…", isDestructive: true, action: revoke)
            }
        }
    }
}

/// The Developer profile and the developer sites. Standing grants and the Developer tier apply only on these sites, in
/// that profile, so a paired app never reaches your everyday sign-ins.
private struct DeveloperWorkSection: View {
    let store: MCPTrustStore
    let profiles: ProfileStore

    @State private var pendingProfile: Profile?
    @State private var addingSite = false
    @State private var siteDraft = ""
    @State private var failure: String?

    var body: some View {
        SettingsSection(
            title: "Developer work", symbol: "hammer",
            footnote: "Without asking works only on developer sites in the Developer profile. Developer also skips the confirmation before purchases, sending, and deleting there."
        ) {
            DetailRow(
                title: "Developer profile",
                caption: "Developer access works only in this profile, so connected apps never use your everyday sign-ins."
            ) {
                SettingsMenu(options: profileOptions, selection: profileSelection)
            }

            if !hasDedicatedProfile {
                RowSeparator()
                AddRow(title: "Create Developer Profile") {
                    attempt { _ = try MCPDeveloperAccess.createDeveloperProfile(in: profiles, trust: store) }
                }
            }

            RowSeparator()

            DetailRow(title: "This Mac", caption: "localhost, 127.0.0.1, and [::1] on any port.") {
                SettingsToggle(Binding(
                    get: { store.includesThisMac },
                    set: { included in attempt { try store.setIncludesThisMac(included) } }
                ))
            }

            ForEach(store.developerSites, id: \.self) { site in
                RowSeparator()
                DetailRow(verbatimTitle: site, verbatimCaption: caption(forSite: site)) {
                    SettingsButton(title: "Remove") { attempt { try store.removeDeveloperSite(site) } }
                }
            }

            RowSeparator()
            AddRow(title: "Add Site…") {
                siteDraft = ""
                addingSite = true
            }

            if let failure {
                RowSeparator()
                DetailRow(verbatimTitle: failure) { EmptyView() }
            }
        }
        .alert("Add a Developer Site", isPresented: $addingSite) {
            TextField("staging.example.com", text: $siteDraft)
            Button("Add") { addSite() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paired apps set to work without asking can use this site too. A site without a port covers the usual web port only. Add one, like staging.example.com:8443, to include another.")
        }
        .confirmationDialog(
            pendingProfile.map { Text("Allow Developer Access in “\($0.name)”?") } ?? Text(verbatim: ""),
            isPresented: Binding(get: { pendingProfile != nil }, set: { if !$0 { pendingProfile = nil } })
        ) {
            Button("Allow") {
                guard let profile = pendingProfile else { return }
                attempt { try store.setDeveloperProfile(profile.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Paired apps could work on your developer sites without asking, and skip the confirmation before purchases, sending, and deleting, while you’re signed in there.")
        }
    }

    private var choosable: [Profile] {
        profiles.profiles.filter { !$0.isPrivate }
    }

    private var hasDedicatedProfile: Bool {
        store.dedicatedProfileID.map { id in choosable.contains { $0.id == id } } ?? false
    }

    private var profileOptions: [SettingsMenu<UUID?>.Option] {
        [.init(value: nil, label: String(localized: "Not set"))]
            + choosable.map { .init(value: $0.id, label: $0.name) }
    }

    /// Choosing any profile except the one WSurf created for this asks first.
    private var profileSelection: Binding<UUID?> {
        Binding(
            get: { store.developerProfileID },
            set: { id in
                guard let id else {
                    attempt { try store.setDeveloperProfile(nil) }
                    return
                }
                if MCPDeveloperAccess.needsConfirmation(choosing: id, trust: store) {
                    pendingProfile = choosable.first { $0.id == id }
                } else {
                    attempt { try store.setDeveloperProfile(id) }
                }
            }
        )
    }

    private func caption(forSite site: String) -> String? {
        MCPDeveloperAccess.site(from: site)?.port == nil
            ? String(localized: "Usual web port only. Add a port to include another.") : nil
    }

    private func addSite() {
        attempt {
            do {
                try store.addDeveloperSite(siteDraft)
            } catch MCPTrustStore.Failure.invalidSite {
                throw SiteFailure.invalid
            } catch MCPTrustStore.Failure.tooManySites {
                throw SiteFailure.tooMany
            }
        }
    }

    private enum SiteFailure: Error {
        case invalid, tooMany
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
            failure = nil
        } catch SiteFailure.invalid {
            failure = String(localized: "Enter a site like staging.example.com or staging.example.com:8443. Wildcards and address ranges aren’t supported.")
        } catch SiteFailure.tooMany {
            failure = String(localized: "WSurf keeps up to \(MCPDeveloperAccess.maximumSites) developer sites. Remove one to add another.")
        } catch {
            failure = String(localized: "WSurf couldn’t save this change. Try again.")
        }
    }
}

/// The Assistant overview row that opens the Connected apps page.
struct ConnectedAppsSection: View {
    let model: IntelligenceViewModel
    let trustStore: MCPTrustStore

    var body: some View {
        SettingsSection(title: "Connected apps", symbol: "app.connected.to.app.below.fill") {
            DrillInRow(
                title: "Connected apps",
                detail: trustStore.clients.isEmpty ? "None" : "\(trustStore.clients.count) paired"
            ) {
                model.showConnectedApps()
            }
            .settingsAnchor("assistant.connectedApps")
        }
        .task { trustStore.loadIfNeeded() }
    }
}
