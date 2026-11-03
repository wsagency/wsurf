// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

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
