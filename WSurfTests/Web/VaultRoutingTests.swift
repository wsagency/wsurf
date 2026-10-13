// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Which vault a page's save or lookup belongs to, asserted through the real registry, managers and store of a profile. Only the
// native passkey prompt is stubbed (`VaultPasskeys`); a locked vault is never read, ambiguity is a choice, never a guess.

private let site = "https://example.test"

struct VaultRoutingTests {
    private func routeFor(_ profile: Profile, origin: String = site, username: String? = nil) async -> VaultRoute {
        await CredentialRouting.route(profile: profile, origin: origin, username: username)
    }

    private func vaultOf(_ route: VaultRoute) -> UUID? {
        if case .manager(let manager) = route {
            manager.vaultID
        } else {
            nil
        }
    }

    private func choiceOf(_ route: VaultRoute) -> (listing: [VaultListing], reason: VaultChoiceReason)? {
        if case .needsChoice(let listing, let reason) = route {
            (listing, reason)
        } else {
            nil
        }
    }

    private func isUnavailable(_ route: VaultRoute) -> Bool {
        if case .unavailable = route {
            true
        } else {
            false
        }
    }

    @Test func importOrAutosaveToAnUnlockedVaultNeverTouchesAnother() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let (a, b) = (vaults[0], vaults[1])
            let kept = VaultFixtures.account(username: "grace")
            try await VaultManagerFixture.save([kept], in: b)
            let before = try await b.manager.snapshot()
            let rows = try VaultManagerFixture.rows(of: b.vaultID, in: profile)
            #expect(!rows.isEmpty)

            let imported = [VaultFixtures.account(username: "ada"), VaultFixtures.account(username: "alan", origin: "https://other.test")]
            try await VaultManagerFixture.save(imported, in: a)

            let after = try await b.manager.snapshot()
            #expect(after.revision == before.revision)
            #expect(after.accounts == [kept])
            #expect(try VaultManagerFixture.rows(of: b.vaultID, in: profile) == rows)
            #expect(Set(try await a.manager.snapshot().accounts.map(\.id)) == Set(imported.map(\.id)))
        }
    }

    @Test func lockedVaultsAreNeverRead() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let (a, b) = (vaults[0], vaults[1])
            try await VaultManagerFixture.save([VaultFixtures.account(origin: "https://a.example")], in: a)
            try await VaultManagerFixture.save([VaultFixtures.account(origin: "https://b.example")], in: b)
            b.manager.lock(reason: .manual)

            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await b.manager.snapshot() }
            // The account only the locked vault holds is not found: the answer is a choice that names the vault, without its content.
            let missed = await routeFor(profile, origin: "https://b.example")
            let choice = try #require(choiceOf(missed))
            #expect(choice.reason == .noneMatchedLockedExists)
            let listed = try #require(choice.listing.first { $0.vaultID == b.vaultID })
            #expect(!listed.isUnlocked)
            #expect(listed.name == nil)
            // The unlocked vault's own account is still found.
            #expect(vaultOf(await routeFor(profile, origin: "https://a.example")) == a.vaultID)
        }
    }

    @Test func autosaveGoesToTheVaultHoldingTheMatch() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let (a, b) = (vaults[0], vaults[1])
            try await VaultManagerFixture.save([VaultFixtures.account(username: "ada")], in: b)
            // The match is in B although A is the default vault.
            #expect(vaultOf(await routeFor(profile, username: "ada")) == b.vaultID)
            #expect(vaultOf(await routeFor(profile)) == b.vaultID)

            try await VaultManagerFixture.save([VaultFixtures.account(username: "zed")], in: a)
            #expect(vaultOf(await routeFor(profile, username: "ada")) == b.vaultID)
            #expect(vaultOf(await routeFor(profile, username: "zed")) == a.vaultID)
        }
    }

    @Test func matchInSeveralUnlockedVaultsNeedsChoice() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let (a, b) = (vaults[0], vaults[1])
            try await VaultManagerFixture.save([VaultFixtures.account(username: "ada")], in: a)
            try await VaultManagerFixture.save([VaultFixtures.account(username: "ada"), VaultFixtures.account(username: "bob")], in: b)

            for username in [nil, "ada"] {
                let choice = try #require(choiceOf(await routeFor(profile, username: username)))
                #expect(choice.reason == .matchInSeveral)
                #expect(choice.listing.map(\.vaultID) == [a.vaultID, b.vaultID])
            }
            // A username only one vault holds is not ambiguous.
            #expect(vaultOf(await routeFor(profile, username: "bob")) == b.vaultID)
        }
    }

    @Test func noMatchWhileAnotherVaultIsLockedNeedsChoice() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .locked]) { profile, _, vaults in
            let choice = try #require(choiceOf(await routeFor(profile)))
            #expect(choice.reason == .noneMatchedLockedExists)
            #expect(choice.listing.map(\.vaultID) == vaults.map(\.vaultID))
        }
    }

    @Test func newLoginGoesToTheDefaultVault() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let (a, b) = (vaults[0], vaults[1])
            // No preference: the first vault.
            #expect(vaultOf(await routeFor(profile)) == a.vaultID)

            let store = try CredentialManager.store(for: profile)
            await store.setDefaultVault(b.vaultID)
            #expect(vaultOf(await routeFor(profile)) == b.vaultID)
        }
    }

    @Test func defaultLockedNeedsChoiceOrUnlockNeverSilentFallback() async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, _, vaults in
            guard case .needsUnlock(let listing) = await routeFor(profile) else {
                Issue.record("the only vault is locked: expected needsUnlock")
                return
            }
            #expect(listing.vaultID == vaults[0].vaultID)
        }
        try await VaultManagerFixture.with(vaults: [.locked, .unlocked]) { profile, _, vaults in
            // The default (the first vault) is locked and B is unlocked: B is offered, never used silently.
            let choice = try #require(choiceOf(await routeFor(profile)))
            #expect(choice.reason == .defaultLocked)
            #expect(choice.listing.map(\.vaultID) == vaults.map(\.vaultID))
        }
    }

    @Test func unavailableRoutes() async throws {
        let privateRoute = await routeFor(.privateBrowsing())
        #expect(isUnavailable(privateRoute))

        // No vault yet, a v1 file still to migrate, an unreadable vault file: nothing is read, written or created by the lookup.
        let arrangements: [(Profile) throws -> Void] = [
            { _ in },
            { profile in
                try FileManager.default.createDirectory(at: profile.supportDirectory, withIntermediateDirectories: true)
                try LegacyV1.make(profileID: profile.id).write(to: profile.supportDirectory)
            },
            { profile in
                try FileManager.default.createDirectory(at: profile.supportDirectory, withIntermediateDirectories: true)
                try Data("not a vault".utf8).write(to: profile.supportDirectory.appendingPathComponent("Credentials.vault"))
            },
        ]
        for arrange in arrangements {
            let profile = try await VaultManagerFixture.newProfile()
            do {
                try arrange(profile)
            } catch {
                await VaultManagerFixture.cleanup(profile)
                throw error
            }
            let before = VaultManagerFixture.image(of: profile.supportDirectory)
            let route = await routeFor(profile)
            let after = VaultManagerFixture.image(of: profile.supportDirectory)
            let existed = FileManager.default.fileExists(atPath: profile.supportDirectory.path)
            await VaultManagerFixture.cleanup(profile)

            #expect(isUnavailable(route))
            #expect(after == before)
            #expect(existed == !before.isEmpty)
        }
    }

    @Test func staleEpochAfterLockIsRefused() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let a = vaults[0]
            let stale = try #require(a.manager.authorizationEpoch)
            let account = VaultFixtures.account()
            let base = try await a.manager.snapshot().revision

            a.manager.lock(reason: .manual)
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await a.manager.commit([account], expectedRevision: base, authorizedEpoch: stale)
            }

            // A newer unlock does not revive the epoch the decision was made under.
            try await VaultManagerFixture.unlock(a)
            let fresh = try #require(a.manager.authorizationEpoch)
            #expect(fresh != stale)
            let before = try VaultManagerFixture.rows(of: a.vaultID, in: profile)
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await a.manager.commit([account], expectedRevision: base, authorizedEpoch: stale)
            }
            let snapshot = try await a.manager.snapshot()
            #expect(snapshot.revision == base)
            #expect(snapshot.accounts.isEmpty)
            #expect(try VaultManagerFixture.rows(of: a.vaultID, in: profile) == before)
        }
    }

    @Test func epochOfOneVaultNeverSelectsAnotherVaultsManager() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            let (a, b) = (vaults[0], vaults[1])
            @MainActor func owner(of epoch: UInt64) -> CredentialManager? {
                CredentialManager.unlockedManagers(for: profile).first { $0.authorizationEpoch == epoch }
            }
            var seen: [UInt64] = []
            for _ in 0..<3 {
                let epochA = try #require(a.manager.authorizationEpoch)
                let epochB = try #require(b.manager.authorizationEpoch)
                #expect(owner(of: epochA) === a.manager)
                #expect(owner(of: epochB) === b.manager)
                seen += [epochA, epochB]

                a.manager.lock(reason: .manual)
                b.manager.lock(reason: .manual)
                #expect(owner(of: epochA) == nil)
                #expect(owner(of: epochB) == nil)
                try await VaultManagerFixture.unlock(a)
                try await VaultManagerFixture.unlock(b)
            }
            seen += [try #require(a.manager.authorizationEpoch), try #require(b.manager.authorizationEpoch)]
            #expect(Set(seen).count == seen.count)
        }
    }
}
