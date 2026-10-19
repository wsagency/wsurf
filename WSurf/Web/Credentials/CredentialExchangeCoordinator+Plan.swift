// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What an import does with the choices made in its review: which stored accounts a credential can join, which choices the
/// codec is given, and which accounts the commit writes. Pure functions of the staged preview, no state.
extension CredentialExchangeCoordinator {
    // The codec treats an account as holding a login when any of these is present, so a username-only
    // record counts. Mirrors its rule so records, warnings and merge targets agree with what it will do.
    static func hasLogin(_ account: CredentialAccount) -> Bool {
        account.password != nil || account.basicAuthenticationMetadata != nil || !account.username.isEmpty
    }

    static func identities(in account: CredentialAccount) -> [CredentialIdentity] {
        CredentialExchangeCodec.identities(in: account)
    }

    nonisolated static func accountID(_ identity: CredentialIdentity) -> UUID {
        switch identity {
        case let .password(id), let .totp(id), let .note(id):
            id
        case let .passkey(id, _):
            id
        }
    }

    static func targets(
        for incoming: CredentialIdentity,
        in preview: CredentialImportPreview
    ) -> [CredentialImportReview.Target] {
        guard let source = preview.candidates.first(where: { $0.id == accountID(incoming) }) else { return [] }
        let passkeyIDIsStored = credentialIDIsStored(incoming, in: preview)
        return preview.base.accounts
            .filter { accepts(incoming, source: source, into: $0, passkeyIDIsStored: passkeyIDIsStored) }
            .map { account in
                CredentialImportReview.Target(
                    accountID: account.id,
                    title: CredentialSummary(account).title,
                    allowedOrigins: account.origins
                )
            }
    }

    /// Whether `incoming`, a credential of `source`, can be merged into the stored `account`: the account doesn't already hold that
    /// kind of credential, and nothing of the exporter's item would be lost.
    static func accepts(
        _ incoming: CredentialIdentity, source: CredentialAccount, into account: CredentialAccount, passkeyIDIsStored: Bool
    ) -> Bool {
        guard CredentialExchangeCodec.canMerge(source, into: account) else { return false }
        switch incoming {
        case .password:
            return !hasLogin(account)
        case .passkey:
            return !passkeyIDIsStored
        case .totp:
            return account.totp == nil
        case .note:
            // Notes are appended to what the account already holds.
            return true
        }
    }

    /// Whether `incoming` is a passkey whose credential ID is already held by a stored passkey.
    static func credentialIDIsStored(_ incoming: CredentialIdentity, in preview: CredentialImportPreview) -> Bool {
        guard case let .passkey(accountID, passkeyID) = incoming,
              let value = preview.candidates.first(where: { $0.id == accountID })?.passkeys.first(where: { $0.id == passkeyID })
        else { return false }
        return preview.base.accounts.contains { $0.passkeys.contains { $0.credentialID == value.credentialID } }
    }

    /// Whether another incoming credential is already set to replace the stored credential `target`.
    static func isReplaced(
        _ target: CredentialIdentity,
        besides incoming: CredentialIdentity,
        in preview: CredentialImportPreview,
        choices: [CredentialIdentity: CredentialImportChoice]
    ) -> Bool {
        preview.conflicts.contains { $0.existing == target && $0.incoming != incoming && choices[$0.incoming] == .replace }
    }

    /// The decisions to hand the codec, or `nil` while a conflict or a `required` record is undecided. Choices on records
    /// that are not conflicts go to the codec as they are: it accepts an explicit decision for any incoming credential.
    static func decisions(
        _ preview: CredentialImportPreview,
        _ choices: [CredentialIdentity: CredentialImportChoice],
        required: Set<CredentialIdentity>
    ) -> [CredentialImportDecision]? {
        let existing = Dictionary(preview.conflicts.map { ($0.incoming, $0.existing) }, uniquingKeysWith: { first, _ in first })
        guard existing.keys.allSatisfy({ choices[$0] != nil }), required.allSatisfy({ choices[$0] != nil }) else { return nil }
        var result: [CredentialImportDecision] = []
        for (incoming, choice) in choices {
            switch choice {
            case .skip:
                result.append(.keep(incoming: incoming))
            case .replace:
                guard let target = existing[incoming] else { return nil }
                result.append(.replace(incoming: incoming, target: target))
            case .addSeparately:
                result.append(.add(incoming: incoming, targetAccountID: nil))
            case let .merge(target):
                result.append(.add(incoming: incoming, targetAccountID: target))
            }
        }
        return result
    }

    /// The items that are decided exactly as their merge into the saved credential they duplicate (`ImportDuplicates`), by candidate.
    static func duplicateMerges(
        _ choices: [CredentialIdentity: CredentialImportChoice], _ duplicates: [UUID: CredentialImportReview.Duplicate]
    ) -> [UUID: CredentialExchangeCodec.DuplicateMerge] {
        var merges: [UUID: CredentialExchangeCodec.DuplicateMerge] = [:]
        for (candidate, duplicate) in duplicates where duplicate.isApplied(by: choices) {
            merges[candidate] = CredentialExchangeCodec.DuplicateMerge(target: duplicate.target, origins: duplicate.origins)
        }
        return merges
    }

    static func plan(
        _ preview: CredentialImportPreview,
        choices: [CredentialIdentity: CredentialImportChoice],
        required: Set<CredentialIdentity>,
        duplicates: [UUID: CredentialImportReview.Duplicate] = [:]
    ) throws -> (touched: [CredentialAccount], outcome: CredentialImportOutcome) {
        guard let decisions = decisions(preview, choices, required: required) else {
            throw CredentialExchangeCoordinatorError.unresolvedConflicts
        }
        var replaced = Set<CredentialIdentity>()
        for case let .replace(_, target) in decisions where !replaced.insert(target).inserted {
            throw CredentialVaultError.invalidData
        }
        let merges = duplicateMerges(choices, duplicates)
        let accounts = try CredentialExchangeCodec.apply(preview, decisions: decisions, duplicates: merges)
        let duplicated = Set(merges.values.map(\.target))
        let before = Dictionary(preview.base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var touched: [CredentialAccount] = []
        var added = 0
        var updated = 0
        for account in accounts {
            if let old = before[account.id] {
                // An account whose only difference is a base that apply recorded is not written: an import writes the accounts it
                // changes, however many items it compared, so a long review isn't discarded because an unrelated account changed.
                // A base is recorded for the accounts that are written anyway. (An item saved before bases were recorded stays
                // unbound until an import changes it; identical content is still recognised as unchanged.)
                let withoutBases = account.withBases(of: old)
                if withoutBases != old {
                    touched.append(account)
                    // A saved credential that only became the other app's item (its identity, its name if it had none, and the field
                    // descriptions of a login that reads the same) is written so the next import knows it, but its content is as it
                    // was: not an update.
                    var withoutLink = withoutBases
                    if duplicated.contains(account.id) {
                        withoutLink.exchangeAccountID = old.exchangeAccountID
                        withoutLink.exchangeItemID = old.exchangeItemID
                        withoutLink.exchangeMetadata = old.exchangeMetadata
                        withoutLink.basicAuthenticationMetadata = old.basicAuthenticationMetadata
                        withoutLink.displayName = old.displayName
                    }
                    if withoutLink != old {
                        updated += 1
                    }
                }
            } else {
                added += 1
                touched.append(account)
            }
        }
        return (touched, CredentialImportOutcome(added: added, updated: updated))
    }

    /// The plan the codec makes of the session's choices, with what became of every incoming credential. The one place a staged
    /// import is turned into writes, for the success message and for the commit alike.
    static func planned(_ session: Session) throws -> (touched: [CredentialAccount], outcome: CredentialImportOutcome) {
        var planned = try plan(
            session.preview, choices: session.choices, required: session.index.mustDecide, duplicates: session.index.duplicates
        )
        let changed = Set(planned.touched.map(\.id))
        planned.outcome.results = session.review.candidates.flatMap(\.records).map { record in
            let action: CredentialImportOutcome.Result.Action
            switch record.destination {
            case nil:
                action = .skipped
            case .skipped:
                // Keeping what is saved is not leaving a credential out.
                switch record.classification {
                case .unchanged, .localChanged:
                    action = .unchanged
                default:
                    action = .skipped
                }
            case .newAccount:
                action = .added
            case let .existing(accountID, _, _, _):
                action = record.classification != .unchanged && changed.contains(accountID) ? .updated : .unchanged
            }
            return CredentialImportOutcome.Result(
                id: record.incoming, kind: record.kind, title: record.title, relyingParty: record.relyingParty, action: action
            )
        }
        // An account is written or moved to Trash, never both: a merge into a saved credential the user also chose to remove doesn't fit.
        let trashed = removals(in: session)
        guard Set(planned.touched.map(\.id)).isDisjoint(with: trashed) else { throw CredentialVaultError.invalidData }
        planned.outcome.movedToTrash = trashed.count
        return planned
    }

    /// The saved credentials Import moves to Trash: the ones the user chose, and only after they said the transfer holds everything the
    /// other app has. Keep is what every one of them starts with.
    static func removals(in session: Session) -> [UUID] {
        guard session.review.transferIsComplete else { return [] }
        return session.review.missing.filter(\.movesToTrash).map(\.accountID)
    }
}
