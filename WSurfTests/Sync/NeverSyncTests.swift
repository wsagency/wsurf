// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

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
        let folders = ["Packages/WSurfCore/Sources/WSurfCore", "Packages/WSurfCore/Sources/WSurfVault/Sync", "WSurf/Sync"]
        var files: [URL] = []
        for folder in folders {
            let enumerator = try #require(FileManager.default.enumerator(at: Self.root.appending(path: folder), includingPropertiesForKeys: nil))
            files += enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        }
        files.append(Self.root.appending(path: "WSurf/Web/Model/BrowserModel+CloudTabs.swift"))
        return try files.map { (path: $0.lastPathComponent, text: try String(contentsOf: $0, encoding: .utf8)) }
    }

    @Test func onlyTheAllowedRecordTypesExist() {
        // A fifth record type is a decision: this list changes in the same commit that adds it.
        #expect(SyncRecordType.allCases.map(\.rawValue) == ["Device", "DeviceSession", "Vault", "Item"])
    }

    @Test func syncSourcesNeverReferenceExcludedData() throws {
        let excluded = [
            "InputHistory", ".wih", "input-history", "sessionState", "deferRestore", "AutofillVaults", "WKWebsiteDataStore",
            "HTTPCookie", "SitePermissions", "PageZoom", "HistoryStore", "NSUbiquitousKeyValueStore", "inputHistoryKey", "VaultBlob",
            "Credentials.blobs", "readAttachment", "AutofillSaveIndex", "PaymentCardVault", "blockedPasswordOrigins", "AutofillLastUsed",
        ]
        // The tab files never reach the credential manager; the vault host is the one sync file that must.
        let managerNeedle = "CredentialManager"
        let vaultHosts: Set = ["CredentialVaultSyncHost.swift"]
        let sources = try syncSources()

        #expect(sources.count >= 14)
        for source in sources {
            for word in excluded {
                #expect(!source.text.contains(word), "\(source.path) names \(word)")
            }
            if !vaultHosts.contains(source.path) {
                #expect(!source.text.contains(managerNeedle), "\(source.path) names \(managerNeedle)")
            }
        }
    }

    @Test func onlyPersonalCanShareInPhaseOne() {
        let named = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .gray)

        #expect(CloudTabs.canShare(.original()))
        #expect(!CloudTabs.canShare(.privateBrowsing()))
        #expect(!CloudTabs.canShare(named))
    }

    @Test func vaultZonesExistOnlyInTheirOwnNameFormat() throws {
        let profile = try #require(UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"))
        let vault = try #require(UUID(uuidString: "FEDCBA98-7654-4321-8FED-CBA987654321"))
        let zone = SyncZone.vault(profileID: profile, vaultID: vault)

        #expect(zone == "v-0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D-FEDCBA98-7654-4321-8FED-CBA987654321" && zone.count == 75)
        #expect(SyncZone.vaultIDs(zone)?.profileID == profile && SyncZone.vaultIDs(zone)?.vaultID == vault)
        #expect(SyncZone.vaultIDs(zone.lowercased()) == nil)
        #expect(SyncZone.vaultIDs("v-" + profile.uuidString) == nil)
        #expect(SyncZone.vaultIDs("v-" + profile.uuidString + "-not-a-uuid") == nil)
        #expect(SyncZone.vaultIDs(SyncZone.devices) == nil && SyncZone.vaultIDs(SyncZone.profile(profile)) == nil)
        #expect(SyncZone.profileID(zone) == nil)
        #expect(SyncZone.isVault(zone) && !SyncZone.isVault(SyncZone.profile(profile)) && !SyncZone.isVault(SyncZone.devices))
    }

    @Test func zonesExistOnlyForProfilesWithTheirOwnNameFormat() {
        let id = UUID()

        #expect(SyncZone.profileID(SyncZone.profile(id)) == id)
        #expect(SyncZone.profileID(SyncZone.devices) == nil)
        #expect(SyncZone.profileID("p-not-a-uuid") == nil)
        #expect(SyncZone.profileID("p-" + id.uuidString.lowercased()) == nil)
    }
}
