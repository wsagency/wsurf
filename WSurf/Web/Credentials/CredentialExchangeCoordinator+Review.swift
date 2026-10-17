// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The review of a staged import: how it is built once, and how one decision updates only the item it belongs to. Nothing here
/// writes to the vault; `commitImport` does, from the choices kept in the session.
extension CredentialExchangeCoordinator {
    typealias Change = (incoming: CredentialIdentity, choice: CredentialImportChoice?)

    /// What the review needs from the staged preview, indexed once so that building it, and later changing one item of it, costs
    /// the size of that item and not the size of the transfer or the vault.
    struct ReviewIndex {
        let preview: CredentialImportPreview
        let context: ReviewContext
        let existingByIncoming: [CredentialIdentity: CredentialIdentity]
        /// Where each incoming item sits in `preview.candidates`.
        let position: [UUID: Int]
        private let summaries: [CredentialSummary]
        private let storedTitles: [UUID: String]
        private let stored: [UUID: CredentialAccount]
        private let lookup: ReviewLookup
        /// The items a saved credential already holds an exact copy of (system imports only), by candidate.
        let duplicates: [UUID: CredentialImportReview.Duplicate]
        /// How each part relates to the vault: what classification says, except that a part of a duplicate that equals what is saved
        /// is unchanged.
        private let classes: [CredentialIdentity: CredentialImportClass]
        /// The parts that must be decided although nothing conflicts: the file rows that clash with others, and every part of a
        /// duplicate whose merge would be the default although it leaves websites out (`Duplicate.needsDecision`).
        let mustDecide: Set<CredentialIdentity>

        init(_ preview: CredentialImportPreview, _ context: ReviewContext) {
            self.preview = preview
            self.context = context
            let existing = Dictionary(preview.conflicts.map { ($0.incoming, $0.existing) }, uniquingKeysWith: { first, _ in first })
            existingByIncoming = existing
            position = Dictionary(preview.candidates.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            summaries = preview.candidates.map { CredentialSummary($0) }
            let accounts = Dictionary(preview.base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            stored = accounts
            let titles = accounts.mapValues { CredentialSummary($0).title }
            storedTitles = titles
            let linked = ReviewLookup(preview)
            lookup = linked
            // A file or the old list has its own rule for what is already saved; only a system import is compared here.
            let found = context.origin == .system
                ? ImportDuplicates.find(
                    candidates: preview.candidates, accounts: preview.base.accounts, classes: context.classes, existing: existing,
                    isLinked: { linked.linkedAccountID(for: $0) != nil }, title: { titles[$0] ?? "" }
                ) : ImportDuplicates.Found()
            duplicates = found.duplicates
            mustDecide = context.needsChoice.union(found.duplicates.values.filter(\.needsDecision).flatMap { $0.mergeChoices.keys })
            classes = context.classes.merging(found.unchanged.map { ($0, CredentialImportClass.unchanged) }, uniquingKeysWith: { _, new in new })
        }

        // MARK: Defaults

        /// The choice every record gets before the user decides anything (`CredentialImportDefaults`).
        func defaultChoices() -> [CredentialIdentity: CredentialImportChoice] {
            var choices: [CredentialIdentity: CredentialImportChoice] = [:]
            for candidate in preview.candidates {
                let identities = CredentialExchangeCoordinator.identities(in: candidate)
                if let duplicate = duplicates[candidate.id] {
                    // Merged into the saved credential that holds it: what that credential lacks is added, everything else is kept.
                    // Unless the item lists websites the merge leaves out: then nothing is decided for it.
                    if !duplicate.needsDecision {
                        choices.merge(duplicate.mergeChoices) { _, new in new }
                    }
                    continue
                }
                for incoming in identities {
                    let existing = existingByIncoming[incoming]
                    let choice = CredentialImportDefaults.choice(
                        for: classes[incoming] ?? .ambiguous,
                        isConflict: existing != nil,
                        removesStoredPasswordOnReplace: removesStoredPassword(incoming, of: candidate, existing: existing)
                    )
                    choices[incoming] = choice
                }
                // A note nobody decided follows its login, a Skip included. Keeping the saved login because it didn't change is not
                // a Skip: a note the saved credential doesn't hold yet still belongs in it.
                if let note = identities.first(where: { if case .note = $0 { true } else { false } }),
                   let lead = CredentialExchangeCodec.leadIdentity(of: candidate), choices[lead] == .skip,
                   choices[note] == nil, existingByIncoming[note] == nil, !mustDecide.contains(note),
                   CredentialImportDefaults.isAdditive(classes[note]) {
                    if let linked = lookup.linkedAccountID(for: candidate) {
                        choices[note] = .merge(into: linked)
                    } else {
                        // No saved credential holds this item, so there is nowhere for the note to go but with the login the user
                        // would be skipping: that one is the user's call, and nothing is dropped by default.
                        choices[lead] = nil
                    }
                }
            }
            return choices
        }

        /// Which incoming credential replaces which stored one under `choices`.
        func replacements(in choices: [CredentialIdentity: CredentialImportChoice]) -> [CredentialIdentity: CredentialIdentity] {
            var replaced: [CredentialIdentity: CredentialIdentity] = [:]
            for (incoming, choice) in choices where choice == .replace {
                if let target = existingByIncoming[incoming] {
                    replaced[target] = incoming
                }
            }
            return replaced
        }

        private func removesStoredPassword(_ incoming: CredentialIdentity, of candidate: CredentialAccount, existing: CredentialIdentity?) -> Bool {
            guard case .password = incoming, candidate.password == nil, let existing else { return false }
            return stored[CredentialExchangeCoordinator.accountID(existing)]?.password != nil
        }

        // MARK: Building

        func makeReview(choices: [CredentialIdentity: CredentialImportChoice]) -> CredentialImportReview {
            var tally = CredentialImportReview.Tally()
            var sections: [CredentialImportReview.Group: [Int]] = [:]
            var omissions: [UUID: [CredentialImportOmission]] = [:]
            var unattached: [CredentialImportOmission] = []
            for (at, omission) in preview.omitted.enumerated() {
                if at < preview.omittedItems.count, let item = preview.omittedItems[at], position[item] != nil {
                    omissions[item, default: []].append(omission)
                } else {
                    unattached.append(omission)
                }
            }
            let candidates = preview.candidates.indices.map { at in
                let candidate = preview.candidates[at]
                let itemRecords = records(at: at, choices: choices)
                let linked = lookup.linkedAccountID(for: candidate)
                let effect = self.effect(of: itemRecords, at: at)
                var group = CredentialImportDefaults.group(of: itemRecords)
                if let duplicate = duplicates[candidate.id], !duplicate.additions.isEmpty, group > .merge {
                    // What it adds to the saved credential is a decision worth a look, even though no part of it conflicts.
                    group = .merge
                }
                tally.add(effect)
                sections[group, default: []].append(at)
                return CredentialImportReview.Candidate(
                    summary: summaries[at],
                    needsManualAssociation: candidate.origins.isEmpty
                        && (CredentialExchangeCoordinator.hasLogin(candidate) || candidate.totp != nil),
                    records: itemRecords,
                    group: group,
                    searchKey: Self.searchKey(summaries[at]),
                    linkedAccountID: linked,
                    omissions: omissions[candidate.id] ?? [],
                    effect: effect,
                    action: nil,
                    duplicate: duplicates[candidate.id]
                )
            }
            var review = CredentialImportReview(
                profileName: context.profileName, vaultName: context.vaultName, candidates: candidates,
                revision: preview.revision, sections: sections, tally: tally,
                csvReport: context.csvReport, origin: context.origin, omitted: preview.omitted
            )
            review.unattachedOmissions = unattached
            return review
        }

        /// What the item does under `records`: its most active part. A duplicate decided as its merge adds what the saved credential
        /// lacks, or, when that is nothing, only links the two.
        func effect(of records: [CredentialImportReview.Record], at itemPosition: Int) -> CredentialImportReview.Effect {
            let candidate = preview.candidates[itemPosition]
            if let duplicate = duplicates[candidate.id], duplicate.isApplied(by: records) {
                return duplicate.additions.isEmpty ? .linked : .merge
            }
            return CredentialImportDefaults.effect(of: records, linkedTo: lookup.linkedAccountID(for: candidate))
        }

        /// Title, username (unless concealed) and websites, folded so a search ignores case and accents. No password, seed or note.
        private static func searchKey(_ summary: CredentialSummary) -> String {
            let hosts = summary.origins.compactMap { URL(string: $0)?.host }
            let text = ([summary.title] + [summary.username].compactMap { $0 } + hosts).joined(separator: "\n")
            return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }

        private static func kind(_ identity: CredentialIdentity) -> CredentialImportReview.Record.Kind {
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

        /// The records of the item at `at` under `choices`. Mirrors what `CredentialExchangeCodec.apply` does with each decision: a
        /// stored account keeps its own websites, and only a new account takes the exporter's.
        func records(at itemPosition: Int, choices: [CredentialIdentity: CredentialImportChoice]) -> [CredentialImportReview.Record] {
            let candidate = preview.candidates[itemPosition]
            let linked = lookup.linkedAccountID(for: candidate)
            // A duplicate decided as its merge takes some of the item's websites too (the saved credential's own stay first).
            let merging = duplicates[candidate.id]?.isApplied(by: choices) == true
            func into(_ id: UUID) -> CredentialImportReview.Record.Destination? {
                guard let account = stored[id] else { return nil }
                var left = candidate.origins.filter { !account.origins.contains($0) }
                var origins = account.origins
                // A duplicate decided as its merge takes the websites the merge names, and no others.
                if merging, let duplicate = duplicates[candidate.id], id == duplicate.target {
                    origins += duplicate.origins
                    left = left.filter { !duplicate.origins.contains($0) }
                }
                return .existing(accountID: id, title: storedTitles[id] ?? "", origins: origins, ignoredOrigins: left)
            }
            func destination(_ existing: CredentialIdentity?, _ choice: CredentialImportChoice?) -> CredentialImportReview.Record.Destination? {
                switch choice {
                case .skip:
                    return .skipped
                case .addSeparately:
                    return .newAccount(origins: candidate.origins)
                case let .merge(target):
                    return into(target)
                case .replace:
                    return existing.flatMap { into(CredentialExchangeCoordinator.accountID($0)) }
                case nil:
                    if existing != nil {
                        return nil
                    }
                    return linked.flatMap(into) ?? .newAccount(origins: candidate.origins)
                }
            }
            return CredentialExchangeCoordinator.identities(in: candidate).map { incoming in
                let existing = existingByIncoming[incoming]
                let choice = choices[incoming]
                // A note nobody decided goes where its item's lead credential goes (`CredentialExchangeCodec.apply`).
                var placement = (existing: existing, choice: choice)
                if case .note = incoming, existing == nil, choice == nil, !mustDecide.contains(incoming),
                   let lead = CredentialExchangeCodec.leadIdentity(of: candidate) {
                    placement = (existingByIncoming[lead], choices[lead])
                }
                let relyingParty: String?
                if case let .passkey(_, passkeyID) = incoming {
                    relyingParty = candidate.passkeys.first { $0.id == passkeyID }?.rpID
                } else {
                    relyingParty = nil
                }
                let needsChoice = existing != nil || mustDecide.contains(incoming)
                return CredentialImportReview.Record(
                    incoming: incoming,
                    existing: existing,
                    kind: Self.kind(incoming),
                    title: summaries[itemPosition].title,
                    existingTitle: existing.flatMap { storedTitles[CredentialExchangeCoordinator.accountID($0)] },
                    relyingParty: relyingParty,
                    destination: choice == nil && mustDecide.contains(incoming)
                        ? nil : destination(placement.existing, placement.choice),
                    canAddSeparately: !lookup.holdsStoredCredentialID(incoming),
                    removesStoredPasswordOnReplace: removesStoredPassword(incoming, of: candidate, existing: existing),
                    classification: classes[incoming] ?? .ambiguous,
                    needsChoice: needsChoice,
                    csvLine: context.csvLines[incoming],
                    choice: choice
                )
            }
        }

        /// The stored credential `target` for a merge, if `incoming` can go into it (the same rule as `targets(for:in:)`).
        func canMerge(_ incoming: CredentialIdentity, into target: UUID, canAddSeparately: Bool) -> Bool {
            guard let account = stored[target], let source = position[CredentialExchangeCoordinator.accountID(incoming)] else { return false }
            return CredentialExchangeCoordinator.accepts(
                incoming, source: preview.candidates[source], into: account, passkeyIDIsStored: !canAddSeparately
            )
        }
    }

    // MARK: Deciding

    /// Decides one incoming credential. A refused choice leaves the review as it was.
    func choose(_ choice: CredentialImportChoice, for incoming: CredentialIdentity, owner: UUID) throws {
        let current = try record(of: incoming, owner: owner)
        try validate(choice, for: current)
        if case .merge = choice {
            try validateCombination(of: incoming, choice)
        }
        session?.apply([(incoming, choice)], action: nil)
    }

    /// Decides every part of one item at once (see `CredentialImportReview.ItemAction`). Refused, and nothing changes, when the
    /// action doesn't apply to the item: it has nothing saved to keep or replace, or replacing would drop a saved password.
    func chooseItem(_ action: CredentialImportReview.ItemAction, for candidateID: UUID, owner: UUID) throws {
        let changes = try itemChanges(action, for: candidateID, owner: owner)
        session?.apply(changes, action: action)
    }

    /// Decides every item of `group` the action applies to, in one step. Items it doesn't apply to are left as they are. Returns how
    /// many items it was applied to.
    @discardableResult
    func chooseAll(_ action: CredentialImportReview.ItemAction, in group: CredentialImportReview.Group, owner: UUID) throws -> Int {
        let (changes, applied) = try groupChanges(action, in: group, owner: owner)
        guard applied > 0 else { return 0 }
        session?.apply(changes, action: action)
        return applied
    }

    /// The staged item `candidateID`, for a row that shows only itself.
    func importCandidate(withID candidateID: UUID, for manager: CredentialManager, owner: UUID) -> CredentialImportReview.Candidate? {
        guard let live, live.manager === manager, live.owner == owner,
              let at = live.index.position[candidateID] else { return nil }
        return live.review.candidates[at]
    }

    /// What Import would do now, for the success message: the plan the codec makes of the choices, as the commit makes it. This is
    /// the one step that costs the size of the whole import; a decision never calls it.
    func plannedOutcome(for manager: CredentialManager, owner: UUID) throws -> CredentialImportOutcome {
        guard let live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard live.manager === manager, live.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        guard live.review.isResolved else { throw CredentialExchangeCoordinatorError.unresolvedConflicts }
        do {
            return try Self.planned(live).outcome
        } catch CredentialVaultError.invalidData, CredentialVaultError.duplicateIdentifier {
            throw CredentialExchangeCoordinatorError.invalidChoice
        }
    }

    // MARK: Checks

    private func record(of incoming: CredentialIdentity, owner: UUID) throws -> CredentialImportReview.Record {
        guard let live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard live.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        guard let at = live.index.position[Self.accountID(incoming)],
              let record = live.review.candidates[at].records.first(where: { $0.incoming == incoming }) else {
            throw CredentialExchangeCoordinatorError.unknownConflict
        }
        return record
    }

    private func groupChanges(
        _ action: CredentialImportReview.ItemAction, in group: CredentialImportReview.Group, owner: UUID
    ) throws -> (changes: [Change], applied: Int) {
        guard let live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard live.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        var changes: [Change] = []
        var applied = 0
        // Replacements already claimed, including the ones this batch makes, so two items never replace one saved credential.
        var taken = live.replaced
        for at in live.review.sections[group] ?? [] {
            let item = live.review.candidates[at]
            guard let itemChanges = Self.changes(
                for: action, records: item.records, replaced: taken, linkedTo: item.linkedAccountID, duplicate: item.duplicate
            ) else { continue }
            for (incoming, choice) in itemChanges {
                guard let target = live.index.existingByIncoming[incoming] else { continue }
                if choice == .replace {
                    taken[target] = incoming
                } else if taken[target] == incoming {
                    taken[target] = nil
                }
            }
            changes += itemChanges
            applied += 1
        }
        return (changes, applied)
    }

    private func itemChanges(_ action: CredentialImportReview.ItemAction, for candidateID: UUID, owner: UUID) throws -> [Change] {
        guard let live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard live.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        guard let at = live.index.position[candidateID] else { throw CredentialExchangeCoordinatorError.unknownConflict }
        let item = live.review.candidates[at]
        guard let changes = Self.changes(
            for: action, records: item.records, replaced: live.replaced, linkedTo: item.linkedAccountID, duplicate: item.duplicate
        ) else {
            throw CredentialExchangeCoordinatorError.invalidChoice
        }
        return changes
    }

    /// The checks every choice passes before it is kept; each is a lookup, so a decision costs nothing like a pass over the import.
    private func validate(_ choice: CredentialImportChoice, for record: CredentialImportReview.Record) throws {
        guard let live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        // A passkey whose key conflicts with the stored one is only ever skipped.
        if record.classification == .passkeyHardConflict, choice != .skip {
            throw CredentialExchangeCoordinatorError.invalidChoice
        }
        switch choice {
        case .replace:
            // A passkey is never replaced: the vault keeps its credential ID unique, and a conflicting key is not ours to overwrite. An
            // incoming login without a password never replaces one that has a password (§13.3).
            guard record.isConflict, record.kind != .passkey, !record.removesStoredPasswordOnReplace, let target = record.existing else {
                throw CredentialExchangeCoordinatorError.invalidChoice
            }
            // One stored credential takes one replacement: a second Replace of the same one would silently overwrite the first.
            if let taker = live.replaced[target], taker != record.incoming {
                throw CredentialExchangeCoordinatorError.replaceTaken
            }
        case let .merge(target):
            guard live.index.canMerge(record.incoming, into: target, canAddSeparately: record.canAddSeparately) else {
                throw CredentialExchangeCoordinatorError.invalidChoice
            }
        case .addSeparately:
            guard record.canAddSeparately else { throw CredentialExchangeCoordinatorError.invalidChoice }
        case .skip:
            break
        }
    }

    /// A merge can make the import inconsistent in ways no single row shows (two items merged into one login, a name that clashes
    /// once the first has claimed the account). When every other decision is made, the plan proves the merge before it is kept; while
    /// something is still undecided it can't, and the plan is proven at Import, which refuses what doesn't fit and keeps the review.
    ///
    /// ponytail: this is the one decision that costs the size of the import, and only a merge to a named account pays it; slot claims
    /// per target account would make it a lookup, if merging at the 25,000-item scale turns out to be common.
    private func validateCombination(of incoming: CredentialIdentity, _ choice: CredentialImportChoice) throws {
        guard let live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        var trial = live.choices
        trial[incoming] = choice
        do {
            _ = try Self.plan(live.preview, choices: trial, required: live.index.mustDecide, duplicates: live.index.duplicates)
        } catch CredentialVaultError.invalidData, CredentialVaultError.duplicateIdentifier {
            throw CredentialExchangeCoordinatorError.invalidChoice
        } catch CredentialExchangeCoordinatorError.unresolvedConflicts {
            // Something else still needs a decision: the plan is proven when the last one is made, and again at Import.
        }
    }

    /// The choices that carry out `action` for an item with these records, or `nil` when it doesn't apply to the item (the same rule
    /// as `CredentialImportReview.availableActions`, plus a saved credential another incoming one already replaces).
    static func changes(
        for action: CredentialImportReview.ItemAction,
        records: [CredentialImportReview.Record],
        replaced: [CredentialIdentity: CredentialIdentity],
        linkedTo linked: UUID? = nil,
        duplicate: CredentialImportReview.Duplicate? = nil
    ) -> [Change]? {
        guard CredentialImportReview.availableActions(for: records, duplicate: duplicate).contains(action) else { return nil }
        let conflicts = records.filter(\.isConflict)
        func all(_ choice: CredentialImportChoice, of records: [CredentialImportReview.Record]) -> [Change] {
            records.map { ($0.incoming, choice) }
        }
        switch action {
        case .mergeIntoSaved:
            // Offered only for an item with a duplicate: what the saved credential lacks goes into it, the rest is kept.
            guard let duplicate else { return nil }
            return records.map { ($0.incoming, duplicate.mergeChoices[$0.incoming]) }
        case .skip:
            return all(.skip, of: records)
        case .keepSaved:
            // What the saved credential doesn't hold yet (a note) is not a conflict, and keeping the saved version doesn't leave it out.
            let additions: [Change] = linked.map { target in
                records.filter { $0.kind == .note && !$0.needsChoice && CredentialImportDefaults.isAdditive($0.classification) }
                    .map { record -> Change in (record.incoming, .merge(into: target)) }
            } ?? []
            return all(.skip, of: conflicts) + additions
        case .useIncoming:
            // A part that is the same, or that only changed here, keeps the saved version: the other app's copy of it is the old one.
            var changes: [Change] = []
            for record in conflicts {
                if record.kind == .passkey || CredentialImportReview.keepsSavedWhenUsingIncoming(record) {
                    changes.append((record.incoming, .skip))
                    continue
                }
                guard let target = record.existing, replaced[target] == nil || replaced[target] == record.incoming else { return nil }
                changes.append((record.incoming, .replace))
            }
            return changes
        case .keepBoth:
            return conflicts.map { record -> Change in
                let adds = record.classification != .unchanged && record.canAddSeparately
                return (record.incoming, adds ? CredentialImportChoice.addSeparately : .skip)
            }
        case .importNew:
            // A part that needs a choice is added next to what is saved; every other part goes back to where it goes by default.
            return records.map { record -> Change in
                guard record.needsChoice else { return (record.incoming, nil) }
                return (record.incoming, record.canAddSeparately ? CredentialImportChoice.addSeparately : .skip)
            }
        }
    }
}

extension CredentialExchangeCoordinator.Session {
    /// Applies `changes` (`nil` clears a choice) and rebuilds only the items they belong to. In place: the review of a large import is
    /// never copied for one decision.
    mutating func apply(_ changes: [CredentialExchangeCoordinator.Change], action: CredentialImportReview.ItemAction?) {
        var touched: [Int] = []
        var seen = Set<Int>()
        for (incoming, choice) in changes {
            if let target = index.existingByIncoming[incoming] {
                if replaced[target] == incoming {
                    replaced[target] = nil
                }
                if choice == .replace {
                    replaced[target] = incoming
                }
            }
            choices[incoming] = choice
            if let at = index.position[CredentialExchangeCoordinator.accountID(incoming)], seen.insert(at).inserted {
                touched.append(at)
            }
        }
        for at in touched {
            let records = index.records(at: at, choices: choices)
            let effect = index.effect(of: records, at: at)
            review.tally.add(review.candidates[at].effect, -1)
            review.tally.add(effect)
            review.candidates[at].records = records
            review.candidates[at].effect = effect
            review.candidates[at].action = action
        }
    }
}
