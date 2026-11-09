// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// Touch ID or the Mac password before a saved password or verification code is shown or copied in the Credential Manager. The list
/// asks for every Show and Copy. The editor of a stored credential asks once, the first time it shows or copies one, and its History
/// shares that answer. Each action asks first and reads the vault only after the answer, so a refused prompt leaves nothing
/// decrypted on the page. A locked vault or a cancelled task asks for nothing. Cards and identity documents keep their own prompt
/// (`+SecureItems`): this answer never stands in for it.
extension CredentialSettingsModel {
    /// The default answer: the system's prompt, with a new context and no reuse each time. In a test host it refuses at once
    /// instead, so a test that injects no answer of its own fails rather than putting a system sheet on the screen.
    static let systemVerifier: @MainActor (String) async throws -> Void = { reason in
        guard !AppDatabase.isRunningTests else { throw WebsiteAuthenticatorError.notAllowed }
        try await NativeWebAuthnInteraction().verifyUser(reason: reason, until: nil)
    }

    /// Asks under the current unlock and returns its authorization epoch, which the caller then reads under. Throws before asking
    /// when the vault is locked or the task was cancelled, and after asking when the vault was locked or unlocked again meanwhile:
    /// an answer given under one unlock never reads under another.
    func verifyOwner(_ reason: String) async throws -> UInt64 {
        try Task.checkCancellation()
        guard let epoch = manager?.authorizationEpoch else { throw CredentialVaultError.unauthorized }
        try await verifyUser(reason)
        try Task.checkCancellation()
        guard manager?.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        return epoch
    }

    /// Whether the open editor shows its verification code and lets its password field show what it holds.
    var editorIsVerified: Bool {
        live?.editorIsVerified ?? false
    }

    /// The editor's one prompt. The first Show or Copy of a password or a code in the editor of a stored credential, or in its
    /// History, asks; the rest of that editor does not. Returns at once for a new credential and for an editor already verified.
    /// Throws when the answer is no, and when the editor closed or changed while the prompt was up.
    ///
    /// A password typed or generated in a stored credential's editor asks too: an edit can keep most of the stored password, and
    /// History's "Use This" can put an earlier one in.
    func verifyEditor() async throws {
        guard let live, live.draft != nil else { throw CredentialVaultError.invalidData }
        guard !live.editorIsVerified else { return }
        let editor = live.editor
        let epoch = try await verifyOwner(String(localized: "show or copy a saved password or verification code"))
        try markVerified(editor, epoch: epoch)
    }

    /// Records a prompt the user answered for `editor`. Throws when `editor` is no longer the open one, so nothing is shown for it.
    /// An editor that was verified and then replaced still names itself in `verifiedEditor`, so that alone proves nothing.
    func markVerified(_ editor: UUID, epoch: UInt64) throws {
        try update(epoch) { session in
            if session.editor == editor, session.draft != nil {
                session.verifiedEditor = editor
            }
        }
        guard let live, live.editor == editor, live.verifiedEditor == editor else { throw CredentialVaultError.unauthorized }
    }

    /// The one prompt an export asks before anything leaves the vault, naming what leaves; `nil` when it sends no passkey, password,
    /// code, card or identity document. `summaries` are the ones the export's stamps vouch for: an account that changed since is
    /// refused by the export.
    static func exportReason(_ selection: [CredentialExportSelection], in summaries: [CredentialSummary]) -> String? {
        let items = CredentialExportSelection.sendsSensitiveItems(selection, in: summaries)
        let secrets = CredentialExportSelection.sendsPasswordsOrCodes(selection, in: summaries)
        if CredentialExportSelection.sendsPasskeys(selection, in: summaries) {
            switch (secrets, items) {
            case (true, true):
                return String(localized: "export saved passkeys, passwords, cards and documents")
            case (true, false):
                return String(localized: "export saved passkeys, passwords and verification codes")
            case (false, true):
                return String(localized: "export saved passkeys, cards and documents")
            case (false, false):
                return String(localized: "export saved passkeys")
            }
        }
        if items, secrets {
            return String(localized: "export saved passwords, cards and documents")
        }
        if items {
            return String(localized: "export saved cards, documents and hidden fields")
        }
        if secrets {
            return String(localized: "export saved passwords and verification codes")
        }
        return nil
    }
}

/// A Show or a Copy found a card or an identity document that the list did not hold when it was read, so nothing asked for it:
/// nothing was shown or copied, and the list has caught up, so the next try asks.
nonisolated enum CredentialPromptError: Error, Equatable, Sendable {
    case listChanged
}

nonisolated extension CredentialExportSelection {
    /// Whether `selection` sends a passkey that `summaries` still hold: its private key leaves the vault, which needs Touch ID
    /// first. A passkey the summary no longer holds is not asked for; the export refuses an account that changed since its stamp.
    static func sendsPasskeys(_ selection: [CredentialExportSelection], in summaries: [CredentialSummary]) -> Bool {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selection.contains { chosen in
            guard !chosen.passkeyIDs.isEmpty, let summary = byID[chosen.accountID] else { return false }
            return summary.passkeys.contains { chosen.passkeyIDs.contains($0.id) }
        }
    }

    /// Whether `selection` sends a saved password or a verification code setup of `summaries`, which needs Touch ID first. A login
    /// with a username and no password sends no secret.
    static func sendsPasswordsOrCodes(_ selection: [CredentialExportSelection], in summaries: [CredentialSummary]) -> Bool {
        let byID = Dictionary(summaries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selection.contains { chosen in
            guard let summary = byID[chosen.accountID] else { return false }
            return (chosen.password && summary.hasPassword) || (chosen.totp && summary.hasTOTP)
        }
    }
}
