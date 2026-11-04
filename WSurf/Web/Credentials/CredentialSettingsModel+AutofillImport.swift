// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Cards from a Safari export, or contacts chosen in Contacts, reviewed before anything is written: the review shows titles only (a
/// card's network and last four digits, a contact's title). The values stay in memory until Import or Cancel.
struct AutofillImportPlan: Identifiable {
    let id = UUID()
    /// The unlock and the vault the review was made for; Import writes nothing under any other.
    let epoch: UInt64
    let vaultID: UUID
    let sources: AutofillVaultMigration.Sources
    let titles: [String]
    /// How many entries Import writes: the cards whose number and the contacts whose values the vault does not hold.
    let writes: Int
    /// Cards of the file that could not be read, left out.
    let skipped: Int
}

/// Imports of cards and contacts into the open vault. They write only to the vault, through its ordinary per-entry write: never to the
/// Keychain lists or the save index autofill used before the vault held cards and addresses.
extension CredentialSettingsModel {
    /// What importing `sources` would add to the open vault. Reads the vault only; `nil` (with the reason on the page) when it is locked.
    func planAutofillImport(_ sources: AutofillVaultMigration.Sources, skipped: Int = 0) async -> AutofillImportPlan? {
        var plan: AutofillImportPlan?
        _ = await perform { manager in
            let (epoch, snapshot) = try await self.authorizedSnapshot()
            plan = AutofillImportPlan(
                epoch: epoch, vaultID: manager.vaultID, sources: sources,
                titles: sources.cards.map(\.summary.label) + sources.contacts.map(\.title),
                writes: AutofillVaultMigration.entries(for: sources, in: snapshot.accounts).count, skipped: skipped
            )
        }
        return plan
    }

    /// Writes what the review showed, in one commit under the unlock it was made under, then keeps an Undo step that moves the new
    /// entries to Trash and says so. A vault that changed since the review (so the import would write something else) writes nothing.
    func commitAutofillImport(_ plan: AutofillImportPlan) async {
        guard plan.writes > 0 else { return }
        _ = await perform(epoch: plan.epoch) { manager in
            guard manager.vaultID == plan.vaultID else { throw CredentialVaultError.unauthorized }
            let snapshot = try await self.authorizedSnapshot(epoch: plan.epoch).snapshot
            let entries = AutofillVaultMigration.entries(for: plan.sources, in: snapshot.accounts)
            guard entries.count == plan.writes else { throw CredentialVaultError.staleRevision }
            try Task.checkCancellation()
            let receipt = try await manager.commitAccounts(
                entries.map { AccountWrite(accountID: $0.id, expected: .absent, replacement: $0) }, authorizedEpoch: plan.epoch,
                cause: CredentialChangeCause.import
            )
            _ = try? await self.reloadAfterWrite(epoch: plan.epoch)
            let ids = entries.map(\.id)
            let recorded = self.recordUndo(receipt: receipt, epoch: plan.epoch) { session in
                let stamps = ids.reduce(into: [UUID: AccountStamp]()) { $0[$1] = session.stamps[$1] }
                return stamps.count == ids.count ? CredentialUndoStep(kind: .add, removing: stamps) : nil
            }
            let text: LocalizedStringResource = ids.count == 1 ? "Added 1 entry to the vault." : "Added \(ids.count) entries to the vault."
            self.showNotice(text, undo: recorded)
        }
    }

    /// A Safari export (its ZIP or its PaymentCards.json) as import sources. Card numbers stay in memory only.
    nonisolated static func safariCards(from file: URL) async throws -> (sources: AutofillVaultMigration.Sources, skipped: Int) {
        let result = try await Task.detached { try SafariCardImport.read(file) }.value
        return (AutofillVaultMigration.Sources(cards: result.cards, contacts: []), result.skipped)
    }
}
