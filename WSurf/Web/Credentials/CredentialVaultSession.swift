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
    /// How many websites the user excluded from save suggestions ("Never for This Site"), as of `revision`. Only the count: the
    /// sites themselves are not shown.
    var blockedSiteCount: Int
    var revealedPassword: RevealedPassword?
    var revealedUsername: RevealedUsername?
    var shownTOTP: (accountID: UUID, generator: TOTPGenerator)?
    var draft: CredentialDraft? {
        // History belongs to the draft it was read for: closing the editor, or opening another draft, drops it with its secrets.
        didSet {
            if history?.accountID != draft?.accountID || history?.revision != draft?.revision {
                history = nil
            }
        }
    }
    /// The open credential's earlier values and versions (secrets included), masked until shown; see `HistoryState`.
    var history: HistoryState?
    var pendingUnlockRemoval: PendingUnlockRemoval?
    /// Verified counts of the vault and its Trash, as of the last Trash load.
    var counts: (live: HistoryCounts, trash: HistoryCounts)?
    var trash: [TrashItem] = []
    /// The cursor of the next Trash page; only meaningful inside this session.
    var trashNext: Int?
    var restoreBlocked: RestoreBlocked?
    var pendingPurge: PendingPurge?
    /// Trash entries the user pressed X on: hidden, counted out, and deleted only when the Trash is left (one assertion for the batch).
    /// Session state, so a lock, a quit or a closed page deletes nothing.
    var markedForDeletion: [UUID] = []
    /// The page's last actions that Undo can take back, oldest first; secrets included, so they go with the session.
    var undoSteps: [CredentialUndoStep] = []
    /// The actions Undo took back, newest last, that Redo can repeat. A new action ends them.
    var redoSteps: [CredentialUndoStep] = []
    /// The most actions Undo keeps; the oldest is dropped for a sixth.
    static let undoDepth = 5

    init(epoch: UInt64, snapshot: StoreSnapshot) {
        self.epoch = epoch
        revision = snapshot.revision
        stamps = snapshot.stamps
        stampsRevision = snapshot.revision
        summaries = snapshot.accounts.map(CredentialSummary.init)
        blockedSiteCount = snapshot.blockedPasswordOrigins.count
    }

    /// Ends the marks on `ids` (all of them for `nil`) and the steps that held them.
    mutating func dropMarks(_ ids: Set<UUID>?) {
        guard let ids else {
            markedForDeletion = []
            undoSteps.removeAll { $0.kind == .markForDeletion }
            redoSteps.removeAll { $0.kind == .markForDeletion }
            return
        }
        markedForDeletion.removeAll { ids.contains($0) }
        undoSteps.removeAll { $0.kind == .markForDeletion && !ids.isDisjoint(with: $0.marked) }
        redoSteps.removeAll { $0.kind == .markForDeletion && !ids.isDisjoint(with: $0.marked) }
    }

    /// A new action of the page: it can be undone, and what was undone before it can no longer be redone.
    mutating func record(_ step: CredentialUndoStep) {
        redoSteps = []
        push(step, onto: .undo)
    }

    private mutating func push(_ step: CredentialUndoStep, onto direction: CredentialReplay) {
        switch direction {
        case .undo:
            undoSteps.append(step)
            if undoSteps.count > Self.undoDepth {
                undoSteps.removeFirst(undoSteps.count - Self.undoDepth)
            }
        case .redo:
            redoSteps.append(step)
        }
    }

    /// The newest step has been replayed. Its inverse goes onto the other stack (`nil` when it cannot be made, and the action is
    /// then gone from both). Every older step expects the accounts the replay rewrote under their new stamps.
    mutating func completed(_ direction: CredentialReplay, inverse: CredentialUndoStep?, touching ids: Set<UUID>) {
        switch direction {
        case .undo:
            undoSteps.removeLast()
        case .redo:
            redoSteps.removeLast()
        }
        if let inverse {
            push(inverse, onto: direction == .undo ? .redo : .undo)
        }
        undoSteps = undoSteps.map { $0.rebound(ids, to: stamps) }
        redoSteps = redoSteps.map { $0.rebound(ids, to: stamps) }
    }

    /// Drops the newest step of a stack because it can no longer be replayed.
    mutating func discardNewest(_ direction: CredentialReplay) {
        switch direction {
        case .undo:
            undoSteps.removeLast()
        case .redo:
            redoSteps.removeLast()
        }
    }

    /// Replays a mark for deletion: Undo shows its entries again, Redo hides them again. No vault write is involved.
    mutating func replayMark(_ step: CredentialUndoStep, _ direction: CredentialReplay) {
        switch direction {
        case .undo:
            markedForDeletion.removeAll { step.marked.contains($0) }
            undoSteps.removeLast()
            redoSteps.append(step)
        case .redo:
            let listed = Set(trash.map(\.id)).subtracting(markedForDeletion)
            var again = step
            again.marked = step.marked.filter { listed.contains($0) }
            markedForDeletion += again.marked
            redoSteps.removeLast()
            push(again, onto: .undo)
        }
    }

    /// The stamps only while they describe the revision shown; after this page's own write they are unknown, not stale.
    var knownStamps: [UUID: AccountStamp]? {
        stampsRevision == revision ? stamps : nil
    }

    mutating func hideSecrets() {
        revealedPassword = nil
        revealedUsername = nil
        shownTOTP = nil
        history?.revealsSecrets = false
    }

    mutating func refresh(_ snapshot: StoreSnapshot) {
        if snapshot.revision != revision {
            hideSecrets()
        }
        revision = snapshot.revision
        stamps = snapshot.stamps
        stampsRevision = snapshot.revision
        summaries = snapshot.accounts.map(CredentialSummary.init)
        blockedSiteCount = snapshot.blockedPasswordOrigins.count
    }

    /// After a write this page made: the accounts as written, and no secret still shown. The stamps stay as they were read.
    mutating func committed(_ accounts: [CredentialAccount], revision: UInt64) {
        self.revision = revision
        summaries = accounts.map(CredentialSummary.init)
        hideSecrets()
    }
}
