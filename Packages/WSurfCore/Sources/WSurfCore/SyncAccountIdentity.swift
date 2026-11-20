// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

/// CloudKit's opaque user record name identifies the account within this app's container.
public protocol SyncAccountIdentity: AnyObject {
    func currentAccountUser() async throws -> String
}
