// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurf

/// The app side of tab sync against real window models, a fake account and a clock the test moves. Serial: it sets the
/// process-wide `CloudTabs.shared` and uses the shared Personal context.
@MainActor
@Suite(.serialized)
struct CloudTabsTests {
    /// One simulated launch: the account, the clock, the windows and the settings a `CloudTabs` reads.
    @MainActor
    final class Launch {
        static let entitlements: [String: Any] = [
            "com.apple.developer.icloud-container-identifiers": [CloudTabsGate.container],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.aps-environment": "production",
        ]

        let cloud = FakeSyncCloud()
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory.appending(path: "cloud-tabs-\(UUID().uuidString)", directoryHint: .isDirectory)
        let suite = UUID().uuidString
        let defaults: UserDefaults
        var models: [BrowserModel] = []
        private(set) var engines: [FakeSyncEngine] = []
        private(set) var cloudTabs: CloudTabs?

        init() {
            defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite(suite))!
        }

        var stateFile: URL {
            directory.appending(path: "iCloudTabs.json")
        }

        var engine: FakeSyncEngine {
            engines[0]
        }

        var sync: TabSync {
            cloudTabs!.sync
        }

        func gate(flag: Bool = true, entitled: Bool = true) -> CloudTabsGate.Inputs {
            let held = Self.entitlements
            return CloudTabsGate.Inputs(
                flag: flag,
                isRunningTests: false,
                isStaged: false,
                ownsSession: true,
                entitlement: { entitled ? held[$0] : nil }
            )
        }

        @discardableResult
        func start(
            flag: Bool = true,
            entitled: Bool = true,
            optedIn: Bool = false,
            profiles: [Profile] = [.original()],
            installIDs: any InstallIDStorage = MemoryInstallIDStorage()
        ) -> CloudTabs? {
            if optedIn {
                defaults.set(true, forKey: CloudTabs.optInKey)
            }
            cloudTabs = CloudTabs.start(
                gate: gate(flag: flag, entitled: entitled),
                installIDs: installIDs,
                stateFile: stateFile,
                profiles: profiles,
                optInDefaults: { [defaults] _ in defaults },
                windows: { [unowned self] in models },
                clock: clock,
                makeEngine: { [unowned self] sync, _ in
                    let engine = FakeSyncEngine(cloud: cloud, delegate: sync)
                    engines.append(engine)
                    return engine
                }
            )
            return cloudTabs
        }

        var personalSessionID: SyncRecordID {
            SyncRecordID(zone: SyncZone.profile(Profile.originalID), name: sync.installID)
        }

        func storedSession() throws -> DeviceSessionPayload {
            try SessionCodec.decodeSession(#require(cloud.record(personalSessionID)).payload)
        }

        /// Sends what the model queued, as the real engine does on its own schedule.
        func sendAll() async throws {
            try await engine.sendNow()
        }

        /// The number of sleepers on the clock once every timer task the test started has had its turn.
        func timerCount() async -> Int {
            for _ in 0..<20 {
                await Task.yield()
            }
            return clock.pendingCount
        }

        func finish() {
            if CloudTabs.shared === cloudTabs {
                CloudTabs.shared = nil
            }
            cloudTabs?.prepareToTerminate()
            defaults.removePersistentDomain(forName: AppDatabase.defaultsSuite(suite))
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func regularWindow() -> BrowserModel {
        BrowserModel(database: .temporary())
    }

    private func urls(in nodes: [SessionNode]) -> [String] {
        nodes.flatMap { node in node.children.map(urls(in:)) ?? [node.url ?? ""] }
    }

    // MARK: - The gate

    @Test func flagOffNeverCreatesTheEngine() {
        let launch = Launch()
        defer { launch.finish() }

        #expect(launch.start(flag: false, optedIn: true) == nil)
        #expect(launch.engines.isEmpty)
    }

    @Test func missingEntitlementNeverCreatesTheEngine() {
        let launch = Launch()
        defer { launch.finish() }

        #expect(launch.start(entitled: false, optedIn: true) == nil)
        #expect(launch.engines.isEmpty)
    }

    @Test func unreadableInstallIDNeverCreatesTheEngine() {
        let launch = Launch()
        defer { launch.finish() }
        let storage = MemoryInstallIDStorage(value: UUID().uuidString)
        storage.failsReads = true

        #expect(launch.start(optedIn: true, installIDs: storage) == nil)
        #expect(launch.engines.isEmpty)
    }

    @Test func engineStartsOnlyOnceAProfileIsShared() throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start())
        #expect(launch.engines.isEmpty)

        cloudTabs.setOptIn(true, for: .original())
        #expect(launch.engines.count == 1)

        cloudTabs.setOptIn(true, for: .original())
        cloudTabs.setOptIn(false, for: .original())
        cloudTabs.setOptIn(true, for: .original())
        #expect(launch.engines.count == 1)
    }

    @Test func optInIsStoredPerProfileAndOnlyForPersonal() throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start())
        let named = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .gray)

        cloudTabs.setOptIn(true, for: named)
        #expect(!cloudTabs.isOptedIn(named.id))
        #expect(launch.defaults.object(forKey: CloudTabs.optInKey) == nil)
        #expect(launch.engines.isEmpty)

        cloudTabs.setOptIn(true, for: .original())
        #expect(cloudTabs.isOptedIn(Profile.originalID))
        #expect(launch.defaults.bool(forKey: CloudTabs.optInKey))
    }

    // MARK: - What a session holds

    @Test func sessionHoldsFavoritesPinsFoldersAndTabsByID() throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        launch.models = [window]
        let favorite = ProfilePin(id: UUID(), parentID: nil, orderKey: "V", kind: .tab, url: "https://fav.test/", title: "Fav", isFavorite: true)
        let folder = ProfilePin(id: UUID(), parentID: nil, orderKey: "W", kind: .folder, title: "Work", isPinned: true)
        let inside = ProfilePin(id: UUID(), parentID: folder.id, orderKey: "V", kind: .tab, url: "https://work.test/", title: "Work page", customTitle: "Renamed")
        ProfilePinStore.store(for: window.database).publish([favorite, folder, inside])
        let first = window.addPage("https://one.test/")
        let second = window.addPage("https://two.test/")
        let loose = window.addPage("https://loose.test/")
        let reading = window.createFolder(named: "Reading", containing: [first, second])

        let payload = try #require(cloudTabs.payload(for: Profile.originalID, running: true))

        #expect(payload.running)
        #expect(payload.favorites == [SessionNode(id: favorite.id, title: "Fav", url: "https://fav.test/")])
        #expect(payload.pins == [
            SessionNode(id: folder.id, title: "Work", children: [SessionNode(id: inside.id, title: "Renamed", url: "https://work.test/")]),
        ])
        let window0 = try #require(payload.windows.first)
        #expect(payload.windows.count == 1 && payload.windows[0].id == window.windowID)
        #expect(window0.nodes.count == 2)
        #expect(Set(window0.nodes.map(\.id)) == [reading.id, loose.id])
        let folderNode = try #require(window0.nodes.first { $0.id == reading.id })
        #expect(folderNode.title == "Reading")
        #expect(Set(folderNode.children?.map(\.id) ?? []) == [first.id, second.id])
        #expect(folderNode.children?.allSatisfy { $0.title == $0.url } == true)
        #expect(urls(in: window0.nodes).sorted() == ["https://loose.test/", "https://one.test/", "https://two.test/"])
    }

    /// A space is a view of the window: every tab stays in `tabs`, so the session lists the rows of all spaces, in tree order.
    @Test func rowsOfEverySpaceArePublishedNotOnlyTheOneOnScreen() throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        let home = UUID()
        let recipes = UUID()
        window.adoptSpaces([home, recipes])
        let first = window.addPage("https://home.test/one")
        let second = window.addPage("https://home.test/two")
        let dinner = window.createFolder(named: "Dinner", containing: [second])
        let pasta = window.addPage("https://recipes.test/pasta")
        pasta.spaceID = recipes
        window.currentSpaceID = recipes
        window.sidebarDidChange()
        launch.models = [window]

        let payload = try #require(cloudTabs.payload(for: Profile.originalID, running: true))

        let nodes = try #require(payload.windows.first).nodes
        #expect(window.sidebarItems == [.tab(pasta.id)])
        #expect(Set(nodes.map(\.id)) == [first.id, dinner.id, pasta.id])
        #expect(urls(in: nodes).sorted() == ["https://home.test/one", "https://home.test/two", "https://recipes.test/pasta"])
        #expect(nodes.allSatisfy { $0.title.isEmpty == false })
    }

    @Test func privateWindowsAreNeverPublished() throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let regular = regularWindow()
        regular.addPage("https://regular.test/")
        let secret = BrowserModel(context: .shared(for: .privateBrowsing()))
        secret.addPage("https://secret.test/private-title")
        launch.models = [regular, secret]

        let payload = try #require(cloudTabs.payload(for: Profile.originalID, running: true))
        let encoded = try #require(SessionCodec.encodeFitted(payload))
        let text = try String(decoding: (encoded as NSData).decompressed(using: .lzfse), as: UTF8.self)

        #expect(payload.windows.count == 1)
        #expect(payload.windows.first?.id == regular.windowID)
        #expect(!text.contains("secret"))
        #expect(cloudTabs.payload(for: Profile.privateID, running: true) == nil)
        #expect(secret.cloudTabsNodes().isEmpty)
    }

    @Test func closingTheLastWindowPublishesNoWindows() throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        window.addPage("https://one.test/")
        launch.models = [window]
        let pin = ProfilePin(id: UUID(), parentID: nil, orderKey: "V", kind: .tab, url: "https://pin.test/", title: "Pin")
        ProfilePinStore.store(for: window.database).publish([pin])

        window.sessionClosedAt = Date()
        let payload = try #require(cloudTabs.payload(for: Profile.originalID, running: true))

        #expect(payload.windows.isEmpty)
        #expect(!payload.running)
        #expect(payload.pins.map(\.id) == [pin.id])
    }

    // MARK: - When it publishes

    @Test func changesArePublishedAfterTheDebounce() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        launch.models = [window]
        CloudTabs.shared = cloudTabs
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()
        let writes = launch.cloud.writeCount
        let waiting = await launch.timerCount()

        window.addPage("https://changed.test/")
        window.scheduleSave()
        #expect(await waitUntil { launch.clock.pendingCount >= waiting + 2 })
        try await launch.sendAll()
        #expect(launch.cloud.writeCount == writes)

        launch.clock.advance(by: .seconds(15))
        #expect(await waitUntil { launch.engine.pending.contains(.saveRecord(launch.personalSessionID)) })
        try await launch.sendAll()

        #expect(try urls(in: #require(launch.storedSession().windows.first).nodes) == ["https://changed.test/"])
    }

    @Test func aBusyWindowStillPublishesWithinTheDeadline() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        launch.models = [window]
        CloudTabs.shared = cloudTabs
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()

        // A change every ten seconds keeps the quiet period from ever ending.
        for index in 0..<6 {
            window.addPage("https://busy.test/\(index)")
            window.scheduleSave()
            await Task.yield()
            launch.clock.advance(by: .seconds(10))
            await Task.yield()
        }
        #expect(await waitUntil { launch.engine.pending.contains(.saveRecord(launch.personalSessionID)) })
        try await launch.sendAll()

        #expect(try !urls(in: #require(launch.storedSession().windows.first).nodes).isEmpty)
    }

    @Test func heartbeatResendsAnUnchangedSession() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        window.addPage("https://same.test/")
        launch.models = [window]
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()
        let first = try #require(launch.cloud.tag(of: launch.personalSessionID))
        let tree = try launch.storedSession().windows

        cloudTabs.beat()
        try await launch.sendAll()
        cloudTabs.beat()
        try await launch.sendAll()

        #expect(launch.cloud.tag(of: launch.personalSessionID) == first + 2)
        #expect(try launch.storedSession().windows == tree)
    }

    @Test func privateWindowChangesPublishNothing() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let secret = BrowserModel(context: .shared(for: .privateBrowsing()))
        launch.models = [secret]
        CloudTabs.shared = cloudTabs
        try await launch.sendAll()
        let writes = launch.cloud.writeCount
        let waiting = await launch.timerCount()

        secret.addPage("https://secret.test/")
        secret.scheduleSave()
        #expect(await launch.timerCount() == waiting)
        launch.clock.advance(by: .seconds(120))
        _ = await launch.timerCount()

        #expect(launch.engine.pending.isEmpty)
        #expect(launch.cloud.writeCount == writes)
    }

    // MARK: - Quit

    @Test func quitKeepsTheTreeAndMarksTheDeviceOffline() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        window.addPage("https://open.test/")
        launch.models = [window]
        CloudTabs.shared = cloudTabs
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()
        let live = try launch.storedSession()
        #expect(live.running)

        cloudTabs.prepareToTerminate()
        await cloudTabs.sendBeforeQuit()

        let stored = try launch.storedSession()
        #expect(!stored.running)
        #expect(stored.windows == live.windows)
        let writes = launch.cloud.writeCount
        window.addPage("https://after.test/")
        window.scheduleSave()
        _ = await launch.timerCount()
        launch.clock.advance(by: .seconds(120))
        _ = await launch.timerCount()
        #expect(launch.engine.pending.isEmpty)
        #expect(launch.cloud.writeCount == writes)
    }

    @Test func clearOnQuitProfileQuitsWithNoTabs() throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        window.addPage("https://private-to-me.test/")
        launch.models = [window]
        let settings = window.context.settings
        let original = settings.clearsDataOnQuit
        defer { settings.clearsDataOnQuit = original }
        settings.clearsDataOnQuit = true

        let live = try #require(cloudTabs.payload(for: Profile.originalID, running: true))
        let quit = try #require(cloudTabs.payload(for: Profile.originalID, running: false))

        #expect(!live.windows.isEmpty)
        #expect(quit.windows.isEmpty)
        #expect(!quit.running)
    }

    @Test func quitWaitsNoLongerThanTheLimit() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        launch.models = [regularWindow()]
        cloudTabs.publishAll(force: true)
        launch.engine.hangsOnSend = true
        cloudTabs.prepareToTerminate()
        let waiting = await launch.timerCount()
        var finished = false

        let quitting = Task {
            await cloudTabs.sendBeforeQuit()
            finished = true
        }
        #expect(await waitUntil { launch.clock.pendingCount > waiting })
        #expect(!finished)
        launch.clock.advance(by: cloudTabs.quitLimit)
        await quitting.value

        #expect(finished)
    }

    @Test func cancelledQuitMakesTheDeviceLiveAgain() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        launch.models = [regularWindow()]
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()
        cloudTabs.prepareToTerminate()
        try await launch.sendAll()
        #expect(try !launch.storedSession().running)

        cloudTabs.cancelTermination()
        try await launch.sendAll()

        #expect(try launch.storedSession().running)
    }

    // MARK: - Opening and ending

    @Test(.boundedWebViews)
    func remoteTabOpensItsLinkAsANewActiveTab() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        let window = regularWindow()
        let node = try #require(SessionNode.tab(id: UUID(), title: "Remote title", url: "http://127.0.0.1:1/remote"))

        #expect(cloudTabs.open(node, in: window))
        let opened = try #require(window.activeTab)
        #expect(window.tabs.count == 1)
        #expect(opened.urlString == "http://127.0.0.1:1/remote")
        #expect(opened.pinID == nil && opened.pinnedURL == nil)

        let hostile = SessionNode(id: UUID(), title: "Hostile", url: "javascript:alert(1)")
        #expect(!cloudTabs.open(hostile, in: window))
        #expect(window.tabs.count == 1)

        window.closeAllTabs(saving: false)
        await opened.waitForRetirement()
    }

    @Test func turningSharingOffDeletesThisMacsRecord() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        launch.models = [regularWindow()]
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()
        #expect(launch.cloud.recordCount == 2)

        cloudTabs.setOptIn(false, for: .original())
        try await launch.sendAll()

        #expect(launch.cloud.recordCount == 0)
        #expect(!launch.defaults.bool(forKey: CloudTabs.optInKey))
    }

    @Test func removedZoneTurnsTheToggleOff() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        launch.models = [regularWindow()]
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()
        let writes = launch.cloud.writeCount

        launch.cloud.deleteZone(SyncZone.profile(Profile.originalID), reason: .purged)
        try await launch.engine.fetchNow()
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()

        #expect(!launch.defaults.bool(forKey: CloudTabs.optInKey))
        #expect(!cloudTabs.isOptedIn(Profile.originalID))
        #expect(launch.cloud.writeCount == writes)
        #expect(launch.cloud.zones[SyncZone.profile(Profile.originalID)] == nil)
    }

    @Test func erasingAProfileDropsItsMirror() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start(optedIn: true))
        launch.models = [regularWindow()]
        cloudTabs.publishAll(force: true)
        try await launch.sendAll()
        let zone = SyncZone.profile(Profile.originalID)
        let other = SyncDevice(cloud: launch.cloud, installID: "install-other", name: "Ana’s iPad")
        other.start(sharing: [Profile.originalID])
        other.sync.share(SyncSamples.session(tabs: ["https://other.test/"]), profileID: Profile.originalID, force: false)
        try await other.engine.sendNow()
        try await launch.engine.fetchNow()
        #expect(cloudTabs.remoteSessions(for: .original()).count == 1)

        cloudTabs.forget(profileID: Profile.originalID)
        try await launch.sendAll()

        #expect(launch.sync.state.sessions[zone] == nil)
        #expect(cloudTabs.remoteSessions(for: .original()).isEmpty)
        #expect(launch.cloud.names(in: zone) == ["install-other"])
    }

    @Test func remoteSessionsAreListedOnlyForASharedNonPrivateProfile() async throws {
        let launch = Launch()
        defer { launch.finish() }
        let cloudTabs = try #require(launch.start())
        let other = SyncDevice(cloud: launch.cloud, installID: "install-other", name: "Ana’s iPad")
        other.start(sharing: [Profile.originalID])
        other.sync.share(SyncSamples.session(tabs: ["https://other.test/"]), profileID: Profile.originalID, force: false)
        try await other.engine.sendNow()
        #expect(cloudTabs.remoteSessions(for: .original()).isEmpty)
        cloudTabs.setOptIn(true, for: .original())
        try await launch.engine.fetchNow()

        #expect(cloudTabs.remoteSessions(for: .original()).map(\.label) == ["iPad"])
        #expect(cloudTabs.remoteSessions(for: .privateBrowsing()).isEmpty)
        cloudTabs.setOptIn(false, for: .original())
        #expect(cloudTabs.remoteSessions(for: .original()).isEmpty)
    }
}
