// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Testing
import WebKit

@testable import WSurf

// Native ceremony invariants against a real encrypted vault, a real WebKit page and the independent verifier. The
// native context is the engine's own `WebAuthnContext` for a fixture page served from localhost; the only scripted
// part is the user (`WebAuthnCeremonyInteraction`): it proves what the ceremony does with each answer, not that the
// system sheet or LocalAuthentication prompt works (that stays a native acceptance item).

@MainActor
struct WebsiteAuthenticatorCeremonyTests {
    private let rpID = "localhost"

    // MARK: Doubles

    private final class User: WebAuthnCeremonyInteraction {
        var canVerify = true
        var respond: (WebAuthnPrompt) -> WebAuthnDecision = { _ in .approved(choice: nil) }
        var offer: (Bool) -> WebAuthnDecision = { _ in .approved(choice: nil) }
        var whileAsking: (() async -> Void)?
        var verifyFailure: (any Error)?
        var whileVerifying: (() -> Void)?
        private(set) var prompts: [WebAuthnPrompt] = []
        private(set) var offers: [Bool] = []
        private(set) var verifications = 0
        private(set) var notices: [(rpID: String, userName: String)] = []

        var canVerifyUser: Bool {
            canVerify
        }

        /// The deadline each native step was given (nil: no timer at all).
        private(set) var deadlines: [ContinuousClock.Instant?] = []

        func decide(_ prompt: WebAuthnPrompt, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
            prompts.append(prompt)
            deadlines.append(deadline)
            await whileAsking?()
            return respond(prompt)
        }

        func offerStart(operation: WebAuthnPrompt.Operation, origin: String, locked: Bool, in anchor: ASPresentationAnchor, until deadline: ContinuousClock.Instant?) async -> WebAuthnDecision {
            offers.append(locked)
            deadlines.append(deadline)
            return offer(locked)
        }

        func verifyUser(reason: String, until deadline: ContinuousClock.Instant?) async throws {
            verifications += 1
            deadlines.append(deadline)
            whileVerifying?()
            if let verifyFailure {
                throw verifyFailure
            }
        }

        func reportUnconfirmedRegistration(rpID: String, userName: String, in anchor: ASPresentationAnchor) {
            notices.append((rpID, userName))
        }
    }

    private struct FixtureError: Error { let reason: String }

    /// One real WebKit page on localhost whose profile is the fresh, test-owned profile of an unlocked encrypted vault.
    private struct Fixture {
        let manager: CredentialManager
        /// The page's own regular profile (never the original or a shared one), forgotten again by `cleanup`.
        let profile: Profile
        let directory: URL
        let page: BrowserPage
        /// The page's tab: the object that owns the page's navigation delegate, so it must outlive the page's use.
        let tab: BrowserTab
        let window: NSWindow
        let server: HTTPFixtureServer
        let origin: String
        let next: URL
        let frame: BrowserFrame

        var file: URL { directory.appendingPathComponent("Credentials.vault", isDirectory: false) }
        func bytes() throws -> Data {
            try Data(contentsOf: file)
        }

        func context(_ operation: WebAuthnOperation) async throws -> WebAuthnContext {
            try await page.credentialContext(for: frame, operation: operation)
        }

        /// Replaces the document the contexts were made for.
        func navigate() async {
            page.load(URLRequest(url: next))
            await PageSettle.untilIdle(page, timeout: .seconds(30))
        }

        func cleanup() async {
            await Self.discard(page: page, window: window, directory: directory, profile: profile)
        }

        static func discard(page: BrowserPage, window: NSWindow, directory: URL, profile: Profile) async {
            await page.close()
            window.close()
            try? FileManager.default.removeItem(at: directory)
            await Profile.erase(profile)
        }
    }

    private func fixture() async throws -> Fixture {
        // The browser's own tab: its navigation delegate records the main-frame response (and its Permissions-Policy) that
        // the native context reads, and the profile it serves is the profile of the vault below: a fresh regular profile
        // owned by this fixture, with its own context. A bare `BrowserPage` has no delegate, so no committed response ever
        // exists and every context is `policyUnavailable`.
        let profile = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = BrowserTab(
            adopting: WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 400), configuration: configuration),
            opensBlank: false, privately: false, context: BrowserProfileContext(profile: profile)
        )
        let page = tab.page
        let clock = TestClock()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let proof = VaultUnlockProof(
            credentialID: Data(repeating: 1, count: 32),
            prfInput: Data(repeating: 2, count: 32),
            prf: SymmetricKey(size: .bits256)
        )
        let vault = try CredentialVault(profileID: profile.id, directory: directory, now: { clock.now })
        let access = VaultAccess(profileID: profile.id, epoch: 1, deadline: clock.now.advanced(by: .seconds(300)))
        try await vault.create(unlock: proof, access: access)
        let manager = try CredentialManager(profile: profile, directory: directory, now: { clock.now })
        try await manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: manager.beginAccess())

        let headers = ["Permissions-Policy": "publickey-credentials-create=(self), publickey-credentials-get=(self)"]
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<!doctype html><title>Passkeys</title>", headers: headers),
            "/next": .html("<!doctype html><title>Next</title>", headers: headers),
        ])
        var components = try #require(URLComponents(url: server.url(), resolvingAgainstBaseURL: false))
        components.host = "localhost"
        let url = try #require(components.url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        page.load(URLRequest(url: url))
        guard await PageSettle.untilIdle(page, timeout: .seconds(30)) else {
            await Fixture.discard(page: page, window: window, directory: directory, profile: profile)
            throw FixtureError(reason: "page did not settle")
        }
        guard await waitUntil({ PageFrameRegistry.shared.mainFrame(in: page) != nil }),
              let frame = PageFrameRegistry.shared.mainFrame(in: page),
              let host = url.host, let scheme = url.scheme else {
            await Fixture.discard(page: page, window: window, directory: directory, profile: profile)
            throw FixtureError(reason: "no main frame")
        }
        let port = url.port.map { ":\($0)" } ?? ""
        return Fixture(
            manager: manager, profile: profile, directory: directory, page: page, tab: tab, window: window, server: server,
            origin: "\(scheme)://\(host)\(port)", next: url.appendingPathComponent("next"), frame: frame
        )
    }

    /// Runs `body` with a fixture and tears it down on every exit, awaited: the page is closed before the window it lives
    /// in and the vault directory it reads are released.
    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await fixture()
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    private func creation(
        challenge: String = "create challenge",
        userVerification: WebAuthnUserVerification = .discouraged,
        exclude: [Data] = [],
        userID: Data = Data([1, 2, 3, 4]),
        userName: String = "ada@example.com",
        deadline: Duration = .seconds(60)
    ) -> WebAuthnRequest {
        WebAuthnRequest(
            requestID: UUID(),
            options: .creation(WebAuthnCreationOptions(
                challenge: Data(challenge.utf8), rpID: rpID, userID: userID, userName: userName, userDisplayName: "Ada",
                publicKeyAlgorithms: [-7], excludeCredentials: exclude, residentKey: .required, authenticatorAttachment: nil,
                userVerification: userVerification, attestation: .none, extensions: .init(credProps: true)
            )),
            deadline: ContinuousClock.now.advanced(by: deadline)
        )
    }

    /// `deadline: nil` is a conditional request's unbounded lifetime.
    private func assertion(
        challenge: String = "get challenge",
        userVerification: WebAuthnUserVerification = .discouraged,
        allow: [Data] = [],
        deadline: Duration? = .seconds(60)
    ) -> WebAuthnRequest {
        WebAuthnRequest(
            requestID: UUID(),
            options: .assertion(WebAuthnAssertionOptions(
                challenge: Data(challenge.utf8), rpID: rpID, allowCredentials: allow, userVerification: userVerification
            )),
            deadline: deadline.map { ContinuousClock.now.advanced(by: $0) }
        )
    }

    private func verified(_ fixture: Fixture, _ result: WebAuthnResult, challenge: String) throws -> WebAuthnVerifier.Registration {
        try WebAuthnVerifier.registration(
            attestationObject: #require(result.attestationObject), clientDataJSON: result.clientDataJSON,
            challenge: Data(challenge.utf8), origin: fixture.origin, topOrigin: nil, crossOrigin: false, rpID: rpID
        )
    }

    @discardableResult
    private func create(
        _ fixture: Fixture,
        _ user: User,
        request: WebAuthnRequest? = nil,
        context: WebAuthnContext? = nil
    ) async throws -> WebAuthnCeremonyOutcome {
        let native: WebAuthnContext
        if let context {
            native = context
        } else {
            native = try await fixture.context(.create)
        }
        return try await WebsiteAuthenticator.perform(
            request ?? creation(), context: native, manager: fixture.manager, in: NSWindow(), interaction: user
        )
    }

    @discardableResult
    private func get(
        _ fixture: Fixture,
        _ user: User,
        request: WebAuthnRequest? = nil,
        conditional: Bool = false
    ) async throws -> WebAuthnCeremonyOutcome {
        try await WebsiteAuthenticator.perform(
            request ?? assertion(), context: fixture.context(.get), manager: fixture.manager,
            in: NSWindow(), conditional: conditional, interaction: user
        )
    }

    private func passkeys(_ fixture: Fixture) async throws -> [WebsitePasskey] {
        try await fixture.manager.snapshot().accounts.flatMap(\.passkeys)
    }

    /// A passkey registered through the ceremony itself, so the account is one the ceremony would offer again.
    @discardableResult
    private func seed(_ fixture: Fixture, _ number: UInt8, userName: String = "ada@example.com") async throws -> UUID {
        let outcome = try await create(fixture, User(), request: creation(challenge: "seed \(number)", userID: Data([number]), userName: userName))
        let accounts = try await fixture.manager.snapshot().accounts
        return try #require(accounts.first { $0.passkeys.contains { $0.credentialID == outcome.result.credentialID } }).id
    }

    // MARK: Registration

    @Test(.boundedWebViews) func registrationNeedsExplicitNativeConfirmationAndIsIndependentlyVerifiable() async throws {
        try await withFixture { fixture in
            let user = User()

            let outcome = try await create(fixture, user)
            let prompt = try #require(user.prompts.first)
            #expect(user.prompts.count == 1)
            #expect(prompt.operation == .create && prompt.origin == fixture.origin && prompt.rpID == rpID)
            #expect(prompt.offersNewAccount && prompt.choices.isEmpty && prompt.requestedUserName == "ada@example.com")

            let registration = try verified(fixture, outcome.result, challenge: "create challenge")
            #expect(registration.counter == 0)
            #expect(registration.credentialID == outcome.result.credentialID)
            let stored = try await fixture.manager.snapshot()
            #expect(stored.accounts.count == 1)
            #expect(stored.accounts[0].passkeys.map(\.credentialID) == [outcome.result.credentialID])

            // The outcome names the durable write and the authority it was produced under.
            #expect(outcome.savedRevision == stored.revision)
            #expect(outcome.generation == fixture.manager.stableGeneration, "the delivered registration was proven in the vault under this generation")
            #expect(outcome.epoch == fixture.manager.authorizationEpoch)
            #expect(outcome.rpID == rpID && outcome.userName == "ada@example.com")
        }
    }

    @Test(.boundedWebViews) func declinedCancelledAndExpiredConfirmationCommitNothing() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            let before = try fixture.bytes()

            let user = User()
            user.respond = { _ in .declined }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await create(fixture, user) }
            user.respond = { _ in .expired }
            do {
                try await create(fixture, user)
                Issue.record("expired confirmation succeeded")
            } catch WebsiteAuthenticatorError.expired {} catch {
                Issue.record("wrong error \(error)")
            }
            user.respond = { _ in .cancelled }
            await #expect(throws: CancellationError.self) { try await create(fixture, user) }

            #expect(user.verifications == 0)
            #expect(try fixture.bytes() == before)
        }
    }

    @Test(.boundedWebViews) func requiredUserVerificationIsFreshNeverInferredFromTheUnlockedVault() async throws {
        try await withFixture { fixture in
            #expect(fixture.manager.isUnlocked)

            // Unlocked vault, discouraged: the UV bit stays clear and nothing is asked.
            let plain = User()
            let first = try await create(fixture, plain, request: creation(challenge: "a", userVerification: .discouraged))
            #expect(plain.verifications == 0)
            #expect(try verified(fixture, first.result, challenge: "a").authenticatorData[32] & 0x04 == 0)

            // Required: a verification happens after the confirmation and sets the bit.
            let strict = User()
            let second = try await create(fixture, strict, request: creation(challenge: "b", userVerification: .required, userID: Data([9])))
            #expect(strict.verifications == 1)
            #expect(try verified(fixture, second.result, challenge: "b").authenticatorData[32] & 0x04 != 0)

            // Preferred verifies when the Mac can and silently omits the bit when it cannot.
            let able = User()
            let third = try await create(fixture, able, request: creation(challenge: "c", userVerification: .preferred, userID: Data([8])))
            #expect(able.verifications == 1 && able.prompts[0].willVerifyUser)
            #expect(try verified(fixture, third.result, challenge: "c").authenticatorData[32] & 0x04 != 0)
            let unable = User()
            unable.canVerify = false
            let fourth = try await create(fixture, unable, request: creation(challenge: "d", userVerification: .preferred, userID: Data([7])))
            #expect(unable.verifications == 0 && !unable.prompts[0].willVerifyUser)
            #expect(try verified(fixture, fourth.result, challenge: "d").authenticatorData[32] & 0x04 == 0)
        }
    }

    @Test(.boundedWebViews) func requiredVerificationThatCannotRunOrFailsCommitsNothing() async throws {
        try await withFixture { fixture in
            let before = try fixture.bytes()

            let unable = User()
            unable.canVerify = false
            do {
                try await create(fixture, unable, request: creation(userVerification: .required))
                Issue.record("succeeded")
            } catch WebsiteAuthenticatorError.notAllowed {} catch {
                Issue.record("wrong error \(error)")
            }
            #expect(unable.prompts.isEmpty) // refused before any prompt

            let failing = User()
            failing.verifyFailure = WebsiteAuthenticatorError.notAllowed
            await #expect(throws: WebsiteAuthenticatorError.self) {
                try await create(fixture, failing, request: creation(userVerification: .required))
            }
            failing.verifyFailure = CancellationError()
            await #expect(throws: CancellationError.self) {
                try await create(fixture, failing, request: creation(userVerification: .required))
            }
            #expect(try fixture.bytes() == before)
        }
    }

    @Test(.boundedWebViews) func newPasskeyNeverMergesByUsernameAndPreservesNeighbours() async throws {
        try await withFixture { fixture in
            // Two accounts that look identical to the user: same username, same kinds of content.
            let firstID = try await seed(fixture, 1)
            let secondID = try await seed(fixture, 2)
            let user = User()

            // The default answer is a new account even though two accounts already use this username.
            try await create(fixture, user, request: creation(challenge: "three", userID: Data([3])))
            let prompt = try #require(user.prompts.first)
            #expect(Set(prompt.choices.map(\.id)) == [firstID, secondID])
            #expect(Set(prompt.choices.map(\.detail)).count == 2, "duplicate-looking accounts must stay distinguishable")
            var accounts = try await fixture.manager.snapshot().accounts
            #expect(accounts.count == 3)

            // Give the first account a password and verification code, then add to it explicitly.
            var edited = accounts
            let index = try #require(edited.firstIndex { $0.id == firstID })
            edited[index].password = "pw"
            edited[index].totp = TOTPGenerator(secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 30, digits: 6, issuer: nil, userName: nil)
            _ = try await fixture.manager.commit(edited, expectedRevision: fixture.manager.snapshot().revision, authorizedEpoch: try #require(fixture.manager.authorizationEpoch))
            let sameName = try #require(try await fixture.manager.snapshot().accounts.first { $0.id == firstID })
            let neighbour = try #require(try await fixture.manager.snapshot().accounts.first { $0.id == secondID })

            user.respond = { _ in .approved(choice: firstID) }
            let added = try await create(fixture, user, request: creation(challenge: "four", userID: Data([5])))
            accounts = try await fixture.manager.snapshot().accounts
            let updated = try #require(accounts.first { $0.id == firstID })
            #expect(updated.password == sameName.password && updated.totp == sameName.totp && updated.origins == sameName.origins)
            #expect(updated.passkeys.map(\.credentialID).contains(added.result.credentialID))
            #expect(updated.passkeys.count == sameName.passkeys.count + 1)
            #expect(accounts.first { $0.id == secondID } == neighbour)
        }
    }

    @Test(.boundedWebViews) func excludedCredentialInAnyAccountFailsAfterTheGestureWithoutCreatingAKey() async throws {
        try await withFixture { fixture in
            let existing = try await create(fixture, User())
            let before = try fixture.bytes()

            let user = User()
            do {
                try await create(fixture, user, request: creation(challenge: "dup", exclude: [existing.result.credentialID], userID: Data([6])))
                Issue.record("excluded registration succeeded")
            } catch WebsiteAuthenticatorError.credentialExcluded {} catch { Issue.record("wrong error \(error)") }
            #expect(user.prompts.count == 1, "the user gesture comes before the exclusion is reported")
            #expect(try fixture.bytes() == before)
        }
    }

    @Test(.boundedWebViews) func pageNavigatingOrVaultLockingWhileTheSheetIsOpenAbortsBeforeAnythingIsSigned() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            let before = try fixture.bytes()

            // The page navigates while the sheet is open: the context the user confirmed for no longer exists.
            let navigated = User()
            navigated.whileAsking = { await fixture.navigate() }
            await #expect(throws: WebAuthnContextError.self) { try await create(fixture, navigated) }
            #expect(navigated.verifications == 0)
            #expect(try fixture.bytes() == before)
        }
    }

    @Test(.boundedWebViews) func vaultLockWhileTheSheetIsOpenAbortsBeforeAnythingIsSigned() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            let before = try fixture.bytes()

            let locked = User()
            locked.whileAsking = { fixture.manager.lock(reason: .manual) }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await create(fixture, locked) }
            #expect(!fixture.manager.isUnlocked)
            #expect(try fixture.bytes() == before)
        }
    }

    @Test(.boundedWebViews) func accountChangedDuringConfirmationIsRejectedButUnrelatedWritesAreKept() async throws {
        try await withFixture { fixture in
            let targetID = try await seed(fixture, 1)

            // Another write lands while the sheet is open: the chosen account is unchanged, so the ceremony proceeds
            // against the fresh revision and keeps that write.
            let neighbour = CredentialAccount(
                id: UUID(), username: "grace", displayName: nil, origins: ["https://other.example"], loginURLs: [], password: "pw",
                passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
            )
            let epoch = try #require(fixture.manager.authorizationEpoch)
            let busy = User()
            busy.respond = { _ in .approved(choice: targetID) }
            busy.whileAsking = {
                let snapshot = try? await fixture.manager.snapshot()
                _ = try? await fixture.manager.commit((snapshot?.accounts ?? []) + [neighbour], expectedRevision: snapshot?.revision ?? 0, authorizedEpoch: epoch)
            }
            try await create(fixture, busy, request: creation(challenge: "busy", userID: Data([2])))
            var accounts = try await fixture.manager.snapshot().accounts
            #expect(accounts.contains { $0.id == neighbour.id })
            #expect(accounts.first { $0.id == targetID }?.passkeys.count == 2)

            // The chosen account itself changes: the user confirmed something else, so nothing is written.
            let changing = User()
            changing.respond = { _ in .approved(choice: targetID) }
            changing.whileAsking = {
                guard let snapshot = try? await fixture.manager.snapshot() else { return }
                var edited = snapshot.accounts
                if let index = edited.firstIndex(where: { $0.id == targetID }) { edited[index].password = "changed" }
                _ = try? await fixture.manager.commit(edited, expectedRevision: snapshot.revision, authorizedEpoch: epoch)
            }
            let changedBefore = try await fixture.manager.snapshot()
            do {
                try await create(fixture, changing, request: creation(challenge: "x", userID: Data([4])))
                Issue.record("succeeded")
            } catch WebsiteAuthenticatorError.notAllowed {} catch {
                Issue.record("wrong error \(error)")
            }
            accounts = try await fixture.manager.snapshot().accounts
            #expect(accounts.first { $0.id == targetID }?.passkeys.count == changedBefore.accounts.first { $0.id == targetID }?.passkeys.count)
        }
    }

    @Test(.boundedWebViews) func contextProfileAndOperationMustMatchTheManagerAndRequest() async throws {
        try await withFixture { fixture in
            let before = try fixture.bytes()
            let user = User()

            // A manager for another profile never serves this page's context.
            let otherProfile = Profile(id: UUID(), name: "Other", symbol: "briefcase", color: .blue)
            let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: otherDirectory) }
            let foreign = try CredentialManager(profile: otherProfile, directory: otherDirectory, now: { ContinuousClock.now })
            await #expect(throws: WebsiteAuthenticatorError.self) {
                try await WebsiteAuthenticator.perform(creation(), context: fixture.context(.create), manager: foreign, in: NSWindow(), interaction: user)
            }

            // A context made for an assertion cannot register, and the reverse.
            let wrongOperation = try await fixture.context(.get)
            await #expect(throws: WebsiteAuthenticatorError.self) { try await create(fixture, user, context: wrongOperation) }
            await #expect(throws: WebsiteAuthenticatorError.self) {
                try await WebsiteAuthenticator.perform(
                    assertion(), context: fixture.context(.create), manager: fixture.manager, in: NSWindow(), interaction: user
                )
            }
            #expect(user.prompts.isEmpty)
            #expect(try fixture.bytes() == before)
        }
    }

    @Test(.boundedWebViews) func cancellationBeforeTheWriteLeavesTheVaultUntouched() async throws {
        try await withFixture { fixture in
            let before = try fixture.bytes()
            let user = User()
            let ceremony = Task { @MainActor in try await create(fixture, user, request: creation(userVerification: .required)) }
            user.whileVerifying = { ceremony.cancel() }

            await #expect(throws: CancellationError.self) { _ = try await ceremony.value }
            #expect(user.verifications == 1)
            #expect(try fixture.bytes() == before)
            #expect(fixture.manager.unconfirmedPasskeys.isEmpty && user.notices.isEmpty)
        }
    }

    @Test(.boundedWebViews) func requestExpiringWhileTheSheetIsOpenCommitsNothing() async throws {
        try await withFixture { fixture in
            let before = try fixture.bytes()
            let user = User()
            user.whileAsking = { try? await Task.sleep(for: .milliseconds(600)) }

            do {
                try await create(fixture, user, request: creation(deadline: .milliseconds(400)))
                Issue.record("expired request succeeded")
            } catch WebsiteAuthenticatorError.expired {} catch {
                Issue.record("wrong error \(error)")
            }
            #expect(try fixture.bytes() == before)
        }
    }

    // MARK: Assertion

    @Test(.boundedWebViews) func assertionUsesTheChosenPasskeyAndIsIndependentlyVerified() async throws {
        try await withFixture { fixture in
            let registered = try verified(fixture, try await create(fixture, User()).result, challenge: "create challenge")
            let beforeSnapshot = try await fixture.manager.snapshot()
            let before = try fixture.bytes()

            let user = User()
            user.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            let outcome = try await get(fixture, user, request: assertion(userVerification: .required))
            let result = outcome.result
            let prompt = try #require(user.prompts.first)
            #expect(prompt.operation == .get && !prompt.offersNewAccount && prompt.choices.count == 1)
            #expect(user.verifications == 1)
            #expect(result.credentialID == registered.credentialID)
            let counter = try WebAuthnVerifier.assertion(
                authenticatorData: #require(result.authenticatorData), clientDataJSON: result.clientDataJSON,
                signature: #require(result.signature), publicKey: registered.publicKey, challenge: Data("get challenge".utf8),
                origin: .init(origin: fixture.origin), rpID: rpID, userHandle: result.userHandle
            )
            #expect(counter == 0)
            #expect(result.userHandle == Data([1, 2, 3, 4]))
            let authenticatorData = try #require(result.authenticatorData)
            #expect(authenticatorData[32] & 0x04 != 0)
            let afterSnapshot = try await fixture.manager.snapshot()
            let storedPasskey = try #require(afterSnapshot.accounts.flatMap(\.passkeys).first { $0.credentialID == registered.credentialID })
            let storedRecord = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(storedPasskey)) as? [String: Any])
            #expect(storedRecord["lastSignedAt"] is NSNumber, "the local signature time is stored with the encrypted vault record")
            #expect(afterSnapshot.revision == beforeSnapshot.revision + 1)
            #expect(try fixture.bytes() != before, "a locally created signature updates the encrypted vault")

            // The signature is bound to the vault state it was read under, so the final dispatch can refuse it if that moved.
            #expect(outcome.epoch == fixture.manager.authorizationEpoch)
            #expect(outcome.generation == fixture.manager.stableGeneration)
            #expect(outcome.savedRevision == nil && outcome.rpID == rpID)
        }
    }
    @Test(.boundedWebViews) func aSecondRegistrationForTheSameUserRetainsBothPasskeysAndRecordsLocalCreation() async throws {
        try await withFixture { fixture in
            let first = try await create(fixture, User(), request: creation(challenge: "first", userID: Data([1, 2, 3]))).result
            let second = try await create(fixture, User(), request: creation(challenge: "second", userID: Data([1, 2, 3]))).result
            let stored = try await passkeys(fixture)

            #expect(stored.count == 2)
            #expect(Set(stored.map(\.credentialID)) == [first.credentialID, second.credentialID])
            for credentialID in [first.credentialID, second.credentialID] {
                let passkey = try #require(stored.first { $0.credentialID == credentialID })
                let record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(passkey)) as? [String: Any])
                #expect(record["source"] as? String == "created")
                #expect(record["createdAt"] is NSNumber)
            }
        }
    }


    @Test(.boundedWebViews) func discoverableAccountsStayDistinctAndAllowListFilters() async throws {
        try await withFixture { fixture in
            // Same RP, same display username, two different user handles: two accounts, not one.
            let first = try await create(fixture, User(), request: creation(challenge: "one", userID: Data([1]))).result
            let second = try await create(fixture, User(), request: creation(challenge: "two", userID: Data([2]))).result

            let user = User()
            user.respond = { prompt in .approved(choice: prompt.choices[1].id) }
            let chosen = try await get(fixture, user).result
            #expect(user.prompts[0].choices.count == 2)
            #expect(Set(user.prompts[0].choices.map(\.id)).count == 2)
            let stored = try await passkeys(fixture)
            let expectedCredential = try #require(stored.first { $0.id == user.prompts[0].choices[1].id }).credentialID
            #expect(chosen.credentialID == expectedCredential)
            #expect(chosen.userHandle == stored.first { $0.credentialID == expectedCredential }?.userHandle)

            let filtered = User()
            filtered.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            let only = try await get(fixture, filtered, request: assertion(allow: [first.credentialID])).result
            #expect(filtered.prompts[0].choices.count == 1)
            #expect(only.credentialID == first.credentialID && only.credentialID != second.credentialID)
        }
    }

    /// A vault with no matching passkey must not answer instantly: that would let a page probe for credentials with no
    /// native step. The prompt (here the scripted user, with the origin and relying party) comes first, has nothing to
    /// approve, and the page's refusal arrives only after it is dismissed or expires.
    @Test(.boundedWebViews) func aGetWithNoMatchingPasskeyAsksFirstHasNothingToApproveAndFailsOnlyAfterTheDecision() async throws {
        try await withFixture { fixture in
            let seeded = try await seed(fixture, 1)
            let stored = try #require(try await passkeys(fixture).first)
            let before = try fixture.bytes()

            @MainActor func outcome(_ decision: WebAuthnDecision, allow: [Data] = [Data([0xFF])]) async throws -> (String, User) {
                let user = User()
                user.respond = { _ in decision }
                do {
                    try await get(fixture, user, request: assertion(allow: allow))
                    return ("signed", user)
                } catch WebsiteAuthenticatorError.notAllowed {
                    return ("notAllowed", user)
                } catch WebsiteAuthenticatorError.expired {
                    return ("expired", user)
                } catch is CancellationError {
                    return ("cancelled", user)
                } catch {
                    return ("other \(error)", user)
                }
            }

            for (decision, expected) in [
                (WebAuthnDecision.declined, "notAllowed"), (.expired, "expired"), (.cancelled, "cancelled"),
                // Nothing is approvable, whatever a (scripted) approval names, including a real passkey of this vault.
                (.approved(choice: nil), "notAllowed"), (.approved(choice: stored.id), "notAllowed"), (.approved(choice: seeded), "notAllowed"),
            ] {
                let (result, user) = try await outcome(decision)
                #expect(result == expected, "\(decision)")
                #expect(user.prompts.count == 1, "the user is asked before any refusal: \(decision)")
                let prompt = try #require(user.prompts.first)
                #expect(prompt.operation == .get && prompt.choices.isEmpty && !prompt.offersNewAccount)
                #expect(prompt.origin == fixture.origin && prompt.rpID == rpID)
                #expect(user.verifications == 0 && user.offers.isEmpty)
            }
            #expect(try fixture.bytes() == before)
            // A get that does match is still exactly one prompt: no extra dialog was added to the success path.
            let matching = User()
            matching.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            try await get(fixture, matching)
            #expect(matching.prompts.count == 1 && matching.offers.isEmpty)
        }
    }

    /// The native no-match sheet cannot be approved: the only decision it ever reports is a dismissal.
    @Test func theNativeNoMatchPromptCarriesNoChoicesAndNothingToChoose() {
        let prompt = WebAuthnPrompt(
            operation: .get, origin: "https://login.example", topOrigin: nil, rpID: "login.example", requestedUserName: nil,
            choices: [], offersNewAccount: false, userVerification: .preferred, willVerifyUser: true
        )
        #expect(NativeWebAuthnInteraction.hasNothingToApprove(prompt))
        #expect(NativeWebAuthnInteraction.makeChooser(for: prompt) == nil)
        let withChoice = WebAuthnPrompt(
            operation: .get, origin: "https://login.example", topOrigin: nil, rpID: "login.example", requestedUserName: nil,
            choices: [WebAuthnPromptChoice(id: UUID(), title: "Ada", detail: "")], offersNewAccount: false,
            userVerification: .preferred, willVerifyUser: true
        )
        #expect(!NativeWebAuthnInteraction.hasNothingToApprove(withChoice))
    }

    @Test(.boundedWebViews) func assertionCancelledDeclinedStaleOrRemovedSignsNothing() async throws {
        try await withFixture { fixture in
            try await create(fixture, User())

            let declined = User()
            declined.respond = { _ in .declined }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await get(fixture, declined) }
            let cancelled = User()
            cancelled.respond = { _ in .cancelled }
            await #expect(throws: CancellationError.self) { try await get(fixture, cancelled) }

            // The passkey is deleted while the sheet is open.
            let epoch = try #require(fixture.manager.authorizationEpoch)
            let removed = User()
            removed.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            removed.whileAsking = {
                guard let snapshot = try? await fixture.manager.snapshot() else { return }
                var stripped = snapshot.accounts
                for index in stripped.indices { stripped[index].passkeys = []; stripped[index].password = "kept" }
                _ = try? await fixture.manager.commit(stripped, expectedRevision: snapshot.revision, authorizedEpoch: epoch)
            }
            do {
                try await get(fixture, removed)
                Issue.record("signed with a removed passkey")
            } catch WebsiteAuthenticatorError.notAllowed {} catch {
                Issue.record("wrong error \(error)")
            }
        }
    }

    @Test(.boundedWebViews) func pageReplacedWhileTheAssertionSheetIsOpenSignsNothing() async throws {
        try await withFixture { fixture in
            try await create(fixture, User())

            let user = User()
            user.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            user.whileAsking = { await fixture.navigate() }
            await #expect(throws: WebAuthnContextError.self) { try await get(fixture, user, request: assertion(userVerification: .required)) }
            #expect(user.verifications == 0)
        }
    }

    @Test(.boundedWebViews) func lockDuringAssertionConfirmationRefusesToSign() async throws {
        try await withFixture { fixture in
            try await create(fixture, User())

            let user = User()
            user.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            user.whileAsking = { fixture.manager.lock(reason: .screenLock) }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await get(fixture, user) }
            #expect(user.verifications == 0)
        }
    }

    // MARK: Conditional (page-gesture) requests

    @Test(.boundedWebViews) func conditionalRequestOffersBeforeAnythingElseAndDecliningDoesNothing() async throws {
        try await withFixture { fixture in
            try await create(fixture, User())
            let before = try fixture.bytes()

            let user = User()
            user.offer = { _ in .declined }
            await #expect(throws: WebsiteAuthenticatorError.self) {
                try await get(fixture, user, request: assertion(userVerification: .required), conditional: true)
            }
            #expect(user.offers == [false], "an unlocked vault is offered as such")
            #expect(user.prompts.isEmpty && user.verifications == 0, "no account prompt, verification or signature before the offer is accepted")
            #expect(try fixture.bytes() == before)

            // Accepting the offer only starts the normal ceremony: the account prompt still decides.
            let accepting = User()
            accepting.respond = { prompt in .approved(choice: prompt.choices[0].id) }
            let outcome = try await get(fixture, accepting, conditional: true)
            #expect(accepting.offers == [false] && accepting.prompts.count == 1)
            #expect(outcome.result.signature != nil)
        }
    }

    @Test(.boundedWebViews) func lockedVaultIsOfferedAsLockedAndNeverUnlockedByADeclinedOffer() async throws {
        try await withFixture { fixture in
            try await create(fixture, User())
            fixture.manager.lock(reason: .manual)

            let user = User()
            user.offer = { _ in .declined }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await get(fixture, user, conditional: true) }
            #expect(user.offers == [true])
            #expect(!fixture.manager.isUnlocked && user.prompts.isEmpty)
        }
    }

    // MARK: Lifetime

    /// WebAuthn L3: a conditional get has no lifetime timer. Every native step it reaches (offer, prompt, verification) is
    /// given no deadline at all, while the same request as a modal one is bounded at each of them.
    @Test(.boundedWebViews) func aConditionalGetHasNoDeadlineAtAnyNativeStepWhileAModalOneIsBoundedAtEach() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            @MainActor func approving() -> User {
                let user = User()
                user.respond = { prompt in .approved(choice: prompt.choices[0].id) }
                return user
            }

            let conditional = approving()
            let outcome = try await get(fixture, conditional, request: assertion(userVerification: .required, deadline: nil), conditional: true)
            #expect(outcome.result.signature != nil)
            #expect(conditional.offers.count == 1 && conditional.prompts.count == 1 && conditional.verifications == 1)
            #expect(conditional.deadlines.count == 3 && conditional.deadlines.allSatisfy { $0 == nil }, "no native step may carry a timer")

            let modal = approving()
            try await get(fixture, modal, request: assertion(userVerification: .required))
            #expect(modal.prompts.count == 1 && modal.verifications == 1 && modal.offers.isEmpty)
            #expect(modal.deadlines.count == 2 && modal.deadlines.allSatisfy { $0 != nil }, "a modal request is bounded at every native step")
        }
    }

    /// The same wait that expires a modal request is no reason to fail a conditional one.
    @Test(.boundedWebViews) func aWaitThatExpiresAModalGetDoesNotExpireAConditionalOne() async throws {
        try await withFixture { fixture in
            try await seed(fixture, 1)
            @MainActor func slow() -> User {
                let user = User()
                user.respond = { prompt in .approved(choice: prompt.choices[0].id) }
                user.whileAsking = { try? await Task.sleep(for: .milliseconds(700)) }
                return user
            }

            do {
                try await get(fixture, slow(), request: assertion(deadline: .milliseconds(400)))
                Issue.record("a modal get outlived its deadline")
            } catch WebsiteAuthenticatorError.expired {} catch { Issue.record("wrong error \(error)") }

            let outcome = try await get(fixture, slow(), request: assertion(deadline: nil), conditional: true)
            #expect(outcome.result.signature != nil)
        }
    }

    @Test(.boundedWebViews) func modalGetOnALockedVaultIsOfferedAndADeclinedOfferNeverUnlocks() async throws {
        try await withFixture { fixture in
            try await create(fixture, User())
            fixture.manager.lock(reason: .manual)

            let user = User()
            user.offer = { _ in .declined }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await get(fixture, user) }
            #expect(user.offers == [true])
            #expect(!fixture.manager.isUnlocked && user.prompts.isEmpty && user.verifications == 0)
        }
    }

    @Test(.boundedWebViews) func modalCreateOnALockedVaultIsOfferedAndADeclinedOfferNeverUnlocks() async throws {
        try await withFixture { fixture in
            fixture.manager.lock(reason: .manual)

            let user = User()
            user.offer = { _ in .declined }
            await #expect(throws: WebsiteAuthenticatorError.self) { try await create(fixture, user) }
            #expect(user.offers == [true])
            #expect(!fixture.manager.isUnlocked && user.prompts.isEmpty)
        }
    }

    @Test func pageSuppliedDisplayTextIsStrippedOfControlAndBidiCharactersAndBounded() {
        #expect("ada\u{202E}evil\u{0007}\n@x.test".displaySafe == "adaevil@x.test")
        #expect(String(repeating: "a", count: 200).displaySafe.count == 81)
        #expect("  Ada  ".displaySafe == "Ada")
    }

    @Test(.boundedWebViews) func conditionalRegistrationIsRefused() async throws {
        try await withFixture { fixture in
            let user = User()
            await #expect(throws: WebsiteAuthenticatorError.self) {
                try await WebsiteAuthenticator.perform(
                    creation(), context: fixture.context(.create), manager: fixture.manager, in: NSWindow(),
                    conditional: true, interaction: user
                )
            }
            #expect(user.offers.isEmpty && user.prompts.isEmpty)
        }
    }

    // MARK: Prompt content

    @Test func indistinguishableAccountsGetADistinctSuffixAndCaseDistinctNamesStayApart() {
        func account(_ username: String, id: UUID = UUID(), origins: [String] = ["https://login.example.com"]) -> CredentialAccount {
            CredentialAccount(
                id: id, username: username, displayName: nil, origins: origins, loginURLs: [], password: "pw", passkeys: [],
                totp: nil, exchangeAccountID: nil, exchangeItemID: nil
            )
        }
        let one = account("Ada", id: UUID(uuidString: "AAAA0000-0000-4000-8000-000000000001")!)
        let two = account("Ada", id: UUID(uuidString: "BBBB0000-0000-4000-8000-000000000002")!)
        let lower = account("ada")
        let unrelated = account("ada", origins: ["https://elsewhere.test"])

        let choices = WebsiteAuthenticator.registrationChoices([one, two, lower, unrelated], rpID: "example.com", origin: "https://login.example.com")
        #expect(choices.map(\.id) == [one.id, two.id, lower.id])
        #expect(Set(choices.map { $0.title + $0.detail }).count == 3)
        #expect(choices[0].detail.hasSuffix("#AAAA") && choices[1].detail.hasSuffix("#BBBB"))
        #expect(!choices[2].detail.contains("#"))
    }

    // MARK: Native chooser identity
    // Real AppKit controls, never presented: this proves which identity each menu position carries, not that the sheet
    // or the user's click works (native consent stays an acceptance item).

    private func prompt(_ choices: [WebAuthnPromptChoice], offersNewAccount: Bool) -> WebAuthnPrompt {
        WebAuthnPrompt(
            operation: offersNewAccount ? .create : .get, origin: "https://login.example.com", topOrigin: nil, rpID: "example.com",
            requestedUserName: offersNewAccount ? "ada" : nil, choices: choices, offersNewAccount: offersNewAccount,
            userVerification: .discouraged, willVerifyUser: false
        )
    }

    @Test func chooserKeepsOneItemPerEntryAndMapsEachPositionToItsOwnIdentityEvenWithIdenticalTitles() throws {
        // Identical title and detail: a title-keyed menu collapses these into one item and shifts every later index.
        let choices = (1...3).map { _ in WebAuthnPromptChoice(id: UUID(), title: "Ada", detail: "ada · 1 passkey(s)") }
        let chooser = try #require(NativeWebAuthnInteraction.makeChooser(for: prompt(choices, offersNewAccount: true)))

        #expect(chooser.numberOfItems == 4, "new account plus one distinct item per account")
        chooser.selectItem(at: 0)
        guard case .approved(let newAccount) = NativeWebAuthnInteraction.decision(from: chooser) else { Issue.record("not approved"); return }
        #expect(newAccount == nil)
        for (offset, choice) in choices.enumerated() {
            chooser.selectItem(at: offset + 1)
            guard case .approved(let picked) = NativeWebAuthnInteraction.decision(from: chooser) else { Issue.record("not approved"); return }
            #expect(picked == choice.id)
        }
    }

    @Test func accountsWhoseIDsShareTheirFirstCharactersStayDistinctAndSelectable() throws {
        func account(_ id: String) -> CredentialAccount {
            CredentialAccount(
                id: UUID(uuidString: id)!, username: "ada", displayName: nil, origins: ["https://login.example.com"], loginURLs: [],
                password: "pw", passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
            )
        }
        // Same first eight characters: a four-character suffix would not tell these apart.
        let accounts = [
            account("ABCD1234-0000-4000-8000-000000000001"),
            account("ABCD1234-0000-4000-8000-000000000002"),
            account("ABCD1234-FFFF-4000-8000-000000000003"),
        ]
        let choices = WebsiteAuthenticator.registrationChoices(accounts, rpID: "example.com", origin: "https://login.example.com")

        #expect(choices.map(\.id) == accounts.map(\.id))
        #expect(Set(choices.map { $0.title + $0.detail }).count == 3, "every account is visibly different")
        let chooser = try #require(NativeWebAuthnInteraction.makeChooser(for: prompt(choices, offersNewAccount: true)))
        #expect(chooser.numberOfItems == 4)
        #expect(Set(chooser.itemTitles).count == 4)
        for (offset, account) in accounts.enumerated() {
            chooser.selectItem(at: offset + 1)
            guard case .approved(let picked) = NativeWebAuthnInteraction.decision(from: chooser) else { Issue.record("not approved"); return }
            #expect(picked == account.id)
        }
    }

    @Test func assertionWithOnePasskeyHasNothingToChooseAndSeveralAreAllListed() throws {
        let one = WebAuthnPromptChoice(id: UUID(), title: "Ada", detail: "ada")
        #expect(NativeWebAuthnInteraction.makeChooser(for: prompt([one], offersNewAccount: false)) == nil)
        let many = [one, WebAuthnPromptChoice(id: UUID(), title: "Ada", detail: "ada")]
        let chooser = try #require(NativeWebAuthnInteraction.makeChooser(for: prompt(many, offersNewAccount: false)))
        #expect(chooser.numberOfItems == 2)
        chooser.selectItem(at: 1)
        guard case .approved(let picked) = NativeWebAuthnInteraction.decision(from: chooser) else { Issue.record("not approved"); return }
        #expect(picked == many[1].id)
    }
}
