// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore

@testable import WSurf

/// Nothing reaches CloudKit unless the flag, the signed entitlements and the environment all allow it, and the install ID is
/// readable.
@MainActor
struct CloudTabsGateTests {
    /// What is missing from an otherwise complete build.
    enum Gap: CaseIterable {
        case flag
        case containerKey
        case ourContainer
        case cloudKitService
        case pushEnvironment
        case nothing
    }

    private func inputs(missing gap: Gap = .nothing, tests: Bool = false, staged: Bool = false, owns: Bool = true) -> CloudTabsGate.Inputs {
        var entitlements: [String: Any] = [
            "com.apple.developer.icloud-container-identifiers": [CloudTabsGate.container, "iCloud.example.other"],
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
        return CloudTabsGate.Inputs(
            flag: gap != .flag,
            isRunningTests: tests,
            isStaged: staged,
            ownsSession: owns,
            entitlement: { held[$0] }
        )
    }

    @Test(arguments: Gap.allCases)
    func syncNeedsTheFlagAndEveryEntitlement(missing gap: Gap) {
        #expect(CloudTabsGate.allows(inputs(missing: gap)) == (gap == .nothing))
    }

    @Test func nothingIsAllowedWithoutAnyEntitlement() {
        let bare = CloudTabsGate.Inputs(flag: true, isRunningTests: false, isStaged: false, ownsSession: true, entitlement: { _ in nil })

        #expect(!CloudTabsGate.allows(bare))
    }

    @Test func testsStagingAndSecondCopiesNeverSync() {
        #expect(!CloudTabsGate.allows(inputs(tests: true)))
        #expect(!CloudTabsGate.allows(inputs(staged: true)))
        #expect(!CloudTabsGate.allows(inputs(owns: false)))
        #expect(CloudTabsGate.allows(inputs()))
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
