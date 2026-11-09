// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// What the dropdown offers from the credentials vault, and after a fill, decided before anything is read.
extension AutofillSuggestions {
    /// Whether the profile has vaults and every one of them is locked. The dropdown then offers to unlock and reads nothing.
    static func allVaultsLocked(of profile: Profile) async -> Bool {
        guard !profile.isPrivate, let store = try? CredentialManager.store(for: profile), await store.openState().isProvisional,
              let listing = try? await store.listing(), !listing.isEmpty else { return false }
        let unlocked = Set(CredentialManager.unlockedManagers(for: profile).map(\.vaultID))
        return !listing.contains { unlocked.contains($0.vaultID) }
    }

    /// What a card or address field is offered from the credentials vault, decided before anything is read: nothing in a tab the
    /// assistant or a connected app controls (so no agent can have one filled into a page it reads), one row that only unlocks while
    /// every vault of the profile is locked, and otherwise the unlocked vaults' cards or addresses.
    nonisolated enum VaultItemRows: Equatable {
        case none, unlock, items
    }

    nonisolated static func vaultItemRows(kind: AutofillSaveKind, underAssistantControl: Bool, allVaultsLocked: Bool) -> VaultItemRows {
        guard kind != .password, !underAssistantControl else { return .none }
        return allVaultsLocked ? .unlock : .items
    }

    /// After a fill from "Check other logins", a login or a verification code alike, the page's website is offered to that credential
    /// ("Add Website"), so the next time it is an exact match. Nothing else offers it here.
    nonisolated static func offersWebsiteAfterFill(kind: AutofillSaveKind, fromSiblingRow: Bool) -> Bool {
        kind == .password && fromSiblingRow
    }
}
