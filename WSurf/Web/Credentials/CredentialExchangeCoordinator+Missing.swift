// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The review's list of saved credentials the transfer no longer holds. Every one of them starts as Keep and nothing here writes: a
/// credential moves to Trash only when the user says the transfer holds everything the other app has, chooses it, and then imports.
extension CredentialExchangeCoordinator {
    /// Records the user's word on whether the transfer is whole; a transfer does not say. Taking it back keeps every credential.
    func declareTransferComplete(_ complete: Bool, owner: UUID) throws {
        _ = try stagedSession(owner: owner)
        session?.review.transferIsComplete = complete
        guard !complete, let missing = session?.review.missing else { return }
        for at in missing.indices where missing[at].movesToTrash {
            session?.review.missing[at].movesToTrash = false
        }
    }

    /// Keeps, or moves to Trash, the credentials in `accountIDs` (all of them when `nil`). Moving needs the transfer declared whole.
    func chooseMissing(moveToTrash: Bool, for accountIDs: Set<UUID>? = nil, owner: UUID) throws {
        let staged = try stagedSession(owner: owner)
        guard staged.review.transferIsComplete || !moveToTrash else { throw CredentialExchangeCoordinatorError.invalidChoice }
        if let accountIDs, !accountIDs.isSubset(of: Set(staged.review.missing.map(\.accountID))) {
            throw CredentialExchangeCoordinatorError.unknownConflict
        }
        for (at, entry) in staged.review.missing.enumerated() where accountIDs?.contains(entry.accountID) ?? true {
            session?.review.missing[at].movesToTrash = moveToTrash
        }
    }

    private func stagedSession(owner: UUID) throws -> Session {
        guard let live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard live.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        return live
    }
}
