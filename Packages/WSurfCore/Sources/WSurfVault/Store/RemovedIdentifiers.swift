// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The non-secret identifiers of a credential that sits in a vault's Trash or is recorded as a tombstone. Import
/// classification matches an incoming item against these identifiers, never against secret content (§13.3).
///
/// Producer contract (Task 8): one account-level row (`passkeyCredentialID == nil`) per removed account, plus one row per
/// removed passkey (`passkeyCredentialID`/`rpID` set). `exchangeAccountID`/`exchangeItemID` are the account's stored
/// values as they are, `nil` for a native account: the classifier derives the same fallback (the account's own UUID
/// bytes, `CredentialExchangeCodec.externalID`) that live accounts and exports use, then matches exactly.
public nonisolated struct RemovedIdentifier: Equatable, Sendable {
    public let entryID: UUID
    public let isTombstone: Bool
    public let accountID: UUID
    let exchangeAccountID: Data?
    let exchangeItemID: Data?
    let passkeyCredentialID: Data?
    let rpID: String?
    /// When the entry went to Trash, or, for a tombstone, when it was purged. A date only, read from the body that is opened for the
    /// identifiers anyway; the import report shows it and nothing else uses it.
    public var removedAt: Date?
    /// What the removed account stood for (`ImportMemoryKey.removedTrace`): on the account-level row only, `nil` on a passkey's row and
    /// for a credential removed from an account that stays. Keyed digests, never a value: read from the Trash entry's snapshot (with the
    /// digests of its password and note, which its History holds in full), or kept in the tombstone when it was purged (its logins only).
    public var trace: ImportTrace?

    /// The removed credential had no item of another app (it was saved here or came from a file), so no exporter id names it.
    public var hasNoExporterItem: Bool {
        exchangeItemID == nil
    }
}

public nonisolated struct RemovedIdentifiers: Equatable, Sendable {
    public let items: [RemovedIdentifier]

    /// What each removed account leaves for a Mac that never held it (`RemovedMemory`), by account id: the logins of its Trash entry and
    /// its tombstones together, and the first ids they name, only where an import could match something. Only a whole account has a
    /// trace, so a credential removed from an account that stays adds nothing. Never the digest of a password or a note.
    public var memories: [UUID: RemovedMemory] {
        var found: [UUID: RemovedMemory] = [:]
        for item in items.sorted(by: { !$0.isTombstone && $1.isTombstone }) where item.passkeyCredentialID == nil {
            guard let trace = item.trace else { continue }
            var memory = found[item.accountID] ?? RemovedMemory()
            memory = RemovedMemory(
                logins: ImportTrace(logins: memory.logins).adding(trace.logins), exchangeAccountID: memory.exchangeAccountID ?? item.exchangeAccountID,
                exchangeItemID: memory.exchangeItemID ?? item.exchangeItemID
            )
            found[item.accountID] = memory
        }
        return found.filter { !$0.value.isEmpty }
    }
}
