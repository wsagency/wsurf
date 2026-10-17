// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The apps paired with WSurf. Revoking one ends its connections and its token at once.
struct ConnectedAppsPage: View {
    let server: BrowserMCPServer
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
                    DetailRow(verbatimTitle: client.name, verbatimCaption: caption(for: client)) {
                        SettingsButton(title: "Revoke…", isDestructive: true) { revoking = client }
                    }
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
    }

    private func caption(for client: PairedClient) -> String {
        if server.sessions.contains(where: { $0.pairedClient?.id == client.id }) {
            return String(localized: "Connected now")
        }
        guard let lastUsed = client.lastUsed else { return String(localized: "Not used yet") }
        return String(localized: "Last used \(lastUsed.formatted(.relative(presentation: .named)))")
    }
}
