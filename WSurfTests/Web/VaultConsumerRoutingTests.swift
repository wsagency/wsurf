// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// A page's password save offer is made against exactly the vault that owns the login, and an offer's lease never reaches another
/// vault: real managers in the registry, the real route, the real session.
@MainActor
@Suite(.boundedWebViews)
struct VaultConsumerRoutingTests {
    private static let origin = "https://login.example"

    private func account(_ username: String, password: String = "old") -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: nil, origins: [Self.origin],
            loginURLs: [URL(string: Self.origin + "/login")!], password: password, passkeys: [], totp: nil,
            exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func login(_ username: String) throws -> AutofillSaveCandidate {
        .password(try SavedPassword(website: Self.origin, username: username, password: "new"))
    }

    /// A session attached to a page, shown in a window, of a context on a profile with `vaults`. The page's
    /// document proof is replaced (no document is loaded); everything else is real.
    private func withSession(
        passkeys: VaultPasskeys = VaultPasskeys(),
        vaults: [VaultState],
        _ body: (AutofillSaveSession, [FixtureVault]) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(passkeys: passkeys, vaults: vaults) { profile, _, vaults in
            let context = BrowserProfileContext(profile: profile)
            let configuration = WebViewPool.makeConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let page = BrowserPage(webKit: WKWebView(frame: .zero, configuration: configuration), context: context)
            page.url = URL(string: Self.origin + "/login")
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = page
            let session = AutofillSaveSession()
            AutofillSaveCoordinator.shared.install(in: page, session: session)
            session.liveness = { _, _, _ in true }
            do {
                try await body(session, vaults)
            } catch {
                window.contentView = nil
                window.close()
                await page.close()
                throw error
            }
            window.contentView = nil
            window.close()
            await page.close()
        }
    }

    @Test func anOfferIsMadeAgainstTheVaultThatHoldsTheLogin() async throws {
        try await withSession(vaults: [.unlocked, .unlocked]) { session, vaults in
            let ada = account("ada"), bob = account("bob")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            try await VaultManagerFixture.save([bob], in: vaults[1])
            let epochA = try #require(vaults[0].manager.authorizationEpoch)
            let epochB = try #require(vaults[1].manager.authorizationEpoch)
            #expect(epochA != epochB)

            await session.offer(try login("ada"), origin: Self.origin)
            #expect(session.current?.managerEpoch == epochA)
            #expect(session.current?.plan == .update(ada.id))

            await session.offer(try login("bob"), origin: Self.origin)
            #expect(session.current?.managerEpoch == epochB)
            #expect(session.current?.plan == .update(bob.id))
        }
    }

    @Test func aLoginHeldByTwoUnlockedVaultsIsOfferedWithoutGuessingOne() async throws {
        try await withSession(vaults: [.unlocked, .unlocked]) { session, vaults in
            try await VaultManagerFixture.save([account("ada", password: "a")], in: vaults[0])
            try await VaultManagerFixture.save([account("ada", password: "b")], in: vaults[1])
            let before = try await vaults.asyncMap { try await $0.manager.snapshot().revision }

            await session.offer(try login("ada"), origin: Self.origin)
            #expect(session.current != nil, "the user is still offered the save")
            #expect(session.current?.managerEpoch == nil, "the vault is chosen when they act, not guessed")
            #expect(try await vaults.asyncMap { try await $0.manager.snapshot().revision } == before)
        }
    }

    @Test func aLockedVaultIsNeverTheOneAnOfferGuesses() async throws {
        try await withSession(vaults: [.unlocked, .locked]) { session, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])

            // The unlocked vault holds it: that is the vault, whatever is locked elsewhere.
            await session.offer(try login("ada"), origin: Self.origin)
            #expect(session.current?.managerEpoch == vaults[0].manager.authorizationEpoch)

            // Nothing unlocked holds it and a locked vault may: no vault is picked for the user.
            await session.offer(try login("someone-else"), origin: Self.origin)
            #expect(session.current?.managerEpoch == nil)
        }
    }

    @Test func aProfileWithoutAVaultMakesNoOffer() async throws {
        try await withSession(vaults: []) { session, _ in
            await session.offer(try login("ada"), origin: Self.origin)
            #expect(session.current == nil)
        }
    }

    @Test func neverBlocksTheSiteOnlyInTheVaultTheOfferWasMadeFor() async throws {
        try await withSession(vaults: [.unlocked, .unlocked]) { session, vaults in
            try await VaultManagerFixture.save([account("ada")], in: vaults[0])
            try await VaultManagerFixture.save([account("bob")], in: vaults[1])

            await session.offer(try login("bob"), origin: Self.origin)
            let offer = try #require(session.current)
            await session.never(offer)

            #expect(session.current == nil)
            #expect(try await vaults[1].manager.snapshot().blockedPasswordOrigins == [Self.origin])
            #expect(try await vaults[0].manager.snapshot().blockedPasswordOrigins.isEmpty)
        }
    }

    @Test func anOfferOfALockedVaultIsRefusedAndNeverFallsToAnotherUnlockedVault() async throws {
        try await withSession(vaults: [.unlocked, .unlocked]) { session, vaults in
            try await VaultManagerFixture.save([account("ada")], in: vaults[0])
            await session.offer(try login("ada"), origin: Self.origin)
            let offer = try #require(session.current)
            #expect(offer.managerEpoch == vaults[0].manager.authorizationEpoch)

            vaults[0].manager.lock(reason: .manual)
            await session.never(offer)

            #expect(session.current == nil, "the offer of the locked vault is gone")
            #expect(try await vaults[1].manager.snapshot().blockedPasswordOrigins.isEmpty, "the other vault is never written")
        }
    }

    /// A "which vault?" answer that waits for the test, like a prompt the user has not answered yet.
    @MainActor private final class OpenChoice {
        private(set) var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            isOpen = true
            await withCheckedContinuation { continuation = $0 }
        }

        func answer() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func aFreshVaultChoiceUnlocksTheChosenVaultThroughItsOwnManager() async throws {
        let passkeys = VaultPasskeys()
        try await withSession(passkeys: passkeys, vaults: [.unlocked, .locked]) { session, vaults in
            await session.offer(try login("someone-else"), origin: Self.origin)
            let offer = try #require(session.current)
            #expect(offer.managerEpoch == nil)
            let before = passkeys.assertions.count

            let chosen = vaults[1].vaultID, profileID = vaults[0].manager.profileID
            VaultChoicePrompt.answersForTesting[profileID] = { _ in chosen }
            defer { VaultChoicePrompt.answersForTesting[profileID] = nil }
            let manager = try await session.target(for: offer, username: "someone-else")

            #expect(manager === vaults[1].manager)
            #expect(manager.isUnlocked)
            #expect(passkeys.assertions.count == before + 1, "one native unlock, for the chosen vault")
        }
    }

    @Test func aVaultChoiceAnsweredAfterALockUnlocksAndSavesNothing() async throws {
        let passkeys = VaultPasskeys()
        try await withSession(passkeys: passkeys, vaults: [.unlocked, .locked]) { session, vaults in
            await session.offer(try login("someone-else"), origin: Self.origin)
            let offer = try #require(session.current)
            let before = passkeys.assertions.count

            let choice = OpenChoice()
            let chosen = vaults[1].vaultID, profileID = vaults[0].manager.profileID
            VaultChoicePrompt.answersForTesting[profileID] = { _ in
                await choice.wait()
                return chosen
            }
            defer { VaultChoicePrompt.answersForTesting[profileID] = nil }
            let saving = Task { await session.save(offer) }
            while !choice.isOpen {
                await Task.yield()
            }
            // The profile's access ends while the prompt is open; the old answer then arrives anyway.
            CredentialManager.lock(profileID: vaults[0].manager.profileID, reason: .profileSwitch)
            choice.answer()
            await saving.value

            #expect(passkeys.assertions.count == before, "no native unlock follows the lock")
            #expect(!vaults[1].manager.isUnlocked)
            #expect(!vaults[0].manager.isUnlocked)
            #expect(session.current == nil, "the offer is withdrawn")
        }
    }

    // MARK: - Passkey routing (get)

    private func passkeyAccount(rpID: String, origins: [String] = [], seed: UInt8 = 1) throws -> CredentialAccount {
        let passkey = WebsitePasskey(
            id: UUID(), credentialID: Data(repeating: seed, count: 32), rpID: rpID, userHandle: Data([seed]),
            userName: "ada", userDisplayName: "Ada", algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: true, backupState: false, exchangeFIDO2Metadata: nil
        )
        return CredentialAccount(
            id: UUID(), username: "ada", displayName: nil, origins: origins, loginURLs: [], password: nil,
            passkeys: [passkey], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func chosen(_ route: VaultRoute) -> UUID? {
        guard case .manager(let manager) = route else { return nil }
        return manager.vaultID
    }

    @Test func aPasskeyAssertionGoesToTheVaultHoldingThePasskeyNotThePasswordOrigin() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked]) { profile, _, vaults in
            try await VaultManagerFixture.save([account("ada")], in: vaults[0])
            try await VaultManagerFixture.save([try passkeyAccount(rpID: "login.example")], in: vaults[1])

            let route = await CredentialRouting.route(profile: profile, origin: Self.origin, passkeyRPID: "login.example", allowed: [])
            #expect(chosen(route) == vaults[1].vaultID, "the vault with the passkey, though the other has the password for the origin")

            // A passkey of another relying party is not here: the answer is the password-origin route, never vault B.
            let other = await CredentialRouting.route(profile: profile, origin: Self.origin, passkeyRPID: "other.example", allowed: [])
            #expect(chosen(other) == vaults[0].vaultID)
        }
    }

    @Test func thePasskeyHeldByTwoUnlockedVaultsNeedsAChoiceBetweenOnlyThose() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .unlocked, .unlocked]) { profile, _, vaults in
            let shared = try passkeyAccount(rpID: "login.example")
            try await VaultManagerFixture.save([shared], in: vaults[0])
            try await VaultManagerFixture.save([shared], in: vaults[2])

            let route = await CredentialRouting.route(profile: profile, origin: Self.origin, passkeyRPID: "login.example", allowed: [])
            guard case .needsChoice(let listings, let reason) = route else {
                Issue.record("expected a choice")
                return
            }
            #expect(Set(listings.map(\.vaultID)) == [vaults[0].vaultID, vaults[2].vaultID])
            #expect(reason == .matchInSeveral)
        }
    }

    @Test func aLockedVaultThatMayHoldThePasskeyIsOfferedNeverRead() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .locked]) { profile, _, vaults in
            try await VaultManagerFixture.save([account("ada")], in: vaults[0])

            let route = await CredentialRouting.route(profile: profile, origin: Self.origin, passkeyRPID: "login.example", allowed: [])
            guard case .needsChoice(let listings, let reason) = route else {
                Issue.record("expected a choice")
                return
            }
            #expect(Set(listings.map(\.vaultID)) == [vaults[0].vaultID, vaults[1].vaultID])
            #expect(reason == .noneMatchedLockedExists)
        }
    }

    @Test func aLocalhostOriginRoutesInsteadOfBeingRefused() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let origin = "http://localhost:8080"
            try await VaultManagerFixture.save([try passkeyAccount(rpID: "localhost")], in: vaults[0])

            let get = await CredentialRouting.route(profile: profile, origin: origin, passkeyRPID: "localhost", allowed: [])
            #expect(chosen(get) == vaults[0].vaultID)
            let create = await CredentialRouting.route(profile: profile, origin: origin, username: nil)
            #expect(chosen(create) == vaults[0].vaultID)
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
