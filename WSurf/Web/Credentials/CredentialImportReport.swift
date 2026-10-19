// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated extension CredentialImportReview {
    /// One thing done to a saved credential in WSurf since the other app's copy of it was imported. It names a field and, when the
    /// vault keeps one, a date. It never holds a value.
    struct LocalChange: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case username, password
            /// The login differs, but not in its username or password (how the other app described its fields, say).
            case login
            case verificationCode
            case websitesOrName
            /// Notes saved here that the other app's copy does not have.
            case notesAdded(Int)
            case notesRemoved
            case merged
            case movedToTrash(Record.Kind)
            /// Removed from Trash for good: the vault keeps only that it was removed, and when.
            case purged(Record.Kind)
        }

        let kind: Kind
        /// When the vault says it happened: the date of the earlier version the change left, or of the move to Trash.
        let date: Date?
    }

    /// A saved credential whose changes made in WSurf the import keeps. `id` is the transfer's item.
    struct KeptChange: Identifiable, Equatable, Sendable {
        let id: UUID
        let title: String
        let changes: [LocalChange]
    }

    /// A saved credential that an earlier import brought and that the transfer no longer holds. Import keeps it unless the user
    /// chose to move it to Trash.
    struct Missing: Identifiable, Equatable, Sendable {
        let accountID: UUID
        let title: String
        var movesToTrash = false

        var id: UUID {
            accountID
        }
    }

    /// How many saved credentials Import moves to Trash.
    var trashCount: Int {
        missing.reduce(0) { $0 + ($1.movesToTrash ? 1 : 0) }
    }

    /// How many saved credentials Import writes or moves to Trash: nothing to do when it is zero.
    var pendingWrites: Int {
        tally.writes + trashCount
    }
}

/// What the import review tells about the vault beyond the transfer: what was changed in WSurf and is kept, and what the transfer no
/// longer holds. Pure functions of the staged vault; nothing is read that the import does not read, and nothing is written.
nonisolated enum CredentialImportReport {
    /// The changes made in WSurf that this import leaves alone, by item of the transfer. The evidence is what the vault records without
    /// values: a part whose content differs from the base the last import recorded while the other app's copy equals it, the earlier
    /// versions (`revisions`) and their cause, what the saved credential holds that the transfer does not, and what went to Trash.
    ///
    /// An earlier version made by an import (`cause` "import") or a merge ("merge") is not an edit. A version written before the cause
    /// was recorded has none, so it counts as an edit here. ponytail: for such a credential an earlier import's refresh of websites or
    /// name can show as a change, but only while its websites or name also differ from the transfer's, which is required.
    static func keptChanges(
        candidates: [CredentialAccount],
        accounts: [CredentialAccount],
        classes: [CredentialIdentity: CredentialImportClass],
        revisions: [UUID: [RevisionItem]],
        removed: RemovedIdentifiers
    ) -> [CredentialImportReview.KeptChange] {
        let linkedIDs = CredentialExchangeCodec.linkedAccountIDs(in: accounts)
        let stored = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let trashedAt = Dictionary(
            removed.items.compactMap { row in row.removedAt.map { (row.entryID, $0) } }, uniquingKeysWith: { first, _ in first }
        )
        return candidates.compactMap { candidate in
            let saved = (try? CredentialExchangeCodec.externalItemID(for: candidate)).flatMap { linkedIDs[$0] }.flatMap { stored[$0] }
            let found = localChanges(
                of: candidate, saved: saved, classes: classes, history: History(revisions[saved?.id ?? candidate.id] ?? []),
                trashedAt: trashedAt
            )
            guard !found.isEmpty else { return nil }
            return CredentialImportReview.KeptChange(id: candidate.id, title: CredentialSummary(saved ?? candidate).title, changes: found)
        }
    }

    /// The saved credentials an earlier import brought from an exporter account this transfer covers, whose item the transfer does not
    /// hold. A credential is present while the transfer holds any of its items: its own or one merged into it (`mergedFrom`). A
    /// credential of another exporter, one made in WSurf, and one that an exact duplicate in the transfer is the copy of
    /// (`duplicateTargets`) are never missing, so a transfer from another app lists nothing.
    static func missing(
        candidates: [CredentialAccount], accounts: [CredentialAccount], duplicateTargets: Set<UUID>
    ) -> [CredentialImportReview.Missing] {
        let sent = Set(candidates.compactMap { try? CredentialExchangeCodec.externalItemID(for: $0) })
        let exporters = Set(candidates.compactMap(\.exchangeAccountID))
        return accounts.compactMap { account in
            guard let exporter = account.exchangeAccountID, account.exchangeItemID != nil, exporters.contains(exporter),
                  !duplicateTargets.contains(account.id),
                  let key = try? CredentialExchangeCodec.externalItemID(for: account), !sent.contains(key),
                  !(account.mergedFrom ?? []).contains(where: { sent.contains($0.identity) }) else { return nil }
            return CredentialImportReview.Missing(accountID: account.id, title: CredentialSummary(account).title)
        }
    }

    // MARK: Changes of one item

    /// The dates of a saved credential's earlier versions that were not made by an import or a merge, by part, and its latest merge.
    private struct History {
        var latest: [RecordSubject: Date] = [:]
        var mergedAt: Date?

        init(_ revisions: [RevisionItem]) {
            for revision in revisions where revision.cause != CredentialChangeCause.import {
                if revision.cause == CredentialChangeCause.merge {
                    mergedAt = max(mergedAt ?? revision.recordedAt, revision.recordedAt)
                } else {
                    latest[revision.subject] = max(latest[revision.subject] ?? revision.recordedAt, revision.recordedAt)
                }
            }
        }
    }

    /// The changes of one item, each kind once.
    private struct Collector {
        var changes: [CredentialImportReview.LocalChange] = []

        mutating func add(_ kind: CredentialImportReview.LocalChange.Kind, _ date: Date?) {
            guard !changes.contains(where: { $0.kind == kind }) else { return }
            changes.append(CredentialImportReview.LocalChange(kind: kind, date: date))
        }
    }

    private static func localChanges(
        of candidate: CredentialAccount,
        saved: CredentialAccount?,
        classes: [CredentialIdentity: CredentialImportClass],
        history: History,
        trashedAt: [UUID: Date]
    ) -> [CredentialImportReview.LocalChange] {
        var found = Collector()
        let identities = CredentialExchangeCodec.identities(in: candidate)
        if let saved {
            for identity in identities where classes[identity] == .localChanged {
                switch identity {
                case .password:
                    for field in loginFields(candidate, saved) {
                        found.add(field, history.latest[.password])
                    }
                case .totp:
                    found.add(.verificationCode, history.latest[.totp])
                case .passkey, .note:
                    break
                }
            }
            keptParts(of: candidate, saved: saved, history: history, into: &found)
        }
        for identity in identities {
            if case let .previouslyRemoved(entryID, isTombstone)? = classes[identity] {
                found.add(isTombstone ? .purged(part(of: identity)) : .movedToTrash(part(of: identity)), trashedAt[entryID])
            }
        }
        return found.changes
    }

    /// What the saved credential holds that the transfer's copy does not, and that the import leaves as it is.
    private static func keptParts(of candidate: CredentialAccount, saved: CredentialAccount, history: History, into found: inout Collector) {
        if let date = history.latest[.metadata], websitesOrNameDiffer(saved, candidate) {
            found.add(.websitesOrName, date)
        }
        if candidate.notes == nil {
            if let notes = saved.notes {
                found.add(.notesAdded(notes.count), history.latest[.note])
            } else if let date = history.latest[.note] {
                found.add(.notesRemoved, date)
            }
        }
        if let date = history.mergedAt {
            found.add(.merged, date)
        }
    }

    /// Which fields of the login differ from the transfer's copy, which equals what the last import brought in.
    private static func loginFields(_ candidate: CredentialAccount, _ saved: CredentialAccount) -> [CredentialImportReview.LocalChange.Kind] {
        var fields: [CredentialImportReview.LocalChange.Kind] = []
        if !same(saved.username, candidate.username) {
            fields.append(.username)
        }
        if !same(saved.password, candidate.password) {
            fields.append(.password)
        }
        return fields.isEmpty ? [.login] : fields
    }

    private static func websitesOrNameDiffer(_ saved: CredentialAccount, _ candidate: CredentialAccount) -> Bool {
        Set(saved.origins) != Set(candidate.origins) || !same(saved.displayName ?? "", candidate.displayName ?? "")
    }

    private static func part(of identity: CredentialIdentity) -> CredentialImportReview.Record.Kind {
        switch identity {
        case .password:
            .password
        case .passkey:
            .passkey
        case .totp:
            .totp
        case .note:
            .note
        }
    }

    /// Exact UTF-8, as the vault compares: `String ==` would treat canonically equivalent spellings as one value.
    private static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.utf8.elementsEqual(rhs.utf8)
    }
}
