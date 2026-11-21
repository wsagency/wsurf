// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore
import WSurfVault

/// What deleting a profile does to its credential vaults, told only as far as it can be known without asking for a passkey:
/// a vault that is open reports its verified counts, and one that is locked (or can't be read) says its contents are unknown and
/// may contain recoverable items, never "empty". The vaults are erased with the profile either way and WSurf has no undo; the
/// note says nothing about copies made elsewhere.
@MainActor
struct CredentialErasureNote {
    let text: String?
    let vaultRemovals: Set<VaultProfileRemoval>
    var sharedCopies: Set<CloudProfileInstance> = []
    private var cloudVaultNames: [String] = []

    var message: String {
        var notes = [String(localized: "Deleting this profile removes its tabs, history, and sign-ins from this Mac. Downloads stay in the Downloads folder.")]
        if let text {
            notes.append(text)
        }
        if !cloudVaultNames.isEmpty {
            let names = cloudVaultNames.formatted(.list(type: .and))
            notes.append(String(localized: "WSurf will also remove \(names) from iCloud. Your other devices keep their copies. To keep a vault in iCloud, turn off Sync with iCloud for it first."))
        }
        if !sharedCopies.isEmpty || !vaultRemovals.isEmpty {
            notes.append(String(localized: "Macs sharing this profile will ask whether to create a new iCloud instance or delete their local copy."))
        }
        return notes.joined(separator: "\n\n")
    }

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

    /// `nil` when the profile has no vault to mention. An open vault's credentials are counted from its candidates
    /// (`autofillCandidates`), which hold no secret.
    static func warning(for profile: Profile, rechecking consent: Set<VaultProfileRemoval>? = nil, localOnly: Bool = false) async throws -> Self {
        var copies: Set<CloudProfileInstance> = []
        if !localOnly, !profile.isPrivate, !profile.isOriginal, let service = CloudSync.shared {
            copies = service.profileStore?.cloudLedger.detached[profile.id] ?? []
            copies.formUnion(service.settingsSync?.memberships(of: profile.id) ?? [])
            if let linked = service.sharedSpaces?.membership(of: profile.id) {
                copies.insert(linked)
            }
        }
        let empty = Self(text: nil, vaultRemovals: [], sharedCopies: copies)
        guard !profile.isPrivate else { return empty }
        func unreadable() throws -> Self {
            if consent?.isEmpty == false {
                throw Profile.VaultListUnavailable()
            }
            let text = String(localized: "Its credential files can’t be read right now, so they may contain recoverable items. They are erased with it and WSurf can’t undo this.")
            return Self(text: text, vaultRemovals: [], sharedCopies: copies)
        }
        guard let store = try? CredentialManager.store(for: profile) else { return try unreadable() }
        switch await store.openState() {
        case .firstRun:
            return empty
        case .failClosed:
            return try unreadable()
        default:
            break
        }
        guard let listing = try? await store.listing() else { return try unreadable() }
        let open = CredentialManager.unlockedManagers(for: profile)
        var vaults: [Vault] = []
        for listed in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            var credentials: Int?
            var trash: Int?
            if let manager = open.first(where: { $0.vaultID == listed.vaultID }),
               let read = try? await manager.autofillCandidates(), let counts = try? await manager.historyCounts() {
                credentials = read.candidates.count
                trash = counts.trash.trashEntry
            }
            vaults.append(Vault(name: listed.displayName, credentials: credentials, trash: trash))
        }
        // Counting may suspend. A newly added or already removed vault was never part of this warning.
        let shown = Set(listing.map(\.vaultID))
        let removals: Set<VaultProfileRemoval> = shown.isEmpty ? [] : try await profile.vaultRemovals(rechecking: consent).filter { shown.contains($0.vaultID) }
        let ids = Set(removals.map(\.vaultID))
        return Self(text: vaults.isEmpty ? nil : text(vaults), vaultRemovals: removals, sharedCopies: copies, cloudVaultNames: listing.filter { ids.contains($0.vaultID) }.map(\.displayName))
    }
}
