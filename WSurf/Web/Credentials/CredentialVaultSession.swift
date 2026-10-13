// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Everything the settings page holds about one unlocked vault, secrets included, tied to one manager authorization epoch.
/// The model keeps the only instance and drops it the moment that epoch ends.
struct CredentialVaultSession {
    let epoch: UInt64
    var revision: UInt64
    /// The accounts' stamps as of `stampsRevision`; an export binds its selection to them.
    var stamps: [UUID: AccountStamp]
    var stampsRevision: UInt64
    var summaries: [CredentialSummary]
    var revealedPassword: RevealedPassword?
    var revealedUsername: RevealedUsername?
    var shownTOTP: (accountID: UUID, generator: TOTPGenerator)?
    var draft: CredentialDraft?
    var pendingRemoval: PendingRemoval?
    var pendingUnlockRemoval: PendingUnlockRemoval?
    /// Verified counts of the vault and its Trash, as of the last Trash load.
    var counts: (live: HistoryCounts, trash: HistoryCounts)?
    var trash: [TrashItem] = []
    /// The cursor of the next Trash page; only meaningful inside this session.
    var trashNext: Int?
    var restoreBlocked: RestoreBlocked?
    var pendingPurge: PendingPurge?
    var revisions: [RevisionItem] = []
    var revisionNext: Int?
    var versionsAccountID: UUID?

    init(epoch: UInt64, snapshot: StoreSnapshot) {
        self.epoch = epoch
        revision = snapshot.revision
        stamps = snapshot.stamps
        stampsRevision = snapshot.revision
        summaries = snapshot.accounts.map(CredentialSummary.init)
    }

    mutating func refresh(_ snapshot: StoreSnapshot) {
        if snapshot.revision != revision {
            revealedPassword = nil
            revealedUsername = nil
            shownTOTP = nil
        }
        revision = snapshot.revision
        stamps = snapshot.stamps
        stampsRevision = snapshot.revision
        summaries = snapshot.accounts.map(CredentialSummary.init)
    }
}
