// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The one thing the user is told when a credential transfer ends or is refused (spec §13.5). Only the factories below
/// build one, so `kind`, `action`, `receipt` and `text` cannot disagree: a receipt exists for `.succeeded` and for nothing
/// else (no other message claims that anything landed). Import endings that drop the staged data say the transfer was
/// discarded and must be started again from Passwords; export endings never say that, since nothing was imported or dropped.
/// "Dropped" means WSurf released every reference it owns; it never claims memory was erased.
///
/// Needs `VaultCommitReceipt: Equatable` (a one-field struct) for the synthesized `==`; that conformance is added where the
/// receipt type lives, not here.
nonisolated struct CredentialTransferMessage: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case alreadyInProgress, discarded, applyFailed(operation: String), succeeded, mayHaveLanded, nothingImported
        /// The codec's own structural position of the bad record (indices only, never content); nil when it names none.
        case malformed(record: CredentialExchangeError.Record?)
        /// The system accepted the hand-off. Says nothing about the other app.
        case handedToSystem
        /// The hand-off had started and then failed or was cancelled: whether data left is unknown.
        case exportUncertain
        /// The export ended before any credential data was passed to the system (failure, not a user cancel).
        case exportNotSent
        /// The selected accounts changed or the vault locked before the hand-off, so nothing was sent.
        case exportSelectionChanged
    }

    /// The next step the consumer offers; the terminal-state policy lives here, not in the text. `exportAgain` is the user
    /// re-sending the discarded INBOUND import from the other app (Passwords); it is never WSurf's own outgoing export.
    enum Action: Equatable, Sendable { case none, exportAgain, checkSavedCredentials }

    let kind: Kind
    let action: Action
    /// Non-nil only for `.succeeded`.
    let receipt: VaultCommitReceipt?
    /// Production wording; tests never assert on it (the operator reads it at Gate B).
    let text: String

    private init(_ kind: Kind, _ action: Action, receipt: VaultCommitReceipt? = nil, _ text: String) {
        self.kind = kind
        self.action = action
        self.receipt = receipt
        self.text = text
    }

    // MARK: Import

    /// A second token arrived while one is pending, claimed or staged. The pending import is untouched.
    static func alreadyInProgress() -> Self {
        Self(.alreadyInProgress, .none, String(localized: """
            Another transfer is already in progress; this one was not received. \
            Finish or cancel it, then export again from Passwords.
            """))
    }

    /// The transfer ended BEFORE any write started: lock, epoch change, lease expiry, a cancel before the write, a spent token,
    /// or an account the plan touches changed since the preview. Nothing was written. Never used once the write has begun.
    static func discarded() -> Self {
        Self(.discarded, .exportAgain, String(localized: """
            This transfer was discarded. WSurf dropped its copy of the imported data and can no longer use it. \
            No data was written. Export again from Passwords.
            """))
    }

    /// Capacity, collision or write error. `operation` is a static localized label of what failed, never system error text.
    static func applyFailed(operation: String) -> Self {
        Self(.applyFailed(operation: operation), .exportAgain, String(localized: """
            \(operation) failed and nothing was written. This transfer was discarded. Export again from Passwords.
            """))
    }

    static func succeeded(_ outcome: CredentialImportOutcome, receipt: VaultCommitReceipt) -> Self {
        Self(.succeeded, .none, receipt: receipt, String(localized: """
            Imported into WSurf: \(outcome.added) added, \(outcome.updated) updated. Nothing was changed in the other app.
            """))
    }

    /// The write had begun and its result is unknown (lock, user cancel, lease or epoch loss while it ran): it may or may not
    /// have landed, so this is neither a discard nor a success, and it names no cause.
    static func mayHaveLanded() -> Self {
        Self(.mayHaveLanded, .checkSavedCredentials, String(localized: """
            WSurf could not confirm the result of this import. It may have been saved. \
            Check Saved Credentials before exporting again.
            """))
    }

    /// Every incoming item was skipped or already identical.
    static func nothingImported() -> Self {
        Self(.nothingImported, .none, String(localized: "Nothing was imported."))
    }

    /// Any bad record rejects the whole payload; only its structural position is shown, never content or the underlying error.
    static func malformed(record: CredentialExchangeError.Record?) -> Self {
        let culprit = record.map { String(localized: "The problem is at \($0.description).") }
            ?? String(localized: "WSurf could not tell which record is at fault.")
        return Self(.malformed(record: record), .exportAgain, String(localized: """
            The transfer could not be read, so nothing was imported. \(culprit) \
            This transfer was discarded. Export again from Passwords.
            """))
    }

    // MARK: Export

    /// The system accepted the hand-off. It never reports whether the other app received or imported anything.
    static func handedToSystem() -> Self {
        Self(.handedToSystem, .none, String(localized: """
            WSurf handed the selected credentials to the system. \
            WSurf cannot tell whether the other app received or imported them.
            """))
    }

    /// The hand-off call started and then failed or was cancelled. WSurf does not retry and records no export snapshot.
    static func exportUncertain() -> Self {
        Self(.exportUncertain, .none, String(localized: """
            WSurf cannot confirm whether the credentials left. Check the other app before exporting again. \
            WSurf did not retry and recorded nothing about this export.
            """))
    }

    /// Failed before any credential data was passed to the system.
    static func exportNotSent() -> Self {
        Self(.exportNotSent, .none, String(localized: """
            The export did not start, so no credentials were sent. Nothing was changed in WSurf.
            """))
    }

    /// A selected account changed, or WSurf locked, before the hand-off.
    static func exportSelectionChanged() -> Self {
        Self(.exportSelectionChanged, .none, String(localized: """
            A selected credential changed or WSurf was locked, so no credentials were sent. Review the selection and export again.
            """))
    }
}

/// How a transfer operation that one window started ends without a result: the message it carries was already delivered
/// to the coordinator's `onMessage`, and the window shows it, so no sink has to route it back to its owner.
nonisolated struct CredentialTransferFailure: Error, Equatable, Sendable {
    let message: CredentialTransferMessage
}
