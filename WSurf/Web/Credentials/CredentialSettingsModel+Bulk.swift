// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Actions on several credentials of the list at once.
extension CredentialSettingsModel {
    /// Moves credentials to the Trash with their history, in one write: either all of them go or, when one changed since the list
    /// showed it, none does (`staleRevision`). There is no confirmation; the Trash keeps everything, and the notice offers Undo.
    func moveToTrash(ids: [UUID]) async throws {
        guard let live else { throw CredentialVaultError.unauthorized }
        let stamps: [UUID: AccountStamp]
        if let known = live.knownStamps {
            stamps = known
        } else {
            stamps = try await authorizedSnapshot(epoch: live.epoch).snapshot.stamps
        }
        var removing: [UUID: AccountStamp] = [:]
        for id in ids {
            guard let stamp = stamps[id] else { throw CredentialVaultError.invalidData }
            removing[id] = stamp
        }
        guard !removing.isEmpty else { return }
        guard let manager, manager.authorizationEpoch == live.epoch else { throw CredentialVaultError.unauthorized }
        // Last point before the durable write: a cancelled task or a changed authorization never commits.
        try Task.checkCancellation()
        let receipt = try await manager.commitAccounts([], removing: removing, authorizedEpoch: live.epoch)
        try? await reloadAfterWrite(epoch: live.epoch)
        let recorded = recordUndo(receipt: receipt, epoch: live.epoch) { _ in
            CredentialUndoStep(kind: .moveToTrash, returning: removing.keys.map(RemovalScope.account))
        }
        let count = removing.count
        let text: LocalizedStringResource = count == 1 ? "Moved 1 credential to Trash." : "Moved \(count) credentials to Trash."
        showNotice(text, undo: recorded)
    }
}
