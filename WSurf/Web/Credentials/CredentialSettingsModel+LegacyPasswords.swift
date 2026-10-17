// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// The one-time import of the passwords saved before Credential Manager, as the Credential Manager page drives it: read the old
/// list (the system asks the user to authenticate), stage what the vault does not hold for the usual review, and, once the import
/// step is complete, offer to remove the old list. Nothing here changes the old list except `confirmLegacyRemoval`.
extension CredentialSettingsModel {
    /// Reads the old list and stages it for review. `epoch` is the authorization the page had when the user chose Review…: a lock
    /// or re-unlock while the system's prompt was up stages nothing. A list whose every password the vault already holds needs
    /// no review, so the import step is complete and the removal is offered.
    func beginLegacyImport(epoch: UInt64) async {
        ownMessage = nil
        _ = await perform(epoch: epoch, describe: { Self.legacyMessage(for: $0) }) { manager in
            let records = try await self.legacy.withSession { try await self.legacy.migration.records(using: $0) }
            let held = try await self.legacy.migration.unlockedAccounts()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            guard !LegacyPasswordMigration.missing(records, in: held).isEmpty else {
                self.legacy.markImported()
                self.legacy.offerRemoval(.init(total: records.count, missing: 0))
                return
            }
            try await self.exchange.beginLegacyImport(records, into: manager, owner: self.owner, onEnding: self.importEnding(in: manager))
        }
    }

    /// The review resolved to nothing to save: everything was skipped or is already saved. That is a decision, not a dead end, so
    /// it ends the review without a message and completes the import step. The removal dialog that follows still names every
    /// password that would be lost.
    func continueLegacyImport() async {
        guard let manager, let review = importReview, review.origin == .legacyPasswords, review.isResolved,
              (review.outcome.map { $0.added + $0.updated } ?? 0) == 0,
              exchange.cancelImport(for: manager, owner: owner) == .reviewCancelled else { return }
        await legacyImportCommitted(.legacyPasswords)
    }

    /// Called after any import committed. Only a receipt for the old list's own review counts: its passwords are in the vault now, so
    /// the import step is complete. A discarded, failed or uncertain import never reaches this and leaves the state alone.
    func legacyImportCommitted(_ origin: CredentialTransferMessage.Origin) async {
        guard origin == .legacyPasswords else { return }
        legacy.markImported()
        await requestLegacyRemoval()
    }

    /// Counts what the old list holds and what the vault does not, and asks the user to confirm the removal. Offered only for an
    /// import that is complete, and only while the vault is open: a locked vault holds nothing that can be counted.
    func requestLegacyRemoval() async {
        guard isUnlocked, legacy.migration.storedState == .imported else { return }
        _ = await perform(describe: { Self.legacyMessage(for: $0) }) { _ in
            let tally = try await self.legacy.withSession { try await self.legacy.migration.tally(using: $0) }
            self.legacy.offerRemoval(tally)
        }
    }

    /// Removes the old list after the user confirmed the dialog that stated `tally`. Both counts are read again first; if either
    /// changed, nothing is removed and the user is told to review again.
    func confirmLegacyRemoval(_ tally: LegacyPasswordMigration.Tally) async {
        legacy.dismissRemoval()
        let removed = await perform(describe: { Self.legacyMessage(for: $0) }) { _ in
            try await self.legacy.withSession {
                try await self.legacy.migration.erase(using: $0, expectedTotal: tally.total, expectedMissing: tally.missing)
            }
        }
        if removed {
            legacy.finishRemoval()
        }
    }

    /// What the removal dialog says. It names every password the vault does not hold before it offers to delete the list.
    static func legacyRemovalText(_ tally: LegacyPasswordMigration.Tally) -> String {
        guard tally.total > 0 else {
            return String(localized: "The old list has no passwords. Remove it to finish the move to Credential Manager.")
        }
        let held = tally.missing == 0
            ? String(localized: "All \(tally.total) passwords from the old list are in Credential Manager.")
            : String(localized: """
                \(tally.missing) of \(tally.total) passwords from the old list aren’t in Credential Manager because you skipped them, \
                kept a different password, or they can’t be imported. Removing the list deletes them permanently.
                """)
        let recovery = String(localized: """
            After this, the passwords you imported exist only in your vault. If you lose every passkey that unlocks it, they can’t be \
            recovered. You can add a second unlock passkey in Credential Manager.
            """)
        return held + " " + recovery
    }

    static func legacyMessage(for error: any Error) -> String? {
        switch error {
        case AutofillVaultError.keychain(let status) where status == errSecUserCanceled:
            nil
        case AutofillVaultError.keychain(let status) where status == errSecAuthFailed:
            String(localized: "Couldn’t unlock passwords. Try again.")
        case AutofillVaultError.invalidData:
            String(localized: "Couldn’t read saved passwords. No passwords were changed.")
        case AutofillVaultError.privateBrowsing:
            String(localized: "Saved passwords are unavailable in Private Browsing.")
        case AutofillVaultError.keychain:
            String(localized: "Couldn’t access passwords. Try again.")
        case LegacyPasswordMigration.Failure.changed:
            String(localized: "Credential Manager changed. Review the old list again.")
        case LegacyPasswordMigration.Failure.notImported:
            String(localized: "Review the old list before removing it.")
        default:
            message(for: error)
        }
    }
}
