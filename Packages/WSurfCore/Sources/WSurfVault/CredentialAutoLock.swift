// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How long one vault stays unlocked, counted from the unlock. It is a plain preference of the profile, not a secret. Nothing
/// extends a running lease: page activity, reading and writing the vault do not, and a longer choice applies from the next unlock.
public nonisolated enum CredentialAutoLock: Int, CaseIterable, Sendable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    /// No timer. Every lock event still ends the lease (`CredentialLockEvent`).
    case whenWSurfQuits = 0

    /// What a vault without a stored choice, or with one this version does not list, uses. A tampered value never lengthens a lease.
    public static let standard = CredentialAutoLock.fiveMinutes

    /// `nil`: no timer.
    public var lifetime: Duration? {
        self == .whenWSurfQuits ? nil : .seconds(rawValue)
    }

    public var label: String {
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
    public static func stored(for vaultID: UUID, in defaults: UserDefaults) -> CredentialAutoLock {
        (defaults.object(forKey: key(for: vaultID)) as? Int).flatMap(CredentialAutoLock.init(rawValue:)) ?? .standard
    }

    public static func store(_ choice: CredentialAutoLock, for vaultID: UUID, in defaults: UserDefaults) {
        defaults.set(choice.rawValue, forKey: key(for: vaultID))
    }

    /// The choice of a vault that no longer exists. Idempotent.
    static func forget(for vaultID: UUID, in defaults: UserDefaults) {
        defaults.removeObject(forKey: key(for: vaultID))
    }
}
