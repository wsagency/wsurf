// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurf

/// What tab sync must never carry. The records allow only their own fields by construction; these tests catch a change that
/// widens them.
struct NeverSyncTests {
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The code that builds, sends or applies a record, and the one window extension that reads a tree.
    private func syncSources() throws -> [(path: String, text: String)] {
        let folders = ["Packages/WSurfCore/Sources/WSurfCore", "WSurf/Sync"]
        var files: [URL] = []
        for folder in folders {
            let enumerator = try #require(FileManager.default.enumerator(at: Self.root.appending(path: folder), includingPropertiesForKeys: nil))
            files += enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        files.append(Self.root.appending(path: "WSurf/Web/Model/BrowserModel+CloudTabs.swift"))
        return try files.map { (path: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func onlyDeviceAndDeviceSessionRecordsExist() {
        // A third record type is a decision: this list changes in the same commit that adds it.
        #expect(SyncRecordType.allCases.map(\.rawValue) == ["Device", "DeviceSession"])
    }

    @Test func syncSourcesNeverReferenceExcludedData() throws {
        let excluded = [
            "InputHistory", ".wih", "input-history", "sessionState", "deferRestore", "AutofillVaults", "CredentialManager",
            "WKWebsiteDataStore", "HTTPCookie", "SitePermissions", "PageZoom", "HistoryStore", "NSUbiquitousKeyValueStore",
        ]
        let sources = try syncSources()

        #expect(sources.count >= 9)
        for source in sources {
            for word in excluded {
                #expect(!source.text.contains(word), "\(source.path) names \(word)")
            }
        }
    }

    @Test func onlyPersonalCanShareInPhaseOne() {
        let named = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .gray)

        #expect(CloudTabs.canShare(.original()))
        #expect(!CloudTabs.canShare(.privateBrowsing()))
        #expect(!CloudTabs.canShare(named))
    }

    @Test func zonesExistOnlyForProfilesWithTheirOwnNameFormat() {
        let id = UUID()

        #expect(SyncZone.profileID(SyncZone.profile(id)) == id)
        #expect(SyncZone.profileID(SyncZone.devices) == nil)
        #expect(SyncZone.profileID("p-not-a-uuid") == nil)
        #expect(SyncZone.profileID("p-" + id.uuidString.lowercased()) == nil)
    }
}
