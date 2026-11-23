// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfCore
import WSurfVault

struct MacSyncSettings: View {
    let coordinator: AppCoordinator
    private var profile: Profile {
        coordinator.context.profile
    }

    var body: some View {
        SettingsPageHeader(title: "Sync", caption: "Choose what stays in sync across WSurf on your Apple Account.")
            .task(id: profile.id) {
                guard !profile.isPrivate, let settings = CloudSync.shared?.settingsSync else { return }
                settings.registerProfile?(profile)
                settings.refreshAccountVerification()
            }
        if profile.isPrivate {
            SettingsCard {
                SettingsEmptyState(symbol: "person.crop.circle", title: "Switch to a regular profile to manage iCloud sync.")
            }
        } else if let cloud = CloudSync.shared, let settings = cloud.settingsSync {
            if let host = cloud.sharedSpaces {
                SharedProfileLinkSection(profile: profile, host: host)
                    .settingsAnchor("sync.profiles")
                SharedSpacesSettingsView(profile: profile, host: host, coordinator: coordinator)
                    .settingsAnchor("sync.spaces")
            }
            ProfileICloudTabsSection(profile: profile)
                .settingsAnchor("sync.otherDevices")
            VaultSharingSettings(profile: profile, coordinator: coordinator, cloud: cloud)
                .id(profile.id)
                .settingsAnchor("sync.vaults")
            MacSettingOptions(settings: settings, profile: profile, cloudProfileID: cloud.sharedSpaces?.cloudProfileID(for: profile.id))
            MacWebsiteSyncApprovalSection(profile: profile)
            ProviderKeySyncSection(profile: profile)
                .settingsAnchor("sync.keys")
        } else {
            SettingsCard {
                SettingsEmptyState(symbol: "icloud", title: "This copy of WSurf doesn’t have access to iCloud sync.")
            }
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
            switchRow("Share website settings", scope: "Sync preferences like zoom and browser engine for websites in this profile.", category: .websiteSettings, global: false)
        }
        .settingsAnchor("sync.websites")
        SettingsSection(title: "AI providers", symbol: "sparkles") {
            switchRow("Sync custom provider definitions", scope: "Sync the names and server addresses of custom AI providers across all profiles.", category: .providers, global: true)
            RowSeparator()
            switchRow(
                "Sync model choices for this profile", scope: "Sync this profile’s selected provider, model and reasoning settings. API keys have their own controls below.",
                category: .providers, global: false
            )
        }
        .settingsAnchor("sync.providers")
        if let notice = settings.hasPendingOptOuts ? String(localized: "Sync is paused for the settings you turned off. Try again to save this choice.") : settings.notice {
            SettingsCard {
                DetailRow(verbatimTitle: notice) {
                    if settings.hasPendingOptOuts || settings.checkpointUnavailable || settings.hasConfirmedChannels {
                        SettingsButton(title: "Try Again") { settings.beat() }
                    }
                }
            }
        }
    }

    private func caption(for channel: MacSettingChannel?, needsProfile: Bool) -> LocalizedStringResource? {
        if let channel {
            let pending = channel.records.values.filter { $0.pending != nil && !$0.conflict }.count
            if pending > 0 { return "\(pending) changes waiting to sync." }
            if let last = channel.lastSync { return "Last synced \(last.formatted())." }
        }
        return needsProfile ? "Choose an iCloud profile above to share these settings." : nil
    }

    @ViewBuilder
    private func switchRow(_ title: LocalizedStringResource, scope: LocalizedStringResource, category: MacSettingsCategory, global: Bool) -> some View {
        let local = global ? nil : profile.id
        let channel = settings.channel(category, localProfileID: local)
        let turningOff = settings.isTurningOff(category, localProfileID: local)
        let summary = [scope, caption(for: channel, needsProfile: !global && cloudProfileID == nil)]
            .compactMap { $0 }.map { String(localized: $0) }.joined(separator: "\n")
        DetailRow(verbatimTitle: String(localized: title), verbatimCaption: summary) {
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
                RowSeparator()
                DetailRow(title: "Confirm to share these settings with your current Apple Account.") {
                    SettingsButton(title: "Confirm Sharing") {
                        enroll { try await settings.confirmEnrollment(channel) }
                    }
                    .disabled(working)
                }
            }
            ForEach(channel.records.keys.filter { channel.records[$0]?.conflict == true }.sorted(), id: \.self) { key in
                RowSeparator()
                DetailRow(verbatimTitle: key, verbatimCaption: String(localized: "This setting differs on this Mac and in iCloud."), layout: .stacked) {
                    ChipFlow(spacing: 8) {
                        SettingsButton(title: "Use This Mac") { resolve(key, channel, cloud: false) }
                        SettingsButton(title: "Use iCloud") { resolve(key, channel, cloud: true) }
                    }
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
    @State private var showsVaultMerge = false
    @State private var heldVaults: Set<VaultMergeOption.ID> = []

    init(profile: Profile, coordinator: AppCoordinator, cloud: CloudSync) {
        self.coordinator = coordinator
        self.cloud = cloud
        _model = State(initialValue: CredentialSettingsModel(profile: profile))
    }

    var body: some View {
        SettingsSection(title: "Credential vaults", symbol: "lock.icloud") {
            DetailRow(
                title: "Find and sync iCloud vaults",
                caption: "Find encrypted vaults from your other Macs and resume sync for vaults you’ve already enabled. To share a vault, turn on sync for that vault."
            ) {
                SettingsToggle(Binding(get: { cloud.vaults != nil }, set: { cloud.setVaultDiscovery($0) }))
            }
            if let first = model.vaults.first {
                RowSeparator()
                DetailRow(verbatimTitle: String(localized: "Vaults for \(ProfileSummary.displayName(for: model.profile))")) {
                    SettingsMenu(
                        options: model.vaults.map { .init(value: $0.vaultID, label: $0.label, detail: vaultStatus($0.vaultID)) },
                        selection: Binding(
                            get: { model.selectedVaultID ?? first.vaultID },
                            set: { id in Task { await model.select(vaultID: id) } }
                        ))
                }
                if !model.isUnlocked, model.selectedVaultID != nil {
                    RowSeparator()
                    DetailRow(title: "Vault is locked") {
                        SettingsButton(title: "Unlock…") {
                            useWindow { await model.unlock(in: $0) }
                        }
                        .disabled(model.isBusy)
                    }
                }
                CloudVaultRow(model: model, run: run)
            }
            CredentialVaultMergeRow(model: model, showsAllVaults: true) { showsVaultMerge = true }
            ForEach(model.retryableSyncedVaults) { retry in
                RowSeparator()
                VaultAdoptionRetryRow(retry: retry, isBusy: model.isBusy) {
                    useWindow { await model.retrySyncedVault(retry, in: $0) }
                }
            }
            if let error = model.error {
                SettingsNotice(symbol: "exclamationmark.triangle", text: error)
            }
            RowSeparator()
            DetailRow(title: "Manage vaults in Autofill", caption: "Manage unlock methods, autofill defaults and review changes from iCloud.") {
                SettingsButton(title: "Open Vaults…") { coordinator.routeSettings(to: .autofill) }
            }
        }
        .modifier(CredentialVaultMergePresentation(model: model, isPresented: $showsVaultMerge))
        .onDisappear { work?.cancel() }
        .task(id: cloud.vaults != nil) { await model.load() }
        .task(id: discoveryVersions) {
            guard cloud.vaults != nil else { return }
            var held = Set<VaultMergeOption.ID>()
            for profile in coordinator.profiles.profiles where profile.id != model.profile.id && !profile.isPrivate {
                guard let store = try? CredentialManager.store(for: profile), let listing = try? await store.listing() else { continue }
                held.formUnion(listing.map { .init(profileID: profile.id, vaultID: $0.vaultID) })
            }
            if !Task.isCancelled {
                heldVaults = held
            }
        }
        if let vaults = cloud.vaults {
            discoveredVaults(vaults)
        }
    }

    private var discoveryVersions: [UUID: UInt64]? {
        guard cloud.vaults != nil else { return nil }
        return Dictionary(uniqueKeysWithValues: coordinator.profiles.profiles.map { ($0.id, VaultStateChanges.shared.count(for: $0.id)) })
    }

    private func vaultStatus(_ id: UUID) -> String {
        guard let vaults = cloud.vaults, vaults.status(profileID: model.profile.id, vaultID: id) != .enrollmentUnavailable else { return "" }
        return vaults.isSyncing(profileID: model.profile.id, vaultID: id) ? String(localized: "Shared via iCloud") : String(localized: "Sync off on this Mac")
    }

    private func discoveredVaults(_ vaults: VaultSync) -> some View {
        let remoteProfiles = vaults.remoteProfiles()
        let alreadyHere = coordinator.profiles.profiles.filter { profile in
            profile.id != model.profile.id && vaults.remoteVaults(profileID: profile.id).contains {
                !heldVaults.contains(.init(profileID: profile.id, vaultID: $0.vaultID))
            }
        }
        let available = model.addableSyncedVaults
        return SettingsSection(title: "iCloud vaults from other Macs", symbol: "icloud.and.arrow.down") {
            if available.isEmpty && remoteProfiles.isEmpty && alreadyHere.isEmpty {
                DetailRow(title: "No additional vaults found", caption: "Vaults you’ve already added appear with the vaults for their profile.") { EmptyView() }
            }
            ForEach(Array(available.enumerated()), id: \.element.id) { index, vault in
                if index > 0 {
                    RowSeparator()
                }
                let title = ProfileSummary.publishedName(vault.payload.profile.name, source: vault.payload.profile.publicationSource)
                let ready = model.canAddSyncedVault(vault)
                let keyCheck: String? = if case .keyDiffers(let id, let check) = model.syncAddFailure, id == vault.id { check } else { nil }
                DetailRow(
                    verbatimTitle: title,
                    verbatimCaption: adoptionCaption(ready: ready, keyCheck: keyCheck)
                ) {
                    SettingsButton(title: keyCheck == nil ? "Add to This Mac…" : "Try Again…") { useWindow { await model.addSyncedVault(vault, in: $0) } }
                        .disabled(model.isBusy || (!ready && keyCheck == nil))
                }
            }
            ForEach(alreadyHere) { profile in
                RowSeparator()
                DetailRow(verbatimTitle: ProfileSummary.displayName(for: profile), verbatimCaption: String(localized: "Open this profile to view or add its iCloud vaults.")) {
                    SettingsButton(title: "Show Profiles…") { coordinator.routeSettings(to: .profiles) }
                }
            }
            ForEach(remoteProfiles, id: \.id) { remote in
                RowSeparator()
                DetailRow(
                    verbatimTitle: ProfileSummary.publishedName(remote.card.name, source: remote.card.publicationSource),
                    verbatimCaption: String(localized: "Add this profile on this Mac to use its iCloud vaults.")
                ) {
                    SettingsButton(title: "Show Profiles…") { coordinator.routeSettings(to: .profiles) }
                }
            }
        }
    }

    private func adoptionCaption(ready: Bool, keyCheck: String?) -> String {
        if let keyCheck {
            return String(localized: "This passkey couldn’t open the vault. Key check on this Mac: \(keyCheck)")
        }
        return ready ? String(localized: "Use the vault’s unlock passkey to add it to this Mac.")
            : String(localized: "Unlock one of this profile’s vaults above before adding this vault.")
    }

    private func useWindow(_ action: @escaping (NSWindow) async -> Void) {
        guard let window = coordinator.nativeWindow, window.isVisible else {
            model.error = String(localized: "Couldn’t find this window to show the passkey prompt. Bring it to the front and try again.")
            return
        }
        run { await action(window) }
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
