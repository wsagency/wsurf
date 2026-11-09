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

/// The vault, unlock and revision Show Password Health's prompt covers. The revision moves on only with this page's own writes that
/// change nothing health reads of the credentials they keep (`CredentialSettingsModel.save`, `remove`); any other revision ends the
/// grant.
struct HealthGrant: Equatable {
    let vaultID: UUID
    let epoch: UInt64
    var revision: UInt64
}

/// Password health on the Credentials page (S4): the vault's report (`CredentialManager.passwordHealth`) puts "Weak" and "Reused"
/// flags on the summaries the list shows, and the editor's note explains them.
///
/// Nothing of it is read or shown until Show Password Health passes Touch ID (`verifyOwner`). The flags are derived from the
/// passwords: without the prompt, saving a guessed password and watching "Reused" appear would tell which login holds it, and
/// saving a guessed username or website name and watching "Weak" appear would tell what the password holds. So the prompt covers
/// one vault, one unlock and the revision shown, and moves on only with this page's own writes that change none of the passwords,
/// usernames, websites and login addresses of the credentials they keep (`PasswordHealth.sameInputs`), such as a rename or a
/// removal (`HealthGrant`). A save that changes one of them or adds a credential ends it, so does an import, and so does any
/// revision the page did not write: autofill's save on submit, another window, sync. After the prompt, the page asks once per
/// settled revision: a write while a request waits cancels it and asks again for the newer revision. The report is made in the
/// vault, so only flags reach the page. A lock drops them with the session, and the next unlock asks again. Reading the vault does
/// not extend its unlock (`CredentialAutoLock`).
extension CredentialSettingsModel {
    /// Whether password health is shown: Show Password Health's prompt covers the vault, unlock and revision shown.
    var showsHealth: Bool {
        guard let live, let manager else { return false }
        return healthGrant == HealthGrant(vaultID: manager.vaultID, epoch: live.epoch, revision: live.revision)
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
        guard self.manager === manager, let live, live.epoch == epoch else { throw CredentialVaultError.unauthorized }
        healthGrant = HealthGrant(vaultID: manager.vaultID, epoch: epoch, revision: live.revision)
        healthKey = nil
        scheduleHealthIfNeeded(after: .zero)
    }

    /// Asks for a report while health is shown and the vault shown is at a revision none was asked for, after `delay` (by default
    /// `healthDelay`). Called whenever the session changes.
    func scheduleHealthIfNeeded(after delay: Duration? = nil) {
        // A revision of the granted vault and unlock that this page did not write ends the grant.
        if let grant = healthGrant, let live, let manager, grant.vaultID == manager.vaultID, grant.epoch == live.epoch,
           grant.revision != live.revision {
            endHealthGrant()
        }
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
    /// Called when this page saves a change to what health reads of a credential or adds one, and when it imports, so each guess
    /// saved here costs a prompt to check, and when the page meets a revision it did not write.
    func endHealthGrant() {
        healthGrant = nil
        cancelHealthRead()
        if let live {
            try? update(live.epoch) { $0.dropHealth() }
        }
    }

    /// Moves the grant on with a write this page made itself from the revision it covers, so a rename or a removal keeps it. A save
    /// that changes what health reads of a credential or adds one, and an import, ended it before they were made (`save`,
    /// `commitImport`).
    func carryHealthGrant(from expected: UInt64, to written: UInt64) {
        guard var grant = healthGrant, grant.revision == expected else { return }
        grant.revision = written
        healthGrant = grant
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
