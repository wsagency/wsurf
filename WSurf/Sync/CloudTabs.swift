// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import SystemConfiguration
import WSurfCore

/// Shares each opted-in profile's open tabs with this person's other devices, and lists theirs.
///
/// It exists only when `CloudTabsGate` allows it, so with the hidden flag off or in an unentitled build `shared` stays nil and
/// every hook that asks it is a no-op. It reads the in-memory windows and the profile's pins. It never writes a session table.
@Observable
final class CloudTabs {
    /// Set once by `startIfAvailable`, before any window exists. Tests set it and reset it in a serial suite.
    static var shared: CloudTabs?

    /// The profile's own defaults domain holds the choice, so it goes when the profile is erased.
    static let optInKey = "sync.iCloudTabs"

    /// Phase 1 shares the Personal profile only: its ID is the same on every Mac, so its zone has a reader everywhere. A named
    /// profile gets a random ID per Mac. The private profile has a fixed ID too and must never get a zone.
    static func canShare(_ profile: Profile) -> Bool {
        profile.isOriginal
    }

    static var stateFile: URL {
        AppDatabase.supportDirectory.appendingPathComponent("iCloudTabs.json")
    }

    let sync: TabSync
    private(set) var optedIn: Set<UUID>

    @ObservationIgnored var debounce: Duration = .seconds(15)
    @ObservationIgnored var deadline: Duration = .seconds(60)
    @ObservationIgnored var heartbeatInterval: Duration = .seconds(15 * 60)
    @ObservationIgnored var quitLimit: Duration = .seconds(2)

    @ObservationIgnored private var known: [UUID: Profile]
    @ObservationIgnored private let optInDefaults: @MainActor (Profile) -> UserDefaults
    @ObservationIgnored private let windows: @MainActor () -> [BrowserModel]
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let makeEngine: @MainActor (TabSync, Data?) -> any SyncEngine
    @ObservationIgnored private var hasEngine = false
    @ObservationIgnored private var isTerminating = false
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?

    @discardableResult
    static func startIfAvailable(profiles: [Profile]) -> CloudTabs? {
        shared = start(gate: .live, installIDs: KeychainInstallIDStorage(), stateFile: stateFile, profiles: profiles)
        return shared
    }

    static func start(
        gate: CloudTabsGate.Inputs,
        installIDs: any InstallIDStorage,
        stateFile: URL,
        profiles: [Profile],
        optInDefaults: @escaping @MainActor (Profile) -> UserDefaults = ProfileSettingsStore.defaults(for:),
        windows: @escaping @MainActor () -> [BrowserModel] = CloudTabs.liveWindows,
        clock: any Clock<Duration> = ContinuousClock(),
        makeEngine: @escaping @MainActor (TabSync, Data?) -> any SyncEngine = CloudTabs.cloudKitEngine
    ) -> CloudTabs? {
        guard CloudTabsGate.allows(gate), let installID = InstallID.resolve(installIDs) else { return nil }
        // A missing or damaged file starts empty, which fetches everything once.
        let restored = (try? Data(contentsOf: stateFile)).flatMap { try? JSONDecoder().decode(TabSyncState.self, from: $0) }
        let device = DeviceInfo(
            name: SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "",
            kind: .mac,
            appVersion: UpdateFeed.currentVersion
        )
        let sync = TabSync(
            installID: installID,
            device: device,
            state: restored ?? TabSyncState(),
            persist: { JSONFileStore.encodeAndWrite($0, to: stateFile) }
        )
        let shareable = profiles.filter(canShare)
        let cloudTabs = CloudTabs(
            sync: sync,
            optedIn: Set(shareable.filter { optInDefaults($0).bool(forKey: optInKey) }.map(\.id)),
            known: Dictionary(shareable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            optInDefaults: optInDefaults,
            windows: windows,
            clock: clock,
            makeEngine: makeEngine
        )
        sync.onSharingEnded = { [weak cloudTabs] profileID in cloudTabs?.sharingEnded(profileID) }
        sync.reconcile(sharing: cloudTabs.optedIn)
        cloudTabs.ensureEngine()
        return cloudTabs
    }

    /// The only place that builds the CloudKit engine.
    static func cloudKitEngine(_ sync: TabSync, _ state: Data?) -> any SyncEngine {
        CloudKitSyncEngine(containerIdentifier: CloudTabsGate.container, state: state, delegate: sync)
    }

    /// Regular windows only. A private window never publishes, counts or times anything.
    static func liveWindows() -> [BrowserModel] {
        BrowserApplication.shared.windows
            .filter { !$0.isClosed && !$0.profiles.isPrivate }
            .map(\.browser)
    }

    private init(
        sync: TabSync,
        optedIn: Set<UUID>,
        known: [UUID: Profile],
        optInDefaults: @escaping @MainActor (Profile) -> UserDefaults,
        windows: @escaping @MainActor () -> [BrowserModel],
        clock: any Clock<Duration>,
        makeEngine: @escaping @MainActor (TabSync, Data?) -> any SyncEngine
    ) {
        self.sync = sync
        self.optedIn = optedIn
        self.known = known
        self.optInDefaults = optInDefaults
        self.windows = windows
        self.clock = clock
        self.makeEngine = makeEngine
    }

    // MARK: - Opt-in

    func isOptedIn(_ id: UUID) -> Bool {
        optedIn.contains(id)
    }

    func setOptIn(_ on: Bool, for profile: Profile) {
        guard Self.canShare(profile) else { return }
        known[profile.id] = profile
        optInDefaults(profile).set(on, forKey: Self.optInKey)
        if on {
            optedIn.insert(profile.id)
        } else {
            optedIn.remove(profile.id)
        }
        sync.reconcile(sharing: optedIn)
        ensureEngine()
        if on, let payload = payload(for: profile.id, running: true) {
            sync.share(payload, profileID: profile.id, force: true)
        }
    }

    /// The server removed a zone or the account changed: the person's choice is off until they make it again.
    private func sharingEnded(_ profileID: UUID?) {
        let ended = profileID.map { Set([$0]) } ?? optedIn
        for id in ended {
            if let profile = known[id] {
                optInDefaults(profile).set(false, forKey: Self.optInKey)
            }
        }
        optedIn.subtract(ended)
        sync.reconcile(sharing: optedIn)
    }

    /// A profile that leaves this Mac stops sharing and drops what the other devices showed for it.
    func forget(profileID: UUID) {
        optedIn.remove(profileID)
        known[profileID] = nil
        sync.reconcile(sharing: optedIn)
        sync.dropMirror(profileID: profileID)
    }

    func remoteSessions(for profile: Profile) -> [RemoteDeviceSession] {
        guard !profile.isPrivate, isOptedIn(profile.id) else { return [] }
        return sync.remoteSessions(profileID: profile.id, fallbackLabel: String(localized: "Device"))
    }

    /// Opens the link in a new active tab. Only the link crosses over: no title, history or page state.
    @discardableResult
    func open(_ node: SessionNode, in browser: BrowserModel) -> Bool {
        guard let url = node.webURL else { return false }
        browser.newTab(url: url, activate: true, after: browser.activeTab)
        return true
    }

    // MARK: - Publishing

    /// Called from `scheduleSave` and `saveBlocking` of a regular window. Does nothing while no profile is shared. Sends after a quiet
    /// `debounce`, and at the latest after `deadline` from the first change. One timer pair serves every profile: the rebuild is cheap and `share` drops unchanged
    /// payloads.
    func noteChange() {
        guard !isTerminating, !optedIn.isEmpty else { return }
        debounceTask?.cancel()
        debounceTask = after(debounce) { $0.publishDue() }
        if deadlineTask == nil {
            deadlineTask = after(deadline) { $0.publishDue() }
        }
    }

    private func publishDue() {
        debounceTask?.cancel()
        deadlineTask?.cancel()
        debounceTask = nil
        deadlineTask = nil
        publishAll(force: false)
    }

    /// Runs `action` once `delay` has passed on the clock, unless the task is cancelled or `self` is gone. It holds `self` weakly while
    /// it sleeps.
    private func after(_ delay: Duration, _ action: @escaping (CloudTabs) -> Void) -> Task<Void, Never> {
        Task { [weak self, clock] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            if let self {
                action(self)
            }
        }
    }

    func publishAll(force: Bool, running: Bool = true) {
        for id in optedIn.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let payload = payload(for: id, running: running) {
                sync.share(payload, profileID: id, force: force)
            }
        }
    }

    /// The heartbeat: send again even if nothing changed, so the server's modification date says this device is alive, and fetch.
    func beat() {
        publishAll(force: true)
        refresh()
    }

    func refresh() {
        Task { [sync] in
            await sync.refresh()
        }
    }

    /// What this device says about `profileID`, or nil when it has nothing to say: the private profile, or a profile with no
    /// database in this run. Favorites and pins come from the profile's pin store, tabs from the regular windows.
    func payload(for profileID: UUID, running: Bool) -> DeviceSessionPayload? {
        guard profileID != Profile.privateID else { return nil }
        let all = windows().filter { $0.context.profile.id == profileID && !$0.opensPrivately }
        let open = all.filter { $0.sessionClosedAt == nil }
        guard let database = all.first?.database ?? BrowserProfileContext.existing(for: profileID)?.database else { return nil }
        let store = ProfilePinStore.store(for: database)
        guard store.isAvailable else { return nil }
        let children = Dictionary(grouping: store.pins, by: \.parentID)
        func node(_ pin: ProfilePin) -> SessionNode? {
            let title = pin.customTitle.flatMap { $0.isEmpty ? nil : $0 } ?? pin.title
            switch pin.kind {
            case .tab:
                return SessionNode.tab(id: pin.id, title: title, url: pin.url)
            case .folder:
                return SessionNode(id: pin.id, title: title, children: (children[pin.id] ?? []).compactMap(node))
            }
        }
        let roots = children[nil] ?? []
        // The saved session of a profile that clears its data on quit must not outlive the data.
        let clearsOnQuit = !running && open.first?.context.settings.clearsDataOnQuit == true
        return DeviceSessionPayload(
            running: running && !open.isEmpty,
            favorites: roots.filter { $0.kind == .tab && $0.isFavorite }.compactMap(node),
            pins: roots.filter { !($0.kind == .tab && $0.isFavorite) }.compactMap(node),
            windows: clearsOnQuit ? [] : open.map { SessionWindow(id: $0.windowID, nodes: $0.cloudTabsNodes()) }
        )
    }

    // MARK: - Engine and lifecycle

    // ponytail: no registerForRemoteNotifications in phase 1; add it at launch if pushes do not arrive (the heartbeat fetches meanwhile).
    /// Creates the engine once, and only when this Mac shares a profile or still owns records on the server that it must delete.
    private func ensureEngine() {
        guard sync.needsEngine else { return }
        if !hasEngine {
            hasEngine = true
            // The engine's state moves to `SyncRouter` with the engine itself; until then a launch reads everything again.
            sync.attach(makeEngine(sync, nil))
        }
        startHeartbeat()
    }

    private func startHeartbeat() {
        guard heartbeatTask == nil, !isTerminating else { return }
        heartbeatTask = after(heartbeatInterval) { cloudTabs in
            cloudTabs.heartbeatTask = nil
            cloudTabs.beat()
            cloudTabs.startHeartbeat()
        }
    }

    private func cancelTimers() {
        heartbeatTask?.cancel()
        debounceTask?.cancel()
        deadlineTask?.cancel()
        heartbeatTask = nil
        debounceTask = nil
        deadlineTask = nil
    }

    /// Quit begins: the trees are still whole, so this publishes the final session as offline. Later changes publish nothing.
    func prepareToTerminate() {
        isTerminating = true
        cancelTimers()
        publishAll(force: true, running: false)
    }

    /// Quit was cancelled: the device is live again.
    func cancelTermination() {
        isTerminating = false
        if hasEngine {
            startHeartbeat()
        }
        publishAll(force: true)
    }

    /// Sends the final session, waiting at most `quitLimit`. A stuck network must not hold the quit.
    func sendBeforeQuit() async {
        guard hasEngine else { return }
        let finish = Finish()
        let send = Task { [sync] in
            await sync.sendNow()
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
