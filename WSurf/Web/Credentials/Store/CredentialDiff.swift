// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated enum PersistenceClass: Equatable, Sendable {
    case noop, persistOnly, semantic
}

/// The earlier value being superseded: `superseded` is the canonical JSON of exactly one typed value
/// (`PasswordValue`, `TOTPGenerator`, `[CredentialNote]` or `MetadataProjection`).
nonisolated struct RevisionDraft: Equatable, Sendable {
    let ownerID: UUID
    let subject: RecordSubject
    let superseded: Data
}

nonisolated enum RemovalScope: Equatable, Sendable {
    case account(UUID)
    case credential(ownerID: UUID, subject: RecordSubject, passkeyID: UUID?)
}

nonisolated struct CredentialChangePlan: Equatable, Sendable {
    let persistence: PersistenceClass
    let revisions: [RevisionDraft]
    let removals: [RemovalScope]
    /// Accounts whose live row differs (added, removed or changed).
    let touched: Set<UUID>
    /// Accounts whose content `modifiedAt` the commit stamps: existing accounts with a semantic change.
    let setsModifiedAt: Set<UUID>
}

/// §11.1: what a commit supersedes, removes and persists. The blocked-origin policy is not an account property and is
/// never part of a plan.
nonisolated enum CredentialDiff {
    /// Throws `CredentialVaultError.invalidData` for duplicate account ids in either list or duplicate passkey ids within an
    /// account (never first-wins, even when the lists are byte-identical, and without validating keys or metadata, so the
    /// byte-identical bypass stays intact); `CredentialStoreError.metadataUndecodable` when a metadata change would
    /// supersede exchange bytes that do not decode; `CredentialVaultError.invalidData` for a changed passkey that cannot be hashed.
    ///
    /// `restoring` names the account an explicit earlier-revision restore applies to: its password slot is never a removal there (a
    /// restored username-only or basic-auth revision leaves no password, yet the current password is superseded, not deleted), so the
    /// current value becomes a new revision and nothing goes to the Trash. An ordinary edit or clear passes `nil` and still removes.
    ///
    /// `removing` names the explicit credential delete the caller is applying. Only that delete moves the notes to the Trash; an
    /// edit that leaves an account without notes supersedes the list like any other note change.
    ///
    /// `returning` lists the accounts an undo gives back from the Trash in the same commit. A password, code or passkey that an
    /// account loses here and that is byte-equal to the same part of one of them is neither moved to the Trash nor kept as a revision:
    /// it comes back with its own account and history, so undoing a merge leaves no second copy of it behind.
    ///
    /// `unchanged` names accounts the caller knows to be byte-equal in both lists (the store's own rows, read in the same transaction):
    /// they are not encoded again. Every other pair is compared on its bytes, and the identity checks above still cover every account.
    static func plan(
        old: [CredentialAccount], new: [CredentialAccount], restoring: UUID? = nil, removing: RemovalScope? = nil,
        returning: [CredentialAccount] = [], unchanged: Set<UUID> = []
    ) throws -> CredentialChangePlan {
        let oldIndex = try indexByID(old)
        var newIDs = Set<UUID>()
        newIDs.reserveCapacity(new.count)
        for account in new {
            guard newIDs.insert(account.id).inserted else { throw CredentialVaultError.invalidData }
            try requireUniquePasskeyIDs(account)
        }
        var plan = Accumulator(restoring: restoring, removing: removing, returning: returning)
        for account in new {
            if let position = oldIndex[account.id] {
                if !unchanged.contains(account.id) {
                    try plan.compare(old[position], account)
                }
            } else {
                plan.touched.insert(account.id)
                plan.semantic = true
            }
        }
        for account in old where !newIDs.contains(account.id) {
            plan.touched.insert(account.id)
            plan.removals.append(.account(account.id))
            plan.semantic = true
        }
        // Complete-payload comparison on the encoded bytes, never `Equatable` (it equates composed and decomposed UTF-8): every pair is
        // byte-equal and in the same order exactly when the encoded payloads are.
        if plan.touched.isEmpty, old.count == new.count, zip(old, new).allSatisfy({ $0.id == $1.id }) {
            return CredentialChangePlan(persistence: .noop, revisions: [], removals: [], touched: [], setsModifiedAt: [])
        }
        return CredentialChangePlan(
            persistence: plan.semantic ? .semantic : .persistOnly,
            revisions: plan.revisions,
            removals: plan.removals,
            touched: plan.touched,
            setsModifiedAt: plan.setsModifiedAt
        )
    }

    /// Position of each old account by id. Ambiguous identities (a repeated account id, a repeated passkey id inside an
    /// account) are refused.
    private static func indexByID(_ accounts: [CredentialAccount]) throws -> [UUID: Int] {
        var index: [UUID: Int] = [:]
        index.reserveCapacity(accounts.count)
        for (position, account) in accounts.enumerated() {
            guard index.updateValue(position, forKey: account.id) == nil else { throw CredentialVaultError.invalidData }
            try requireUniquePasskeyIDs(account)
        }
        return index
    }

    private static func requireUniquePasskeyIDs(_ account: CredentialAccount) throws {
        var seen = Set<UUID>()
        for passkey in account.passkeys {
            guard seen.insert(passkey.id).inserted else { throw CredentialVaultError.invalidData }
        }
    }

    private struct Accumulator {
        let restoring: UUID?
        let removing: RemovalScope?
        let returning: [CredentialAccount]
        var semantic = false
        var revisions: [RevisionDraft] = []
        var removals: [RemovalScope] = []
        var touched = Set<UUID>()
        var setsModifiedAt = Set<UUID>()

        mutating func compare(_ old: CredentialAccount, _ new: CredentialAccount) throws {
            guard try CredentialContent.canonicalJSON(old) != CredentialContent.canonicalJSON(new) else { return }
            touched.insert(new.id)
            let passwordChanged = try comparePassword(old, new)
            let totpChanged = try compareTOTP(old, new)
            let notesChanged = try compareNotes(old, new)
            let metadataChanged = try compareMetadata(old, new)
            let passkeysChanged = try comparePasskeys(old, new)
            if passwordChanged || totpChanged || notesChanged || metadataChanged || passkeysChanged {
                semantic = true
                setsModifiedAt.insert(new.id)
            }
        }

        private mutating func comparePassword(_ old: CredentialAccount, _ new: CredentialAccount) throws -> Bool {
            guard try CredentialContent.hash(.password(old)) != CredentialContent.hash(.password(new)) else { return false }
            if !returning.isEmpty {
                let lost = try CredentialContent.hash(.password(old))
                if try returning.contains(where: { try CredentialContent.hash(.password($0)) == lost }) {
                    return true
                }
            }
            if old.password != nil, new.password == nil, old.id != restoring {
                removals.append(.credential(ownerID: old.id, subject: .password, passkeyID: nil))
            } else if old.password != nil || !old.username.isEmpty || old.basicAuthenticationMetadata != nil {
                let value = PasswordValue(
                    username: old.username,
                    password: old.password,
                    basicAuthenticationMetadata: old.basicAuthenticationMetadata
                )
                revisions.append(RevisionDraft(ownerID: old.id, subject: .password, superseded: try CredentialContent.canonicalJSON(value)))
            }
            return true
        }

        private mutating func compareTOTP(_ old: CredentialAccount, _ new: CredentialAccount) throws -> Bool {
            guard try CredentialContent.hash(.totp(old)) != CredentialContent.hash(.totp(new)) else { return false }
            if old.totp != nil, !returning.isEmpty {
                let lost = try CredentialContent.hash(.totp(old))
                if try returning.contains(where: { try CredentialContent.hash(.totp($0)) == lost }) {
                    return true
                }
            }
            if new.totp == nil {
                removals.append(.credential(ownerID: old.id, subject: .totp, passkeyID: nil))
            } else if let previous = old.totp {
                revisions.append(RevisionDraft(ownerID: old.id, subject: .totp, superseded: try CredentialContent.canonicalJSON(previous)))
            }
            return true
        }

        /// Notes are one part: any change supersedes the whole earlier list, including an edit that clears every note. Only an
        /// explicit notes delete (`RemovalScope.credential(subject: .note)`) moves the list to the Trash.
        private mutating func compareNotes(_ old: CredentialAccount, _ new: CredentialAccount) throws -> Bool {
            guard try CredentialContent.hash(.note(old)) != CredentialContent.hash(.note(new)) else { return false }
            let delete = RemovalScope.credential(ownerID: old.id, subject: .note, passkeyID: nil)
            if new.notes == nil, removing == delete {
                removals.append(delete)
            } else if let previous = old.notes {
                revisions.append(RevisionDraft(ownerID: old.id, subject: .note, superseded: try CredentialContent.canonicalJSON(previous)))
            }
            return true
        }

        private mutating func compareMetadata(_ old: CredentialAccount, _ new: CredentialAccount) throws -> Bool {
            // Byte-identical raw inputs are unchanged without decoding, so undecodable-but-unchanged exchange metadata
            // never blocks an unrelated edit.
            guard !Self.sameMetadataInputs(old, new) else { return false }
            guard try CredentialContent.hash(.metadata(old)) != CredentialContent.hash(.metadata(new)) else { return false }
            let projection = try MetadataProjection(old)
            revisions.append(RevisionDraft(ownerID: old.id, subject: .metadata, superseded: try CredentialContent.canonicalJSON(projection)))
            return true
        }

        /// A passkey has no revisions and no replacement: a removed one is a removal, an added one supersedes nothing, and
        /// changed key material, credential id, rpID or user handle under the same passkey id is refused (§13.3).
        private mutating func comparePasskeys(_ old: CredentialAccount, _ new: CredentialAccount) throws -> Bool {
            // Ids are unique here: `plan` refuses duplicate passkey ids before any comparison.
            var newPosition: [UUID: Int] = [:]
            for (position, passkey) in new.passkeys.enumerated() {
                newPosition[passkey.id] = position
            }
            var changed = false
            for passkey in old.passkeys {
                if let position = newPosition[passkey.id] {
                    guard try !Self.keyMaterialChanged(passkey, new.passkeys[position]) else { throw CredentialVaultError.invalidData }
                    continue
                }
                changed = true
                if try isGivenBack(passkey) {
                    continue
                }
                removals.append(.credential(ownerID: old.id, subject: .passkey, passkeyID: passkey.id))
            }
            // With unique ids on both sides and no old passkey flagged, the old ids map one-to-one into the new ones, so a
            // larger new list means at least one addition.
            return changed || old.passkeys.count != new.passkeys.count
        }

        /// Whether an account the undo returns holds exactly this passkey (the same bytes).
        private func isGivenBack(_ passkey: WebsitePasskey) throws -> Bool {
            guard !returning.isEmpty else { return false }
            let bytes = try CredentialContent.canonicalJSON(passkey)
            return try returning.contains { account in
                try account.passkeys.contains { try CredentialContent.canonicalJSON($0) == bytes }
            }
        }

        /// Byte-identical passkeys are unchanged without hashing, so a stored passkey is never re-parsed needlessly.
        private static func keyMaterialChanged(_ old: WebsitePasskey, _ new: WebsitePasskey) throws -> Bool {
            if try CredentialContent.canonicalJSON(old) == CredentialContent.canonicalJSON(new) {
                return false
            }
            return try CredentialContent.hash(.passkey(old)) != CredentialContent.hash(.passkey(new))
        }

        /// UTF-8 comparison: `String ==` would treat canonically equivalent spellings as the same value.
        private static func sameMetadataInputs(_ old: CredentialAccount, _ new: CredentialAccount) -> Bool {
            guard old.exchangeMetadata == new.exchangeMetadata, sameBytes(old.displayName, new.displayName) else { return false }
            guard old.origins.elementsEqual(new.origins, by: { sameBytes($0, $1) }) else { return false }
            return old.loginURLs.elementsEqual(new.loginURLs, by: { sameBytes($0.absoluteString, $1.absoluteString) })
        }

        private static func sameBytes(_ lhs: String?, _ rhs: String?) -> Bool {
            guard let lhs, let rhs else { return lhs == nil && rhs == nil }
            return lhs.utf8.elementsEqual(rhs.utf8)
        }
    }
}
