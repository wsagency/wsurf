// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The History panel beside the editor (spec §14.1): a credential's earlier versions, read-only. Copying a value into the draft
/// changes only the draft; saving is the ordinary commit, which keeps the value it replaces as a new earlier version. Everything
/// decrypted lives in the authorization session (`HistoryState`), so a lock or another unlock drops it.
extension CredentialSettingsModel {
    var history: HistoryState? {
        live?.history
    }

    /// Opens History for `accountID`: starts editing it unless the editor is already on it, then reads the newest earlier values.
    /// A vault that changed since the draft opened is refused, so the versions always describe the stored credential the draft is
    /// based on.
    func openHistory(accountID: UUID) async throws {
        if draft?.accountID != accountID {
            try await beginEditing(accountID: accountID)
        }
        guard let live, let draft = live.draft, draft.accountID == accountID, let manager else { throw CredentialVaultError.unauthorized }
        let (epoch, snapshot) = try await authorizedSnapshot(epoch: live.epoch)
        guard let current = snapshot.accounts.first(where: { $0.id == accountID }) else { throw CredentialVaultError.invalidData }
        guard snapshot.revision == draft.revision else { throw CredentialVaultError.staleRevision }
        let page = try await manager.revisionValuePage(accountID: accountID, after: nil)
        let versions = try await Self.versions(current: current, revisions: page.items)
        try update(epoch) {
            guard $0.draft?.accountID == accountID else { return }
            $0.history = HistoryState(accountID: accountID, revision: snapshot.revision, values: page.items, next: page.next, versions: versions)
        }
    }

    /// The next page of older values, appended to what is loaded. A page that no longer follows the one shown (History closed or
    /// reopened meanwhile) is dropped.
    func loadOlderVersions() async throws {
        guard let live, let state = live.history, let after = state.next, let manager, let current = state.versions.first?.account else { return }
        let page = try await manager.revisionValuePage(accountID: state.accountID, after: after)
        try Task.checkCancellation()
        let known = Set(state.values.map(\.item.id))
        let values = state.values + page.items.filter { !known.contains($0.item.id) }
        let versions = try await Self.versions(current: current, revisions: values)
        // Values shown unmasked were shown under a Touch ID check of what was loaded then; an older card or document loaded now is
        // masked again until it is shown with its own check.
        let addsSensitive = versions.contains { Self.holdsSensitiveItems($0) } && !state.versions.contains { Self.holdsSensitiveItems($0) }
        try update(live.epoch) {
            guard $0.history?.accountID == state.accountID, $0.history?.next == after else { return }
            $0.history?.values = values
            $0.history?.next = page.next
            $0.history?.versions = versions
            if addsSensitive {
                $0.history?.revealsSecrets = false
            }
        }
    }

    /// Shows `id` (a version's `id`, `nil` for the current one) against the draft. An id History does not list changes nothing.
    func selectVersion(_ id: UUID?) {
        guard let live, live.history?.versions.contains(where: { $0.id == id }) == true else { return }
        try? update(live.epoch) { $0.history?.selected = id }
    }

    /// Unmasks the passwords, notes and items History shows. The current unlock is the authority, as for every other Show: the vault
    /// is read under it first. An earlier version that held a card or an identity document also asks for Touch ID.
    func revealHistorySecrets() async throws {
        guard let live, let history = live.history else { throw CredentialVaultError.invalidData }
        let (epoch, _) = try await authorizedSnapshot(epoch: live.epoch)
        if let sensitive = history.versions.first(where: Self.holdsSensitiveItems) {
            try await verifySensitiveItems(of: sensitive.account)
        }
        try update(epoch) { $0.history?.revealsSecrets = true }
    }

    private static func holdsSensitiveItems(_ version: CredentialVersion) -> Bool {
        version.account.secureItems?.contains { $0.kind.isSensitive } == true
    }

    func hideHistorySecrets() {
        guard let live else { return }
        try? update(live.epoch) { $0.history?.revealsSecrets = false }
    }

    /// Puts one part of a version into the draft. Nothing is written until the user chooses Save. Items go through `copyItemsToDraft`.
    func copyToDraft(_ field: CredentialHistoryField, from versionID: UUID?) {
        guard field != .secureItems, let version = live?.history?.versions.first(where: { $0.id == versionID }) else { return }
        draft?.take(field, from: version.account)
    }

    /// Puts a version's cards and other items into the draft. A card or an identity document asks for Touch ID first: the editor was
    /// opened without it when the credential holds none now, and the draft shows and copies what it holds without asking again.
    func copyItemsToDraft(from versionID: UUID?) async throws {
        guard let live, let version = live.history?.versions.first(where: { $0.id == versionID }) else { return }
        try await verifySensitiveItems(of: version.account)
        guard self.live?.epoch == live.epoch, self.live?.history?.versions.contains(where: { $0.id == versionID }) == true else {
            throw CredentialVaultError.unauthorized
        }
        draft?.take(.secureItems, from: version.account)
    }

    /// Closes History and drops what it decrypted; the editor stays open.
    func closeHistory() {
        guard let live else { return }
        try? update(live.epoch) { $0.history = nil }
    }

    /// Rebuilt away from the main actor: a note can be megabytes, and a page holds up to 50 values.
    private static func versions(current: CredentialAccount, revisions: [RevisionValue]) async throws -> [CredentialVersion] {
        try await Task.detached { try CredentialHistory.versions(current: current, revisions: revisions) }.value
    }
}
