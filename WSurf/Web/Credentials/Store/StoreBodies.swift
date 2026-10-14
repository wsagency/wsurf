// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

// Row plaintext bodies (spec §11): the row's `kind` selects the body. Encoded with `CredentialContent.canonicalJSON`, so a body is
// immutable text once written. None of them holds a whole `CredentialAccount` except a whole-account `TrashEntryBody.snapshot`.

/// An earlier value that was superseded. `value` is the canonical JSON of exactly one typed value: `PasswordValue`, `TOTPGenerator` or
/// `MetadataProjection` (§11.1), selected by the row's `subject`; `cause` is the caller's explicit provenance, `nil` when unknown.
nonisolated struct RevisionBody: Codable, Equatable, Sendable {
    var recordedAt: Date
    var cause: String?
    var value: Data
}

/// One removed account (`scope == .account`, `snapshot` once) or one removed credential (`scope == .credential`, `label` and
/// `credentialValue`: the `PasswordValue`, `TOTPGenerator` or `WebsitePasskey` of that credential only).
nonisolated struct TrashEntryBody: Codable, Equatable, Sendable {
    var deletedAt: Date
    var scope: TransferScope
    var ownerID: UUID
    var subject: RecordSubject?
    var passkeyID: UUID?
    var label: String?
    var snapshot: CredentialAccount?
    var credentialValue: Data?
    /// A credential entry's owner's raw `exchangeAccountID`/`exchangeItemID` as they were when the credential was removed (non-secret;
    /// `nil` is a native owner that had none). A whole-account entry reads them from `snapshot` and leaves these `nil`. Never read from
    /// the live owner later: it can change or be deleted before a restore, a purge or a re-import.
    var exchangeAccountID: Data?
    var exchangeItemID: Data?
}

/// What survives a purge: identity only. No secret field exists.
nonisolated struct TombstoneBody: Codable, Equatable, Sendable {
    var entryID: UUID
    var purgedAt: Date
    var scope: TransferScope
    var ownerID: UUID
    var subject: RecordSubject?
    var passkeyCredentialID: Data?
    var rpID: String?
    var exchangeAccountID: Data?
    var exchangeItemID: Data?
}
