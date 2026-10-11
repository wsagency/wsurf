// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated extension CredentialExchangeCodec {
    /// Applies `decisions` to `preview`. A decision may name any identity the preview's candidates hold; every
    /// real conflict must have exactly one. A record without a decision keeps the default: merged into the
    /// account sharing its external identifiers, otherwise added under its own. Nothing is mutated: the result
    /// is a new array, and any invalid, unknown or repeated decision rejects the whole call.
    static func apply(_ preview: CredentialImportPreview, decisions: [CredentialImportDecision]) throws -> [CredentialAccount] {
        try validateAccounts(preview.base.accounts)
        try validateAccounts(preview.candidates)
        let conflictByIncoming = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.incoming, $0) })
        let decisionsByIncoming = try validatedDecisions(decisions, for: preview, conflicts: conflictByIncoming)

        var result = preview.base.accounts
        for candidate in preview.candidates {
            try place(candidate, decisions: decisionsByIncoming, conflicts: conflictByIncoming, into: &result)
        }
        try validateAccounts(result)
        return result
    }

    private static func incomingIdentity(of decision: CredentialImportDecision) -> CredentialIdentity {
        switch decision {
        case let .keep(value), let .add(value, _):
            value
        case let .replace(value, _):
            value
        }
    }

    /// Indexes `decisions` by the incoming identity they name, rejecting any that is unknown, repeated or
    /// inconsistent with the stored accounts, and any real conflict left without one.
    private static func validatedDecisions(
        _ decisions: [CredentialImportDecision],
        for preview: CredentialImportPreview,
        conflicts conflictByIncoming: [CredentialIdentity: CredentialImportConflict]
    ) throws -> [CredentialIdentity: CredentialImportDecision] {
        let incomingIdentities = Set(preview.candidates.flatMap(identities(in:)))
        let baseIdentities = Set(preview.base.accounts.flatMap(identities(in:)))
        let baseAccountIDs = Set(preview.base.accounts.map(\.id))
        var decisionsByIncoming: [CredentialIdentity: CredentialImportDecision] = [:]
        for decision in decisions {
            let incoming = incomingIdentity(of: decision)
            guard incomingIdentities.contains(incoming),
                  decisionsByIncoming.updateValue(decision, forKey: incoming) == nil else {
                throw CredentialVaultError.invalidData
            }
            switch decision {
            case .keep:
                break
            case let .add(_, targetAccountID):
                guard targetAccountID.map(baseAccountIDs.contains) ?? true else { throw CredentialVaultError.invalidData }
            case let .replace(_, target):
                // A conflict is replaced only at the stored credential it matched; any other replacement
                // needs a stored credential of the same kind to overwrite.
                if let conflict = conflictByIncoming[incoming] {
                    guard target == conflict.existing else { throw CredentialVaultError.invalidData }
                } else {
                    guard baseIdentities.contains(target), sameKind(incoming, target) else { throw CredentialVaultError.invalidData }
                }
            }
        }
        guard conflictByIncoming.keys.allSatisfy({ decisionsByIncoming[$0] != nil }) else { throw CredentialVaultError.invalidData }
        return decisionsByIncoming
    }

    /// Places every credential of `candidate` into `result` as its decision, or the default, directs.
    private static func place(
        _ candidate: CredentialAccount,
        decisions decisionsByIncoming: [CredentialIdentity: CredentialImportDecision],
        conflicts conflictByIncoming: [CredentialIdentity: CredentialImportConflict],
        into result: inout [CredentialAccount]
    ) throws {
        let candidateExternalID = try externalItemID(for: candidate)
        let linkedIndices = try result.indices.filter {
            try externalItemID(for: result[$0]) == candidateExternalID
        }
        guard linkedIndices.count <= 1 else { throw CredentialVaultError.duplicateIdentifier }
        let linkedIndex = linkedIndices.first
        var unattached = emptyLike(candidate)
        var unattachedPlaced = false
        // The exporter's item identifiers (and the metadata under them) belong to exactly one account: the
        // stored one that already holds them, else the first destination of this item's credentials. Every
        // other destination is given fresh identifiers and a remapped copy of the metadata.
        var claimed = linkedIndex != nil
        var carried = Set<UUID>()

        func addToSeparateAccount(_ identity: CredentialIdentity, forceFork: Bool) throws {
            if !unattachedPlaced {
                if claimed || forceFork {
                    try fork(&unattached, from: candidate, candidateID: candidateExternalID)
                } else {
                    claimed = true
                }
                unattachedPlaced = true
            }
            try add(identity, from: candidate, to: &unattached)
        }

        for identity in identities(in: candidate) {
            if let decision = decisionsByIncoming[identity] {
                switch decision {
                case .keep:
                    continue
                case let .replace(_, target):
                    try replace(identity, from: candidate, target: target, in: &result)
                case let .add(_, targetAccountID):
                    if let targetAccountID {
                        guard let index = result.firstIndex(where: { $0.id == targetAccountID }) else {
                            throw CredentialVaultError.invalidData
                        }
                        try carryAndMerge(
                            identity,
                            from: candidate,
                            id: candidateExternalID,
                            into: &result[index],
                            claimed: &claimed,
                            carried: &carried
                        )
                    } else {
                        try addToSeparateAccount(identity, forceFork: conflictByIncoming[identity] != nil)
                    }
                }
            } else if conflictByIncoming[identity] != nil {
                throw CredentialVaultError.invalidData
            } else if let linkedIndex {
                try carryAndMerge(
                    identity,
                    from: candidate,
                    id: candidateExternalID,
                    into: &result[linkedIndex],
                    claimed: &claimed,
                    carried: &carried
                )
            } else {
                try addToSeparateAccount(identity, forceFork: false)
            }
        }
        if !identities(in: unattached).isEmpty {
            result.append(unattached)
        }
    }

    private static func carryAndMerge(
        _ identity: CredentialIdentity,
        from source: CredentialAccount,
        id: ExternalItemID,
        into target: inout CredentialAccount,
        claimed: inout Bool,
        carried: inout Set<UUID>
    ) throws {
        try carry(source, id: id, into: &target, claimed: &claimed, carried: &carried)
        try merge(identity, from: source, into: &target)
    }

    private static func sameKind(_ lhs: CredentialIdentity, _ rhs: CredentialIdentity) -> Bool {
        switch (lhs, rhs) {
        case (.password, .password), (.passkey, .passkey), (.totp, .totp):
            true
        default:
            false
        }
    }

    private static func forkMetadata(
        _ data: Data?,
        from old: ExternalItemID,
        to new: ExternalItemID
    ) throws -> Data? {
        guard let data else { return nil }
        var metadata = try JSONDecoder().decode(ExchangeMetadata.self, from: data)
        func remap(_ collections: inout [ExchangeCollection]) {
            for index in collections.indices {
                for itemIndex in collections[index].items.indices {
                    let link = collections[index].items[itemIndex]
                    guard link.item == old.item, link.account == nil || link.account == old.account else { continue }
                    collections[index].items[itemIndex].item = new.item
                    if link.account != nil {
                        collections[index].items[itemIndex].account = new.account
                    }
                }
                remap(&collections[index].subcollections)
            }
        }
        remap(&metadata.collections)
        return try JSONEncoder().encode(metadata)
    }

    private static func emptyLike(_ account: CredentialAccount) -> CredentialAccount {
        CredentialAccount(
            id: account.id,
            username: "",
            displayName: account.displayName,
            origins: account.origins,
            loginURLs: account.loginURLs,
            password: nil,
            passkeys: [],
            totp: nil,
            exchangeAccountID: account.exchangeAccountID,
            exchangeItemID: account.exchangeItemID,
            exchangeMetadata: account.exchangeMetadata,
            basicAuthenticationMetadata: nil
        )
    }

    private static func isSameItem(_ source: CredentialAccount, _ target: CredentialAccount) -> Bool {
        guard let lhs = try? externalItemID(for: source), let rhs = try? externalItemID(for: target) else { return false }
        return lhs == rhs
    }

    /// The stored account that already holds `candidate`'s exporter item, which is where its credentials go unless
    /// the user decides otherwise. `nil` when the item is new here.
    static func linkedAccountID(for candidate: CredentialAccount, in accounts: [CredentialAccount]) -> UUID? {
        accounts.first { isSameItem(candidate, $0) }?.id
    }

    /// A credential can be merged into `target` when nothing of the exporter's item would be lost: the item
    /// is the same one (its metadata is refreshed), or `target` is a plain account with no exchange identity
    /// of its own and no different name, which then takes the item's name and metadata. Another imported item,
    /// or an account the user has named differently, is refused rather than silently overwritten.
    static func canMerge(_ source: CredentialAccount, into target: CredentialAccount) -> Bool {
        if isSameItem(source, target) {
            return true
        }
        if let title = source.displayName, !title.isEmpty,
           let existing = target.displayName, !existing.isEmpty, existing != title {
            return false
        }
        guard source.exchangeMetadata != nil else { return true }
        return target.exchangeMetadata == nil && target.exchangeAccountID == nil && target.exchangeItemID == nil
    }

    /// Gives `account` fresh exporter identifiers and a copy of the item's metadata remapped to them.
    private static func fork(_ account: inout CredentialAccount, from source: CredentialAccount, candidateID: ExternalItemID) throws {
        let newAccountID = try externalID(nil, fallback: UUID())
        let newItemID = try externalID(nil, fallback: UUID())
        account.exchangeAccountID = newAccountID
        account.exchangeItemID = newItemID
        account.exchangeMetadata = try forkMetadata(
            source.exchangeMetadata,
            from: candidateID,
            to: ExternalItemID(account: newAccountID, item: newItemID)
        )
    }

    /// Brings the imported item's name and metadata into `target`, once per target. The first destination of an
    /// item takes its identifiers; a later one takes a fork, so no two accounts ever claim the same item.
    private static func carry(
        _ source: CredentialAccount,
        id: ExternalItemID,
        into target: inout CredentialAccount,
        claimed: inout Bool,
        carried: inout Set<UUID>
    ) throws {
        guard carried.insert(target.id).inserted else { return }
        if isSameItem(source, target) {
            if source.exchangeMetadata != nil {
                target.exchangeMetadata = source.exchangeMetadata
            }
            claimed = true
            return
        }
        guard canMerge(source, into: target) else { throw CredentialVaultError.invalidData }
        if target.displayName?.isEmpty ?? true, let title = source.displayName, !title.isEmpty {
            target.displayName = title
        }
        guard source.exchangeMetadata != nil else { return }
        if claimed {
            try fork(&target, from: source, candidateID: id)
        } else {
            target.exchangeAccountID = source.exchangeAccountID
            target.exchangeItemID = source.exchangeItemID
            target.exchangeMetadata = source.exchangeMetadata
            claimed = true
        }
    }

    private static func merge(_ identity: CredentialIdentity, from source: CredentialAccount, into target: inout CredentialAccount) throws {
        switch identity {
        case .password:
            guard !hasBasicAuthentication(target) else { throw CredentialVaultError.invalidData }
            copyBasicAuthentication(from: source, to: &target)
        case let .passkey(_, passkeyID):
            guard let value = source.passkeys.first(where: { $0.id == passkeyID }),
                  !target.passkeys.contains(where: {
                      $0.credentialID == value.credentialID && $0.rpID == value.rpID
                  }) else {
                throw CredentialVaultError.duplicateIdentifier
            }
            target.passkeys.append(value)
        case .totp:
            guard target.totp == nil else { throw CredentialVaultError.invalidData }
            target.totp = source.totp
        }
    }

    private static func replace(
        _ incoming: CredentialIdentity,
        from source: CredentialAccount,
        target: CredentialIdentity,
        in accounts: inout [CredentialAccount]
    ) throws {
        guard let index = accounts.firstIndex(where: { $0.id == accountID(for: target) }) else {
            throw CredentialVaultError.invalidData
        }
        // The same exporter item is being refreshed, so its newer metadata comes with the credential.
        if source.exchangeMetadata != nil,
           let lhs = try? externalItemID(for: source), let rhs = try? externalItemID(for: accounts[index]), lhs == rhs {
            accounts[index].exchangeMetadata = source.exchangeMetadata
        }
        switch (incoming, target) {
        case (.password, .password):
            copyBasicAuthentication(from: source, to: &accounts[index])
        case let (.passkey(_, incomingID), .passkey(_, targetID)):
            guard let sourcePasskey = source.passkeys.first(where: { $0.id == incomingID }),
                  let targetIndex = accounts[index].passkeys.firstIndex(where: { $0.id == targetID }) else {
                throw CredentialVaultError.invalidData
            }
            var replacement = sourcePasskey
            replacement.id = targetID
            accounts[index].passkeys[targetIndex] = replacement
        case (.totp, .totp):
            accounts[index].totp = source.totp
        default:
            throw CredentialVaultError.invalidData
        }
    }

    private static func add(_ identity: CredentialIdentity, from source: CredentialAccount, to target: inout CredentialAccount) throws {
        switch identity {
        case .password:
            copyBasicAuthentication(from: source, to: &target)
        case let .passkey(_, passkeyID):
            guard let value = source.passkeys.first(where: { $0.id == passkeyID }) else { throw CredentialVaultError.invalidData }
            target.passkeys.append(value)
        case .totp:
            target.totp = source.totp
        }
    }

    private static func copyBasicAuthentication(from source: CredentialAccount, to target: inout CredentialAccount) {
        target.username = source.username
        target.password = source.password
        target.basicAuthenticationMetadata = source.basicAuthenticationMetadata
    }

    private static func accountID(for identity: CredentialIdentity) -> UUID {
        switch identity {
        case let .password(accountID), let .totp(accountID):
            accountID
        case let .passkey(accountID, _):
            accountID
        }
    }
}
