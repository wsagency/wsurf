// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The import review's decisions, as the review sheet makes them. A refused one leaves the review as it was and says why.
extension CredentialSettingsModel {
    func chooseImport(_ choice: CredentialImportChoice, for incoming: CredentialIdentity) {
        settle { try exchange.choose(choice, for: incoming, owner: owner) }
    }

    /// Decides every part of one item at once.
    func chooseImportItem(_ action: CredentialImportReview.ItemAction, for candidateID: UUID) {
        settle { try exchange.chooseItem(action, for: candidateID, owner: owner) }
    }

    /// Decides every item of a group the action applies to. The others are left as they are.
    func chooseImportGroup(_ action: CredentialImportReview.ItemAction, in group: CredentialImportReview.Group) {
        settle { _ = try exchange.chooseAll(action, in: group, owner: owner) }
    }

    /// Stored accounts the credential can be merged into, each with every website it would then work on. A scan of the vault: call it
    /// when the user opens the list of targets, never for a row that is merely shown.
    func mergeTargets(for incoming: CredentialIdentity) -> [CredentialImportReview.Target] {
        exchange.mergeTargets(for: incoming, owner: owner)
    }

    /// One item of the review, for a row that shows only itself.
    func importCandidate(withID candidateID: UUID) -> CredentialImportReview.Candidate? {
        manager.flatMap { exchange.importCandidate(withID: candidateID, for: $0, owner: owner) }
    }

    /// What Import would do now, with what became of every credential; `nil` while something is undecided or the choices don't fit
    /// together. It plans the whole import, so it is asked for when Import is chosen, not while the user decides.
    func plannedImportOutcome() -> CredentialImportOutcome? {
        manager.flatMap { try? exchange.plannedOutcome(for: $0, owner: owner) }
    }

    /// Runs one decision. A refusal is shown on the page; a decision that is kept clears an earlier refusal.
    private func settle(_ decide: () throws -> Void) {
        do {
            try decide()
            error = nil
        } catch {
            self.error = importMessage(for: error, origin: currentImportOrigin())
        }
    }
}
