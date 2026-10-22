// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// Copying a credential's values to the clipboard from the list, the editor and History. Every copy reads the vault under the
/// current unlock first, like every Show: a locked vault or a stale authorization copies nothing, and a secret goes out with the
/// concealed marker (`deliver`). Only a hidden value of a card or an identity document adds a prompt (Touch ID).
extension CredentialSettingsModel {
    /// Puts one part of a credential on the clipboard. A draft or a History version copies only while the session it was read in
    /// is the current one. A History version never yields a verification code: its setup key stays out of the clipboard.
    /// `now` is read after the last suspension so a step boundary crossed while waiting yields the new code.
    func copy(
        _ part: CredentialCopyPart,
        of source: CredentialCopySource,
        now: @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) async throws {
        let bound: UInt64?
        switch source {
        case .stored:
            bound = nil
        case .draft, .version:
            guard let live else { throw CredentialVaultError.unauthorized }
            bound = live.epoch
        }
        let (epoch, snapshot) = try await authorizedSnapshot(epoch: bound)
        let parts = try copyParts(of: source, in: snapshot, epoch: epoch)
        // A card's or an ID document's hidden value asks for Touch ID on every copy from the list or History. The editor was opened
        // with that authentication (`beginEditing`), so its own copies don't ask again.
        if source != .draft, parts.isSensitive(part) {
            try await verifyUser(String(localized: "copy a saved card or document detail"))
            try Task.checkCancellation()
        }
        try deliver(epoch: epoch, notice: part.copiedNotice) { try parts.value(of: part, now: now) }
    }

    private func copyParts(of source: CredentialCopySource, in snapshot: StoreSnapshot, epoch: UInt64) throws -> CredentialCopyParts {
        switch source {
        case .stored(let id):
            guard let account = snapshot.accounts.first(where: { $0.id == id }) else { throw CredentialVaultError.invalidData }
            return CredentialCopyParts(account)
        case .draft:
            guard let live, live.epoch == epoch else { throw CredentialVaultError.unauthorized }
            guard let draft = live.draft else { throw CredentialVaultError.invalidData }
            return CredentialCopyParts(draft)
        case .version:
            guard let live, live.epoch == epoch else { throw CredentialVaultError.unauthorized }
            guard let version = live.history?.shown else { throw CredentialVaultError.invalidData }
            return CredentialCopyParts(version.account, allowsCode: false)
        }
    }

    /// The one clipboard exit. `produce` runs first, so whatever it costs (a code calculation, a clock read)
    /// is over before the last authorization and cancellation check; a failure leaves the pasteboard untouched.
    /// A secret also carries the concealed marker, which clipboard managers skip.
    func deliver(epoch: UInt64, notice: LocalizedStringResource, _ produce: () throws -> CredentialCopyValue) throws {
        let value = try produce()
        try Task.checkCancellation()
        guard manager?.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        pasteboard.declareTypes(value.isSecret ? [.string, Self.concealedType] : [.string], owner: nil)
        pasteboard.setString(value.text, forType: .string)
        if value.isSecret {
            pasteboard.setString("", forType: Self.concealedType)
        }
        showNotice(notice)
    }

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
}
