// SPDX-FileCopyrightText: 2026 WSurf contributors
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Testing
import WebKit

@testable import WSurf

// Account choice, step carry-over and save planning for the credential manager. Vault state comes from the real
// encrypted vault with test-only in-memory unlock material; no native ceremony or provider is involved.

@MainActor
@Suite(.boundedWebViews)
struct CredentialAccountSelectionTests {
    private static let origin = "https://login.example"
    private static let rfcSeed = Data("12345678901234567890".utf8)

    private func account(
        _ username: String,
        password: String? = "pw",
        displayName: String? = nil,
        origins: [String] = [origin],
        path: String = "/login",
        passkeys: [WebsitePasskey] = [],
        totp: TOTPGenerator? = nil
    ) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: displayName, origins: origins,
            loginURLs: origins.compactMap { URL(string: $0 + path) }, password: password, passkeys: passkeys, totp: totp,
            exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func passkey(_ seed: UInt8) throws -> WebsitePasskey {
        WebsitePasskey(
            id: UUID(), credentialID: Data(repeating: seed, count: 32), rpID: "login.example", userHandle: Data([seed]),
            userName: "ada", userDisplayName: "Ada", algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: true, backupState: false, exchangeFIDO2Metadata: nil
        )
    }

    private var rfcGenerator: TOTPGenerator {
        TOTPGenerator(secret: Self.rfcSeed, algorithm: .sha1, period: 30, digits: 8, issuer: "login.example", userName: "ada")
    }

    private func ids(
        _ accounts: [CredentialAccount], entered: String? = nil, pageURL: URL? = nil,
        field: CredentialAutofillField = .password, pinned: UUID? = nil
    ) -> [UUID] {
        CredentialAccountSelection.candidates(
            in: accounts, origin: Self.origin, pageURL: pageURL, entered: entered, field: field, pinned: pinned
        ).map(\.id)
    }

    // MARK: - Choosing

    @Test func tenAccountsStayDistinctChoicesAndNothingIsPickedForTheUser() throws {
        let gmail = (1...10).map { account("user\($0)@gmail.test", password: "pw-\($0)") }
        let sorted = gmail.sorted { $0.username < $1.username }.map(\.id)

        // Empty and nil input offer every associated account; nothing is filled until one is chosen.
        #expect(ids(gmail) == sorted)
        #expect(ids(gmail, entered: "") == sorted)
        #expect(ids(gmail, entered: "USER1").count == 2)
        #expect(ids(gmail, entered: "user1@gmail.test") == [gmail[0].id])
        let chosen = CredentialAccountSelection.suggestions(
            gmail, origin: Self.origin, pageURL: nil, entered: "user7@gmail.test", field: .password
        )
        #expect(chosen.map(\.id) == [gmail[6].id])
        #expect(ids(gmail, pinned: gmail[2].id) == [gmail[2].id])

        let all = CredentialAccountSelection.suggestions(gmail, origin: Self.origin, pageURL: nil, entered: nil, field: .password)
        let encoded = String(decoding: try JSONEncoder().encode(all), as: UTF8.self)
        #expect(!encoded.contains("pw-"))

        // Identities differing only by case stay separate accounts, and an exact match leads.
        let upper = account("Ada", password: "upper"), lower = account("ada", password: "lower")
        #expect(ids([lower, upper]) == [upper.id, lower.id])
        #expect(ids([upper, lower], entered: "ada") == [lower.id, upper.id])
        #expect(ids([upper, lower], entered: "Ada") == [upper.id, lower.id])

        // Duplicate usernames remain distinct rows a person can tell apart.
        let home = account("ada", displayName: "Home"), work = account("ada", displayName: "Work")
        let labelled = CredentialAccountSelection.suggestions([home, work], origin: Self.origin, pageURL: nil, entered: nil, field: .password)
        #expect(Set(labelled.map(\.id)) == [home.id, work.id])
        #expect(Set(labelled.map(\.detail)).count == 2)
        let bare = CredentialAccountSelection.suggestions(
            [account("ada"), account("ada")], origin: Self.origin, pageURL: nil, entered: nil, field: .password
        )
        #expect(bare.count == 2 && Set(bare.map(\.detail)).count == 2)

        // The page's path ranks relevance only among accounts already associated with the origin.
        let checkout = account("a-checkout", path: "/checkout"), login = account("b-login", path: "/login")
        let elsewhere = account("c-other", origins: ["https://other.example"], path: "/login")
        let page = URL(string: "https://login.example/login?next=1")
        #expect(ids([checkout, login, elsewhere], pageURL: page) == [login.id, checkout.id])
    }

    // MARK: - Carry-over

    @Test func usernameChangeInvalidatesNextStep() {
        let profile = Profile(id: UUID(), name: "Selection", symbol: "key", color: .blue)
        let page = BrowserPage(webKit: WKWebView(), profile: profile)
        let session = AutofillSaveSession()
        session.attach(to: page, profileID: profile.id)
        let id = UUID(), t0 = ContinuousClock.now, ada = "ada@example.test"
        session.selectAccount(id, username: ada, in: page, origin: Self.origin, now: t0, epoch: 7)

        func selected(
            _ username: String?, origin: String = CredentialAccountSelectionTests.origin, in page: BrowserPage = page, at seconds: Int = 0, epoch: UInt64? = 7
        ) -> UUID? {
            session.selectedAccount(
                in: page, origin: origin, enteredUsername: username, now: t0.advanced(by: .seconds(seconds)), epoch: epoch
            )
        }

        // Username -> password -> verification code, each step a new staged attempt in the same tab and origin.
        #expect(selected(ada, at: 1) == id)
        session.stageUsername(ada, origin: Self.origin, documentID: "", attemptID: UUID(), in: page)
        #expect(selected(ada, at: 2) == id)
        #expect(selected(nil, at: 3) == id)
        #expect(selected("", at: 3) == id)
        #expect(selected(ada, at: 299) == id)
        // The deadline is the original one; staging did not extend it.
        #expect(selected(ada, at: 300) == nil)

        #expect(selected("grace@example.test") == nil)
        #expect(selected(ada, origin: "https://other.example") == nil)
        #expect(selected(ada, in: BrowserPage(webKit: WKWebView(), profile: profile)) == nil)
        #expect(selected(ada, epoch: 8) == nil)
        #expect(selected(ada, epoch: nil) == nil)

        // A different username on a later step drops the pick for good, even if the first comes back.
        session.stageUsername("grace@example.test", origin: Self.origin, documentID: "", attemptID: UUID(), in: page)
        #expect(selected(nil) == nil)
        session.stageUsername(ada, origin: Self.origin, documentID: "", attemptID: UUID(), in: page)
        #expect(selected(ada) == nil)

        // Policy changes (provider switch, extension, lock of the session) forget the pick.
        session.selectAccount(id, username: ada, in: page, origin: Self.origin, now: t0, epoch: 7)
        #expect(selected(ada) == id)
        session.refreshPolicy()
        #expect(selected(ada) == nil)

        // A tab never inherits another profile's pick.
        session.selectAccount(id, username: ada, in: page, origin: Self.origin, now: t0, epoch: 7)
        session.attach(to: page, profileID: UUID())
        #expect(selected(ada) == nil)
    }

    /// A rejected step is an invalidation, not a suppression: nothing but an explicit new pick brings the account back.
    @Test(.boundedWebViews) func aRejectedStepNeverRevivesTheOldPick() {
        let profile = Profile(id: UUID(), name: "Selection", symbol: "key", color: .blue)
        let page = BrowserPage(webKit: WKWebView(), profile: profile)
        let other = BrowserPage(webKit: WKWebView(), profile: profile)
        let session = AutofillSaveSession()
        session.attach(to: page, profileID: profile.id)
        let id = UUID(), t0 = ContinuousClock.now, ada = "ada@example.test"

        func pick() { session.selectAccount(id, username: ada, in: page, origin: Self.origin, now: t0, epoch: 7) }
        func selected(
            _ username: String?, origin: String = CredentialAccountSelectionTests.origin, in page: BrowserPage = page, at seconds: Int = 0, epoch: UInt64? = 7
        ) -> UUID? {
            session.selectedAccount(
                in: page, origin: origin, enteredUsername: username, now: t0.advanced(by: .seconds(seconds)), epoch: epoch
            )
        }

        pick()
        #expect(selected("grace@example.test") == nil)
        #expect(selected(nil) == nil, "an empty step must not bring the old account back")
        #expect(selected(ada) == nil)

        pick()
        #expect(selected(ada, origin: "https://other.example") == nil)
        #expect(selected(ada) == nil)

        pick()
        #expect(selected(ada, epoch: 8) == nil)
        #expect(selected(ada, epoch: 7) == nil)

        pick()
        #expect(selected(ada, at: 300) == nil)
        #expect(selected(ada, at: 0) == nil)

        // A query about another tab says nothing about this tab's pick.
        pick()
        #expect(selected(ada, in: other) == nil)
        #expect(selected(ada) == id)

        // An explicit new pick is the only way back.
        #expect(selected("grace@example.test") == nil)
        pick()
        #expect(selected(ada) == id)
    }

    // MARK: - Saving

    private final class Vault {
        let profile = Profile(id: UUID(), name: "Selection", symbol: "key", color: .blue)
        let manager: CredentialManager
        let gate: VaultClockGate?
        private let credentialID = Data(repeating: 1, count: 32)
        private let prf = SymmetricKey(size: .bits256)

        /// With a `gate`, the manager is private to this fixture and its vault reads the gate's clock.
        init(gate: VaultClockGate? = nil) throws {
            self.gate = gate
            if let gate {
                manager = try CredentialManager(profile: profile, directory: profile.supportDirectory, now: { gate.now() })
            } else {
                manager = try CredentialManager.forProfile(profile)
            }
        }

        func seed(_ accounts: [CredentialAccount]) async throws {
            let proof = VaultUnlockProof(credentialID: credentialID, prfInput: Data(repeating: 2, count: 32), prf: prf)
            try await manager.completeCreate(proof, access: manager.beginAccess())
            _ = try await manager.commit(accounts, expectedRevision: 0)
        }

        /// A fresh unlock with the same unlock material, as after a lock.
        func unlockAgain() async throws {
            try await manager.completeUnlock(credentialID: credentialID, prf: prf, access: manager.beginAccess())
        }

        func cleanup() async {
            gate?.release()
            if gate != nil { manager.lock(reason: .manual) }
            await CredentialManager.retire(profileID: profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
        }
    }

    private func encoded(_ account: CredentialAccount) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(account)
    }

    @Test func passwordUpdatePlansTouchOnlyTheExactAccountInARealVault() async throws {
        let vault = try Vault()
        do {
            var accounts = (0..<10).map { account("user\($0)@example.test", password: "pw-\($0)") }
            accounts[3].passkeys = [try passkey(3)]
            accounts[4].totp = rfcGenerator
            accounts.append(account("ada", password: "home", displayName: "Home"))
            accounts.append(account("ada", password: "work", displayName: "Work"))
            try await vault.seed(accounts)
            let before = try await vault.manager.snapshot()
            let target = accounts[3]
            let login = try SavedPassword(website: Self.origin, username: target.username, password: "changed")

            // A new password for the exact username updates that one account.
            let plan = CredentialAccountSelection.savePlan(for: login, origin: Self.origin, accountID: target.id, in: before.accounts)
            #expect(plan == .update(target.id))
            let updated = try CredentialAccountSelection.applying(
                plan, login: login, origin: Self.origin, loginURL: nil, to: before.accounts
            )
            _ = try await vault.manager.commit(updated, expectedRevision: before.revision)
            let after = try await vault.manager.snapshot()
            #expect(after.accounts.count == before.accounts.count)
            for old in before.accounts where old.id != target.id {
                let new = try #require(after.accounts.first { $0.id == old.id })
                #expect(try encoded(new) == encoded(old))
            }
            let changed = try #require(after.accounts.first { $0.id == target.id })
            #expect(changed.password == "changed")
            #expect(changed.passkeys == target.passkeys && changed.totp == target.totp && changed.username == target.username)
            let totpAccount = try #require(after.accounts.first { $0.id == accounts[4].id })
            #expect(totpAccount.totp == rfcGenerator && totpAccount.password == "pw-4")

            // An account chosen for another username is never overwritten; the exact username decides.
            let other = try SavedPassword(website: Self.origin, username: "user5@example.test", password: "x")
            #expect(CredentialAccountSelection.savePlan(for: other, origin: Self.origin, accountID: target.id, in: after.accounts)
                == .update(accounts[5].id))

            // Same password is no change; two accounts for one username are never guessed between.
            let same = try SavedPassword(website: Self.origin, username: "user0@example.test", password: "pw-0")
            #expect(CredentialAccountSelection.savePlan(for: same, origin: Self.origin, accountID: nil, in: after.accounts) == .unchanged)
            let duplicate = try SavedPassword(website: Self.origin, username: "ada", password: "new")
            let ambiguous = CredentialAccountSelection.savePlan(for: duplicate, origin: Self.origin, accountID: nil, in: after.accounts)
            #expect(ambiguous == .ambiguous)
            #expect(throws: CredentialVaultError.invalidData) {
                try CredentialAccountSelection.applying(ambiguous, login: duplicate, origin: Self.origin, loginURL: nil, to: after.accounts)
            }
            // ...unless the user picked one, which resolves it to exactly that account.
            let work = try #require(after.accounts.first { $0.displayName == "Work" })
            #expect(CredentialAccountSelection.savePlan(for: duplicate, origin: Self.origin, accountID: work.id, in: after.accounts)
                == .update(work.id))

            // A first account on this origin is appended with a sanitized path and nothing else changes.
            let fresh = try SavedPassword(website: Self.origin, username: "new@example.test", password: "new-pw")
            let created = CredentialAccountSelection.savePlan(for: fresh, origin: Self.origin, accountID: nil, in: after.accounts)
            #expect(created == .create)
            let url = CredentialAccountSelection.loginURL(
                for: URL(string: "https://user:secret@login.example/signin?token=abc#frag")!, origin: Self.origin
            )
            #expect(url?.absoluteString == "https://login.example/signin")
            let appended = try CredentialAccountSelection.applying(created, login: fresh, origin: Self.origin, loginURL: url, to: after.accounts)
            #expect(appended.count == after.accounts.count + 1)
            #expect(try zip(after.accounts, appended).allSatisfy { try encoded($0) == encoded($1) })
            #expect(appended.last?.origins == [Self.origin] && appended.last?.loginURLs == [url!])
            // A different origin's URL never becomes this account's login page.
            #expect(CredentialAccountSelection.loginURL(for: URL(string: "https://evil.example/login")!, origin: Self.origin) == nil)

            // A commit made from an outdated snapshot is refused rather than overwriting the newer vault.
            await #expect(throws: CredentialVaultError.staleRevision) {
                try await vault.manager.commit(appended, expectedRevision: before.revision)
            }
            #expect(try await vault.manager.snapshot().accounts.count == after.accounts.count)
        } catch {
            await vault.cleanup()
            throw error
        }
        await vault.cleanup()
    }
    // MARK: - Reviewed saves

    private func withSeeded(_ accounts: [CredentialAccount], _ body: (Vault, VaultSnapshot) async throws -> Void) async throws {
        let vault = try Vault()
        do {
            try await vault.seed(accounts)
            try await body(vault, try await vault.manager.snapshot())
        } catch {
            await vault.cleanup()
            throw error
        }
        await vault.cleanup()
    }

    private func save(
        _ username: String, _ password: String, offered: CredentialSavePlan?, in vault: Vault, _ snapshot: VaultSnapshot
    ) async throws -> CredentialSaveOutcome {
        try await CredentialAccountSelection.commitSave(
            try SavedPassword(website: Self.origin, username: username, password: password),
            origin: Self.origin, offered: offered, loginURL: nil, snapshot: snapshot, manager: vault.manager
        )
    }

    private func untouched(_ vault: Vault, _ before: VaultSnapshot, except changed: UUID? = nil) async throws {
        let after = try await vault.manager.snapshot()
        for old in before.accounts where old.id != changed {
            let new = try #require(after.accounts.first { $0.id == old.id })
            #expect(try encoded(new) == encoded(old))
        }
    }

    @Test func anEditedUsernameNeverOverwritesAnAccountTheUserWasNotShown() async throws {
        let ada = account("ada@example.test", password: "ada-secret"), grace = account("grace@example.test", password: "grace-secret")
        try await withSeeded([ada, grace]) { vault, before in
            // Offered an update of ada; the review form edits the username to grace's.
            #expect(try await save("grace@example.test", "new", offered: .update(ada.id), in: vault, before) == .needsReview)
            try await untouched(vault, before)
            #expect(try await vault.manager.snapshot().revision == before.revision)

            // Offered a brand new account; the edit lands on an existing one.
            #expect(try await save("grace@example.test", "new", offered: .create, in: vault, before) == .needsReview)
            try await untouched(vault, before)

            // An edit to a username nobody has is a different action than the update that was shown.
            #expect(try await save("linus@example.test", "new", offered: .update(ada.id), in: vault, before) == .needsReview)
            try await untouched(vault, before)
            #expect(try await vault.manager.snapshot().accounts.count == 2)
        }
    }

    @Test func aSaveWhoseTargetChangedSinceTheOfferWritesNothing() async throws {
        let ada = account("ada@example.test", password: "ada-secret"), grace = account("grace@example.test", password: "grace-secret")
        try await withSeeded([ada, grace]) { vault, before in
            // The offer was a create, but a stored account now owns that username.
            #expect(try await save("grace@example.test", "new", offered: .create, in: vault, before) == .needsReview)
            try await untouched(vault, before)
            #expect(try await vault.manager.snapshot().revision == before.revision)
        }
    }

    @Test func reviewEditsStayLimitedToTheTargetThatWasShown() async throws {
        let ada = account("ada@example.test", password: "ada-secret", totp: rfcGenerator), grace = account("grace@example.test", password: "grace-secret")
        try await withSeeded([ada, grace]) { vault, before in
            // Same account, password edited in the review form.
            #expect(try await save("ada@example.test", "edited", offered: .update(ada.id), in: vault, before) == .saved)
            let edited = try await vault.manager.snapshot()
            #expect(edited.accounts.first { $0.id == ada.id }?.password == "edited")
            #expect(edited.accounts.first { $0.id == ada.id }?.totp == rfcGenerator)
            try await untouched(vault, before, except: ada.id)

            // A new account stays a new account after the review edit; the neighbours are unchanged.
            #expect(try await save("linus@example.test", "fresh", offered: .create, in: vault, edited) == .saved)
            let created = try await vault.manager.snapshot()
            #expect(created.accounts.count == 3)
            #expect(created.accounts.last?.username == "linus@example.test" && created.accounts.last?.password == "fresh")
            try await untouched(vault, edited)

            // Nothing to change is not a write.
            #expect(try await save("grace@example.test", "grace-secret", offered: .update(grace.id), in: vault, created) == .unchanged)
            #expect(try await vault.manager.snapshot().revision == created.revision)
        }
    }

    // MARK: - Vault generation

    @MainActor private final class GenerationRead {
        var ran = false
        var generation: UInt64?
    }

    /// The generation is what a fill compares across its vault read; it must be unavailable while a write runs and
    /// different once any write has run. The write is parked inside the vault, so it is genuinely in flight.
    @Test func aWriteInFlightHidesTheVaultGenerationAndEveryWriteChangesIt() async throws {
        let gate = VaultClockGate()
        let vault = try Vault(gate: gate)
        do {
            try await vault.seed([account("ada@example.test")])
            let manager = vault.manager
            let before = try #require(manager.stableGeneration)
            let stored = try await manager.snapshot()
            #expect(manager.stableGeneration == before) // reads never change it

            gate.holdNextVaultRead()
            let writing = Task { @MainActor in
                try await manager.commit(stored.accounts + [account("grace@example.test")], expectedRevision: stored.revision)
            }
            let during = GenerationRead()
            gate.whenParked {
                during.ran = true
                during.generation = manager.stableGeneration
                gate.release()
            }
            let receipt = try await writing.value

            #expect(gate.hasParked && during.ran)
            #expect(during.generation == nil)
            #expect(receipt.revision == stored.revision + 1)
            let after = try #require(manager.stableGeneration)
            #expect(after != before)
        } catch {
            await vault.cleanup()
            throw error
        }
        await vault.cleanup()
    }

    @Test func aRefusedWriteAndAPolicyWriteEachChangeTheVaultGenerationAndALockHidesIt() async throws {
        try await withSeeded([account("ada@example.test")]) { vault, stored in
            let manager = vault.manager
            let first = try #require(manager.stableGeneration)

            // A write the vault refused may still have been attempted: it invalidates like any other.
            await #expect(throws: CredentialVaultError.staleRevision) {
                try await manager.commit(stored.accounts, expectedRevision: stored.revision + 5)
            }
            let refused = try #require(manager.stableGeneration)
            #expect(refused != first)

            _ = try await manager.updatePasswordSavePolicy(["https://blocked.example"], expectedRevision: stored.revision)
            let policy = try #require(manager.stableGeneration)
            #expect(policy != refused)

            // Locked: nothing to rely on. Unlocked again with no write in between, the vault content is what it was;
            // an old request is rejected by its own authorization epoch, not by this value.
            manager.lock(reason: .manual)
            #expect(manager.stableGeneration == nil)
            try await vault.unlockAgain()
            #expect(manager.stableGeneration == policy)
        }
    }


    // MARK: - Verification codes

    @Test func totpFillNeedsAssociationAndFreshCode() throws {
        let associated = account("ada", password: nil, totp: rfcGenerator)
        // Same issuer string and host name, but the origin was never associated: not a match.
        let issuerOnly = account("grace", password: nil, origins: ["https://other.example"], totp: rfcGenerator)
        let passwordOnly = account("hopper", password: "pw")
        let list = [issuerOnly, passwordOnly, associated]

        #expect(ids(list, field: .totp) == [associated.id])
        #expect(ids(list, field: .password) == [associated.id, passwordOnly.id])
        let rows = CredentialAccountSelection.suggestions(list, origin: Self.origin, pageURL: nil, entered: nil, field: .totp)
        let json = String(decoding: try JSONEncoder().encode(rows), as: UTF8.self)
        #expect(!json.contains("94287082") && !json.contains("3132333435"))

        #expect(CredentialAccountSelection.totpCode(for: issuerOnly, origin: Self.origin, at: Date(timeIntervalSince1970: 59)) == nil)
        #expect(CredentialAccountSelection.totpCode(for: passwordOnly, origin: Self.origin, at: Date(timeIntervalSince1970: 59)) == nil)
        // RFC 6238 appendix B, SHA-1, eight digits; the code follows the time it is asked for.
        #expect(CredentialAccountSelection.totpCode(for: associated, origin: Self.origin, at: Date(timeIntervalSince1970: 59)) == "94287082")
        #expect(CredentialAccountSelection.totpCode(for: associated, origin: Self.origin, at: Date(timeIntervalSince1970: 1_111_111_109)) == "07081804")
    }
}
