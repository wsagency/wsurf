// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

/// CloudKit's opaque user record name identifies the account within this app's container.
public protocol SyncAccountIdentity: AnyObject {
    func currentAccountUser() async throws -> String
}

extension SyncEngineDelegate {
    /// A failed account lookup leaves pending changes in the transport. A subsequent batch verifies the account again.
    public func permitsUpload(using currentUser: @MainActor @Sendable () async throws -> String) async -> Bool {
        await prepareForUpload()
        guard let user = try? await currentUser(), !user.isEmpty else { return false }
        return acceptsUploadAccount(user)
    }
}
