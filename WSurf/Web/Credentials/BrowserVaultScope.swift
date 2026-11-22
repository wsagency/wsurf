// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfVault

/// The vaults a native browser action can use. A Space stores only the owner's and vault's IDs on this Mac.
nonisolated enum BrowserVaultScope: Hashable, Sendable {
    case profile(Profile)
    case selected(owner: Profile, vaultID: UUID)
    case unavailable

    var owner: Profile? {
        switch self {
        case .profile(let profile), .selected(let profile, _):
            profile.isPrivate ? nil : profile
        case .unavailable:
            nil
        }
    }

    var isRestricted: Bool {
        if case .profile(let profile) = self {
            return profile.isPrivate
        }
        return true
    }

    @MainActor func contains(_ manager: CredentialManager) -> Bool {
        guard owner?.id == manager.profileID else { return false }
        if case .selected(_, let id) = self {
            return id == manager.vaultID
        }
        return true
    }

    @MainActor var unlockedManagers: [CredentialManager] {
        guard let owner else { return [] }
        return CredentialManager.unlockedManagers(for: owner).filter { contains($0) }
    }

    @MainActor func listing() async throws -> [VaultListing] {
        guard let owner else { throw CredentialVaultError.unauthorized }
        let store = try CredentialManager.store(for: owner)
        guard await store.openState().isProvisional else { throw CredentialVaultError.missingVault }
        let rows = try await store.listing()
        guard case .selected(_, let id) = self else { return rows }
        guard let row = rows.first(where: { $0.vaultID == id }) else { throw CredentialVaultError.missingVault }
        return [row]
    }

    @MainActor func manager(for vaultID: UUID) throws -> CredentialManager {
        guard let owner else { throw CredentialVaultError.unauthorized }
        if case .selected(_, let id) = self, id != vaultID {
            throw CredentialVaultError.unauthorized
        }
        return try CredentialManager.forVault(owner, vaultID: vaultID)
    }

    @MainActor func defaultVaultID() async -> UUID? {
        if case .selected(_, let id) = self {
            return id
        }
        guard let owner else { return nil }
        return try? await CredentialManager.store(for: owner).defaultVaultID()
    }
}

extension BrowserModel {
    /// An ordinary tab follows its own Space, even in the background. Profile pins follow the Space showing them in this window.
    func vaultScope(for tab: BrowserTab? = nil) -> BrowserVaultScope {
        let profile = context.profile
        guard !profile.isPrivate, pendingSpaceStore == nil else { return .unavailable }
        if let tab, tab.context !== context || unplacedSpaceRows.contains(.tab(tab.id)) {
            return .unavailable
        }
        return vaultScope(in: tab?.spaceID ?? currentSpaceID)
    }

    func vaultScope(in spaceID: UUID?) -> BrowserVaultScope {
        let profile = context.profile
        guard !profile.isPrivate, pendingSpaceStore == nil else { return .unavailable }
        guard let id = spaceID else { return .profile(profile) }
        guard let space = (adoptedSpaceStore ?? context.spaces)?.space(id: id) else { return .unavailable }
        guard let reference = space.vault else { return .profile(profile) }
        let profiles = vaultProfileCatalog ?? .shared
        guard let owner = profiles.verifiedProfiles?.first(where: { $0.id == reference.profileID && !$0.isPrivate }) else { return .unavailable }
        return .selected(owner: owner, vaultID: reference.vaultID)
    }
}

extension BrowserTab {
    func bindVaultScope(to browser: BrowserModel) {
        if let previous = vaultBrowser, previous !== browser, previous.vaultScope(for: self) != browser.vaultScope(for: self) {
            invalidateSpaceVault()
        }
        vaultBrowser = browser
    }

    func invalidateSpaceVault() {
        guard let page = liveView else { return }
        autofillSave.resetDismissalsForNavigation()
        autofillSave.invalidateVaultContext(in: page)
    }
}
