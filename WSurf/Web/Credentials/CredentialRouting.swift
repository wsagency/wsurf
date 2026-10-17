// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum VaultChoiceReason: Sendable {
    /// The match is in more than one unlocked vault.
    case matchInSeveral
    /// Nothing matched in the unlocked vaults and another vault is locked, so the match may be there.
    case noneMatchedLockedExists
    /// A new login would go to the default vault, which is locked.
    case defaultLocked
}

enum VaultRoute {
    case manager(CredentialManager)
    case needsChoice([VaultListing], reason: VaultChoiceReason)
    case needsUnlock(VaultListing)
    /// The browser cannot use a vault now: private browsing, no vault yet, a vault still to migrate, or an unreadable store.
    /// Migration and creation are Settings actions, never a side effect of a page.
    case unavailable
}

/// Which one vault a write or a lookup belongs to. Locked vaults are never read; ambiguity is an explicit choice, never a guess.
enum CredentialRouting {
    /// Whether the profile has never made a vault, which is the only state a page may suggest setting one up in. A vault from an
    /// older format that still has to be upgraded, an unreadable store and a private context are not: those are fixed in Settings.
    static func profileNeedsFirstVault(_ profile: Profile) async -> Bool {
        guard let store = try? CredentialManager.store(for: profile) else { return false }
        return await store.openState() == .firstRun
    }

    /// Whether the profile has a vault the browser can use at all: the test every route makes before it looks at any vault. Looking
    /// lists the vaults and reads nothing from them.
    static func hasUsableVault(profile: Profile) async -> Bool {
        guard let store = try? CredentialManager.store(for: profile), case .provisional = await store.openState(),
              let listing = try? await store.listing() else { return false }
        return !listing.isEmpty
    }

    static func route(profile: Profile, origin: String, username: String?) async -> VaultRoute {
        guard let store = try? CredentialManager.store(for: profile),
              case .provisional = await store.openState(),
              let listing = try? await store.listing(), !listing.isEmpty else { return .unavailable }
        let active = Dictionary(uniqueKeysWithValues: listing.map { ($0.vaultID, $0) })
        let unlocked = CredentialManager.unlockedManagers(for: profile).filter { active[$0.vaultID] != nil }

        var holders: [CredentialManager] = []
        for manager in unlocked {
            guard let snapshot = try? await manager.snapshot() else { continue }
            if snapshot.accounts.contains(where: { $0.origins.contains(origin) && (username == nil || $0.username == username) }) {
                holders.append(manager)
            }
        }
        switch holders.count {
        case 1:
            return .manager(holders[0])
        case 2...:
            return .needsChoice(holders.compactMap { active[$0.vaultID] }.sorted { $0.ordinal < $1.ordinal }, reason: .matchInSeveral)
        default:
            break
        }

        // A new login goes to the default vault: the stored preference, else the first vault.
        let unlockedIDs = Set(unlocked.map(\.vaultID))
        let preferred = await store.defaultVaultID().flatMap { active[$0] } ?? listing.min { $0.ordinal < $1.ordinal }
        guard let preferred else { return .unavailable }
        if !unlockedIDs.contains(preferred.vaultID) {
            return unlockedIDs.isEmpty ? .needsUnlock(preferred) : .needsChoice(listing.sorted { $0.ordinal < $1.ordinal }, reason: .defaultLocked)
        }
        if unlockedIDs.count < listing.count {
            return .needsChoice(listing.sorted { $0.ordinal < $1.ordinal }, reason: .noneMatchedLockedExists)
        }
        return .manager(unlocked.first { $0.vaultID == preferred.vaultID } ?? unlocked[0])
    }
}
