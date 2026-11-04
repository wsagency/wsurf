// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

/// The one iCloud engine of this install and what rides on it: tab sharing (`CloudTabs`) and vault sync (`VaultSync`). It exists only
/// when `CloudSyncGate` allows at least one of them, so with both hidden flags off or in an unentitled build `shared` stays nil and
/// every hook that asks it is a no-op. It owns the engine, its state file, the heartbeat and the quit, and hands each feature the
/// records of its own zones through `SyncRouter`.
final class CloudSync {
    /// Set once by `startIfAvailable`, before any window exists. Tests set it and reset it in a serial suite.
    static var shared: CloudSync?

    static var stateFile: URL {
        AppDatabase.supportDirectory.appendingPathComponent("iCloudSync.json")
    }

    let router: SyncRouter
    /// Also `CloudTabs.shared`, which the tab hooks read.
    let tabs: CloudTabs?
    let vaults: VaultSync?

    var heartbeatInterval: Duration = .seconds(15 * 60)
    var quitLimit: Duration = .seconds(2)

    private let clock: any Clock<Duration>
    private let makeEngine: @MainActor (any SyncEngineDelegate, Data?) -> any SyncEngine
    private var engine: (any SyncEngine)?
    private var attachedTabs = false
    private var attachedVaults = false
    private var isTerminating = false
    private var heartbeatTask: Task<Void, Never>?

    @discardableResult
    static func startIfAvailable(profiles: [Profile]) -> CloudSync? {
        shared = start(gate: .live, installIDs: KeychainInstallIDStorage(), stateFile: stateFile, profiles: profiles)
        CloudTabs.shared = shared?.tabs
        return shared
    }

    /// `stateFile` is the router's file; tab sharing keeps its own beside it. Neither feature starts unless its flag, the signed
    /// entitlements and the environment allow it (and, for tabs, the install ID is readable).
    static func start(
        gate: CloudSyncGate.Inputs,
        installIDs: any InstallIDStorage,
        stateFile: URL,
        profiles: [Profile],
        host: @MainActor () -> any VaultSyncHost = { CredentialVaultSyncHost() },
        optInDefaults: @escaping @MainActor (Profile) -> UserDefaults = ProfileSettingsStore.defaults(for:),
        windows: @escaping @MainActor () -> [BrowserModel] = CloudTabs.liveWindows,
        clock: any Clock<Duration> = ContinuousClock(),
        makeEngine: @escaping @MainActor (any SyncEngineDelegate, Data?) -> any SyncEngine = CloudSync.cloudKitEngine
    ) -> CloudSync? {
        let tabs = CloudSyncGate.allowsTabs(gate)
            ? InstallID.resolve(installIDs).map {
                CloudTabs.make(
                    installID: $0, stateFile: CloudTabs.stateFile(besides: stateFile), profiles: profiles, optInDefaults: optInDefaults,
                    windows: windows, clock: clock
                )
            }
            : nil
        let allowsVaults = CloudSyncGate.allowsVaults(gate)
        guard tabs != nil || allowsVaults else { return nil }
        // A missing or damaged file starts empty, which fetches everything once.
        let restored = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(SyncRouterState.self, from: $0) }
            ?? SyncRouterState()
        let keeper = RouterBox()
        // An account the tabs already saw is the account the vaults sync with: without it, a sign-out and sign-in of the same account would
        // read as another account the first time the vaults hear of it.
        var vaultState = restored.vaults
        if vaultState.accountUser == nil {
            vaultState.accountUser = tabs?.sync.state.accountUser
        }
        let vaults = allowsVaults
            ? VaultSync(
                host: host(), state: vaultState, persist: { keeper.router?.setVaults($0) }, excludedProfiles: [Profile.privateID],
                clock: clock
            )
            : nil
        let router = SyncRouter(
            state: restored, persist: { JSONFileStore.encodeAndWrite($0, to: stateFile) }, tabs: tabs?.sync, vaults: vaults
        )
        keeper.router = router
        let cloudSync = CloudSync(router: router, tabs: tabs, vaults: vaults, clock: clock, makeEngine: makeEngine)
        tabs?.needsEngine = { [weak cloudSync] in cloudSync?.ensureEngine() }
        cloudSync.ensureEngine()
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
        clock: any Clock<Duration>,
        makeEngine: @escaping @MainActor (any SyncEngineDelegate, Data?) -> any SyncEngine
    ) {
        self.router = router
        self.tabs = tabs
        self.vaults = vaults
        self.clock = clock
        self.makeEngine = makeEngine
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
        guard wantsTabs || vaults != nil else { return }
        let engine = engine ?? makeEngine(router, router.state.engineState)
        self.engine = engine
        if wantsTabs, !attachedTabs, let tabs {
            attachedTabs = true
            tabs.sync.attach(engine)
        }
        if !attachedVaults, let vaults {
            attachedVaults = true
            vaults.attach(engine)
        }
        startHeartbeat()
    }

    /// The heartbeat: every feature sends again what is waiting and fetches.
    func beat() {
        tabs?.beat()
        vaults?.beat()
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
