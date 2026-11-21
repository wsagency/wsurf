// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation
import WSurfCore

/// Each eligible feature uses the same private iCloud engine. It starts when the Mac has an opted-in category or outstanding work.
@Observable
final class CloudSync {
    /// Set once by `startIfAvailable`, before any window exists. Tests set it and reset it in a serial suite.
    static var shared: CloudSync?

    static var stateFile: URL {
        AppDatabase.supportDirectory.appendingPathComponent("iCloudSync.json")
    }

    let router: SyncRouter
    /// Also `CloudTabs.shared`, which the tab hooks read.
    private(set) var tabs: CloudTabs?
    private(set) var vaults: VaultSync?
    let sharedSpaces: CloudSharedSpaces?
    let settingsSync: CloudSettingsSync?

    var heartbeatInterval: Duration = .seconds(15 * 60)
    var quitLimit: Duration = .seconds(2)

    private let clock: any Clock<Duration>
    private let makeEngine: @MainActor (any SyncEngineDelegate, Data?) -> any SyncEngine
    private var engine: (any SyncEngine)?
    @ObservationIgnored private var startOtherDevices: (() -> CloudTabs?)?
    private var attachedTabs = false
    private var attachedVaults = false
    @ObservationIgnored private var vaultCatalogTask: Task<Void, Never>?
    @ObservationIgnored private var makeVaults: (() -> VaultSync)?
    @ObservationIgnored private var rememberVaultDiscovery: ((Bool) -> Void)?
    @ObservationIgnored private var profileStore: ProfileStore?
    @ObservationIgnored private var removingVaultZones: Set<VaultProfileRemoval> = []
    private var attachedSpaces = false
    private var attachedSettings = false
    private var isTerminating = false
    private var heartbeatTask: Task<Void, Never>?

    @discardableResult
    static func startIfAvailable(profileStore: ProfileStore) -> CloudSync? {
        shared = start(
            gate: .live, installIDs: KeychainInstallIDStorage(), stateFile: stateFile, profiles: profileStore.profiles, profileStore: profileStore,
            rememberOtherDevices: { UserDefaults.standard.set(true, forKey: CloudSyncGate.tabsFlagKey) },
            rememberVaultDiscovery: { UserDefaults.standard.set($0, forKey: CloudSyncGate.vaultFlagKey) }
        )
        shared?.settingsSync?.startMonitoringAccount()
        return shared
    }

    /// `stateFile` is the router's file; tab sharing keeps its own beside it. Neither feature starts unless its flag, the signed
    /// entitlements and the environment allow it (and, for tabs, the install ID is readable).
    static func start(
        gate: CloudSyncGate.Inputs,
        installIDs: any InstallIDStorage,
        stateFile: URL,
        profiles: [Profile],
        profileStore: ProfileStore? = nil,
        host: @escaping @MainActor () -> any VaultSyncHost = { CredentialVaultSyncHost() },
        rememberOtherDevices: @escaping @MainActor () -> Void = {},
        rememberVaultDiscovery: @escaping @MainActor (Bool) -> Void = { _ in },
        optInDefaults: @escaping @MainActor (Profile) -> UserDefaults = ProfileSettingsStore.defaults(for:),
        windows: @escaping @MainActor () -> [BrowserModel] = CloudTabs.liveWindows,
        clock: any Clock<Duration> = ContinuousClock(),
        makeEngine: @escaping @MainActor (any SyncEngineDelegate, Data?) -> any SyncEngine = CloudSync.cloudKitEngine
    ) -> CloudSync? {
        let makeTabs = {
            InstallID.resolve(installIDs).map {
                CloudTabs.make(
                    installID: $0, stateFile: CloudTabs.stateFile(besides: stateFile), profiles: profiles, optInDefaults: optInDefaults,
                    windows: windows, clock: clock
                )
            }
        }
        let tabs = CloudSyncGate.allowsTabs(gate) ? makeTabs() : nil
        let allowsVaults = CloudSyncGate.allowsVaults(gate)
        let offersMacSync = CloudSyncGate.canOfferMacSync(gate)
        guard tabs != nil || allowsVaults || offersMacSync else { return nil }
        let directory = stateFile.deletingLastPathComponent()
        let spaces = offersMacSync ? CloudSharedSpaces(
            stateFile: directory.appending(path: "iCloudSharedSpaces.json"), profiles: profiles, profileStore: profileStore, windows: windows
        ) : nil
        let settings = offersMacSync ? CloudSettingsSync(
            stateFile: directory.appending(path: "iCloudMacSettings.json"), profiles: profiles, profileStore: profileStore, clock: clock
        ) : nil
        // A missing or damaged file starts empty, which fetches everything once.
        let restored = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(SyncRouterState.self, from: $0) }
            ?? SyncRouterState()
        let keeper = RouterBox()
        let makeVaults = {
            var state = keeper.router?.state.vaults ?? restored.vaults
            if offersMacSync {
                state.remote = [:]
            }
            return VaultSync(host: host(), state: state, persist: { keeper.router?.setVaults($0) }, excludedProfiles: [Profile.privateID], clock: clock)
        }
        let vaults = allowsVaults ? makeVaults() : nil
        let router = SyncRouter(
            state: restored, persist: { JSONFileStore.encodeAndWrite($0, to: stateFile) }, tabs: tabs?.sync, vaults: offersMacSync ? nil : vaults,
            additional: [spaces?.catalog as (any SyncZoneHandler)?, settings as (any SyncZoneHandler)?].compactMap { $0 }
        )
        keeper.router = router
        let cloudSync = CloudSync(router: router, tabs: tabs, vaults: vaults, sharedSpaces: spaces, settingsSync: settings, clock: clock, makeEngine: makeEngine)
        cloudSync.profileStore = profileStore
        if let profileStore {
            router.isLiveVaultProfile = { id in id == Profile.originalID || profileStore.verifiedProfiles?.contains { $0.id == id } == true }
            profileStore.onVaultRemoval = { [weak cloudSync] in cloudSync?.ensureEngine() }
        }
        if offersMacSync {
            cloudSync.startOtherDevices = {
                guard let sharing = makeTabs() else { return nil }
                rememberOtherDevices()
                return sharing
            }
            cloudSync.makeVaults = makeVaults
            cloudSync.rememberVaultDiscovery = rememberVaultDiscovery
            router.accountChanged = { [weak cloudSync] change in
                switch change {
                case .signOut, .switchAccounts:
                    cloudSync?.setVaultDiscovery(false)
                case .signIn(let user):
                    if let old = cloudSync?.vaults?.state.accountUser, old != user {
                        cloudSync?.setVaultDiscovery(false)
                    }
                }
            }
        }
        settings?.onAccountVerification = { [weak spaces] in spaces?.accountVerificationChanged($0) }
        spaces?.onNeedsEngine = { [weak cloudSync] in cloudSync?.ensureEngine() }
        settings?.onNeedsEngine = { [weak cloudSync] in cloudSync?.ensureEngine() }
        tabs?.needsEngine = { [weak cloudSync] in cloudSync?.ensureEngine() }
        cloudSync.ensureEngine()
        if offersMacSync, let profileStore, profileStore.verifiedProfiles == nil {
            // Saved enrollments can be waiting on the local profile list before any feature can start the engine.
            cloudSync.startHeartbeat()
        }
        spaces?.beat()
        settings?.beat()
        return cloudSync
    }

    /// The only place that builds the CloudKit engine.
    static func cloudKitEngine(_ delegate: any SyncEngineDelegate, _ state: Data?) -> any SyncEngine {
        CloudKitSyncEngine(containerIdentifier: CloudSyncGate.container, state: state, delegate: delegate)
    }

    /// Hands the router to a closure made before the router exists.
    private final class RouterBox {
        weak var router: SyncRouter?
    }

    private init(
        router: SyncRouter,
        tabs: CloudTabs?,
        vaults: VaultSync?,
        sharedSpaces: CloudSharedSpaces?,
        settingsSync: CloudSettingsSync?,
        clock: any Clock<Duration>,
        makeEngine: @escaping @MainActor (any SyncEngineDelegate, Data?) -> any SyncEngine
    ) {
        self.router = router
        self.tabs = tabs
        self.vaults = vaults
        self.sharedSpaces = sharedSpaces
        self.settingsSync = settingsSync
        self.clock = clock
        self.makeEngine = makeEngine
    }

    /// Other Devices starts on the first explicit choice and reuses the existing Personal session on later launches.
    @discardableResult
    func setOtherDeviceSharing(_ on: Bool, for profile: Profile) -> Bool {
        guard CloudTabs.canShare(profile) else { return false }
        if tabs == nil {
            guard on else { return true }
            guard let sharing = startOtherDevices?() else { return false }
            sharing.needsEngine = { [weak self] in self?.ensureEngine() }
            router.routeTabs(to: sharing.sync)
            tabs = sharing
        }
        tabs?.setOptIn(on, for: profile)
        return true
    }

    /// The category switch controls discovery. Each individual vault still requires its own opt-in.
    func setVaultDiscovery(_ on: Bool) {
        guard let makeVaults, on != (vaults != nil) else { return }
        rememberVaultDiscovery?(on)
        if on {
            vaults = makeVaults()
            ensureEngine()
        } else {
            vaultCatalogTask?.cancel()
            vaultCatalogTask = nil
            router.routeVaults(to: nil)
            vaults?.pauseDiscovery()
            vaults = nil
            attachedVaults = false
        }
    }

    private func refreshVaultCatalog(_ sync: VaultSync, engine: any SyncEngine) {
        guard vaultCatalogTask == nil, let identity = engine as? any SyncAccountIdentity,
              let reader = engine as? any VaultCatalogReading else { return }
        vaultCatalogTask = Task { [weak self] in
            guard let self else { return }
            defer { if vaults === sync { vaultCatalogTask = nil } }
            do {
                let user = try await identity.currentAccountUser()
                guard vaults === sync, !Task.isCancelled else { return }
                if !attachedVaults || user != sync.state.accountUser, !sync.acceptDiscoveryAccount(user) {
                    setVaultDiscovery(false)
                    return
                }
                let cards = try? await reader.fetchVaultCards()
                let current = try await identity.currentAccountUser()
                guard vaults === sync, !Task.isCancelled else { return }
                guard current == user else {
                    _ = sync.acceptDiscoveryAccount(current)
                    setVaultDiscovery(false)
                    return
                }
                if let cards {
                    sync.refreshAvailableVaults(cards, for: current)
                }
                if attachedVaults {
                    sync.beat()
                } else if cards != nil {
                    router.routeVaults(to: sync)
                    attachedVaults = true
                    sync.attach(engine)
                }
            } catch {
                // A later heartbeat retries discovery and checks the account again.
            }
        }
    }

    // MARK: - Hooks

    /// A write reached a vault: its sync produces after a quiet moment. Does nothing for a vault that is not synced here.
    func noteVaultWrite(profileID: UUID, vaultID: UUID) {
        vaults?.noteWrite(profileID: profileID, vaultID: vaultID)
    }

    // MARK: - Engine and lifecycle

    // ponytail: no registerForRemoteNotifications yet; add it at launch if pushes do not arrive (the heartbeat fetches meanwhile).
    /// Creates the engine once, and only when this Mac shares tabs, still owns tab records on the server that it must delete, or syncs
    /// vaults (the flag is the consent to fetch). Each feature is attached the first time it needs the engine.
    private func ensureEngine() {
        let wantsTabs = tabs?.sync.needsEngine == true
        let wantsSpaces = sharedSpaces?.needsEngine == true
        let wantsSettings = settingsSync?.needsEngine == true
        let withdrawals = profileStore?.vaultRemovals ?? []
        guard wantsTabs || vaults != nil || wantsSpaces || wantsSettings || !withdrawals.isEmpty else { return }
        let engine = engine ?? makeEngine(router, router.state.engineState)
        self.engine = engine
        if let profileStore, let transport = engine as? any VaultProfileZoneDeleting {
            for removal in withdrawals where removingVaultZones.insert(removal).inserted {
                Task {
                    defer { removingVaultZones.remove(removal) }
                    do {
                        try await transport.deleteVaultZone(removal)
                        try profileStore.acknowledgeVaultRemoval(removal)
                    } catch {
                        // The profile list keeps this exact owner's withdrawal for the next heartbeat or launch.
                    }
                }
            }
        }
        if wantsTabs, !attachedTabs, let tabs {
            attachedTabs = true
            tabs.sync.attach(engine)
        }
        if !attachedVaults, let vaults {
            if makeVaults != nil {
                refreshVaultCatalog(vaults, engine: engine)
            } else {
                attachedVaults = true
                vaults.attach(engine)
            }
        }
        if wantsSpaces, !attachedSpaces, let sharedSpaces {
            attachedSpaces = true
            sharedSpaces.attach(engine)
        }
        if wantsSettings, !attachedSettings, let settingsSync {
            attachedSettings = true
            settingsSync.attach(engine)
        }
        startHeartbeat()
    }

    /// The heartbeat: every feature sends again what is waiting and fetches.
    func beat() {
        if profileStore?.vaultRemovals.isEmpty == false {
            ensureEngine()
        }
        tabs?.beat()
        if let vaults, let engine, makeVaults != nil {
            refreshVaultCatalog(vaults, engine: engine)
        } else if attachedVaults {
            vaults?.beat()
        } else if vaults != nil {
            ensureEngine()
        }
        sharedSpaces?.beat()
        settingsSync?.beat()
    }

    private func startHeartbeat() {
        guard heartbeatTask == nil, !isTerminating else { return }
        heartbeatTask = Task { [weak self, clock, heartbeatInterval] in
            do {
                try await clock.sleep(for: heartbeatInterval)
            } catch {
                return
            }
            guard let self else { return }
            heartbeatTask = nil
            beat()
            startHeartbeat()
        }
    }

    /// Quit begins: tabs publish their final session as offline, and nothing is sent on a timer any more.
    func prepareToTerminate() {
        isTerminating = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
        tabs?.prepareToTerminate()
    }

    /// Quit was cancelled: the device is live again.
    func cancelTermination() {
        isTerminating = false
        if engine != nil {
            startHeartbeat()
        }
        tabs?.cancelTermination()
    }

    /// Sends what is waiting, for at most `quitLimit`. A stuck network must not hold the quit.
    func sendBeforeQuit() async {
        guard let engine else { return }
        let finish = Finish()
        let send = Task {
            try? await engine.sendNow()
            finish.complete()
        }
        let limit = Task { [clock, quitLimit] in
            try? await clock.sleep(for: quitLimit)
            finish.complete()
        }
        await finish.wait()
        send.cancel()
        limit.cancel()
    }

    /// Resumes one waiter the first time either competitor finishes.
    private final class Finish {
        private var continuation: CheckedContinuation<Void, Never>?
        private var isComplete = false

        func wait() async {
            await withCheckedContinuation { continuation in
                if isComplete {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }

        func complete() {
            isComplete = true
            continuation?.resume()
            continuation = nil
        }
    }
}
