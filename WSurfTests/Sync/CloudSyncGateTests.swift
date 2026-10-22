// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurf

/// Nothing reaches CloudKit unless the feature's own flag, the signed entitlements and the environment all allow it, and the install
/// ID is readable. Tab sharing and vault sync each have a flag and neither enables the other.
@MainActor
struct CloudSyncGateTests {
    /// What is missing from an otherwise complete build.
    enum Gap: CaseIterable {
        case flag
        case containerKey
        case ourContainer
        case cloudKitService
        case pushEnvironment
        case nothing
    }

    /// `tabs` and `vaults` are the two hidden flags; `missing: .flag` clears the one under test.
    private func inputs(
        missing gap: Gap = .nothing, tabs: Bool = true, vaults: Bool = true, tests: Bool = false, staged: Bool = false, owns: Bool = true
    ) -> CloudSyncGate.Inputs {
        var entitlements: [String: Any] = [
            "com.apple.developer.icloud-container-identifiers": [CloudSyncGate.container, "iCloud.example.other"],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.aps-environment": "production",
        ]
        switch gap {
        case .containerKey:
            entitlements["com.apple.developer.icloud-container-identifiers"] = nil
        case .ourContainer:
            entitlements["com.apple.developer.icloud-container-identifiers"] = ["iCloud.example.other"]
        case .cloudKitService:
            entitlements["com.apple.developer.icloud-services"] = ["CloudDocuments"]
        case .pushEnvironment:
            entitlements["com.apple.developer.aps-environment"] = nil
        case .flag, .nothing:
            break
        }
        let held = entitlements
        return CloudSyncGate.Inputs(
            tabsFlag: tabs && gap != .flag,
            vaultFlag: vaults && gap != .flag,
            isRunningTests: tests,
            isStaged: staged,
            ownsSession: owns,
            entitlement: { held[$0] }
        )
    }

    @Test(arguments: Gap.allCases)
    func syncNeedsTheFlagAndEveryEntitlement(missing gap: Gap) {
        #expect(CloudSyncGate.allowsTabs(inputs(missing: gap)) == (gap == .nothing))
    }

    @Test(arguments: Gap.allCases)
    func vaultSyncNeedsItsOwnFlagAndEveryEntitlement(missing gap: Gap) {
        #expect(CloudSyncGate.allowsVaults(inputs(missing: gap)) == (gap == .nothing))
    }

    @Test func eachFeatureNeedsItsOwnFlag() {
        #expect(CloudSyncGate.allowsTabs(inputs(vaults: false)) && !CloudSyncGate.allowsVaults(inputs(vaults: false)))
        #expect(CloudSyncGate.allowsVaults(inputs(tabs: false)) && !CloudSyncGate.allowsTabs(inputs(tabs: false)))
        #expect(!CloudSyncGate.allowsTabs(inputs(tabs: false, vaults: false)) && !CloudSyncGate.allowsVaults(inputs(tabs: false, vaults: false)))
    }

    @Test func nothingIsAllowedWithoutAnyEntitlement() {
        let bare = CloudSyncGate.Inputs(
            tabsFlag: true, vaultFlag: true, isRunningTests: false, isStaged: false, ownsSession: true, entitlement: { _ in nil }
        )

        #expect(!CloudSyncGate.allowsTabs(bare) && !CloudSyncGate.allowsVaults(bare))
    }

    @Test func testsStagingAndSecondCopiesNeverSync() {
        for allows in [CloudSyncGate.allowsTabs, CloudSyncGate.allowsVaults] {
            #expect(!allows(inputs(tests: true)))
            #expect(!allows(inputs(staged: true)))
            #expect(!allows(inputs(owns: false)))
            #expect(allows(inputs()))
        }
    }

    @Test func installIDIsCreatedOnceAndReused() throws {
        let storage = MemoryInstallIDStorage()

        let first = try #require(InstallID.resolve(storage))
        let second = InstallID.resolve(storage)

        #expect(UUID(uuidString: first) != nil)
        #expect(second == first)
        #expect(storage.writes == 1)
    }

    @Test func unreadableInstallIDStopsSync() {
        let storage = MemoryInstallIDStorage(value: UUID().uuidString)
        storage.failsReads = true

        #expect(InstallID.resolve(storage) == nil)
        #expect(storage.writes == 0)
    }

    @Test func invalidStoredInstallIDIsReplaced() throws {
        let storage = MemoryInstallIDStorage(value: "not-a-uuid")

        let resolved = try #require(InstallID.resolve(storage))

        #expect(resolved != "not-a-uuid")
        #expect(UUID(uuidString: resolved) != nil)
        #expect(storage.value == resolved)
    }
}
