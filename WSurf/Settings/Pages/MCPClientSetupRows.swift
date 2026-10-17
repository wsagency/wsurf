// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import SwiftUI

struct MCPClientSetupRows: View {
    let trustStore: MCPTrustStore
    @State private var targets: [MCPClientTarget] = []
    @State private var installer = MCPClientInstaller()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(targets) { target in
                if target.id != targets.first?.id {
                    RowSeparator()
                }
                MCPClientSetupRow(target: target, installer: installer, trustStore: trustStore)
            }
        }
        .task {
            trustStore.loadIfNeeded()
            targets = MCPClientDiscovery.targets()
        }
    }
}

private struct MCPClientSetupRow: View {
    let target: MCPClientTarget
    let installer: MCPClientInstaller
    let trustStore: MCPTrustStore
    @State private var selectedURL: URL?
    @State private var message: String?
    @State private var backupURL: URL?
    @State private var isAdding = false
    @State private var installation = MCPClientInstallation.absent
    @State private var isChecking = true
    @State private var refreshID = UUID()

    var body: some View {
        DetailRow(verbatimTitle: target.kind.name, verbatimCaption: caption) {
            HStack(spacing: 8) {
                if canPair {
                    SettingsButton(title: "Pair", symbol: "link") {
                        add()
                    }
                    .disabled(isChecking || isAdding)
                    .accessibilityLabel(Text("Pair \(target.kind.name) with WSurf"))
                } else {
                    SettingsButton(title: isAdded ? "Added" : "Add", symbol: isAdded ? "checkmark" : "plus") {
                        add()
                    }
                    .disabled(isChecking || isAdding || isAdded || (!target.isDetected && selectedURL == nil))
                    .accessibilityLabel(Text("Add WSurf to \(target.kind.name)"))
                }

                SettingsMoreMenu {
                    if paired != nil {
                        Button("Re-pair") { add() }
                    }
                    Button("Choose Configuration…") { chooseConfiguration() }
                    Button("Show Configuration") {
                        NSWorkspace.shared.activateFileViewerSelecting([configurationURL])
                    }
                    if let backupURL {
                        Button("Show Backup") { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }
                    }
                }
                .accessibilityLabel(Text("Setup Options for \(target.kind.name)"))
                .disabled(isAdding)
            }
        }
        .task(id: configurationURL) { await refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshStatus() }
        }
    }

    private var configurationURL: URL {
        selectedURL ?? target.configurationURL
    }

    private var isAdded: Bool {
        installation != .absent
    }

    /// The paired client whose token this entry passes. A missing, revoked or unknown token is not paired.
    private var paired: PairedClient? {
        guard case .installed(let token?) = installation else { return nil }
        return trustStore.client(forToken: token)
    }

    private var canPair: Bool {
        isAdded && paired == nil && trustStore.isAvailable
    }

    private var caption: String? {
        if isAdding {
            return String(localized: "Adding WSurf…")
        } else if let message {
            return message
        } else if !isAdded && !target.isDetected && selectedURL == nil {
            return String(localized: "Not detected. Install the client or choose its configuration file.")
        } else if canPair {
            return String(localized: "Not paired. It asks for approval each time it connects.")
        } else if let paired {
            return String(localized: "Paired as \(paired.name)")
        }
        return nil
    }

    private func add() {
        refreshID = UUID()
        var destination = target
        destination.configurationURL = configurationURL
        isAdding = true
        message = nil
        Task {
            var failure: String?
            do {
                if trustStore.isAvailable {
                    backupURL = try await installer.pair(destination, command: MCPClientConfiguration.command, trustStore: trustStore).backupURL
                } else {
                    backupURL = try await installer.install(destination, command: MCPClientConfiguration.command).backupURL
                }
            } catch {
                failure = error.localizedDescription
            }
            isAdding = false
            await refreshStatus()
            if let failure {
                message = failure
            }
        }
    }

    private func refreshStatus() async {
        guard !isAdding else { return }
        let id = UUID()
        refreshID = id
        isChecking = true
        var destination = target
        destination.configurationURL = configurationURL
        defer {
            if refreshID == id {
                isChecking = false
            }
        }
        do {
            let found = try await installer.installation(destination, command: MCPClientConfiguration.command)
            guard !Task.isCancelled, refreshID == id, !isAdding else { return }
            installation = found
            message = nil
        } catch {
            guard !Task.isCancelled, refreshID == id, !isAdding else { return }
            installation = .absent
            message = error.localizedDescription
        }
    }

    private func chooseConfiguration() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Configuration")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = configurationURL.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            selectedURL = url
            installation = .absent
            message = nil
            backupURL = nil
        }
    }
}
