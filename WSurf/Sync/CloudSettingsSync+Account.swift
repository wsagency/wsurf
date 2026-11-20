// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CloudKit
import Foundation

extension CloudSettingsSync {
    func acceptsUploadAccount(_ user: String) -> Bool {
        guard let previous = state.account, previous != user else { return true }
        do {
            try resetAccount(to: user)
        } catch {
            reportError()
        }
        if accountNotifications != nil {
            ProviderKeySharing.shared.setAccountIdentifier(user)
        }
        return false
    }

    /// Called by the signed app only after the entitlement and session checks.
    func startMonitoringAccount() {
        guard accountNotifications == nil else { return }
        accountNotifications = Task { [weak self] in
            let changes = NotificationCenter.default.notifications(named: .CKAccountChanged).map { _ in () }
            self?.refreshAccountVerification()
            for await _ in changes {
                guard !Task.isCancelled, let self else { return }
                refreshAccountVerification()
            }
        }
    }

    func refreshAccountVerification() {
        guard accountNotifications != nil else { return }
        accountLookup?.cancel()
        suspendAccount()
        ProviderKeySharing.shared.suspendAccountVerification()
        accountLookup = Task { [weak self] in
            guard let self else { return }
            let container = CKContainer(identifier: CloudSyncGate.container)
            do {
                let identity: String?
                switch try await container.accountStatus() {
                case .available:
                    identity = try await container.userRecordID().recordName
                case .noAccount:
                    identity = nil
                default:
                    throw Issue.unavailable
                }
                try Task.checkCancellation()
                ProviderKeySharing.shared.setAccountIdentifier(identity)
                try accountDidResolve(identity)
            } catch {
                if !Task.isCancelled {
                    reportError()
                }
            }
        }
    }

    func accountDidResolve(_ identity: String?) throws {
        // A first offline choice has no verified owner yet. An explicit retry binds its saved edits.
        if let prior = state.account, prior != identity {
            try resetAccount(to: identity)
        }
        if identity == nil {
            notice = String(localized: "Sign in to iCloud in System Settings to use Sync.")
        } else {
            beat()
        }
    }

    func suspendAccount() {
        generation = UUID()
        trustedUser = nil
        ready.removeAll()
        loading.removeAll()
        buffered.removeAll()
        preparations.values.forEach { $0.cancel() }
        preparations.removeAll()
    }
}
