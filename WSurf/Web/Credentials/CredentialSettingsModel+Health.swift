// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// What a password health report was asked for: one vault's revision under one unlock.
struct HealthKey: Equatable {
    let vaultID: UUID
    let epoch: UInt64
    let revision: UInt64
}

/// Password health on the Credentials page (S4): the vault's report (`CredentialManager.passwordHealth`) puts "Weak" and "Reused"
/// flags on the summaries the list shows. The page asks after the list has shown, never before it, and once per settled revision: a
/// write while a request waits cancels it and asks again for the newer revision. The report is made in the vault, so only flags reach
/// the page, and a lock drops them with the session. Reading the vault does not extend its unlock (`CredentialAutoLock`).
extension CredentialSettingsModel {
    /// The app asks half a second after a revision settles. A test host asks never, unless a test passes its own delay, so other
    /// suites' vault reads and timings stay as they were.
    static let defaultHealthDelay: Duration? = AppDatabase.isRunningTests ? nil : .milliseconds(500)

    /// The revision whose health the summaries show, `nil` while they show none.
    var healthRevision: UInt64? {
        live?.healthRevision
    }

    /// Asks for a report when the vault shown is at a revision none was asked for. Called whenever the session changes.
    func scheduleHealthIfNeeded() {
        guard let healthDelay, let live, let manager else { return }
        let key = HealthKey(vaultID: manager.vaultID, epoch: live.epoch, revision: live.revision)
        guard key != healthKey else { return }
        healthKey = key
        healthTask?.cancel()
        healthTask = Task { [weak self, manager] in
            try? await Task.sleep(for: healthDelay)
            guard !Task.isCancelled, let report = try? await manager.passwordHealth(), !Task.isCancelled else { return }
            // Another vault on the page, another unlock or another revision takes nothing from this report.
            guard let self, self.manager === manager, report.vaultID == key.vaultID else { return }
            try? self.update(key.epoch) { $0.applyHealth(report) }
        }
    }

    /// The other credentials that save the same password as `summary`, in the list's order; empty when it is not reused.
    func sharingPassword(with summary: CredentialSummary) -> [CredentialSummary] {
        guard let group = summary.health?.reuse?.group else { return [] }
        return summaries.filter { $0.id != summary.id && $0.health?.reuse?.group == group }
    }
}
