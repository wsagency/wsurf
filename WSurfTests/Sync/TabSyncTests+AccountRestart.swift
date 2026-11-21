// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

extension TabSyncTests {
    enum ReturnAfterRestart: CaseIterable {
        case keepSharing, stayOff, withdrawBeforeSend, staleTabs, staleRouter
        case replaySharing, replayOff, replayThenWithdraw, replayAfterOldState, replaySameState, detachedRoundTrip, detachedRoundTripBeforeCheckpoint, sendBeforeDetachedReturn
        case differentOrigin, differentAccount, engineFirst, engineFirstWithdraw, legacyEngineFirst, legacyOtherInstall, unprovenSwitch, alreadyConsumed
        case deliveredWithoutTabs, freshEngine, unreadableEngine, replacedEngine, signedOut, otherInstallation

        var notifiedFirst: Bool {
            self == .engineFirst || self == .engineFirstWithdraw || self == .legacyEngineFirst || self == .legacyOtherInstall
        }

        var turnsOffAfterReplay: Bool {
            self == .withdrawBeforeSend || self == .replayThenWithdraw || self == .engineFirstWithdraw
        }

        var keepsSharing: Bool {
            switch self {
            case .keepSharing, .staleTabs, .staleRouter, .engineFirst, .legacyEngineFirst, .replaySharing, .replayAfterOldState, .replaySameState:
                true
            default:
                false
            }
        }
    }

    @Test(arguments: ReturnAfterRestart.allCases)
    func aVerifiedReturnSurvivesRestartUntilItsAccountEvent(outcome: ReturnAfterRestart) async throws {
        let first = FakeSyncCloud(user: "A"), other = FakeSyncCloud(user: "B")
        let files = try PersonalAccountFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let id = SyncRecordID(zone: SyncZone.profile(files.profile), name: "air")
        let peerID = SyncRecordID(zone: id.zone, name: "studio")
        let initial = SyncSamples.session(tabs: ["https://old.test/"])
        let payload = try #require(SessionCodec.encodeFitted(initial))
        first.createZone(id.zone)
        other.createZone(id.zone)
        _ = first.save(SyncRecord(id: peerID, type: .deviceSession, schema: 1, payload: payload))
        _ = other.save(SyncRecord(id: id, type: .deviceSession, schema: 1, payload: payload))
        let peer = try #require(first.record(peerID)), foreign = try #require(other.record(id))

        let engineStateB: Data
        do {
            let run = try files.open(first)
            files.choose(true, for: run.tabs)
            run.tabs.attach(run.engine)
            await run.tabs.refresh()
            run.tabs.share(initial, profileID: files.profile, force: true)
            var accepted = false
            run.engine.holdSendReceipt = { _ in accepted = true }
            try await run.engine.sendNow()
            try #require(accepted && first.record(id) != nil && run.tabs.state.ownSystemFields[id.zone] == nil)
            files.choose(false, for: run.tabs)
            await run.engine.simulateAccount(.signOut)
            run.engine.cloud = other
            await run.engine.simulateAccount(.signIn(user: other.user))
            try await run.engine.fetchNow()
            engineStateB = try #require(run.router.state.engineState)
        }

        let optedIn = outcome != .stayOff && outcome != .replayOff
        do {
            let run = try files.open(other)
            await run.tabs.refresh()
            try await run.engine.sendNow()
            try #require(other.record(id) == foreign && !run.router.wantsRecordDeletion(id))
            let tabsInB = try Data(contentsOf: files.tabsFile), routerInB = try Data(contentsOf: files.routerFile)
            run.engine.cloud = first
            if outcome.notifiedFirst {
                await run.engine.simulateAccount(.switchAccounts(user: first.user), from: other.user)
            } else if outcome == .unprovenSwitch {
                // A sign-in identifies A, without evidence that the engine already delivered a B → A switch.
                await run.engine.simulateAccount(.signIn(user: first.user))
            } else {
                await run.tabs.refresh()
            }
            try #require(run.tabs.state.accountUser == first.user && run.router.wantsRecordDeletion(id))
            run.engine.available = false
            if optedIn {
                files.choose(true, for: run.tabs)
            }
            switch outcome {
            case .alreadyConsumed:
                // The router received the switch and saved its new cursor, but the tab file still predates delivery.
                let stale = try Data(contentsOf: files.tabsFile)
                await run.engine.simulateAccount(.switchAccounts(user: first.user), from: other.user)
                try await run.engine.fetchNow()
                try stale.write(to: files.tabsFile, options: .atomic)
            case .signedOut:
                await run.engine.simulateAccount(.signOut)
            case .staleTabs:
                try tabsInB.write(to: files.tabsFile, options: .atomic)
            case .replaySharing, .replayOff, .replayThenWithdraw, .replayAfterOldState, .replaySameState:
                // Delivery completed, but CloudKit has not yet serialized its state for A.
                await run.engine.simulateAccount(.switchAccounts(user: first.user), from: other.user)
                if outcome == .replaySameState {
                    await run.router.handle(.state(engineStateB))
                }
                try #require(try files.isSharing() == optedIn && run.router.state.engineState == engineStateB)
            case .staleRouter, .detachedRoundTrip, .detachedRoundTripBeforeCheckpoint, .sendBeforeDetachedReturn:
                try routerInB.write(to: files.routerFile, options: .atomic)
            default:
                break
            }
        }

        let engineAdvanced = try await files.advanceWithoutTabs(outcome, first: first, other: other)
        let run = try files.open(first, installID: (outcome == .otherInstallation || outcome == .legacyOtherInstall) ? "replacement" : "air")
        if !engineAdvanced && outcome != .alreadyConsumed {
            try #require(run.router.state.engineState == engineStateB)
        }
        if outcome != .detachedRoundTrip && outcome != .detachedRoundTripBeforeCheckpoint && outcome != .sendBeforeDetachedReturn {
            try #require(try files.isSharing() == optedIn && run.tabs.state.accountUser == first.user)
        }
        var engine = run.engine
        if outcome == .replacedEngine {
            engine = FakeSyncEngine(cloud: first, delegate: run.router)
            run.tabs.attach(engine)
        }
        // Keep the new process from rediscovering the first save before the notification or the person's opt-out.
        engine.available = false
        run.tabs.share(SyncSamples.session(tabs: ["https://fresh.test/"]), profileID: files.profile, force: true)
        let before = first.writeCount
        if outcome == .sendBeforeDetachedReturn {
            engine.available = true
            await run.tabs.refresh()
            try await engine.sendNow()
            #expect(first.writeCount == before && first.record(id)?.payload != nil && other.record(id) == foreign)
            engine.available = false
        }
        if outcome == .differentAccount {
            engine.cloud = other
            await engine.simulateAccount(.switchAccounts(user: other.user), from: first.user)
        } else {
            await engine.simulateAccount(.switchAccounts(user: first.user), from: outcome == .differentOrigin ? "C" : other.user)
        }
        #expect(try files.isSharing() == (outcome.keepsSharing || outcome.turnsOffAfterReplay))
        if outcome.turnsOffAfterReplay {
            files.choose(false, for: run.tabs)
        }
        let withdraw = !optedIn || outcome.turnsOffAfterReplay
        #expect(run.router.wantsRecordDeletion(id) == withdraw)
        engine.available = true
        if outcome.keepsSharing {
            await run.tabs.refresh()
        }
        try await engine.sendNow()
        if outcome.keepsSharing {
            let latest = try #require(first.record(id))
            #expect(try SessionCodec.decodeSession(latest.payload).windows.first?.nodes.first?.url == "https://fresh.test/")
        } else {
            #expect((first.record(id) == nil) == withdraw && first.writeCount == before)
        }
        #expect(first.record(peerID) == peer && other.record(id) == foreign && other.writeCount == 1)
    }

    enum MissingTabAccount: CaseIterable {
        case sameAccount, revoked, renewed, withdrawOwn, signInsOnly, restoredEngine, backInB, sameVerifiedReturn
    }

    @Test(arguments: MissingTabAccount.allCases)
    func firstSendAfterDetachedAccountEventsUsesTheLastChoice(outcome: MissingTabAccount) async throws {
        let files = try PersonalAccountFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let first = FakeSyncCloud(user: "A"), other = FakeSyncCloud(user: "B")
        let zone = SyncZone.profile(files.profile), own = SyncRecordID(zone: zone, name: "air"), peerID = SyncRecordID(zone: zone, name: "studio")
        let old = SyncSamples.session(tabs: ["https://old.test/"])
        let payload = try #require(SessionCodec.encodeFitted(old))
        first.createZone(zone)
        other.createZone(zone)
        _ = first.save(SyncRecord(id: peerID, type: .deviceSession, schema: 1, payload: payload))
        _ = other.save(SyncRecord(id: own, type: .deviceSession, schema: 1, payload: payload))
        let foreign = try #require(other.record(own)), peer = try #require(first.record(peerID))
        do {
            let run = try files.open(first)
            files.choose(true, for: run.tabs)
            run.tabs.attach(run.engine)
            await run.tabs.refresh()
            run.tabs.share(old, profileID: files.profile, force: true)
            run.engine.holdSendReceipt = { _ in }
            try await run.engine.sendNow()
            try #require(first.record(own) != nil && run.tabs.state.ownSystemFields[zone] == nil)
            if outcome == .withdrawOwn || outcome == .sameVerifiedReturn {
                files.choose(false, for: run.tabs)
            }
            if outcome == .sameVerifiedReturn {
                await run.engine.simulateAccount(.signOut)
                run.engine.cloud = other
                await run.engine.simulateAccount(.signIn(user: other.user))
                try await run.engine.fetchNow()
                run.engine.cloud = first
                await run.tabs.refresh()
                try #require(run.tabs.state.accountUser == first.user && run.router.wantsRecordDeletion(own))
                files.choose(true, for: run.tabs)
            }
        }
        let prior = try #require(first.record(own)), before = first.writeCount
        do {
            let router = try files.openRouter(tabs: nil)
            let engine = FakeSyncEngine(cloud: other, delegate: router, state: router.state.engineState)
            if outcome == .sameVerifiedReturn {
                engine.cloud = first
                await engine.simulateAccount(.switchAccounts(user: first.user), from: other.user)
            } else if outcome == .signInsOnly {
                await engine.simulateAccount(.signOut)
                await engine.simulateAccount(.signIn(user: other.user))
            } else if outcome != .sameAccount {
                await engine.simulateAccount(.switchAccounts(user: other.user), from: first.user)
            }
            try await engine.fetchNow()
            await engine.simulateAccount(.signOut)
            try await engine.fetchNow()
        }
        let active = outcome == .backInB ? other : first
        do {
            let router = try files.openRouter(tabs: nil)
            let engine = FakeSyncEngine(cloud: active, delegate: router, state: outcome == .restoredEngine ? nil : router.state.engineState)
            await engine.simulateAccount(.signIn(user: active.user))
            try await engine.fetchNow()
        }
        let returned = try files.open(active)
        let keep = outcome == .sameAccount || outcome == .sameVerifiedReturn
        #expect(try files.isSharing() == keep)
        if outcome == .renewed {
            files.choose(true, for: returned.tabs)
            returned.tabs.attach(returned.engine)
        }
        let share = keep || outcome == .renewed
        returned.tabs.share(SyncSamples.session(tabs: ["https://latest.test/"]), profileID: files.profile, force: true)
        try await returned.engine.sendNow()
        #expect(try files.isSharing() == share)
        if share {
            let actual = try #require(first.record(own))
            #expect(try SessionCodec.decodeSession(actual.payload).windows.first?.nodes.first?.url == "https://latest.test/")
        } else if outcome == .withdrawOwn {
            #expect(first.record(own) == nil && first.writeCount == before)
        } else {
            #expect(first.record(own) == prior && first.writeCount == before)
        }
        #expect(first.record(peerID) == peer && other.record(own) == foreign && other.writeCount == 1)
    }
}

/// Each launch reads the last writes of both production models and restores the profile's independent local choice.
@MainActor
private struct PersonalAccountFiles {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let profile = UUID()
    var tabsFile: URL { directory.appending(path: "iCloudTabs.json") }
    var routerFile: URL { directory.appending(path: "iCloudSync.json") }
    private var choiceFile: URL { directory.appending(path: "personal-opt-in.json") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 19f recorded delivery and the publication's owner in the router, but no lookup receipt for an engine-first switch.
    func restoreEngineFirstFormat19f() throws {
        var tabs = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: tabsFile)) as? [String: Any])
        var local = try #require(tabs["zoneObservations"] as? [String: Any])
        local.removeValue(forKey: "verifiedSwitch")
        tabs["zoneObservations"] = local
        try JSONSerialization.data(withJSONObject: tabs).write(to: tabsFile, options: .atomic)

        var router = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: routerFile)) as? [String: Any])
        var checkpoint = try #require(router["tabRemoval"] as? [String: Any])
        var remote = try #require(checkpoint["observations"] as? [String: Any])
        remote.removeValue(forKey: "verifiedSwitch")
        checkpoint["observations"] = remote
        router["tabRemoval"] = checkpoint
        var events = try #require(router["tabAccountEvents"] as? [String: Any])
        let pending = try #require(events["pending"] as? [String: Any])
        try #require(pending["deliveredToTabs"] as? Bool == true)
        events.removeValue(forKey: "deferred")
        router["tabAccountEvents"] = events
        try JSONSerialization.data(withJSONObject: router).write(to: routerFile, options: .atomic)
    }

    /// Another category owns the engine while the installation ID is unreadable. The newer tab file stays on disk.
    func advanceWithoutTabs(_ outcome: TabSyncTests.ReturnAfterRestart, first: FakeSyncCloud, other: FakeSyncCloud) async throws -> Bool {
        switch outcome {
        case .legacyEngineFirst, .legacyOtherInstall:
            try restoreEngineFirstFormat19f()
            return false
        case .deliveredWithoutTabs, .detachedRoundTrip, .detachedRoundTripBeforeCheckpoint, .sendBeforeDetachedReturn:
            let router = try openRouter(tabs: nil)
            let engine = FakeSyncEngine(cloud: first, delegate: router, state: router.state.engineState)
            await engine.simulateAccount(.switchAccounts(user: first.user), from: other.user)
            if outcome != .deliveredWithoutTabs {
                engine.cloud = other
                await engine.simulateAccount(.switchAccounts(user: other.user), from: first.user)
            }
            if outcome == .detachedRoundTripBeforeCheckpoint {
                return false
            }
            try await engine.fetchNow()
        case .replayAfterOldState:
            // On restart a change to B's restored queue can serialize before CloudKit redelivers B → A.
            let router = try openRouter(tabs: nil)
            let engine = FakeSyncEngine(cloud: other, delegate: router, state: router.state.engineState)
            try await engine.fetchNow()
        case .freshEngine:
            try FileManager.default.removeItem(at: routerFile)
        case .unreadableEngine:
            let router = try openRouter(tabs: nil)
            await router.handle(.state(Data("invalid checkpoint".utf8)))
        default:
            return false
        }
        return true
    }

    func open(_ cloud: FakeSyncCloud, installID: String = "air") throws -> (tabs: TabSync, router: SyncRouter, engine: FakeSyncEngine) {
        let tabs = TabSync(
            installID: installID, device: DeviceInfo(name: "Air", kind: .mac, appVersion: "test"),
            state: try read(TabSyncState.self, from: tabsFile) ?? .init(), persist: { write($0, to: tabsFile) }
        )
        tabs.onSharingEnded = { [weak tabs] _ in
            if let tabs {
                choose(false, for: tabs)
            }
        }
        tabs.reconcile(sharing: try isSharing() ? [profile] : [])
        let router = try openRouter(tabs: tabs)
        let engine = FakeSyncEngine(cloud: cloud, delegate: router, state: router.state.engineState)
        if tabs.needsEngine {
            tabs.attach(engine)
        }
        return (tabs, router, engine)
    }

    func openRouter(tabs: TabSync?) throws -> SyncRouter {
        let state = try read(SyncRouterState.self, from: routerFile) ?? .init()
        return SyncRouter(state: state, persist: { write($0, to: routerFile) }, tabs: tabs, vaults: nil)
    }

    func choose(_ sharing: Bool, for tabs: TabSync) {
        write(sharing, to: choiceFile)
        tabs.reconcile(sharing: sharing ? [profile] : [])
    }

    func isSharing() throws -> Bool {
        try read(Bool.self, from: choiceFile) ?? false
    }

    private func read<T: Decodable>(_ type: T.Type, from file: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }

    private func write(_ value: some Encodable, to file: URL) {
        do {
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        } catch {
            Issue.record(error)
        }
    }
}
