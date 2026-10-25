// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WSurfVault

/// A merge as the sheet shows it: what it would do, bound to the revision and authorization it was read at. It holds ids, the
/// picks and a preview without secrets, so a lock or a change to the vault makes it stale and the confirmation refuses it.
nonisolated struct CredentialMergeProposal: Equatable, Sendable {
    let ids: [UUID]
    let picks: MergePicks
    let preview: MergePreview
    let revision: UInt64
    let epoch: UInt64
}

/// What merging every identical group did.
nonisolated struct CredentialMergeAllResult: Equatable, Sendable {
    /// Groups merged into one credential each.
    let merged: Int
    /// Credentials that went to the Trash.
    let absorbed: Int
    /// Groups left as they were because merging them would exceed a limit.
    let skipped: Int
}

extension CredentialMergeError {
    /// What the sheet says. A fixed sentence: no title, username or website.
    var text: String {
        switch self {
        case .fewerThanTwo:
            String(localized: "Choose at least two credentials to merge.")
        case .usernamesDiffer:
            String(localized: "Credentials with different usernames can’t be merged.")
        case .invalidPicks:
            String(localized: "That choice isn’t available. Change it and try again.")
        case .websiteLimit:
            String(localized: "The merged credential would have more than \(CredentialAccount.websiteLimit) websites. Remove some websites first.")
        case .noteLimit:
            String(localized: "The merged credential would have more than \(CredentialAccount.noteLimit) notes. Remove some notes first.")
        case .itemLimit:
            String(localized: "The merged credential would have more than \(SecureItem.itemLimit) cards and other items. Remove some first.")
        case .linkLimit:
            String(localized: "Too many credentials were already merged into one of these. Keep a different credential instead.")
        case .fileLimit:
            String(localized: "The merged credential would have more than \(CredentialAttachment.entryLimit) files. Remove some files first.")
        }
    }
}

extension CredentialSettingsModel {
    /// What the page says for an error of a merge: the rule it broke, else the vault's own wording.
    static func mergeMessage(for error: any Error) -> String? {
        (error as? CredentialMergeError)?.text ?? message(for: error)
    }

    /// Every suggestion for the vault as it is now. Computed off the main actor; nothing secret is returned.
    func mergeSuggestions() async throws -> CredentialMergeIndex {
        let (epoch, snapshot) = try await authorizedSnapshot()
        let index = await Task.detached(priority: .userInitiated) {
            CredentialMergeSuggestions.index(for: snapshot.accounts, revision: snapshot.revision)
        }.value
        try Task.checkCancellation()
        guard authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        return index
    }

    /// Reads `ids` and what merging them would do under `picks`. Nothing is written, and the proposal holds no secret. Throws
    /// `CredentialMergeError` for what the rules refuse. Without `picks` it starts from the default picks for `survivor` (the
    /// primary) with every website of the others ticked, so nothing is left out unless the user unticks it.
    func mergeProposal(ids: [UUID], survivor: UUID? = nil, picks: MergePicks? = nil) async throws -> CredentialMergeProposal {
        let (epoch, snapshot) = try await authorizedSnapshot()
        let accounts = try Self.accounts(ids, in: snapshot.accounts)
        guard var chosen = picks ?? CredentialMerge.defaultPicks(for: accounts, survivor: survivor) else {
            throw CredentialMergeError.fewerThanTwo
        }
        var preview = try CredentialMerge.preview(accounts, picks: chosen)
        // Ticked only while the merged credential stays within its limits; past one, the boxes start unticked.
        if picks == nil, !preview.otherSite.isEmpty {
            var ticked = chosen
            ticked.extraWebsites = Set(preview.otherSite)
            if let wider = try? CredentialMerge.preview(accounts, picks: ticked) {
                (chosen, preview) = (ticked, wider)
            }
        }
        return CredentialMergeProposal(ids: ids, picks: chosen, preview: preview, revision: snapshot.revision, epoch: epoch)
    }

    /// Merges what the proposal shows, in one commit: the survivor is replaced by the merged credential and the others leave the
    /// vault, which moves each to the Trash with its history. A vault that changed since the proposal was read, or a lock, writes nothing.
    @discardableResult
    func confirmMerge(_ proposal: CredentialMergeProposal) async throws -> VaultCommitReceipt {
        let (epoch, snapshot) = try await authorizedSnapshot(epoch: proposal.epoch)
        guard snapshot.revision == proposal.revision else { throw CredentialVaultError.staleRevision }
        let accounts = try Self.accounts(proposal.ids, in: snapshot.accounts)
        let merged = try CredentialMerge.merged(accounts, picks: proposal.picks)
        let absorbed = Set(proposal.ids).subtracting([merged.id])
        let result = snapshot.accounts.compactMap { $0.id == merged.id ? merged : (absorbed.contains($0.id) ? nil : $0) }
        let survivor = accounts.filter { $0.id == merged.id }
        let merging = Dictionary(uniqueKeysWithValues: absorbed.map { ($0, merged.id) })
        return try await commitMerge(
            result, revision: proposal.revision, epoch: epoch, survivors: survivor, merging: merging, starting: snapshot.stamps
        ) {
            "Merged \(proposal.ids.count) credentials."
        }
    }

    /// Merges every group the vault finds identical, in one commit, with each group's default picks. A group that can't be merged
    /// without exceeding a limit is left as it is. It adds no website on another site: an identical group's members are all on the same
    /// sites, and a website on another site is only ever added by a tick.
    func mergeAllIdentical(revision: UInt64, epoch bound: UInt64? = nil) async throws -> CredentialMergeAllResult {
        let (epoch, snapshot) = try await authorizedSnapshot(epoch: bound)
        guard snapshot.revision == revision else { throw CredentialVaultError.staleRevision }
        let groups = await Task.detached(priority: .userInitiated) {
            CredentialMergeSuggestions.index(for: snapshot.accounts, revision: snapshot.revision).identical
        }.value
        var position: [UUID: Int] = [:]
        for (offset, account) in snapshot.accounts.enumerated() {
            position[account.id] = offset
        }
        var replaced: [Int: CredentialAccount] = [:]
        var removed = Set<Int>()
        var merging: [UUID: UUID] = [:]
        var skipped = 0
        for group in groups {
            let chosen = group.ids.compactMap { position[$0].map { snapshot.accounts[$0] } }
            // A group whose merge breaks a rule or a limit (a count, or one credential's bytes) is left as it is, not the whole commit.
            guard chosen.count == group.ids.count, let picks = CredentialMerge.defaultPicks(for: chosen),
                  let merged = try? CredentialMerge.merged(chosen, picks: picks),
                  (try? ProfileVaultStore.validate([merged], blockedOrigins: [])) != nil else {
                skipped += 1
                continue
            }
            for id in group.ids {
                guard let at = position[id] else { continue }
                if id == merged.id {
                    replaced[at] = merged
                } else {
                    removed.insert(at)
                    merging[id] = merged.id
                }
            }
        }
        guard !replaced.isEmpty else { return CredentialMergeAllResult(merged: 0, absorbed: 0, skipped: skipped) }
        let result = snapshot.accounts.enumerated().compactMap { offset, account in removed.contains(offset) ? nil : replaced[offset] ?? account }
        let survivors = replaced.keys.sorted().map { snapshot.accounts[$0] }
        _ = try await commitMerge(result, revision: revision, epoch: epoch, survivors: survivors, merging: merging, starting: snapshot.stamps) {
            "Merged \(replaced.count) groups of identical credentials."
        }
        return CredentialMergeAllResult(merged: replaced.count, absorbed: removed.count, skipped: skipped)
    }

    /// Remembers that `ids` are not one credential (Not the Same on a suggestion), so no suggestion puts any two of them together again.
    /// Each keeps the others' ids in its sealed row (`CredentialAccount.notSameAs`), so the choice syncs with the entries and outlives
    /// edits, a trip to the Trash and a merge. One per-account write bound to the stamps it read, one Undo step, nothing in History.
    func markNotTheSame(_ ids: [UUID]) async throws {
        try await rememberApart(ids, kind: .notTheSame) { held, group in held.union(group) }
    }

    /// Forgets every Not the Same between `ids`, a group the sheet lists as dismissed, so they can be suggested again. An id of a
    /// credential since merged into one of them counts as that one.
    func suggestAgain(_ ids: [UUID]) async throws {
        try await rememberApart(ids, kind: .suggestAgain) { held, group in held.subtracting(group) }
    }

    private func rememberApart(
        _ ids: [UUID], kind: CredentialUndoStep.Kind, _ change: (_ held: Set<UUID>, _ group: Set<UUID>) -> Set<UUID>
    ) async throws {
        let group = Set(ids)
        guard group.count == ids.count, group.count > 1 else { throw CredentialVaultError.invalidData }
        let (epoch, snapshot) = try await authorizedSnapshot()
        let survivors = CredentialMergeSuggestions.survivors(in: snapshot.accounts)
        var before: [CredentialAccount] = []
        var writes: [AccountWrite] = []
        var starting: [UUID: AccountStamp] = [:]
        for account in try Self.accounts(ids, in: snapshot.accounts) {
            guard let stamp = snapshot.stamps[account.id] else { throw CredentialVaultError.invalidData }
            let held = (account.notSameAs ?? []).map { survivors[$0] ?? $0 }
            var next = change(Set(held), group)
            next.remove(account.id)
            var changed = account
            changed.notSameAs = next.isEmpty ? nil : next.sorted { $0.uuidString < $1.uuidString }
            guard changed.notSameAs != account.notSameAs else { continue }
            before.append(account)
            writes.append(AccountWrite(accountID: account.id, expected: .stamp(stamp), replacement: changed))
            starting[account.id] = stamp
        }
        guard !writes.isEmpty else { return }
        guard let manager, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        // Last point before the durable write: a cancelled task or a changed authorization never commits.
        try Task.checkCancellation()
        let receipt = try await manager.commitAccounts(writes, authorizedEpoch: epoch)
        _ = try? await reloadAfterWrite(epoch: epoch)
        let recorded = recordUndo(receipt: receipt, epoch: epoch) { session in
            var replaced: [CredentialReplaced] = []
            for account in before {
                guard let stamp = session.stamps[account.id] else { return nil }
                replaced.append(CredentialReplaced(before: account, after: stamp))
            }
            return CredentialUndoStep(kind: kind, accounts: replaced, starting: starting)
        }
        showNotice(kind == .notTheSame ? "These won’t be suggested for merging again." : "These can be suggested for merging again.", undo: recorded)
    }

    /// Writes the merged accounts and keeps a step that takes the merge back: `survivors` as they were, and the absorbed accounts
    /// (`merging`, each mapped to its survivor, whose History keeps their passwords and codes), which went to Trash.
    private func commitMerge(
        _ accounts: [CredentialAccount], revision: UInt64, epoch: UInt64, survivors: [CredentialAccount], merging: [UUID: UUID],
        starting: [UUID: AccountStamp], notice: () -> LocalizedStringResource
    ) async throws -> VaultCommitReceipt {
        guard let manager, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        // Last point before the durable write: a cancelled task or a changed authorization never commits.
        try Task.checkCancellation()
        let absorbed = merging.keys.sorted { $0.uuidString < $1.uuidString }
        let touched = Set(survivors.map(\.id)).union(absorbed)
        let receipt = try await manager.commit(
            accounts, expectedRevision: revision, authorizedEpoch: epoch, cause: "merge", changing: touched, merging: merging
        )
        // Nothing throws once the vault has committed: the receipt reflects what is on disk.
        try? update(epoch) { $0.committed(accounts, revision: receipt.revision) }
        _ = try? await reloadAfterWrite(epoch: epoch)
        recordMerge(
            survivors, absorbed: absorbed, starting: starting.filter { touched.contains($0.key) }, receipt: receipt, epoch: epoch,
            notice: notice()
        )
        return receipt
    }

    private static func accounts(_ ids: [UUID], in all: [CredentialAccount]) throws -> [CredentialAccount] {
        guard Set(ids).count == ids.count else { throw CredentialVaultError.invalidData }
        let wanted = Set(ids)
        let found = all.filter { wanted.contains($0.id) }
        guard found.count == ids.count else { throw CredentialVaultError.invalidData }
        // The order given, so the first is the first the sheet lists.
        return ids.compactMap { id in found.first { $0.id == id } }
    }
}
