// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How one incoming credential relates to the destination vault (§13.3). Never decided by a clock, by site and
/// username, or by an exchange id alone.
nonisolated enum CredentialImportClass: Equatable, Sendable {
    case new
    case unchanged
    case remoteChanged
    case localChanged
    case bothChanged
    case noCommonBase
    case previouslyRemoved(entryID: UUID, isTombstone: Bool)
    case ambiguous
    case passkeyHardConflict
}

/// The destination vault as classification sees it: its live accounts and the identifiers of what it removed. The accounts are
/// indexed once, by exporter item and by passkey identity, so classifying every credential of a transfer costs the size of the
/// transfer and not the transfer times the vault.
nonisolated struct ImportDestinationView: Sendable {
    let accounts: [CredentialAccount]
    let removed: RemovedIdentifiers
    /// Positions in `accounts`, in order, of the accounts that hold each exporter item.
    fileprivate let positionsByItem: [CredentialExchangeCodec.ExternalItemID: [Int]]
    /// Every stored passkey by its identity (website and credential id), in the order the accounts and passkeys are stored.
    fileprivate let passkeysByIdentity: [PasskeyIdentity: [WebsitePasskey]]
    /// Where an exporter item that was merged into a stored account now lives (a vault holds each item once: `validateAccounts`).
    fileprivate let positionsByMergedItem: [CredentialExchangeCodec.ExternalItemID: CredentialExchangeCodec.MergedItemPlace]
    /// Some stored account has an exporter id that cannot be derived. Classifying a login, a code or a note then fails, as it
    /// always did when it met such an account.
    fileprivate let hasUnreadableIdentity: Bool

    fileprivate struct PasskeyIdentity: Hashable, Sendable {
        let relyingPartyID: String
        let credentialID: Data
    }

    init(accounts: [CredentialAccount], removed: RemovedIdentifiers) {
        self.accounts = accounts
        self.removed = removed
        var positions: [CredentialExchangeCodec.ExternalItemID: [Int]] = [:]
        var passkeys: [PasskeyIdentity: [WebsitePasskey]] = [:]
        var unreadable = false
        for (position, account) in accounts.enumerated() {
            if let key = try? CredentialExchangeCodec.externalItemID(for: account) {
                positions[key, default: []].append(position)
            } else {
                unreadable = true
            }
            for passkey in account.passkeys {
                passkeys[PasskeyIdentity(relyingPartyID: passkey.rpID.lowercased(), credentialID: passkey.credentialID), default: []]
                    .append(passkey)
            }
        }
        positionsByItem = positions
        positionsByMergedItem = CredentialExchangeCodec.mergedItemPositions(in: accounts)
        passkeysByIdentity = passkeys
        hasUnreadableIdentity = unreadable
    }
}

nonisolated extension CredentialExchangeCodec {
    /// Classifies `incoming` (an identity of `preview.candidates`) against `destination` only.
    /// Throws what `CredentialContent.hash` and `CredentialContent.exchangeMetadata` throw; nothing is classified
    /// from raw bytes when a stored value cannot be hashed.
    static func classify(
        _ incoming: CredentialIdentity,
        in preview: CredentialImportPreview,
        destination: ImportDestinationView
    ) throws -> CredentialImportClass {
        let candidate = try candidate(owner(of: incoming), in: preview)
        return try classify(incoming, of: candidate, destination: destination)
    }

    /// The same, for a caller that already holds the candidate `incoming` belongs to (a loop over the preview's candidates), so
    /// the preview is not searched for it again.
    static func classify(
        _ incoming: CredentialIdentity,
        of candidate: CredentialAccount,
        destination: ImportDestinationView
    ) throws -> CredentialImportClass {
        guard candidate.id == owner(of: incoming) else { throw CredentialVaultError.invalidData }
        switch incoming {
        case .password:
            return try classifyLogin(
                candidate,
                destination: destination,
                hasPart: hasBasicAuthentication,
                hash: { try CredentialContent.hash(.password($0)) },
                base: \.passwordBase,
                linkBase: \.passwordBase,
                identicalWithoutBaseIsUnchanged: false
            )
        case .totp:
            return try classifyLogin(
                candidate,
                destination: destination,
                hasPart: { $0.totp != nil },
                hash: { try CredentialContent.hash(.totp($0)) },
                base: \.totpBase,
                linkBase: \.totpBase,
                identicalWithoutBaseIsUnchanged: true
            )
        case .note:
            return try classifyLogin(
                candidate,
                destination: destination,
                hasPart: { $0.notes != nil },
                hash: { try CredentialContent.hash(.note($0)) },
                base: { _ in nil },
                linkBase: { _ in nil },
                identicalWithoutBaseIsUnchanged: true,
                isHeld: notesAreHeld
            )
        case let .passkey(_, passkeyID):
            guard let passkey = candidate.passkeys.first(where: { $0.id == passkeyID }) else {
                throw CredentialVaultError.invalidData
            }
            return try classifyPasskey(passkey, destination: destination)
        }
    }

    private static func owner(of identity: CredentialIdentity) -> UUID {
        switch identity {
        case let .password(accountID), let .totp(accountID), let .note(accountID):
            accountID
        case let .passkey(accountID, _):
            accountID
        }
    }

    private static func candidate(_ accountID: UUID, in preview: CredentialImportPreview) throws -> CredentialAccount {
        guard let candidate = preview.candidates.first(where: { $0.id == accountID }) else { throw CredentialVaultError.invalidData }
        return candidate
    }

    /// Password, TOTP and notes: an exchange id is a hint, so a match counts only with a bound pairing. Notes keep no observed
    /// base, so notes the saved credential already holds (`isHeld`: a note added here, or the notes of items merged into it) are
    /// unchanged, and any other difference has no common base.
    ///
    /// An item that was merged into a saved credential (`CredentialMerge`) is found there, never in the Trash it left for: the
    /// credential that holds it is `local`, and what the other app last sent for the item (`linkBase`) is the base, so a change made
    /// in the other app is told from one made here by the same rule as for any linked item. A part the item did not supply to the
    /// merged credential differs from that base, so a change to it is a conflict, never a replacement nobody chose.
    private static func classifyLogin(
        _ candidate: CredentialAccount,
        destination: ImportDestinationView,
        hasPart: (CredentialAccount) -> Bool,
        hash: (CredentialAccount) throws -> Data,
        base: (CredentialAccount) -> ExchangeBase?,
        linkBase: (MergedItemLink) -> ExchangeBase?,
        identicalWithoutBaseIsUnchanged: Bool,
        isHeld: (_ incoming: CredentialAccount, _ local: CredentialAccount) -> Bool = { _, _ in false }
    ) throws -> CredentialImportClass {
        let key = try externalItemID(for: candidate)
        guard !destination.hasUnreadableIdentity else { throw CredentialVaultError.invalidData }
        let matches = (destination.positionsByItem[key] ?? []).map { destination.accounts[$0] }
        let place = matches.isEmpty ? destination.positionsByMergedItem[key] : nil
        guard let local = matches.first ?? place.map({ destination.accounts[$0.position] }) else {
            // A removed row keeps the external ids as stored; a native account has none and exported under its own
            // id, so both sides are derived exactly like the live accounts' (no wildcard, no raw comparison).
            return try previouslyRemoved(destination.removed) { entry in
                guard entry.passkeyCredentialID == nil else { return false }
                let removedKey = ExternalItemID(
                    account: try externalID(entry.exchangeAccountID, fallback: entry.accountID),
                    item: try externalID(entry.exchangeItemID, fallback: entry.accountID)
                )
                return removedKey == key
            } ?? .new
        }
        guard matches.count <= 1 else { return .ambiguous }
        _ = try CredentialContent.exchangeMetadata(local)
        let merged = place.flatMap { local.mergedFrom?[$0.link] }
        guard isBound(local, to: key.item, merged: merged) else {
            // No accepted pairing yet: the item was saved before bases were recorded. The exchange id is still only a hint, but a
            // part that equals what is saved is the same credential whoever pairs it; anything that differs waits for the user.
            guard hasPart(local), try hash(candidate) == hash(local) || isHeld(candidate, local) else { return .ambiguous }
            return .unchanged
        }
        guard hasPart(local) else { return .new }

        let incomingHash = try hash(candidate)
        let localHash = try hash(local)
        let observed = (merged.map(linkBase) ?? base(local)).flatMap { $0.itemID == key.item ? $0 : nil }
        // Equal content is "unchanged" through a bound base; without one only an identical TOTP (§13.3) is.
        if incomingHash == localHash || isHeld(candidate, local), observed != nil || identicalWithoutBaseIsUnchanged {
            return .unchanged
        }
        guard let observed else { return .noCommonBase }
        switch (incomingHash != observed.contentHash, localHash != observed.contentHash) {
        case (true, true):
            return .bothChanged
        case (true, false):
            return .remoteChanged
        default:
            return .localChanged
        }
    }

    /// Whether every note `incoming` brings is already one of `local`'s, compared as exact UTF-8 text as a merge compares them: the
    /// other app sent nothing that isn't saved here.
    private static func notesAreHeld(_ incoming: CredentialAccount, by local: CredentialAccount) -> Bool {
        let held = Set((local.notes ?? []).map { Data($0.text.utf8) })
        return (incoming.notes ?? []).allSatisfy { held.contains(Data($0.text.utf8)) }
    }

    /// An accepted pairing (§13.2a): some credential of `account` was observed from this exact remote item, or `merged`, the item
    /// that was merged into it, records what was.
    private static func isBound(_ account: CredentialAccount, to itemID: Data, merged: MergedItemLink?) -> Bool {
        let bases = [account.passwordBase, account.totpBase] + account.passkeys.map(\.base) + [merged?.passwordBase, merged?.totpBase]
        return bases.contains { $0?.itemID == itemID }
    }

    /// Passkeys: only the cryptographic identity decides. Exchange ids never match a passkey.
    private static func classifyPasskey(_ passkey: WebsitePasskey, destination: ImportDestinationView) throws -> CredentialImportClass {
        let rpID = passkey.rpID.lowercased()
        let live = destination.passkeysByIdentity[
            ImportDestinationView.PasskeyIdentity(relyingPartyID: rpID, credentialID: passkey.credentialID)
        ] ?? []
        guard !live.isEmpty else {
            return previouslyRemoved(destination.removed) { entry in
                entry.passkeyCredentialID == passkey.credentialID && entry.rpID?.lowercased() == rpID
            } ?? .new
        }
        let incomingHash = try CredentialContent.hash(.passkey(passkey))
        // Any stored copy with another key or user handle dominates: the identity is fixed.
        for stored in live where try CredentialContent.hash(.passkey(stored)) != incomingHash {
            return .passkeyHardConflict
        }
        return .unchanged
    }

    private static func previouslyRemoved(
        _ removed: RemovedIdentifiers,
        matching predicate: (RemovedIdentifier) throws -> Bool
    ) rethrows -> CredentialImportClass? {
        let matches = try removed.items.filter(predicate)
        // A Trash entry can still be restored; a tombstone only says it was removed.
        guard let entry = matches.first(where: { !$0.isTombstone }) ?? matches.first else { return nil }
        return .previouslyRemoved(entryID: entry.entryID, isTombstone: entry.isTombstone)
    }

    /// `apply` never writes a passkey whose credential ID and relying party are already stored, whatever its key
    /// material: an equivalent copy would duplicate the cryptographic identity, a different one would fork it. Only
    /// `.keep` is valid for such a passkey.
    static func rejectStoredPasskeyWrite(_ incoming: CredentialIdentity, of candidate: CredentialAccount, stored: ImportDestinationView) throws {
        guard case .passkey = incoming else { return }
        guard try classify(incoming, of: candidate, destination: stored) == .new else {
            throw CredentialVaultError.invalidData
        }
    }
}
