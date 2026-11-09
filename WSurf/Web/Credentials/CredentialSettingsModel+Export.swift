// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AuthenticationServices
import Foundation
import WSurfVault

/// Sending the selection to another app, or writing it as a CSV file. Both prove the selection against the vault first, and both ask
/// for Touch ID once before a passkey, a password, a code, a card or an identity document leaves the vault (`+PasswordPrivacy`).
extension CredentialSettingsModel {
    /// `epoch` is the one the selection was made at; a lock, a re-unlock or a change to a selected account since the page
    /// read it rejects it. A cancel before any data was passed is `.cancelled` and leaves no status; every other result is recorded.
    func exportCredentials(
        selection: [CredentialExportSelection],
        epoch: UInt64,
        in anchor: @autoclosure () -> ASPresentationAnchor
    ) async -> CredentialExportOutcome? {
        let vault = manager?.vaultID
        ownMessage = nil
        var outcome: CredentialExportOutcome?
        let sent = await perform(describe: { Self.exportMessage(for: $0) }) {
            let stamps = try await self.exportStamps(epoch: epoch)
            // Asked before the system's sheet. The summaries are the ones the stamps vouch for: an account that changed since is
            // refused by the export itself.
            if let reason = Self.exportReason(selection, in: self.summaries) {
                guard try await self.verifyOwner(reason) == epoch else { throw CredentialVaultError.unauthorized }
            }
            outcome = try await self.exchange.exportCredentials(
                selection: selection, expectedStamps: stamps, epoch: epoch, from: $0, in: anchor()
            )
        }
        // The page showed an older vault than the one on disk: read it again, or every retry would fail the same way.
        if !sent, ownMessage?.message.kind == .exportSelectionChanged {
            await load()
        }
        if let outcome, outcome != .cancelled {
            ownMessage = outcome.message.map { ($0, vault) }
        }
        return outcome
    }

    /// Writes the selection as a plain-text CSV at `url`, which the user chose in the save panel the caller ran BEFORE this
    /// call, so the stamps are proved after it. Returns whether a file was written; every other result leaves `url` as it was.
    @discardableResult
    func exportCSV(selection: [CredentialExportSelection], epoch: UInt64, to url: URL) async -> Bool {
        let vault = manager?.vaultID
        ownMessage = nil
        var rows: Int?
        let saved = await perform(describe: { Self.exportMessage(for: $0) }) {
            let stamps = try await self.exportStamps(epoch: epoch)
            // A file of passwords asks first, like an export to another app; a CSV file carries no code, card or document.
            if CredentialExportSelection.sendsPasswordsOrCodes(selection, in: self.summaries) {
                guard try await self.verifyOwner(String(localized: "export saved passwords")) == epoch else {
                    throw CredentialVaultError.unauthorized
                }
            }
            rows = try await self.exchange.exportCSV(selection: selection, expectedStamps: stamps, epoch: epoch, from: $0, to: url)
        }
        if !saved, ownMessage?.message.kind == .exportSelectionChanged {
            await load()
        }
        if saved, let rows {
            ownMessage = (.csvExported(rows: rows), vault)
        }
        return saved
    }

    private static func exportMessage(for error: any Error) -> String? {
        if case WebsiteAuthenticatorError.notAllowed = error {
            return String(localized: "Authentication didn’t finish. Nothing was exported.")
        }
        return message(for: error)
    }

    /// The stamps the selection was made against; after this page's own write, a fresh read of the same revision stands in.
    private func exportStamps(epoch: UInt64) async throws -> [UUID: AccountStamp] {
        guard let live, live.epoch == epoch else { throw CredentialTransferFailure(message: .exportSelectionChanged()) }
        if let known = live.knownStamps {
            return known
        }
        let (_, snapshot) = try await authorizedSnapshot(epoch: epoch)
        guard snapshot.revision == live.revision else {
            throw CredentialTransferFailure(message: .exportSelectionChanged())
        }
        return snapshot.stamps
    }
}
