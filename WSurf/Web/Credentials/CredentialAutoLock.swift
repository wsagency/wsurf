// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// How long one vault stays unlocked, counted from the unlock. It is a plain preference of the profile, not a secret. Nothing
/// extends a running lease: page activity, reading and writing the vault do not, and a longer choice applies from the next unlock.
nonisolated enum CredentialAutoLock: Int, CaseIterable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    /// No timer. Every lock event still ends the lease (`CredentialLockEvent`).
    case whenWSurfQuits = 0

    /// What a vault without a stored choice, or with one this version does not list, uses. A tampered value never lengthens a lease.
    static let standard = CredentialAutoLock.fiveMinutes

    /// `nil`: no timer.
    var lifetime: Duration? {
        self == .whenWSurfQuits ? nil : .seconds(rawValue)
    }

    var label: String {
        switch self {
        case .oneMinute:
            String(localized: "After 1 minute")
        case .fiveMinutes:
            String(localized: "After 5 minutes")
        case .fifteenMinutes:
            String(localized: "After 15 minutes")
        case .thirtyMinutes:
            String(localized: "After 30 minutes")
        case .oneHour:
            String(localized: "After 1 hour")
        case .whenWSurfQuits:
            String(localized: "When WSurf quits")
        }
    }

    static func key(for vaultID: UUID) -> String {
        "io.wsagency.wsurf.credentialVault.autoLock." + vaultID.uuidString.lowercased()
    }

    /// `object(forKey:)`, not `integer(forKey:)`: a missing key must not read as 0, which is `whenWSurfQuits`.
    static func stored(for vaultID: UUID, in defaults: UserDefaults) -> CredentialAutoLock {
        (defaults.object(forKey: key(for: vaultID)) as? Int).flatMap(CredentialAutoLock.init(rawValue:)) ?? .standard
    }

    static func store(_ choice: CredentialAutoLock, for vaultID: UUID, in defaults: UserDefaults) {
        defaults.set(choice.rawValue, forKey: key(for: vaultID))
    }

    /// The choice of a vault that no longer exists. Idempotent.
    static func forget(for vaultID: UUID, in defaults: UserDefaults) {
        defaults.removeObject(forKey: key(for: vaultID))
    }
}

/// A system event that locks every vault of every profile, whatever the vault's `CredentialAutoLock`. A table, so a test can read
/// what is observed without posting a system notification. Main Actor: the notification names belong to AppKit's main-actor classes.
struct CredentialLockEvent: Equatable {
    enum Center {
        case workspace, distributed, application
    }

    let center: Center
    let name: Notification.Name
    let reason: CredentialLockReason

    static let all = [
        CredentialLockEvent(center: .workspace, name: NSWorkspace.willSleepNotification, reason: .sleep),
        CredentialLockEvent(center: .workspace, name: NSWorkspace.screensDidSleepNotification, reason: .sleep),
        // Login-session switch-out; NSApplication focus loss would cancel ceremonies behind provider UI.
        CredentialLockEvent(center: .workspace, name: NSWorkspace.sessionDidResignActiveNotification, reason: .screenLock),
        CredentialLockEvent(center: .distributed, name: Notification.Name("com.apple.screenIsLocked"), reason: .screenLock),
        CredentialLockEvent(center: .application, name: NSApplication.willTerminateNotification, reason: .termination),
    ]
}
