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
nonisolated struct RemovedIdentifier: Equatable, Sendable {
    let entryID: UUID
    let isTombstone: Bool
    let accountID: UUID
    let exchangeAccountID: Data?
    let exchangeItemID: Data?
    let passkeyCredentialID: Data?
    let rpID: String?
}

nonisolated struct RemovedIdentifiers: Equatable, Sendable {
    let items: [RemovedIdentifier]
}
