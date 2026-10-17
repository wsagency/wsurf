// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct MCPSettingsPage: View {
    let server: BrowserMCPServer
    let onBack: () -> Void

    @State private var namingConfiguration = false
    @State private var configurationName = ""
    @State private var configurationFailure: String?

    private var trustStore: MCPTrustStore {
        server.trustStore
    }

    var body: some View {
        SubPageHeader(backTitle: "Advanced", onBack: onBack)
        SettingsPageHeader(title: "External connections")

        SettingsCard {
            DetailRow(
                title: "MCP server",
                caption: "Connect external assistants to tabs you choose. Private tabs are never shared."
            ) {
                SettingsToggle(Binding(get: { server.isEnabled }, set: { server.setEnabled($0) }))
                    .disabled(server.isPaused)
            }
            .settingsAnchor("advanced.mcp")

            if let status = server.status {
                RowSeparator()
                DetailRow(verbatimTitle: status) { EmptyView() }
            }
        }

        SettingsSection(title: "Clients", symbol: "app.connected.to.app.below.fill", accessory: {
            SettingsButton(title: trustStore.isAvailable ? "Copy Configuration…" : "Copy Configuration") {
                if trustStore.isAvailable {
                    configurationName = ""
                    namingConfiguration = true
                } else {
                    copy(server.configuration, concealed: false)
                }
            }
        }) {
            MCPClientSetupRows(trustStore: trustStore)

            RowSeparator()

            DetailRow(
                title: "Paired apps",
                attributedCaption: trustStore.isAvailable
                    ? SettingsIndex.caption(
                        "Pairing lets WSurf recognize an app. Review paired apps in Connected apps.",
                        naming: "Connected apps",
                        at: "assistant.connectedApps"
                    )
                    : AttributedString(String(localized: "Pairing isn’t available because WSurf can’t reach its secure storage. Apps ask for approval each time they connect."))
            ) {
                EmptyView()
            }

            if let configurationFailure {
                RowSeparator()
                DetailRow(verbatimTitle: configurationFailure) { EmptyView() }
            }
        }
        .task { trustStore.loadIfNeeded() }
        .alert("Name This App", isPresented: $namingConfiguration) {
            TextField("Name", text: $configurationName)
            Button("Copy") { copyPairedConfiguration() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("WSurf copies a configuration that pairs the app you paste it into. Keep it private.")
        }

        if !server.sessions.isEmpty {
            SettingsSection(title: "Connected clients", symbol: "cable.connector") {
                ForEach(server.sessions) { session in
                    if session.id != server.sessions.first?.id {
                        RowSeparator()
                    }
                    MCPConnectionRow(session: session) { server.disconnect(session.id) }
                }
            }
        }
    }
}

extension MCPSettingsPage {
    /// Pairs a new app under the typed name and copies a configuration holding its token.
    private func copyPairedConfiguration() {
        do {
            let token = try MCPPairing.makeToken()
            try trustStore.pair(token: token, name: configurationName, kind: nil)
            copy(server.configuration(pairedWith: token), concealed: true)
            configurationFailure = nil
        } catch {
            configurationFailure = String(localized: "WSurf couldn’t pair this app. Try again.")
        }
    }

    private func copy(_ configuration: String, concealed: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(configuration, forType: .string)
        if concealed {
            // Clipboard managers skip items with this marker, so the token is not kept in their history.
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        }
    }
}

private struct MCPConnectionRow: View {
    let session: MCPBrowserSession
    let disconnect: () -> Void

    var body: some View {
        DetailRow(
            verbatimTitle: session.clientName,
            verbatimCaption: caption
        ) {
            SettingsButton(title: "Disconnect", action: disconnect)
        }
    }

    private var caption: String {
        let count = String(localized: "Shared tabs: \(session.grants.count) · Tool calls: \(session.completedCalls)")
        guard let action = session.lastActionTitle else { return count }
        return count + "\n" + String(localized: "Latest action: \(action)")
    }
}
