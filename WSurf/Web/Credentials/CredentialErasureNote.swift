// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What deleting a profile does to its credential vaults, told only as far as it can be known without asking for a passkey:
/// a vault that is open reports its verified counts, and one that is locked (or can't be read) says its contents are unknown and
/// may contain recoverable items, never "empty". The vaults are erased with the profile either way and WSurf has no undo; the
/// note says nothing about copies made elsewhere.
@MainActor
enum CredentialErasureNote {
    struct Vault: Equatable, Sendable {
        let name: String
        /// `nil` while the vault is locked or can't be read.
        let credentials: Int?
        let trash: Int?
    }

    static func text(_ vaults: [Vault]) -> String {
        let lines = vaults.map { vault -> String in
            guard let credentials = vault.credentials, let trash = vault.trash else {
                return String(localized: "“\(vault.name)” is locked, so what it holds is unknown and may contain recoverable items")
            }
            return String(localized: "“\(vault.name)” holds \(credentials) credentials and \(trash) in Trash")
        }
        return String(localized: "Its credential vaults, with their Trash and earlier versions, are erased with it and WSurf can’t undo this: \(lines.joined(separator: "; ")).")
    }

    /// `nil` when the profile has no vault to mention.
    static func note(for profile: Profile) async -> String? {
        guard !profile.isPrivate, let store = try? CredentialManager.store(for: profile) else { return nil }
        let unreadable = String(localized: "Its credential files can’t be read right now, so they may contain recoverable items. They are erased with it and WSurf can’t undo this.")
        switch await store.openState() {
        case .firstRun:
            return nil
        case .failClosed:
            return unreadable
        default:
            break
        }
        guard let listing = try? await store.listing() else { return unreadable }
        let open = CredentialManager.unlockedManagers(for: profile)
        var vaults: [Vault] = []
        for listed in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            var credentials: Int?
            var trash: Int?
            if let manager = open.first(where: { $0.vaultID == listed.vaultID }),
               let snapshot = try? await manager.snapshot(), let counts = try? await manager.historyCounts() {
                credentials = snapshot.accounts.count
                trash = counts.trash.trashEntry
            }
            vaults.append(Vault(name: listed.displayName, credentials: credentials, trash: trash))
        }
        return vaults.isEmpty ? nil : text(vaults)
    }
}
