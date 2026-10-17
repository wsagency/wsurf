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
                identicalWithoutBaseIsUnchanged: false
            )
        case .totp:
            return try classifyLogin(
                candidate,
                destination: destination,
                hasPart: { $0.totp != nil },
                hash: { try CredentialContent.hash(.totp($0)) },
                base: \.totpBase,
                identicalWithoutBaseIsUnchanged: true
            )
        case .note:
            return try classifyLogin(
                candidate,
                destination: destination,
                hasPart: { $0.notes != nil },
                hash: { try CredentialContent.hash(.note($0)) },
                base: { _ in nil },
                identicalWithoutBaseIsUnchanged: true
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
    /// base, so identical notes are unchanged and different ones have no common base.
    private static func classifyLogin(
        _ candidate: CredentialAccount,
        destination: ImportDestinationView,
        hasPart: (CredentialAccount) -> Bool,
        hash: (CredentialAccount) throws -> Data,
        base: (CredentialAccount) -> ExchangeBase?,
        identicalWithoutBaseIsUnchanged: Bool
    ) throws -> CredentialImportClass {
        let key = try externalItemID(for: candidate)
        guard !destination.hasUnreadableIdentity else { throw CredentialVaultError.invalidData }
        let matches = (destination.positionsByItem[key] ?? []).map { destination.accounts[$0] }
        guard let local = matches.first else {
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
        guard matches.count == 1 else { return .ambiguous }
        _ = try CredentialContent.exchangeMetadata(local)
        guard isBound(local, to: key.item) else { return .ambiguous }
        guard hasPart(local) else { return .new }

        let incomingHash = try hash(candidate)
        let localHash = try hash(local)
        let observed = base(local).flatMap { $0.itemID == key.item ? $0 : nil }
        // Equal content is "unchanged" through a bound base; without one only an identical TOTP (§13.3) is.
        if incomingHash == localHash, observed != nil || identicalWithoutBaseIsUnchanged {
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

    /// An accepted pairing (§13.2a): some credential of `account` was observed from this exact remote item.
    private static func isBound(_ account: CredentialAccount, to itemID: Data) -> Bool {
        let bases = [account.passwordBase, account.totpBase] + account.passkeys.map(\.base)
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
    static func rejectStoredPasskeyWrite(_ incoming: CredentialIdentity, in preview: CredentialImportPreview) throws {
        guard case .passkey = incoming else { return }
        let stored = ImportDestinationView(accounts: preview.base.accounts, removed: RemovedIdentifiers(items: []))
        guard try classify(incoming, in: preview, destination: stored) == .new else {
            throw CredentialVaultError.invalidData
        }
    }
}
