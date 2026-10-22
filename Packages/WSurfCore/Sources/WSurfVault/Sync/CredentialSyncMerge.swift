// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

// The per-part three-way merge of iCloud sync (spec amendment 2026-10-22). It reuses the classes (`CredentialImportClass`), the part
// hashes (`CredentialContent.hash`), the passkey identity rule and `RemovedIdentifiers` of §13.3, but not `CredentialExchangeCodec`'s
// classify and apply: those match by the other app's item ids and record its observed bases (§13.2a), and a synced value is never one.
// A clock decides nothing: no date, no `modifiedAt` and no `lastSignedAt` is read.

/// The parts of an account that are merged on their own. Passkeys are merged by identity beside them (`PasskeyPart`).
public nonisolated enum SyncPart: String, Codable, CaseIterable, Sendable {
    case password, totp, notes, secureItems, metadata
}

/// One passkey of an account: its identity, which is fixed (website and credential id), and the hash of its key material.
public nonisolated struct PasskeyPart: Codable, Equatable, Sendable {
    public var identity: Data
    public var hash: Data

    public init(identity: Data, hash: Data) {
        self.identity = identity
        self.hash = hash
    }

    /// `SHA-256(text(rpID.lowercased()) ‖ bytes(credentialID))`.
    static func identity(of passkey: WebsitePasskey) -> Data {
        var writer = StoreWriter()
        writer.text(passkey.rpID.lowercased())
        writer.bytes(passkey.credentialID)
        return Data(SHA256.hash(data: writer.data))
    }
}

/// What an account is, part by part, as `CredentialContent.hash` sees it. These are plain SHA-256 of secrets: they are stored and
/// uploaded only sealed (`VaultSyncCodec.sealParts`). Dates, events, the Apple observed bases, `mergedFrom`, a passkey's `lastSignedAt`
/// and files are not parts: they never raise an upload or a conflict, and they travel with the part they belong to.
public nonisolated struct SyncParts: Codable, Equatable, Sendable {
    public var removed: Bool
    public var password: Data
    public var totp: Data
    public var notes: Data
    public var secureItems: Data
    public var metadata: Data
    /// Sorted by identity.
    public var passkeys: [PasskeyPart]

    public init(removed: Bool, password: Data, totp: Data, notes: Data, secureItems: Data, metadata: Data, passkeys: [PasskeyPart]) {
        self.removed = removed
        self.password = password
        self.totp = totp
        self.notes = notes
        self.secureItems = secureItems
        self.metadata = metadata
        self.passkeys = passkeys
    }

    /// An account that was removed: nothing but the state.
    public static let removedParts = SyncParts(
        removed: true, password: zero, totp: zero, notes: zero, secureItems: zero, metadata: zero, passkeys: []
    )

    private static let zero = Data(count: 32)

    /// SHA-256 over every field above, in this order. Two accounts with one sum have no part to merge.
    public var sum: Data {
        var writer = StoreWriter()
        writer.bool(removed)
        for part in SyncPart.allCases {
            writer.bytes(hash(of: part))
        }
        writer.array(passkeys) { writer, passkey in
            writer.bytes(passkey.identity)
            writer.bytes(passkey.hash)
        }
        return Data(SHA256.hash(data: writer.data))
    }

    /// The parts of `account`; its files are ignored. Throws what `CredentialContent.hash` throws, and `duplicateIdentifier` for two
    /// passkeys with one identity.
    public static func of(_ account: CredentialAccount) throws -> SyncParts {
        var identities = Set<Data>()
        var passkeys: [PasskeyPart] = []
        for passkey in account.passkeys {
            let identity = PasskeyPart.identity(of: passkey)
            guard identities.insert(identity).inserted else { throw CredentialVaultError.duplicateIdentifier }
            passkeys.append(PasskeyPart(identity: identity, hash: try CredentialContent.hash(.passkey(passkey))))
        }
        return SyncParts(
            removed: false,
            password: try CredentialContent.hash(.password(account)),
            totp: try CredentialContent.hash(.totp(account)),
            notes: try CredentialContent.hash(.note(account)),
            secureItems: try CredentialContent.hash(.secureItems(account)),
            metadata: try CredentialContent.hash(.metadata(account)),
            passkeys: passkeys.sorted { $0.identity.lexicographicallyPrecedes($1.identity) }
        )
    }

    func hash(of part: SyncPart) -> Data {
        switch part {
        case .password:
            password
        case .totp:
            totp
        case .notes:
            notes
        case .secureItems:
            secureItems
        case .metadata:
            metadata
        }
    }
}

/// The last state this Mac and iCloud agreed on for one account: the version and parts of the incoming record it processed, or of
/// its own record once the server confirmed it. Never an Apple observed base, and never written into an account.
public nonisolated struct SyncBase: Equatable, Sendable {
    public var version: UInt64
    public var parts: SyncParts

    public init(version: UInt64, parts: SyncParts) {
        self.version = version
        self.parts = parts
    }
}

/// Why an incoming item waits for the person. `ambiguous` and `refused` are information only.
public nonisolated enum SyncConflictKind: String, Codable, CaseIterable, Sendable {
    /// Changed here and on another device (some part, or the same part).
    case bothChanged
    /// No common base, and the two differ.
    case noCommonBase
    /// Removed on another device, changed here.
    case deletedThereChangedHere
    /// Changed on another device, removed here.
    case changedThereDeletedHere
    /// Not here, but the entry was removed from this vault before (Trash entry or tombstone): no silent re-import.
    case previouslyRemoved
    /// Another entry here holds the same item, or the same passkey: not added.
    case ambiguous
    /// The vault cannot take the entry on this Mac (a limit, a rule, an identity); set by the caller that tried.
    case refused
}

/// What to do with one incoming item. A `SyncBase` is the base to record once the decision is applied.
public nonisolated enum SyncDecision: Equatable, Sendable {
    /// A replay or this Mac's own record: nothing changes and the base stays.
    case ignore
    /// Nothing to write here.
    case keep(SyncBase)
    /// Add this account, or replace the local one by it.
    case write(CredentialAccount, SyncBase)
    /// Move the whole local account, with its History, to Trash.
    case moveToTrash(SyncBase)
    /// Wait for the person. The incoming item is applied and uploaded by nothing until `resolve`.
    case review(SyncConflictKind, parts: [SyncPart])
}

/// What a merge takes from the incoming account: whole parts, and passkeys by identity.
public nonisolated struct SyncTaking: Equatable, Sendable {
    public var parts: Set<SyncPart>
    public var addPasskeys: Set<Data>
    public var dropPasskeys: Set<Data>

    public init(parts: Set<SyncPart> = [], addPasskeys: Set<Data> = [], dropPasskeys: Set<Data> = []) {
        self.parts = parts
        self.addPasskeys = addPasskeys
        self.dropPasskeys = dropPasskeys
    }
}

/// The vault's own accounts as a decision needs them: who holds an exporter item identity (as the account's own or as a merged
/// item) or a passkey credential id, and which account ids were removed (a Trash entry or a tombstone, matched by account id: an
/// `Item` is authenticated by the vault's key, unlike an exporter id).
public nonisolated struct SyncLocalIndex: Sendable {
    private let items: [CredentialExchangeCodec.ExternalItemID: Set<UUID>]
    private let credentials: [Data: Set<UUID>]
    private let removedAccounts: Set<UUID>

    public init(accounts: [CredentialAccount], removed: RemovedIdentifiers) {
        var items: [CredentialExchangeCodec.ExternalItemID: Set<UUID>] = [:]
        var credentials: [Data: Set<UUID>] = [:]
        for account in accounts {
            for identity in CredentialSyncMerge.identities(of: account) {
                items[identity, default: []].insert(account.id)
            }
            for passkey in account.passkeys {
                credentials[passkey.credentialID, default: []].insert(account.id)
            }
        }
        self.items = items
        self.credentials = credentials
        removedAccounts = Set(removed.items.lazy.filter { $0.passkeyCredentialID == nil }.map(\.accountID))
    }

    func holders(ofItem identity: CredentialExchangeCodec.ExternalItemID) -> Set<UUID> {
        items[identity] ?? []
    }

    func holders(ofCredentialID credentialID: Data) -> Set<UUID> {
        credentials[credentialID] ?? []
    }

    func wasRemoved(_ accountID: UUID) -> Bool {
        removedAccounts.contains(accountID)
    }
}

public nonisolated enum CredentialSyncMerge {
    // MARK: Classes (§13.3 on parts)

    /// One part, from its three hashes. Equal content is `unchanged` whatever the base; without a base the two differ with no common
    /// ground; otherwise the side that left the base changed.
    public static func classify(incoming: Data, local: Data, base: Data?) -> CredentialImportClass {
        if incoming == local {
            return .unchanged
        }
        guard let base else { return .noCommonBase }
        return switch (incoming != base, local != base) {
        case (true, true):
            .bothChanged
        case (true, false):
            .remoteChanged
        case (false, _):
            .localChanged
        }
    }

    /// One passkey identity, from the hash of each side's key material (`nil`: the side does not hold it). The identity is fixed, so
    /// the same identity with another hash is a hard conflict and the local one stays. A passkey only the incoming side holds was
    /// removed here when the base held it (it stays removed), else it is new. A passkey only this side holds was removed there when
    /// the base held this very key (`remoteChanged`: it is dropped), else it was added here (it is kept).
    public static func classifyPasskey(incoming: Data?, local: Data?, base: Data?) -> CredentialImportClass {
        switch (incoming, local) {
        case let (incoming?, local?):
            return incoming == local ? .unchanged : .passkeyHardConflict
        case (_?, nil):
            return base == nil ? .new : .localChanged
        case let (nil, local?):
            return base == local ? .remoteChanged : .localChanged
        case (nil, nil):
            return .unchanged
        }
    }

    // MARK: Decision

    /// What to do with `item` given the local account (if any), the base and the vault's index. Automatic unless `.review`.
    public static func decide(_ item: SyncItem, local: CredentialAccount?, base: SyncBase?, index: SyncLocalIndex) throws -> SyncDecision {
        if let base, item.version <= base.version {
            return .ignore
        }
        if let local, local.id != item.accountID {
            throw VaultSyncError.malformed
        }
        let incoming = try item.parts()
        let accepted = SyncBase(version: item.version, parts: incoming)
        guard let account = item.account else {
            guard let local else { return .keep(accepted) }
            // Files are never synced, so an entry that has some holds the only copy of them: its move to Trash is the owner's choice.
            let hasFiles = local.attachments?.isEmpty == false
            if let base, !base.parts.removed, !hasFiles, try SyncParts.of(local).sum == base.parts.sum {
                return .moveToTrash(accepted)
            }
            return .review(.deletedThereChangedHere, parts: [])
        }
        guard let local else {
            if let base {
                guard base.parts.removed else { return .review(.changedThereDeletedHere, parts: []) }
            } else if index.wasRemoved(item.accountID) {
                return .review(.previouslyRemoved, parts: [])
            }
            return adding(account, incoming: incoming, version: item.version, index: index)
        }
        let own = try SyncParts.of(local)
        if own.sum == incoming.sum {
            return .keep(accepted)
        }
        let found = plan(incoming: account, parts: incoming, own: own, base: base.flatMap { $0.parts.removed ? nil : $0.parts }, index: index)
        guard base?.parts.removed == false else {
            return .review(.noCommonBase, parts: found.conflicts)
        }
        if !found.conflicts.isEmpty {
            return .review(.bothChanged, parts: found.conflicts)
        }
        return applying(found, incoming: account, parts: incoming, local: local, own: own, version: item.version, index: index)
    }

    /// The decision for a review row the person answered: keep this Mac's version or take iCloud's. `base` is the base the row was
    /// made against. A kind that is only information has no answer and stays a review.
    public static func resolve(
        _ item: SyncItem, kind: SyncConflictKind, local: CredentialAccount?, base: SyncBase?, keepLocal: Bool, index: SyncLocalIndex
    ) throws -> SyncDecision {
        let incoming = try item.parts()
        let accepted = SyncBase(version: item.version, parts: incoming)
        switch kind {
        case .bothChanged, .noCommonBase:
            guard let local, let account = item.account else { return .review(kind, parts: []) }
            guard !keepLocal else { return .keep(accepted) }
            let own = try SyncParts.of(local)
            var found = plan(incoming: account, parts: incoming, own: own, base: base.flatMap { $0.parts.removed ? nil : $0.parts }, index: index)
            found.taking.parts.formUnion(found.conflicts)
            return applying(found, incoming: account, parts: incoming, local: local, own: own, version: item.version, index: index)
        case .deletedThereChangedHere:
            guard item.account == nil, local != nil else { return .review(kind, parts: []) }
            return keepLocal ? .keep(accepted) : .moveToTrash(accepted)
        case .changedThereDeletedHere, .previouslyRemoved:
            guard let account = item.account, local == nil else { return .review(kind, parts: []) }
            return keepLocal ? .keep(accepted) : adding(account, incoming: incoming, version: item.version, index: index)
        case .ambiguous, .refused:
            return .review(kind, parts: [])
        }
    }

    // MARK: Merge

    /// `local` with what `taking` names copied from `incoming`. Always the local one's: `id`, `attachments`, `createdAt`,
    /// `modifiedAt`, `migratedAt` and every passkey kept (so `lastSignedAt` stays local). Each part brings the fields that belong to it:
    /// the login its events and observed base, the code likewise, the items their observed base, and the name and websites the
    /// exchange metadata, the exchanger's ids and the merged items.
    public static func merge(local: CredentialAccount, incoming: CredentialAccount, taking: SyncTaking) -> CredentialAccount {
        var result = local
        for part in taking.parts {
            switch part {
            case .password:
                result.username = incoming.username
                result.password = incoming.password
                result.basicAuthenticationMetadata = incoming.basicAuthenticationMetadata
                result.passwordEvents = incoming.passwordEvents
                result.passwordBase = incoming.passwordBase
            case .totp:
                result.totp = incoming.totp
                result.totpEvents = incoming.totpEvents
                result.totpBase = incoming.totpBase
            case .notes:
                result.notes = incoming.notes
            case .secureItems:
                result.secureItems = incoming.secureItems
                result.secureItemsBase = incoming.secureItemsBase
            case .metadata:
                result.displayName = incoming.displayName
                result.origins = incoming.origins
                result.loginURLs = incoming.loginURLs
                result.exchangeMetadata = incoming.exchangeMetadata
                result.exchangeAccountID = incoming.exchangeAccountID
                result.exchangeItemID = incoming.exchangeItemID
                result.mergedFrom = incoming.mergedFrom
            }
        }
        if !taking.dropPasskeys.isEmpty {
            result.passkeys.removeAll { taking.dropPasskeys.contains(PasskeyPart.identity(of: $0)) }
        }
        result.passkeys += incoming.passkeys.filter { taking.addPasskeys.contains(PasskeyPart.identity(of: $0)) }
        return result
    }

    // MARK: Internals

    private nonisolated struct Plan {
        var taking = SyncTaking()
        /// Parts both sides changed (or that differ with no base).
        var conflicts: [SyncPart] = []
        /// Passkey identities held on both sides with different key material: the local one stays and the base takes its hash.
        var hard: Set<Data> = []
        /// Passkey identities not added because another entry here holds the credential id; the base leaves them out.
        var held: Set<Data> = []
    }

    /// §4.3 for every part and every passkey identity.
    private static func plan(incoming: CredentialAccount, parts: SyncParts, own: SyncParts, base: SyncParts?, index: SyncLocalIndex) -> Plan {
        var plan = Plan()
        for part in SyncPart.allCases {
            switch classify(incoming: parts.hash(of: part), local: own.hash(of: part), base: base?.hash(of: part)) {
            case .remoteChanged:
                plan.taking.parts.insert(part)
            case .bothChanged, .noCommonBase:
                plan.conflicts.append(part)
            default:
                break
            }
        }
        func hashes(_ passkeys: [PasskeyPart]?) -> [Data: Data] {
            Dictionary((passkeys ?? []).map { ($0.identity, $0.hash) }) { first, _ in first }
        }
        let theirs = hashes(parts.passkeys), mine = hashes(own.passkeys), known = hashes(base?.passkeys)
        for identity in Set(theirs.keys).union(mine.keys) {
            switch classifyPasskey(incoming: theirs[identity], local: mine[identity], base: known[identity]) {
            case .new:
                let held = incoming.passkeys.first { PasskeyPart.identity(of: $0) == identity }
                    .map { !index.holders(ofCredentialID: $0.credentialID).isEmpty } ?? true
                if held {
                    plan.held.insert(identity)
                } else {
                    plan.taking.addPasskeys.insert(identity)
                }
            case .remoteChanged:
                plan.taking.dropPasskeys.insert(identity)
            case .passkeyHardConflict:
                plan.hard.insert(identity)
            default:
                break
            }
        }
        return plan
    }

    /// Merges and judges the result: nothing to change is `keep`, an account the vault would refuse is a refusal, an exporter identity
    /// another entry holds is `ambiguous`.
    private static func applying(
        _ plan: Plan, incoming: CredentialAccount, parts: SyncParts, local: CredentialAccount, own: SyncParts, version: UInt64,
        index: SyncLocalIndex
    ) -> SyncDecision {
        let next = nextBase(version: version, incoming: parts, local: own, plan: plan)
        let result = merge(local: local, incoming: incoming, taking: plan.taking)
        guard result != local else { return .keep(next) }
        return judged(result, next: next, index: index)
    }

    private static func judged(_ account: CredentialAccount, next: SyncBase, index: SyncLocalIndex) -> SyncDecision {
        guard acceptable(account) else { return .review(.refused, parts: []) }
        let clash = identities(of: account).contains { !index.holders(ofItem: $0).subtracting([account.id]).isEmpty }
        return clash ? .review(.ambiguous, parts: []) : .write(account, next)
    }

    /// An account that is not here yet: its passkeys whose credential id another entry holds are left out.
    private static func adding(_ account: CredentialAccount, incoming: SyncParts, version: UInt64, index: SyncLocalIndex) -> SyncDecision {
        var added = account
        var parts = incoming
        let held = Set(account.passkeys.filter { !index.holders(ofCredentialID: $0.credentialID).isEmpty }.map { PasskeyPart.identity(of: $0) })
        if !held.isEmpty {
            added.passkeys.removeAll { held.contains(PasskeyPart.identity(of: $0)) }
            parts.passkeys.removeAll { held.contains($0.identity) }
        }
        return judged(added, next: SyncBase(version: version, parts: parts), index: index)
    }

    /// The base to record after applying `incoming`: its parts, except that a hard-conflicted passkey takes the local hash and a held
    /// one is left out, so neither Mac uploads again because of either and nothing loops.
    private static func nextBase(version: UInt64, incoming: SyncParts, local: SyncParts, plan: Plan) -> SyncBase {
        var parts = incoming
        parts.passkeys = incoming.passkeys.compactMap { passkey in
            if plan.held.contains(passkey.identity) {
                return nil
            }
            if plan.hard.contains(passkey.identity), let own = local.passkeys.first(where: { $0.identity == passkey.identity }) {
                return PasskeyPart(identity: passkey.identity, hash: own.hash)
            }
            return passkey
        }
        return SyncBase(version: version, parts: parts)
    }

    /// The exporter identity of `account` and of every item merged into it.
    static func identities(of account: CredentialAccount) -> [CredentialExchangeCodec.ExternalItemID] {
        [try? CredentialExchangeCodec.externalItemID(for: account)].compactMap { $0 } + (account.mergedFrom ?? []).map(\.identity)
    }

    /// What the vault accepts of one account (the store's own checks).
    private static func acceptable(_ account: CredentialAccount) -> Bool {
        guard (try? account.validate()) != nil, let live = try? CredentialVaultCrypto.liveBytes(of: account),
              let stored = try? CredentialVaultCrypto.storedBytes(of: account)
        else { return false }
        return live <= CredentialVaultLimits.accountBytes && stored <= CredentialVaultLimits.encodedAccountBytes
    }
}
