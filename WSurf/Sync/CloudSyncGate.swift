// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Security

/// Verify the process and its signed grants before creating a CloudKit container. On a development-signed Mac,
/// Settings can offer each category before any content sharing is enabled.
enum CloudSyncGate {
    /// Restores the tab service after the person enables Other Devices. Per-profile consent controls its snapshots.
    static let tabsFlagKey = "experiments.iCloudTabs"
    /// Restores vault discovery. Each vault has its own consent to share entries and files.
    static let vaultFlagKey = "experiments.iCloudVault"
    static let container = "iCloud.io.wsagency.wsurf"

    struct Inputs {
        var tabsFlag: Bool
        var vaultFlag: Bool
        var isRunningTests: Bool
        var isStaged: Bool
        var ownsSession: Bool
        var entitlement: (String) -> Any?
        var offersMacSync = false

        static var live: Inputs {
            let tabs = UserDefaults.standard.bool(forKey: tabsFlagKey)
            let vaults = UserDefaults.standard.bool(forKey: vaultFlagKey)
            return Inputs(
                tabsFlag: tabs,
                vaultFlag: vaults,
                isRunningTests: AppDatabase.isRunningTests,
                isStaged: stageIsActive,
                // A second copy of the app keeps nothing and so syncs nothing.
                ownsSession: AppDatabase.ownsSession,
                entitlement: signedEntitlement,
                offersMacSync: true
            )
        }
    }

    /// The Mac can show the sharing controls before someone chooses what to send.
    static func canOfferMacSync(_ inputs: Inputs) -> Bool {
        inputs.offersMacSync && environmentAllows(inputs)
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
