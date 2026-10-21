// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices

/// What a vault choice came to: a vault, the way out to the system's authenticator (a passkey request only), or nothing
/// (no usable vault, or the user canceled).
enum VaultSelection {
    case vault(CredentialManager)
    case handOff
    case none
}

extension VaultRoute {
    /// The manager a browser action may use: the routed one, or the vault the user picks in `VaultChoicePrompt`. Selection only:
    /// nothing is unlocked here, so a caller that unlocks does so after revalidating its own page, frame, offer and lifecycle (the
    /// prompt suspends, and a lock or sleep while it was open must not be followed by an unlock the user never asked for then).
    /// `nil` when there is no usable vault or the user canceled.
    func resolve(profile: Profile, in anchor: @autoclosure () -> ASPresentationAnchor) async -> CredentialManager? {
        guard case .vault(let manager) = await select(profile: profile, offersHandOff: false, in: anchor()) else { return nil }
        return manager
    }

    /// `resolve`, for a request that can also be answered by the system's authenticator: its prompt then offers that as a
    /// choice, and choosing it is an answer that unlocks nothing.
    func select(
        profile: Profile, offersHandOff: Bool, continuesInChromium: Bool = false, in anchor: @autoclosure () -> ASPresentationAnchor
    ) async -> VaultSelection {
        let candidates: [VaultListing]
        let reason: VaultChoiceReason
        switch self {
        case .manager(let manager):
            return .vault(manager)
        case .unavailable:
            return .none
        case .needsUnlock(let listing):
            (candidates, reason) = ([listing], .defaultLocked)
        case .needsChoice(let listings, let why):
            (candidates, reason) = (listings, why)
        }
        switch await VaultChoicePrompt.present(
            candidates, reason: reason, profileID: profile.id, offersHandOff: offersHandOff,
            continuesInChromium: continuesInChromium, in: anchor()
        ) {
        case .vault(let vaultID):
            return (try? CredentialManager.forVault(profile, vaultID: vaultID)).map(VaultSelection.vault) ?? .none
        case .handOff:
            return .handOff
        case nil:
            return .none
        }
    }
}

extension CredentialRouting {
    /// Which vault serves a passkey assertion for `rpID`. Passkeys scope to the relying party, not to a password origin, so the
    /// holders are the unlocked vaults whose own snapshot (read under that vault's lease) has a matching passkey; a locked vault is
    /// never read. One holder is the vault, several are a choice among only those. With no unlocked holder and a locked vault that
    /// may hold it, the answer is that vault's unlock (alone) or a choice among all; with nothing locked, the password-origin
    /// route decides, and the ceremony then tells the user there is no passkey.
    static func route(profile: Profile, origin: String, passkeyRPID rpID: String, allowed: [Data]) async -> VaultRoute {
        guard let store = try? CredentialManager.store(for: profile),
              case .provisional = await store.openState(),
              let listing = try? await store.listing(), !listing.isEmpty else { return .unavailable }
        let active = Dictionary(uniqueKeysWithValues: listing.map { ($0.vaultID, $0) })
        let unlocked = CredentialManager.unlockedManagers(for: profile).filter { active[$0.vaultID] != nil }
        var holders: [CredentialManager] = []
        for manager in unlocked {
            guard let snapshot = try? await manager.snapshot() else { continue }
            if !WebsiteAuthenticator.assertionCandidates(snapshot.accounts, rpID: rpID, allowed: allowed).isEmpty {
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
        guard unlocked.count < listing.count else {
            return await route(profile: profile, origin: origin, username: nil)
        }
        let ordered = listing.sorted { $0.ordinal < $1.ordinal }
        return ordered.count == 1 ? .needsUnlock(ordered[0]) : .needsChoice(ordered, reason: .noneMatchedLockedExists)
    }
}
