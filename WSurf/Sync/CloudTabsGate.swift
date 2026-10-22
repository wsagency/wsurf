// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Whether this process may reach CloudKit at all. Creating a container in a process whose signed entitlements lack the iCloud
/// keys raises an Objective-C exception that Swift cannot catch, so every condition is read before the first container exists.
/// An unsigned test build, a build with a bundle ID suffix and a stage app read no entitlement and never pass.
enum CloudTabsGate {
    /// Hidden. Turn it on with `defaults write <bundle id> experiments.iCloudTabs -bool YES`.
    static let flagKey = "experiments.iCloudTabs"
    static let container = "iCloud.io.wsagency.wsurf"

    struct Inputs {
        var flag: Bool
        var isRunningTests: Bool
        var isStaged: Bool
        var ownsSession: Bool
        var entitlement: (String) -> Any?

        static var live: Inputs {
            let flag = UserDefaults.standard.bool(forKey: flagKey)
            return Inputs(
                flag: flag,
                isRunningTests: AppDatabase.isRunningTests,
                isStaged: stageIsActive,
                // A second copy of the app keeps nothing and so shares nothing.
                ownsSession: flag && AppDatabase.ownsSession,
                entitlement: signedEntitlement
            )
        }
    }

    static func allows(_ inputs: Inputs) -> Bool {
        guard inputs.flag, !inputs.isRunningTests, !inputs.isStaged, inputs.ownsSession else { return false }
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
