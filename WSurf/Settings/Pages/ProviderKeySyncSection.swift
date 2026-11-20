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
    }

    var body: some View {
        if !profile.isPrivate {
            SettingsSection(title: "Saved provider keys", symbol: "key.icloud") {
                DetailRow(title: "Share saved keys with iCloud Keychain") {
                    SettingsToggle(Binding(get: { enabled }, set: { next in
                        guard !next || (account != nil && account == keys.accountContext) else { return }
                        confirmation = nil
                        perform { try keys.setEnabled(next) }
                    }))
                    .disabled(account == nil && !enabled)
                }
                if account == nil {
                    Footnote("A verified Apple Account is required to share saved keys.")
                }
                if enabled || catalog.custom.contains(where: keys.needsEndpointApproval) {
                    providerControls
                }
                if let status {
                    Text(verbatim: status).font(.caption).textSelection(.enabled)
                }
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
            Picker("Provider", selection: Binding(get: { choice.id }, set: { id in
                selectedID = id
                status = nil
                confirmation = nil
            })) {
                ForEach(endpoints) { option in
                    if option.isRetired {
                        Text("\(option.provider.name) — previous endpoint (\(option.provider.baseURL?.absoluteString ?? ""))").tag(option.id)
                    } else {
                        Text(verbatim: option.provider.name).tag(option.id)
                    }
                }
            }
            if let url = provider.baseURL {
                Text(verbatim: url.absoluteString).font(.caption).textSelection(.enabled)
            }
            if !choice.isRetired && keys.needsEndpointApproval(provider) {
                Button("Approve changed endpoint…") { confirmation = Request(action: .approveEndpoint, endpoint: choice, account: account) }
            } else if enabled && account != nil {
                HStack {
                    Button("Use shared key…") { confirmation = Request(action: .adopt, endpoint: choice, account: account) }
                    Button("Share this Mac’s key…") { confirmation = Request(action: .publish, endpoint: choice, account: account) }
                }
            }
            if enabled && account != nil {
                if participating.contains(choice.id) {
                    Button("Pause this key") { perform { keys.pause(provider) } }
                }
                Button("Remove shared copy…", role: .destructive) { confirmation = Request(action: .remove, endpoint: choice, account: account) }
            }
            if let request = confirmation, request.endpoint.provider == provider, request.endpoint.isRetired == choice.isRetired, request.account == account {
                confirm(request)
            }
        }
    }

    @ViewBuilder private func confirm(_ request: Request) -> some View {
        let provider = request.endpoint.provider
        let endpoint = provider.baseURL?.absoluteString ?? ""
        switch request.action {
        case .publish:
            Text("Replace the shared key for \(endpoint) with this Mac’s saved key?")
        case .adopt:
            Text("Use the shared key for \(endpoint) and save a local copy on this Mac?")
        case .approveEndpoint:
            Text("Allow this provider’s previously saved key to be used at \(endpoint)?")
        case .remove:
            Text("Remove the iCloud Keychain copy for \(endpoint)? Each Mac keeps its local key.")
        }
        HStack {
            Button("Cancel") { confirmation = nil }
            Button("Confirm") {
                confirmation = nil
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
                        ForEach(pending.keys.sorted(), id: \.self) { key in
                            if let grant = pending[key] {
                                review(key, grant: grant)
                            }
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

    @ViewBuilder private func review(_ key: String, grant: SitePermissions.SyncGrant) -> some View {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            if let permission = WebPermission(rawValue: parts[0]) {
                Text("Allow \(String(localized: permission.sentenceName)) for \(parts[1]) on this Mac?")
            } else {
                let target = parts[0] == "default" ? String(localized: "all websites by default") : parts[1]
                let policy = grant.value.flatMap(AssistantAccessPolicy.init(rawValue:)) ?? grant.inheritedAccess ?? BrowserProfileContext.shared(for: profile).sitePermissions.assistantDefault
                Text("Allow assistant access for \(target) on this Mac? \(String(localized: policy.label))")
            }
            HStack {
                Button("Keep local permission") { decide(grant, key: key, allow: false) }
                Button("Allow on this Mac") { decide(grant, key: key, allow: true) }
            }
        }
    }
    private func decide(_ grant: SitePermissions.SyncGrant, key: String, allow: Bool) {
        guard isSharingWebsites else { return }
        MacSettingsSyncAdapter(profiles: [profile]).reviewWebsiteGrant(grant, key: key, profileID: profile.id, allow: allow)
    }

}
