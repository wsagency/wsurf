// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WSurfCore

extension TabSyncTests {
    enum ReturnAfterRestart: CaseIterable {
        case keepSharing, stayOff, withdrawBeforeSend, staleTabs, staleRouter
        case replaySharing, replayOff, replayThenWithdraw, replayAfterOldState, replaySameState, detachedRoundTrip, detachedRoundTripBeforeCheckpoint, sendBeforeDetachedReturn
        case differentOrigin, differentAccount, unrecorded, alreadyConsumed, deliveredWithoutTabs, freshEngine, unreadableEngine, replacedEngine, signedOut, otherInstallation

        var keepsSharing: Bool {
            switch self {
            case .keepSharing, .staleTabs, .staleRouter, .replaySharing, .replayAfterOldState, .replaySameState:
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
            if outcome == .unrecorded {
                await run.engine.simulateAccount(.switchAccounts(user: first.user), from: other.user)
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
        let run = try files.open(first, installID: outcome == .otherInstallation ? "replacement" : "air")
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
            // B → A can reach the delegate after the recovered installation already had a chance to send.
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
        let turnOff = outcome == .withdrawBeforeSend || outcome == .replayThenWithdraw
        let keepsChoice = outcome.keepsSharing || turnOff
        #expect(try files.isSharing() == keepsChoice)
        if turnOff {
            files.choose(false, for: run.tabs)
        }
        let withdraw = !optedIn || turnOff
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

    /// Another category owns the engine while the installation ID is unreadable. The newer tab file stays on disk.
    func advanceWithoutTabs(_ outcome: TabSyncTests.ReturnAfterRestart, first: FakeSyncCloud, other: FakeSyncCloud) async throws -> Bool {
        switch outcome {
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
