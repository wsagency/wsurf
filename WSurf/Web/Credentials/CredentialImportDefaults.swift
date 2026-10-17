// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What a review does for the user before they click anything, and where each item sits (spec §13.3). The one table: a record's
/// classification decides both its default choice and its group, so what the row says and what Import does cannot drift apart.
///
/// | classification                                     | default choice                          | group                 |
/// | -------------------------------------------------- | --------------------------------------- | --------------------- |
/// | bothChanged, noCommonBase, ambiguous               | none                                    | decide (conflicts)    |
/// | new                                                | none (imported, or into the linked one) | new                   |
/// | remoteChanged                                      | replace, unless it would drop a password | update               |
/// | unchanged, localChanged                            | skip (keep the saved one)               | saved                 |
/// | previouslyRemoved, passkeyHardConflict             | skip                                    | skipped               |
///
/// A record that still has no choice although it needs one (a conflict, or a CSV row that clashes) is always in `decide`.
nonisolated enum CredentialImportDefaults {
    /// The choice made for a record when the review is staged, or `nil` when the user decides it or it needs none.
    /// Only a conflict is ever given a choice for being `unchanged` or `localChanged`: a part the saved credential does not hold
    /// is not a conflict, and it is imported into the item's stored credential or as a new one, as it always was.
    static func choice(
        for classification: CredentialImportClass, isConflict: Bool, removesStoredPasswordOnReplace: Bool
    ) -> CredentialImportChoice? {
        switch classification {
        case .unchanged, .localChanged:
            isConflict ? .skip : nil
        case .remoteChanged:
            // Replacing must never drop a stored password (the codec refuses it), so that one is the user's call.
            isConflict && !removesStoredPasswordOnReplace ? .replace : nil
        case .previouslyRemoved, .passkeyHardConflict:
            .skip
        case .new, .bothChanged, .noCommonBase, .ambiguous:
            nil
        }
    }

    /// The group of one record under its current choice.
    static func group(
        for classification: CredentialImportClass, needsChoice: Bool, choice: CredentialImportChoice?
    ) -> CredentialImportReview.Group {
        if needsChoice, choice == nil {
            return .decide
        }
        switch classification {
        case .previouslyRemoved, .passkeyHardConflict:
            return .skipped
        case .unchanged, .localChanged:
            return .saved
        case .remoteChanged:
            return .update
        case .new, .ambiguous, .noCommonBase, .bothChanged:
            return .new
        }
    }

    /// The group of an item: the most urgent group among its parts. An item with no parts has nothing to do.
    static func group(of records: [CredentialImportReview.Record]) -> CredentialImportReview.Group {
        records.map { group(for: $0.classification, needsChoice: $0.needsChoice, choice: $0.choice) }.min() ?? .skipped
    }

    /// Whether a part the saved credential doesn't hold yet (or can't be compared with) is added to it when nothing says otherwise.
    static func isAdditive(_ classification: CredentialImportClass?) -> Bool {
        switch classification {
        case .new, .ambiguous:
            true
        default:
            false
        }
    }

    /// What an item does: its most active part. An undecided part makes the whole item undecided. `linked` is the saved credential
    /// that already holds the item: joining it is an update, and only joining another one is a merge.
    static func effect(of records: [CredentialImportReview.Record], linkedTo linked: UUID? = nil) -> CredentialImportReview.Effect {
        var result = CredentialImportReview.Effect.skipped
        var rank = 0
        for record in records {
            let (effect, weight) = effect(of: record, linkedTo: linked)
            if effect == .undecided {
                return .undecided
            }
            if weight > rank {
                (result, rank) = (effect, weight)
            }
        }
        return result
    }

    private static func effect(of record: CredentialImportReview.Record, linkedTo linked: UUID?) -> (CredentialImportReview.Effect, Int) {
        switch record.destination {
        case nil:
            return (.undecided, 5)
        case .skipped:
            // Keeping what is saved is not the same as leaving a credential out.
            switch record.classification {
            case .unchanged, .localChanged:
                return (.unchanged, 1)
            default:
                return (.skipped, 0)
            }
        case .newAccount:
            return (.new, 4)
        case let .existing(accountID, _, _, _):
            if case .merge? = record.choice, accountID != linked {
                return (.merge, 3)
            }
            return record.classification == .unchanged ? (.unchanged, 1) : (.update, 2)
        }
    }
}
