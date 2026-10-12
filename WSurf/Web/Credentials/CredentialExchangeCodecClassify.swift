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

/// The destination vault as classification sees it: its live accounts and the identifiers of what it removed.
nonisolated struct ImportDestinationView: Sendable {
    let accounts: [CredentialAccount]
    let removed: RemovedIdentifiers
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
        switch incoming {
        case let .password(accountID):
            let candidate = try candidate(accountID, in: preview)
            return try classifyLogin(
                candidate,
                destination: destination,
                hasPart: hasBasicAuthentication,
                hash: { try CredentialContent.hash(.password($0)) },
                base: \.passwordBase,
                identicalWithoutBaseIsUnchanged: false
            )
        case let .totp(accountID):
            let candidate = try candidate(accountID, in: preview)
            return try classifyLogin(
                candidate,
                destination: destination,
                hasPart: { $0.totp != nil },
                hash: { try CredentialContent.hash(.totp($0)) },
                base: \.totpBase,
                identicalWithoutBaseIsUnchanged: true
            )
        case let .passkey(accountID, passkeyID):
            guard let passkey = try candidate(accountID, in: preview).passkeys.first(where: { $0.id == passkeyID }) else {
                throw CredentialVaultError.invalidData
            }
            return try classifyPasskey(passkey, destination: destination)
        }
    }

    private static func candidate(_ accountID: UUID, in preview: CredentialImportPreview) throws -> CredentialAccount {
        guard let candidate = preview.candidates.first(where: { $0.id == accountID }) else { throw CredentialVaultError.invalidData }
        return candidate
    }

    /// Password and TOTP: an exchange id is a hint, so a match counts only with a bound pairing.
    private static func classifyLogin(
        _ candidate: CredentialAccount,
        destination: ImportDestinationView,
        hasPart: (CredentialAccount) -> Bool,
        hash: (CredentialAccount) throws -> Data,
        base: KeyPath<CredentialAccount, ExchangeBase?>,
        identicalWithoutBaseIsUnchanged: Bool
    ) throws -> CredentialImportClass {
        let key = try externalItemID(for: candidate)
        let matches = try destination.accounts.filter { try externalItemID(for: $0) == key }
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
        let observed = local[keyPath: base].flatMap { $0.itemID == key.item ? $0 : nil }
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
        let live = destination.accounts.flatMap(\.passkeys).filter {
            $0.credentialID == passkey.credentialID && $0.rpID.lowercased() == rpID
        }
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
