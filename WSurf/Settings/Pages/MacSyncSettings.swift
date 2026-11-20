// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfVault

struct MacSyncSettings: View {
    let coordinator: AppCoordinator
    private var profile: Profile {
        coordinator.context.profile
    }

    var body: some View {
        SettingsPageHeader(title: "Sync", caption: "Choose what this Mac shares through your Apple Account.")
        if profile.isPrivate {
            Text("Switch to a regular profile to manage iCloud sync.")
        } else if let cloud = CloudSync.shared, let settings = cloud.settingsSync {
            SharedProfileLinkSection(profile: profile, cloud: cloud)
                .task {
                    settings.registerProfile?(profile)
                    settings.refreshAccountVerification()
                }
            SharedSpacesSettingsView(profile: profile, cloud: cloud)
                .settingsAnchor("sync.spaces")
            ProfileICloudTabsSection(profile: profile)
                .settingsAnchor("sync.otherDevices")
            VaultSharingSettings(coordinator: coordinator, cloud: cloud)
                .settingsAnchor("sync.vaults")
            MacSettingOptions(settings: settings, profile: profile, cloudProfileID: cloud.sharedSpaces?.cloudProfileID(for: profile.id))
            MacWebsiteSyncApprovalSection(profile: profile)
            ProviderKeySyncSection(profile: profile)
                .settingsAnchor("sync.keys")
        } else {
            Text("This copy of WSurf doesn’t have access to iCloud sync.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct MacSettingOptions: View {
    let settings: CloudSettingsSync
    let profile: Profile
    let cloudProfileID: UUID?
    @State private var working = false

    var body: some View {
        SettingsSection(title: "Website settings", symbol: "globe") {
            switchRow("Share website settings", category: .websiteSettings, global: false)
        }
        .settingsAnchor("sync.websites")
        SettingsSection(title: "AI providers", symbol: "sparkles") {
            switchRow("Share custom providers", category: .providers, global: true)
            RowSeparator()
            switchRow("Share model choices for this profile", category: .providers, global: false)
        }
        .settingsAnchor("sync.providers")
        if settings.hasPendingOptOuts {
            HStack {
                Text("Sync is paused for the settings you turned off. Try again to save this choice.").foregroundStyle(.secondary)
                Button("Try Again") { settings.beat() }
            }
        } else if let notice = settings.notice {
            HStack {
                Text(verbatim: notice).foregroundStyle(.secondary)
                if settings.checkpointUnavailable || settings.hasConfirmedChannels {
                    Button("Try Again") { settings.beat() }
                }
            }
        }
    }

    @ViewBuilder
    private func switchRow(_ title: LocalizedStringResource, category: MacSettingsCategory, global: Bool) -> some View {
        let local = global ? nil : profile.id
        let channel = settings.channel(category, localProfileID: local)
        let turningOff = settings.isTurningOff(category, localProfileID: local)
        DetailRow(title: title, caption: global || cloudProfileID != nil ? nil : "Choose an iCloud profile above to share these settings.") {
            SettingsToggle(
                Binding(
                    get: { channel != nil || turningOff },
                    set: { enabled in
                        if enabled {
                            enroll { try await settings.enable(category, localProfileID: local, cloudProfileID: global ? nil : cloudProfileID) }
                        } else {
                            do { try settings.disable(category, localProfileID: local) } catch { settings.reportError() }
                        }
                    })
            )
            .disabled(settings.checkpointUnavailable || turningOff || (channel == nil && (working || (!global && cloudProfileID == nil))))
        }
        if let channel {
            if channel.needsConfirmation {
                HStack {
                    Text("Confirm to share these settings with your current Apple Account.").foregroundStyle(.secondary)
                    Button("Confirm Sharing") {
                        enroll { try await settings.confirmEnrollment(channel) }
                    }
                    .disabled(working)
                }
            }
            let pending = channel.records.values.filter { $0.pending != nil && !$0.conflict }.count
            if pending > 0 {
                Text("\(pending) changes waiting to sync.").foregroundStyle(.secondary)
            } else if let last = channel.lastSync {
                Text("Last synced \(last.formatted()).").foregroundStyle(.secondary)
            }
            ForEach(channel.records.keys.filter { channel.records[$0]?.conflict == true }.sorted(), id: \.self) { key in
                RowSeparator()
                DetailRow(verbatimTitle: key, verbatimCaption: String(localized: "This setting differs on this Mac and in iCloud.")) {
                    Button("Use This Mac") { resolve(key, channel, cloud: false) }
                    Button("Use iCloud") { resolve(key, channel, cloud: true) }
                }
            }
        }
    }

    private func enroll(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        Task {
            defer { working = false }
            do {
                try await action()
            } catch is CancellationError {
                // The enrollment changed while this action was waiting.
            } catch {
                settings.reportError()
            }
        }
    }

    private func resolve(_ key: String, _ channel: MacSettingChannel, cloud: Bool) {
        do { try settings.resolve(key, in: channel.zone, useCloud: cloud) } catch { settings.reportError() }
    }
}

private struct VaultSharingSettings: View {
    let coordinator: AppCoordinator
    let cloud: CloudSync
    @State private var model: CredentialSettingsModel
    @State private var work: Task<Void, Never>?

    init(coordinator: AppCoordinator, cloud: CloudSync) {
        self.coordinator = coordinator
        self.cloud = cloud
        _model = State(initialValue: CredentialSettingsModel(profile: coordinator.context.profile))
    }

    var body: some View {
        SettingsSection(title: "Credential vaults", symbol: "lock.icloud") {
            DetailRow(title: "Find my vaults in iCloud", caption: "Choose separately which vaults to share from this Mac.") {
                SettingsToggle(Binding(get: { cloud.vaults != nil }, set: { cloud.setVaultDiscovery($0) }))
            }
            if cloud.vaults != nil, let first = model.vaults.first {
                RowSeparator()
                DetailRow(title: "Vault") {
                    SettingsMenu(
                        options: model.vaults.map { .init(value: $0.vaultID, label: $0.label) },
                        selection: Binding(
                            get: { model.selectedVaultID ?? first.vaultID },
                            set: { id in Task { await model.select(vaultID: id) } }
                        ))
                }
                CloudVaultRow(model: model, run: run)
            }
            ForEach(model.retryableSyncedVaults) { retry in
                RowSeparator()
                VaultAdoptionRetryRow(retry: retry, isBusy: model.isBusy) {
                    guard let window = coordinator.nativeWindow, window.isVisible else {
                        model.error = String(localized: "Couldn’t find this window to show the passkey prompt. Bring it to the front and try again.")
                        return
                    }
                    run { await model.retrySyncedVault(retry, in: window) }
                }
            }
            if let error = model.error {
                Text(verbatim: error).foregroundStyle(.secondary)
            }
            if cloud.vaults != nil {
                RowSeparator()
                DetailRow(title: "Manage credential vaults", caption: "Unlock a vault, add a vault from another Mac or review changes.") {
                    Button("Open Vaults…") { coordinator.routeSettings(to: .autofill) }
                }
            }
        }
        .onDisappear { work?.cancel() }
        .task(id: cloud.vaults != nil) {
            if cloud.vaults != nil {
                await model.load()
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        let epoch = model.authorizationEpoch
        work?.cancel()
        work = Task {
            guard model.authorizationEpoch == epoch else { return }
            await model.attempt { try await action() }
        }
    }
}
