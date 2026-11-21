// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing
import WebKit

@testable import WSurf

extension ProfileTests {
    private func history(onDiskFor profile: Profile) throws -> HistoryStore {
        let database = AppDatabase(at: try #require(profile.databaseURL))
        try #require(!database.isEphemeral)
        return HistoryStore(database: database)
    }

    private func recordVisit(for profile: Profile) throws {
        let history = try history(onDiskFor: profile)
        try #require(history.record(url: "https://example.invalid/\(profile.id)", title: profile.name) != nil)
    }

    @Test func launchFinishesErasureInterruptedWhileWindowsWereLeaving() async throws {
        try await checkLaunchRecovery(restoringListAfterLaunch: false)
    }

    @Test func theReturningProfileListAlsoResumesAnInterruptedErasure() async throws {
        try await checkLaunchRecovery(restoringListAfterLaunch: true)
    }

    private func checkLaunchRecovery(restoringListAfterLaunch: Bool) async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        let file = root.appending(path: "profiles.json")
        let store = ProfileStore(file: file)
        let work = store.add(name: "Work"), kept = store.add(name: "Kept")
        let unlisted = Profile(id: UUID(), name: "Unlisted", symbol: "person", color: .gray)
        defer {
            for profile in [work, kept, unlisted] {
                try? files.removeItem(at: profile.supportDirectory)
            }
            try? files.removeItem(at: root)
        }
        for profile in [work, kept, unlisted] {
            try recordVisit(for: profile)
        }
        var checkpoint: Data?
        await store.remove(work, releaseWindows: {
            // A window can save its new selection before all the old tabs have closed.
            let window = ProfileStore.selection(profile: kept, catalog: store)
            #expect(window.currentID == kept.id && !window.profiles.contains(work))
            #expect((try? history(onDiskFor: work).visits.first?.title) == work.name)
            checkpoint = try? Data(contentsOf: file)
        }, settingsSync: nil, sharedSpaces: nil, eraseData: { _ in })
        // Relaunch from the exact bytes visible during detachment, with all three databases still on disk.
        let bytes = try #require(checkpoint)
        let restarted: ProfileStore
        if restoringListAfterLaunch {
            try files.removeItem(at: file)
            restarted = ProfileStore(file: file)
            #expect(restarted.verifiedProfiles == nil)
            try bytes.write(to: file, options: .atomic)
        } else {
            try bytes.write(to: file, options: .atomic)
            restarted = ProfileStore(file: file)
            #expect(restarted.currentID == kept.id)
        }
        #expect(restarted.verifiedProfiles == [.original(), kept])
        #expect(await waitUntil(timeout: .seconds(8)) {
            guard let saved = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return !files.fileExists(atPath: work.supportDirectory.path) && !saved.contains(work.id.uuidString)
        })
        try await restarted.remove(work, settingsSync: nil, sharedSpaces: nil).get()
        try await restarted.remove(unlisted, settingsSync: nil, sharedSpaces: nil).get()
        for profile in [kept, unlisted] {
            #expect(try history(onDiskFor: profile).visits.map(\.title) == [profile.name])
        }
    }

    @Test func retryFinishesAnErasureWhoseHistoryFileCouldNotBeRemoved() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        let store = ProfileStore(file: root.appending(path: "profiles.json"))
        let work = store.add(name: "Work")
        let database = try #require(work.databaseURL)
        defer {
            try? files.setAttributes([.immutable: false], ofItemAtPath: database.path)
            try? files.removeItem(at: work.supportDirectory)
            try? files.removeItem(at: root)
        }
        try recordVisit(for: work)
        // The interactive removal starts after a window has already initialized WebKit.
        _ = WKWebsiteDataStore.nonPersistent()
        try files.setAttributes([.immutable: true], ofItemAtPath: database.path)
        let first = await store.remove(work, settingsSync: nil, sharedSpaces: nil)
        #expect(throws: (any Error).self) { try first.get() }
        #expect(!store.profiles.contains(work) && files.fileExists(atPath: database.path))

        try files.setAttributes([.immutable: false], ofItemAtPath: database.path)
        #expect(try history(onDiskFor: work).visits.map(\.title) == [work.name])
        try await store.remove(work, settingsSync: nil, sharedSpaces: nil).get()
        #expect(!files.fileExists(atPath: work.supportDirectory.path))
        try await store.remove(work, settingsSync: nil, sharedSpaces: nil).get()
    }

    @Test func recoveryIgnoresBuiltInAndLiveProfilesEvenWhenMarked() async throws {
        struct Checkpoint: Codable {
            var profiles: [Profile]
            var currentID: UUID
            var pendingErasures: [Profile]?
        }
        let files = FileManager.default, root = files.temporaryDirectory.appending(path: UUID().uuidString)
        let file = root.appending(path: "profiles.json")
        let kept = Profile(id: UUID(), name: "Kept", symbol: "person", color: .gray)
        let work = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        defer {
            try? files.removeItem(at: kept.supportDirectory)
            try? files.removeItem(at: work.supportDirectory)
            try? files.removeItem(at: root)
        }
        try recordVisit(for: kept)
        try recordVisit(for: work)
        let saved = Checkpoint(profiles: [kept], currentID: kept.id, pendingErasures: [.original(), .privateBrowsing(), kept, work])
        try JSONFileStore.writeAtomically(saved, to: file, sortedKeys: true)
        let reopened = ProfileStore(file: file)
        #expect(reopened.profiles == [.original(), kept])
        #expect(await waitUntil(timeout: .seconds(8)) {
            let state = try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: file))
            return state != nil && (state?.pendingErasures ?? []).isEmpty
        })
        #expect(!files.fileExists(atPath: work.supportDirectory.path))
        #expect(try history(onDiskFor: kept).visits.map(\.title) == [kept.name])
    }

    @Test func theIDStaysReservedUntilErasureIsAcknowledgedOnDisk() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appending(path: UUID().uuidString)
        let file = root.appending(path: "profiles.json"), checkpoint = root.appending(path: "checkpoint")
        let store = ProfileStore(file: file)
        let work = store.add(name: "Work")
        defer {
            try? files.removeItem(at: work.supportDirectory)
            try? files.removeItem(at: root)
        }
        try recordVisit(for: work)
        let first = await store.remove(work, releaseWindows: {
            let window = ProfileStore.selection(profile: .original(), catalog: store)
            #expect(window.adopt(id: work.id, name: "Too soon", symbol: "person", color: .gray) == nil)
            await window.remove(work, settingsSync: nil, sharedSpaces: nil, eraseData: { _ in Issue.record("Erased during detachment") })
            #expect((try? history(onDiskFor: work).visits.first?.title) == work.name)
            do {
                try files.moveItem(at: file, to: checkpoint)
                try files.createDirectory(at: file, withIntermediateDirectories: false)
            } catch {
                Issue.record(error)
            }
        }, settingsSync: nil, sharedSpaces: nil)
        #expect(throws: (any Error).self) { try first.get() }
        #expect(!files.fileExists(atPath: work.supportDirectory.path))
        #expect(store.adopt(id: work.id, name: "Too soon", symbol: "person", color: .gray) == nil)

        try files.removeItem(at: file)
        try files.moveItem(at: checkpoint, to: file)
        try await store.remove(work, settingsSync: nil, sharedSpaces: nil).get()
        let adopted = try #require(store.adopt(id: work.id, name: "New Work", symbol: "person", color: .gray))
        try recordVisit(for: adopted)
        let reopened = ProfileStore(file: file)
        #expect(reopened.profiles.contains(adopted))
        #expect(try history(onDiskFor: adopted).visits.map(\.title) == [adopted.name])
    }

    @Test func anInUseWebsiteStoreKeepsItsErasurePendingAfterWindowsLeave() async throws {
        let files = FileManager.default, root = files.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let store = ProfileStore(file: root.appending(path: "profiles.json"))
        let work = store.add(name: "Work")
        func busy(_ profile: Profile) async throws {
            #expect(profile == work)
            throw Profile.PendingWebsiteData(underlying: CocoaError(.fileLocking))
        }
        try await store.remove(work, settingsSync: nil, sharedSpaces: nil, eraseData: busy).get()
        #expect(!store.profiles.contains(work))
        #expect(store.adopt(id: work.id, name: "Too soon", symbol: "person", color: .gray) == nil)
        let retry = await store.remove(work, settingsSync: nil, sharedSpaces: nil, eraseData: busy)
        #expect(throws: Profile.PendingWebsiteData.self) { try retry.get() }
        try await store.remove(work, settingsSync: nil, sharedSpaces: nil, eraseData: { _ in }).get()
        #expect(store.adopt(id: work.id, name: "Reopened", symbol: "person", color: .gray) != nil)
    }
}
