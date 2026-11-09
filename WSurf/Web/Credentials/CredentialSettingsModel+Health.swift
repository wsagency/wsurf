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

/// The vault and unlock under which Show Password Health passed its prompt.
struct HealthGrant: Equatable {
    let vaultID: UUID
    let epoch: UInt64
}

/// Password health on the Credentials page (S4): the vault's report (`CredentialManager.passwordHealth`) puts "Weak" and "Reused"
/// flags on the summaries the list shows, and the editor's note explains them.
///
/// Nothing of it is read or shown until Show Password Health passes Touch ID (`verifyOwner`), once per vault and unlock. The flags
/// are derived from the passwords: without the prompt, saving a guessed password and watching "Reused" appear would tell which
/// login holds it. After the prompt, the page asks once per settled revision: a write while a request waits cancels it and asks
/// again for the newer revision. The report is made in the vault, so only flags reach the page. A lock drops them with the session,
/// and the next unlock asks again. Reading the vault does not extend its unlock (`CredentialAutoLock`).
extension CredentialSettingsModel {
    /// Whether password health is shown: Show Password Health passed its prompt for the vault and unlock shown.
    var showsHealth: Bool {
        guard let live, let manager else { return false }
        return healthGrant == HealthGrant(vaultID: manager.vaultID, epoch: live.epoch)
    }

    /// The revision whose health the summaries show, `nil` while they show none.
    var healthRevision: UInt64? {
        live?.healthRevision
    }

    /// Show Password Health: Touch ID or the Mac password, then the report of the revision shown, read at once. Returns at once while
    /// health is shown or its prompt is up. A refusal reads and shows nothing.
    func revealHealth() async throws {
        guard !showsHealth, !isRevealingHealth, let manager else { return }
        isRevealingHealth = true
        defer { isRevealingHealth = false }
        let epoch = try await verifyOwner(String(localized: "show weak and reused passwords"))
        guard self.manager === manager, live?.epoch == epoch else { throw CredentialVaultError.unauthorized }
        healthGrant = HealthGrant(vaultID: manager.vaultID, epoch: epoch)
        healthKey = nil
        scheduleHealthIfNeeded(after: .zero)
    }

    /// Asks for a report while health is shown and the vault shown is at a revision none was asked for, after `delay` (by default
    /// `healthDelay`). Called whenever the session changes.
    func scheduleHealthIfNeeded(after delay: Duration? = nil) {
        guard showsHealth, let live, let manager else { return }
        let key = HealthKey(vaultID: manager.vaultID, epoch: live.epoch, revision: live.revision)
        guard key != healthKey else { return }
        healthKey = key
        healthTask?.cancel()
        let wait = delay ?? healthDelay
        healthTask = Task { [weak self, manager] in
            try? await Task.sleep(for: wait)
            // Right before the read: still shown, for this vault, under the unlock it was asked under. A lock and a new unlock
            // during the wait read nothing under the new one.
            guard !Task.isCancelled, let self, self.manager === manager, self.showsHealth, manager.authorizationEpoch == key.epoch
            else { return }
            guard let report = try? await manager.passwordHealth(), !Task.isCancelled else { return }
            // Another vault on the page, another unlock or another revision takes nothing from this report.
            guard self.manager === manager, report.vaultID == key.vaultID else { return }
            try? self.update(key.epoch) { $0.applyHealth(report) }
        }
    }

    /// Ends Show Password Health's grant: the flags go at once, nothing more is read, and the next Show Password Health asks again.
    /// Called when this page saves a new or changed password, so each guess saved here costs a prompt to check.
    func endHealthGrant() {
        healthGrant = nil
        cancelHealthRead()
        if let live {
            try? update(live.epoch) { $0.dropHealth() }
        }
    }

    /// Cancels a report that waits or is being read: a page that was closed, locked or moved to another vault reads none.
    func cancelHealthRead() {
        healthTask?.cancel()
        healthTask = nil
        healthKey = nil
    }

    /// The other credentials that save the same password as `summary`, in the list's order; empty when it is not reused.
    func sharingPassword(with summary: CredentialSummary) -> [CredentialSummary] {
        guard let group = summary.health?.reuse?.group else { return [] }
        return summaries.filter { $0.id != summary.id && $0.health?.reuse?.group == group }
    }
}
