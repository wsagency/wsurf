// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

struct ProviderKeySyncSection: View {
    let profile: Profile
    @State private var enabled = ProviderKeySharing.shared.wantsSharing
    @State private var account = ProviderKeySharing.shared.accountContext
    @State private var selectedID = ""
    @State private var status: String?
    @State private var confirmation: Request?
    @State private var participating: Set<String> = []
    private let keys = ProviderKeySharing.shared
    private let catalog = ProviderCatalog.shared

    private enum Action {
        case publish, adopt, approveEndpoint, remove
    }

    private struct Request {
        let action: Action
        let endpoint: ProviderCatalog.KeyEndpoint
        let account: String?

        var prompt: Text {
            let url = endpoint.provider.baseURL?.absoluteString ?? ""
            return switch action {
            case .publish:
                Text("Replace the shared key for \(url) with this Mac’s saved key?")
            case .adopt:
                Text("Use the shared key for \(url) and save a local copy on this Mac?")
            case .approveEndpoint:
                Text("Allow this provider’s previously saved key to be used at \(url)?")
            case .remove:
                Text("Remove the iCloud Keychain copy for \(url)? Each Mac keeps its local key.")
            }
        }

        var buttonTitle: LocalizedStringResource {
            switch action {
            case .publish:
                "Share Key"
            case .adopt:
                "Use Shared Key"
            case .approveEndpoint:
                "Approve Endpoint"
            case .remove:
                "Remove Shared Copy"
            }
        }
    }

    var body: some View {
        if !profile.isPrivate {
            SettingsSection(
                title: "Saved provider keys", symbol: "key.icloud",
                footnote: account == nil ? "A verified Apple Account is required to share saved keys." : nil
            ) {
                DetailRow(
                    title: "Share saved keys with iCloud Keychain",
                    caption: "Choose an AI provider and share the API key saved for its endpoint in WSurf on this Mac. Each Mac keeps its local key."
                ) {
                    SettingsToggle(Binding(get: { enabled }, set: { next in
                        guard !next || (account != nil && account == keys.accountContext) else { return }
                        confirmation = nil
                        perform { try keys.setEnabled(next) }
                    }))
                    .disabled(account == nil && !enabled)
                }
                if enabled || catalog.custom.contains(where: keys.needsEndpointApproval) {
                    providerControls
                }
                if let status {
                    SettingsNotice(symbol: "info.circle", text: status, level: .idle)
                        .textSelection(.enabled)
                }
            }
            .confirmationDialog(
                confirmation?.prompt ?? Text(verbatim: ""),
                isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                titleVisibility: .visible, presenting: confirmation
            ) { request in
                Button(request.buttonTitle, role: request.action == .remove ? .destructive : nil) { confirm(request) }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { refresh() }
            .onChange(of: catalog.keyEndpoints.map(\.id)) { _, _ in confirmation = nil }
            .onReceive(NotificationCenter.default.publisher(for: .wsurfProviderKeyConsentDidChange)) { _ in refresh() }
        }
    }

    @ViewBuilder private var providerControls: some View {
        let endpoints = catalog.keyEndpoints
        if let choice = endpoints.first(where: { $0.id == selectedID }) ?? endpoints.first {
            let provider = choice.provider
            let canShare = enabled && account != nil
            let needsApproval = !choice.isRetired && keys.needsEndpointApproval(provider)
            RowSeparator()
            DetailRow(verbatimTitle: String(localized: "Provider"), verbatimCaption: provider.baseURL?.absoluteString) {
                SettingsMenu(options: endpoints.map { option in
                    let label = option.isRetired
                        ? String(localized: "\(option.provider.name) — previous endpoint (\(option.provider.baseURL?.absoluteString ?? ""))")
                        : option.provider.name
                    return .init(value: option.id, label: label)
                }, selection: Binding(get: { choice.id }, set: { id in
                    selectedID = id
                    status = nil
                    confirmation = nil
                }))
            }
            .textSelection(.enabled)
            if needsApproval || canShare {
                RowSeparator()
                DetailRow(title: "API key for this endpoint", layout: .stacked) {
                    ChipFlow(spacing: 8) {
                        if needsApproval {
                            SettingsButton(title: "Approve changed endpoint…") { request(.approveEndpoint, for: choice) }
                        } else {
                            SettingsButton(title: "Use shared key…") { request(.adopt, for: choice) }
                            SettingsButton(title: "Share this Mac’s key…") { request(.publish, for: choice) }
                        }
                        if canShare {
                            SettingsMoreMenu {
                                if participating.contains(choice.id) {
                                    Button("Pause this key") { perform { keys.pause(provider) } }
                                }
                                Button("Remove shared copy…", role: .destructive) { request(.remove, for: choice) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func request(_ action: Action, for endpoint: ProviderCatalog.KeyEndpoint) {
        confirmation = Request(action: action, endpoint: endpoint, account: account)
    }

    private func confirm(_ request: Request) {
        confirmation = nil
        let provider = request.endpoint.provider
        guard request.account == keys.accountContext,
              catalog.keyEndpoints.contains(where: { $0.provider == provider && $0.isRetired == request.endpoint.isRetired }) else { return }
        perform {
            switch request.action {
            case .publish:
                try keys.shareLocal(provider)
            case .adopt:
                try keys.useCloud(provider)
            case .approveEndpoint:
                try keys.approveLocalEndpoint(provider)
            case .remove:
                try keys.removeCloudCopy(provider)
            }
            if !request.endpoint.isRetired {
                MacSettingsSyncAdapter.refreshWindows(category: .providers, profileID: nil, key: provider.id)
            }
        }
    }

    private func refresh() {
        let currentAccount = keys.accountContext
        if account != currentAccount {
            account = currentAccount
            confirmation = nil
            status = nil
        }
        enabled = keys.wantsSharing
        participating = Set(catalog.keyEndpoints.filter { keys.participates($0.provider) }.map(\.id))
    }

    private func perform(_ work: () throws -> Void) {
        do {
            try work()
            status = String(localized: "Saved provider key settings updated.")
        } catch {
            status = error.localizedDescription
        }
        enabled = keys.wantsSharing
        NotificationCenter.default.post(name: .wsurfProviderKeyConsentDidChange, object: nil)
    }
}

struct MacWebsiteSyncApprovalSection: View {
    let profile: Profile
    @State private var writeError: String?
    @State private var account = ProviderKeySharing.shared.accountContext

    private var isSharingWebsites: Bool {
        !profile.isPrivate && CloudSync.shared?.settingsSync?.isEnabled(.websiteSettings, localProfileID: profile.id) == true
    }

    var body: some View {
        if isSharingWebsites {
            let sites = BrowserProfileContext.shared(for: profile).sitePermissions
            let pending = sites.pendingSyncGrants.filter { account != nil && $0.value.account == account && $0.value.dismissed != true }
            Group {
                if !pending.isEmpty {
                    SettingsSection(title: "Website permissions to review", symbol: "hand.raised") {
                        let keys = pending.keys.sorted()
                        ForEach(keys, id: \.self) { key in
                            if let grant = pending[key], let question = question(for: key, grant: grant) {
                                DetailRow(title: question, layout: .stacked) {
                                    ChipFlow(spacing: 8) {
                                        SettingsButton(title: "Keep local permission") { decide(grant, key: key, allow: false) }
                                        SettingsButton(title: "Allow on this Mac") { decide(grant, key: key, allow: true) }
                                    }
                                }
                                .separated(above: key != keys.first)
                            }
                        }
                        if let writeError {
                            SettingsNotice(symbol: "exclamationmark.triangle", text: writeError)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .onAppear { account = ProviderKeySharing.shared.accountContext }
            .onReceive(NotificationCenter.default.publisher(for: .wsurfProviderKeyConsentDidChange)) { _ in
                account = ProviderKeySharing.shared.accountContext
            }
        }
    }

    private func question(for key: String, grant: SitePermissions.SyncGrant) -> LocalizedStringResource? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        if let permission = WebPermission(rawValue: parts[0]) {
            return "Allow \(String(localized: permission.sentenceName)) for \(parts[1]) on this Mac?"
        }
        let target = parts[0] == "default" ? String(localized: "all websites by default") : parts[1]
        let policy = grant.value.flatMap(AssistantAccessPolicy.init(rawValue:)) ?? grant.inheritedAccess
            ?? BrowserProfileContext.shared(for: profile).sitePermissions.assistantDefault
        return "Allow assistant access for \(target) on this Mac? \(String(localized: policy.label))"
    }

    private func decide(_ grant: SitePermissions.SyncGrant, key: String, allow: Bool) {
        guard isSharingWebsites else { return }
        let result = MacSettingsSyncAdapter(profiles: [profile]).reviewWebsiteGrant(grant, key: key, profileID: profile.id, allow: allow)
        do {
            try result.get()
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
    }
}
