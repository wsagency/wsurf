// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated extension CredentialExchangeCodec {
    /// Applies `decisions` to `preview`. A decision may name any identity the preview's candidates hold; every
    /// real conflict must have exactly one. A record without a decision keeps the default: merged into the
    /// account sharing its external identifiers, otherwise added under its own. Nothing is mutated: the result
    /// is a new array, and any invalid, unknown or repeated decision rejects the whole call.
    ///
    /// `duplicates` names, by candidate, the saved account that holds an exact copy of the item (`ImportDuplicates`) and that the user
    /// merges it into. The merge adds what that account lacks and replaces nothing: the item's websites that the merge names (and
    /// no others, since a saved password is filled on its credential's websites), its name if the account has none, and the item's
    /// identity when the account has none of its own, so the next import finds it unchanged.
    static func apply(
        _ preview: CredentialImportPreview, decisions: [CredentialImportDecision], duplicates: [UUID: DuplicateMerge] = [:]
    ) throws -> [CredentialAccount] {
        try validateAccounts(preview.base.accounts)
        try validateAccounts(preview.candidates)
        let conflictByIncoming = Dictionary(uniqueKeysWithValues: preview.conflicts.map { ($0.incoming, $0) })
        let decisionsByIncoming = try validatedDecisions(decisions, for: preview, conflicts: conflictByIncoming)

        var result = preview.base.accounts
        // Indexed once so placing a candidate does not scan the vault. Both are exact for this loop: the candidates have distinct
        // exporter items (validated above), so only a stored account that held a candidate's item when the loop began can still hold
        // it; `place` re-checks the account it finds. `result` only grows, so a position stays valid.
        let storedByItem = try positionsByItem(in: result)
        let storedByMergedItem = mergedItemPositions(in: result)
        var positionByID = Dictionary(result.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        for candidate in preview.candidates {
            try place(
                candidate, decisions: decisionsByIncoming, conflicts: conflictByIncoming, duplicateMerge: duplicates[candidate.id],
                storedByItem: storedByItem, storedByMergedItem: storedByMergedItem, positionByID: &positionByID, into: &result
            )
        }
        try recordObservedBases(&result, candidates: preview.candidates)
        try validateAccounts(result, blockedOrigins: preview.base.blockedPasswordOrigins)
        return result
    }

    /// Spec §13.2(a): an item that arrived through a user-applied import is an accepted remote observation. For every candidate whose
    /// exporter item is now held by a stored account, a login or code that equals what the exporter sent is recorded as its base (the
    /// content hash and the item), so a later import can tell which side changed. A part the user kept different from the incoming one
    /// is not an observation of it and keeps the base it had. Notes have no base, and passkeys are matched by their identity.
    /// Pure: no dates, and an account the item was not placed in (a fork has fresh identifiers) is never touched.
    private static func recordObservedBases(_ result: inout [CredentialAccount], candidates: [CredentialAccount]) throws {
        var positions: [ExternalItemID: Int] = [:]
        for (position, account) in result.enumerated() {
            positions[try externalItemID(for: account)] = position
        }
        let merged = mergedItemPositions(in: result)
        for candidate in candidates {
            guard let itemID = candidate.exchangeItemID else { continue }
            let key = try externalItemID(for: candidate)
            if let position = positions[key] {
                try observe(candidate, itemID: itemID, in: &result[position], link: nil)
            } else if let place = merged[key] {
                // An item merged into a saved credential: what it sent is recorded against the item, not against the credential's own.
                try observe(candidate, itemID: itemID, in: &result[place.position], link: place.link)
            }
        }
    }

    /// Records the login, the code and the items of `candidate` that equal what `account` holds, as the base of the item (`link` nil) or of the
    /// merged item at that place in `account.mergedFrom`.
    private static func observe(_ candidate: CredentialAccount, itemID: Data, in account: inout CredentialAccount, link: Int?) throws {
        if hasBasicAuthentication(candidate), hasBasicAuthentication(account) {
            let hash = try CredentialContent.hash(.password(candidate))
            if try CredentialContent.hash(.password(account)) == hash {
                let base = ExchangeBase(contentHash: hash, itemID: itemID)
                if let link {
                    account.mergedFrom?[link].passwordBase = base
                } else {
                    account.passwordBase = base
                }
            }
        }
        if candidate.totp != nil, account.totp != nil {
            let hash = try CredentialContent.hash(.totp(candidate))
            if try CredentialContent.hash(.totp(account)) == hash {
                let base = ExchangeBase(contentHash: hash, itemID: itemID)
                if let link {
                    account.mergedFrom?[link].totpBase = base
                } else {
                    account.totpBase = base
                }
            }
        }
        // A merged item's link keeps no base for items: a later change to them is a decision, never a replacement nobody chose.
        if link == nil, candidate.secureItems != nil, account.secureItems != nil {
            let hash = try CredentialContent.hash(.secureItems(candidate))
            if try CredentialContent.hash(.secureItems(account)) == hash {
                account.secureItemsBase = ExchangeBase(contentHash: hash, itemID: itemID)
            }
        }
    }

    /// Where an exact duplicate is merged: the saved account, and the only websites of the item the merge may add to it.
    struct DuplicateMerge: Sendable, Equatable {
        let target: UUID
        let origins: [String]
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
                try rejectStoredPasskeyWrite(incoming, in: preview)
            case let .replace(_, target):
                // A passkey is never replaced: its cryptographic identity is fixed (§13.3).
                if case .passkey = incoming {
                    throw CredentialVaultError.invalidData
                }
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

    /// Where each exporter item sits in `accounts`, in order.
    private static func positionsByItem(in accounts: [CredentialAccount]) throws -> [ExternalItemID: [Int]] {
        var positions: [ExternalItemID: [Int]] = [:]
        for (position, account) in accounts.enumerated() {
            positions[try externalItemID(for: account), default: []].append(position)
        }
        return positions
    }

    /// Places every credential of `candidate` into `result` as its decision, or the default, directs.
    private static func place(
        _ candidate: CredentialAccount,
        decisions decisionsByIncoming: [CredentialIdentity: CredentialImportDecision],
        conflicts conflictByIncoming: [CredentialIdentity: CredentialImportConflict],
        duplicateMerge: DuplicateMerge?,
        storedByItem: [ExternalItemID: [Int]],
        storedByMergedItem: [ExternalItemID: MergedItemPlace],
        positionByID: inout [UUID: Int],
        into result: inout [CredentialAccount]
    ) throws {
        let candidateExternalID = try externalItemID(for: candidate)
        let linkedIndices = try (storedByItem[candidateExternalID] ?? []).filter {
            try externalItemID(for: result[$0]) == candidateExternalID
        }
        guard linkedIndices.count <= 1 else { throw CredentialVaultError.duplicateIdentifier }
        // An item that was merged into a stored account goes where the merge put it, never to a credential of its own.
        let linkedIndex = linkedIndices.first ?? storedByMergedItem[candidateExternalID]?.position
        var unattached = emptyLike(candidate)
        var unattachedPlaced = false
        // The exporter's item identifiers (and the metadata under them) belong to exactly one account: the
        // stored one that already holds them, else the first destination of this item's credentials. Every
        // other destination is given fresh identifiers and a remapped copy of the metadata.
        var claimed = linkedIndex != nil
        var carried = Set<UUID>()
        if let duplicateMerge {
            guard let index = positionByID[duplicateMerge.target], linkedIndex == nil else { throw CredentialVaultError.invalidData }
            try carryDuplicate(candidate, adding: duplicateMerge.origins, into: &result[index], claimed: &claimed)
            carried.insert(duplicateMerge.target)
        }

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
            let decision = decisionsByIncoming[identity]
                ?? (conflictByIncoming[identity] == nil ? followedDecision(for: identity, of: candidate, decisions: decisionsByIncoming) : nil)
            if let decision {
                switch decision {
                case .keep:
                    continue
                case let .replace(_, target):
                    guard let index = positionByID[accountID(for: target)] else { throw CredentialVaultError.invalidData }
                    try replace(identity, from: candidate, target: target, at: index, in: &result)
                case let .add(_, targetAccountID):
                    if let targetAccountID {
                        guard let index = positionByID[targetAccountID] else {
                            throw CredentialVaultError.invalidData
                        }
                        try carryAndMerge(
                            identity,
                            from: candidate,
                            id: candidateExternalID,
                            into: &result[index],
                            claimed: &claimed,
                            carried: &carried,
                            keepsIdenticalLogin: targetAccountID == duplicateMerge?.target
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
            positionByID[unattached.id] = result.count - 1
        }
    }

    /// A note or an item nobody decided goes where its item's lead credential was sent, a Skip included: choosing Skip, Merge Into or
    /// Add Separately for a login moves the notes and items of that item with it. Only one without a conflict of its own follows.
    private static func followedDecision(
        for identity: CredentialIdentity,
        of candidate: CredentialAccount,
        decisions: [CredentialIdentity: CredentialImportDecision]
    ) -> CredentialImportDecision? {
        guard identity.followsLogin, let lead = leadIdentity(of: candidate), let decision = decisions[lead] else { return nil }
        switch decision {
        case .keep:
            return .keep(incoming: identity)
        case let .add(_, targetAccountID):
            return .add(incoming: identity, targetAccountID: targetAccountID)
        case let .replace(_, target):
            return .add(incoming: identity, targetAccountID: accountID(for: target))
        }
    }

    private static func carryAndMerge(
        _ identity: CredentialIdentity,
        from source: CredentialAccount,
        id: ExternalItemID,
        into target: inout CredentialAccount,
        claimed: inout Bool,
        carried: inout Set<UUID>,
        keepsIdenticalLogin: Bool = false
    ) throws {
        try carry(source, id: id, into: &target, claimed: &claimed, carried: &carried)
        try merge(identity, from: source, into: &target, keepsIdenticalLogin: keepsIdenticalLogin)
    }

    /// Whether the exporter's item can become the identity of the saved account `target`, which holds an exact copy of its login: the
    /// account has no identity of its own, and its login reads as the exporter's, so the base the import records is true. A login the
    /// account keeps without field descriptions takes the exporter's.
    static func canLinkDuplicate(_ source: CredentialAccount, to target: CredentialAccount) -> Bool {
        guard target.exchangeAccountID == nil, target.exchangeItemID == nil, target.exchangeMetadata == nil else { return false }
        return !hasBasicAuthentication(source) || target.basicAuthenticationMetadata == nil
            || target.basicAuthenticationMetadata == source.basicAuthenticationMetadata
    }

    /// The part of an exact duplicate's merge that is not one of its credentials. Adds, never replaces.
    private static func carryDuplicate(
        _ source: CredentialAccount, adding allowed: [String], into target: inout CredentialAccount, claimed: inout Bool
    ) throws {
        // Only the websites the merge names: the item's others are not the saved credential's to be filled on.
        let origins = source.origins.filter { allowed.contains($0) && !target.origins.contains($0) }
        target.origins += origins
        target.loginURLs += source.loginURLs.filter { url in CredentialAccount.origin(for: url).map(origins.contains) ?? false }
        guard target.origins.count <= CredentialAccount.websiteLimit, target.loginURLs.count <= CredentialAccount.websiteLimit else {
            throw CredentialVaultError.invalidData
        }
        if target.displayName?.isEmpty ?? true, let title = source.displayName, !title.isEmpty {
            target.displayName = title
        }
        guard canLinkDuplicate(source, to: target) else { return }
        target.exchangeAccountID = source.exchangeAccountID
        target.exchangeItemID = source.exchangeItemID
        target.exchangeMetadata = source.exchangeMetadata
        if target.basicAuthenticationMetadata == nil {
            target.basicAuthenticationMetadata = source.basicAuthenticationMetadata
        }
        claimed = true
    }

    /// Where the exporter item merged into a stored account now lives: the account's position and the item's place in `mergedFrom`.
    struct MergedItemPlace: Sendable {
        let position: Int
        let link: Int
    }

    /// Where each exporter item that was merged into an account of `accounts` lives (the first account that holds one).
    static func mergedItemPositions(in accounts: [CredentialAccount]) -> [ExternalItemID: MergedItemPlace] {
        var places: [ExternalItemID: MergedItemPlace] = [:]
        for (position, account) in accounts.enumerated() {
            for (link, item) in (account.mergedFrom ?? []).enumerated() where places[item.identity] == nil {
                places[item.identity] = MergedItemPlace(position: position, link: link)
            }
        }
        return places
    }

    static func holdsMergedItem(_ account: CredentialAccount, _ key: ExternalItemID) -> Bool {
        account.mergedFrom?.contains { $0.identity == key } ?? false
    }

    private static func sameKind(_ lhs: CredentialIdentity, _ rhs: CredentialIdentity) -> Bool {
        switch (lhs, rhs) {
        case (.password, .password), (.passkey, .passkey), (.totp, .totp), (.note, .note), (.secureItems, .secureItems):
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

    /// The first stored account that holds each exporter item: where a candidate's credentials go unless the user decides
    /// otherwise. An item that is not in the result is new here.
    static func linkedAccountIDs(in accounts: [CredentialAccount]) -> [ExternalItemID: UUID] {
        var linked: [ExternalItemID: UUID] = [:]
        for account in accounts {
            if let key = try? externalItemID(for: account), linked[key] == nil {
                linked[key] = account.id
            }
        }
        // An item merged into an account is held by it: that is where the item's credentials go.
        for account in accounts {
            for item in account.mergedFrom ?? [] where linked[item.identity] == nil {
                linked[item.identity] = account.id
            }
        }
        return linked
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
        if holdsMergedItem(target, id) {
            // The merged credential keeps its own name and metadata; the item's identifiers stay claimed by its link.
            claimed = true
            return
        }
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

    private static func merge(
        _ identity: CredentialIdentity, from source: CredentialAccount, into target: inout CredentialAccount, keepsIdenticalLogin: Bool
    ) throws {
        switch identity {
        case .password:
            if keepsIdenticalLogin, hasBasicAuthentication(target) {
                // The saved account holds this very login (an exact duplicate): there is nothing to add, and nothing is replaced.
                guard let password = source.password, let held = target.password,
                      password.utf8.elementsEqual(held.utf8), source.username.utf8.elementsEqual(target.username.utf8) else {
                    throw CredentialVaultError.invalidData
                }
                return
            }
            guard !hasBasicAuthentication(target) else { throw CredentialVaultError.invalidData }
            copyBasicAuthentication(from: source, to: &target)
        case let .passkey(_, passkeyID):
            guard let value = source.passkeys.first(where: { $0.id == passkeyID }),
                  !target.passkeys.contains(where: {
                      $0.credentialID == value.credentialID && $0.rpID.lowercased() == value.rpID.lowercased()
                  }) else {
                throw CredentialVaultError.duplicateIdentifier
            }
            target.passkeys.append(value)
        case .totp:
            guard target.totp == nil else { throw CredentialVaultError.invalidData }
            target.totp = source.totp
        case .note:
            // Appends what the target does not already hold, compared as exact UTF-8; its own notes stay.
            var notes = target.notes ?? []
            for note in source.notes ?? [] where !notes.contains(where: { $0.text.utf8.elementsEqual(note.text.utf8) }) {
                notes.append(note)
            }
            guard notes.count <= CredentialAccount.noteLimit else { throw CredentialVaultError.invalidData }
            target.notes = notes.isEmpty ? nil : notes
        case .secureItems:
            // Appends the items the target does not already hold as the same bytes; its own stay.
            let items = try (target.secureItems ?? []).uniting(source.secureItems ?? [])
            guard items.count <= SecureItem.itemLimit else { throw CredentialVaultError.invalidData }
            target.secureItems = items.isEmpty ? nil : items
        }
    }

    private static func replace(
        _ incoming: CredentialIdentity,
        from source: CredentialAccount,
        target: CredentialIdentity,
        at index: Int,
        in accounts: inout [CredentialAccount]
    ) throws {
        // The same exporter item is being refreshed, so its newer metadata comes with the credential.
        if source.exchangeMetadata != nil,
           let lhs = try? externalItemID(for: source), let rhs = try? externalItemID(for: accounts[index]), lhs == rhs {
            accounts[index].exchangeMetadata = source.exchangeMetadata
        }
        switch (incoming, target) {
        case (.password, .password):
            // An incoming login without a password never removes or hides a stored one (§13.3).
            guard source.password != nil || accounts[index].password == nil else { throw CredentialVaultError.invalidData }
            copyBasicAuthentication(from: source, to: &accounts[index])
        case (.totp, .totp):
            accounts[index].totp = source.totp
        case (.note, .note):
            accounts[index].notes = source.notes
        case (.secureItems, .secureItems):
            accounts[index].secureItems = source.secureItems
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
        case .note:
            target.notes = source.notes
        case .secureItems:
            target.secureItems = source.secureItems
        }
    }

    private static func copyBasicAuthentication(from source: CredentialAccount, to target: inout CredentialAccount) {
        target.username = source.username
        target.password = source.password
        target.basicAuthenticationMetadata = source.basicAuthenticationMetadata
    }

    private static func accountID(for identity: CredentialIdentity) -> UUID {
        switch identity {
        case let .password(accountID), let .totp(accountID), let .note(accountID), let .secureItems(accountID):
            accountID
        case let .passkey(accountID, _):
            accountID
        }
    }
}
