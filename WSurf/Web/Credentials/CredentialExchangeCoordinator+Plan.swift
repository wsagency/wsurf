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
        func accepts(_ account: CredentialAccount) -> Bool {
            guard CredentialExchangeCodec.canMerge(source, into: account) else { return false }
            switch incoming {
            case .password:
                return !hasLogin(account)
            case .passkey:
                return !credentialIDIsStored(incoming, in: preview)
            case .totp:
                return account.totp == nil
            case .note:
                // Notes are appended to what the account already holds.
                return true
            }
        }
        return preview.base.accounts.filter(accepts).map { account in
            CredentialImportReview.Target(
                accountID: account.id,
                title: CredentialSummary(account).title,
                allowedOrigins: account.origins
            )
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

    static func plan(
        _ preview: CredentialImportPreview,
        choices: [CredentialIdentity: CredentialImportChoice],
        required: Set<CredentialIdentity>
    ) throws -> (touched: [CredentialAccount], outcome: CredentialImportOutcome) {
        guard let decisions = decisions(preview, choices, required: required) else {
            throw CredentialExchangeCoordinatorError.unresolvedConflicts
        }
        var replaced = Set<CredentialIdentity>()
        for case let .replace(_, target) in decisions where !replaced.insert(target).inserted {
            throw CredentialVaultError.invalidData
        }
        let accounts = try CredentialExchangeCodec.apply(preview, decisions: decisions)
        let before = Dictionary(preview.base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var touched: [CredentialAccount] = []
        var added = 0
        var updated = 0
        for account in accounts {
            if let old = before[account.id] {
                if old != account {
                    updated += 1
                    touched.append(account)
                }
            } else {
                added += 1
                touched.append(account)
            }
        }
        return (touched, CredentialImportOutcome(added: added, updated: updated))
    }
}
