// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Security

/// Whether this process may reach CloudKit at all, for tab sharing and for vault sync. Creating a container in a process whose signed
/// entitlements lack the iCloud keys raises an Objective-C exception that Swift cannot catch, so every condition is read before the
/// first container exists. An unsigned test build, a build with a bundle ID suffix and a stage app read no entitlement and never pass.
/// Each feature has its own hidden flag; the environment checks are shared.
enum CloudSyncGate {
    /// Hidden. Turn it on with `defaults write <bundle id> experiments.iCloudTabs -bool YES`.
    static let tabsFlagKey = "experiments.iCloudTabs"
    /// Hidden, and off until the owner's two-Mac passkey check passes. `defaults write <bundle id> experiments.iCloudVault -bool YES`.
    static let vaultFlagKey = "experiments.iCloudVault"
    static let container = "iCloud.io.wsagency.wsurf"

    struct Inputs {
        var tabsFlag: Bool
        var vaultFlag: Bool
        var isRunningTests: Bool
        var isStaged: Bool
        var ownsSession: Bool
        var entitlement: (String) -> Any?

        static var live: Inputs {
            let tabs = UserDefaults.standard.bool(forKey: tabsFlagKey)
            let vaults = UserDefaults.standard.bool(forKey: vaultFlagKey)
            return Inputs(
                tabsFlag: tabs,
                vaultFlag: vaults,
                isRunningTests: AppDatabase.isRunningTests,
                isStaged: stageIsActive,
                // A second copy of the app keeps nothing and so syncs nothing.
                ownsSession: (tabs || vaults) && AppDatabase.ownsSession,
                entitlement: signedEntitlement
            )
        }
    }

    static func allowsTabs(_ inputs: Inputs) -> Bool {
        inputs.tabsFlag && environmentAllows(inputs)
    }

    /// The flag is the consent to fetch; nothing uploads before a vault's own switch.
    static func allowsVaults(_ inputs: Inputs) -> Bool {
        inputs.vaultFlag && environmentAllows(inputs)
    }

    private static func environmentAllows(_ inputs: Inputs) -> Bool {
        guard !inputs.isRunningTests, !inputs.isStaged, inputs.ownsSession else { return false }
        let containers = inputs.entitlement("com.apple.developer.icloud-container-identifiers") as? [String]
        let services = inputs.entitlement("com.apple.developer.icloud-services") as? [String]
        return containers?.contains(container) == true
            && services?.contains("CloudKit") == true
            && inputs.entitlement("com.apple.developer.aps-environment") is String
    }

    /// The running binary's own signed entitlement, or nil. macOS only: `SecTask` is not in the iOS SDK.
    static func signedEntitlement(_ name: String) -> Any? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        return SecTaskCopyValueForEntitlement(task, name as CFString, nil)
    }

    private static var stageIsActive: Bool {
        #if DEBUG
        StageMode.isActive
        #else
        false
        #endif
    }
}
