// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Testing

@testable import WSurf

// Crypto/settings verification only: unlock keys are test-only in-memory PRF material handed to the shared
// `completeCreate`/`completeUnlock` transition. Nothing here is evidence of Apple provider behavior, and no
// native ceremony is started.

private nonisolated let settingsLockReasons: [CredentialLockReason] = [
    .manual, .profileSwitch, .screenLock, .sleep, .termination, .timeout,
]

struct CredentialSettingsTests {
    /// RFC 6238 appendix B SHA-1 seed; eight digits.
    private static let rfcSeed = Data("12345678901234567890".utf8)
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private final class Fixture {
        let profile = Profile(id: UUID(), name: "Settings", symbol: "key", color: .blue)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
        let proof = VaultUnlockProof(
            credentialID: Data(repeating: 1, count: 32),
            prfInput: Data(repeating: 2, count: 32),
            prf: SymmetricKey(size: .bits256)
        )
        let manager: CredentialManager
        let model: CredentialSettingsModel

        @MainActor init() throws {
            manager = try CredentialManager.forProfile(profile)
            model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard)
        }

        @MainActor func create() async throws {
            try await manager.completeCreate(proof, access: manager.beginAccess())
        }

        @MainActor func unlock() async throws {
            try await manager.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: manager.beginAccess())
        }

        /// Writes accounts straight through the manager so tests start from known stored state.
        @MainActor func seed(_ accounts: [CredentialAccount]) async throws {
            try await create()
            _ = try await manager.commit(accounts, expectedRevision: 0, authorizedEpoch: try #require(manager.authorizationEpoch))
        }

        @MainActor func stored() async throws -> VaultSnapshot {
            try await manager.snapshot()
        }

        @MainActor func sentinel() -> String {
            pasteboard.clearContents()
            pasteboard.setString("sentinel-not-a-secret", forType: .string)
            return "sentinel-not-a-secret"
        }

        @MainActor func cleanup() async {
            pasteboard.releaseGlobally()
            await CredentialManager.retire(profileID: profile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
        }
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture()
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    private func account(
        _ username: String,
        password: String? = nil,
        displayName: String? = nil,
        passkeys: [WebsitePasskey] = [],
        totp: TOTPGenerator? = nil
    ) -> CredentialAccount {
        CredentialAccount(
            id: UUID(),
            username: username,
            displayName: displayName,
            origins: ["https://example.test"],
            loginURLs: [URL(string: "https://example.test/login")!],
            password: password,
            passkeys: passkeys,
            totp: totp,
            exchangeAccountID: nil,
            exchangeItemID: nil
        )
    }

    private func passkey(_ seed: UInt8, id: UUID = UUID()) throws -> WebsitePasskey {
        WebsitePasskey(
            id: id,
            credentialID: Data(repeating: seed, count: 32),
            rpID: "example.test",
            userHandle: Data([seed]),
            userName: "ada",
            userDisplayName: "Ada",
            algorithm: -7,
            privateKeyPKCS8: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey()),
            backupEligible: true,
            backupState: false,
            exchangeFIDO2Metadata: nil
        )
    }

    private func passkeyWithMetadata(
        _ passkey: WebsitePasskey,
        source: String,
        createdAt: Date?,
        lastSignedAt: Date?
    ) throws -> WebsitePasskey {
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(passkey)) as? [String: Any])
        record["source"] = source
        record["createdAt"] = createdAt?.timeIntervalSinceReferenceDate
        record["lastSignedAt"] = lastSignedAt?.timeIntervalSinceReferenceDate
        return try JSONDecoder().decode(
            WebsitePasskey.self, from: JSONSerialization.data(withJSONObject: record)
        )
    }

    private var rfcGenerator: TOTPGenerator {
        TOTPGenerator(secret: Self.rfcSeed, algorithm: .sha1, period: 30, digits: 8, issuer: "Example", userName: "ada")
    }

    private func bytes(_ account: CredentialAccount) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(account)
    }

    // MARK: - Editing

    @Test func editingOneAccountPreservesItsNeighbours() async throws {
        try await withFixture { f in
            var accounts: [CredentialAccount] = [
                account("ada", password: "pw-0"), account("ada", password: "pw-1"),
                account("Grace", password: "pw-2", passkeys: [try passkey(1)]),
                account("grace", password: "pw-3", totp: rfcGenerator),
            ]
            for index in 4..<10 {
                var keys: [WebsitePasskey] = []
                var generator: TOTPGenerator?
                if index == 5 {
                    keys = [try passkey(UInt8(index))]
                    generator = rfcGenerator
                }
                accounts.append(account("user\(index)", password: "pw-\(index)", passkeys: keys, totp: generator))
            }
            let original = try accounts.map(bytes)
            try await f.seed(accounts)
            await f.model.load()

            // The second of two identical display usernames is the selected account.
            try await f.model.beginEditing(accountID: accounts[1].id)
            f.model.draft?.password = "new-selected-password"
            let receipt = try await f.model.commitDraft()
            #expect(receipt.revision == 2)
            #expect(f.model.draft == nil)

            let after = try await f.stored().accounts
            #expect(after.map(\.id) == accounts.map(\.id))
            #expect(after[1].password == "new-selected-password")
            var expected = accounts[1]
            expected.password = "new-selected-password"
            #expect(try bytes(after[1]) == bytes(expected))
            for index in accounts.indices where index != 1 {
                #expect(try bytes(after[index]) == original[index], "account \(index) changed")
            }
        }
    }

    @Test func unmodifiedDraftReproducesTheStoredAccountExactly() throws {
        var rich = account("ada", password: "", displayName: "Ada", passkeys: [try passkey(3)], totp: rfcGenerator)
        rich.origins = ["https://example.test", "https://login.example.test"]
        rich.loginURLs = [URL(string: "https://example.test/login")!]
        rich.exchangeAccountID = Data([1, 2, 3])
        rich.exchangeItemID = Data([4, 5])
        rich.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: CredentialEditableFieldMetadata(id: Data([1]), label: "Login", fieldType: .string),
            password: CredentialEditableFieldMetadata(id: Data([2]), label: "Password", fieldType: .concealedString)
        )
        let draft = CredentialDraft(editing: rich, revision: 7)
        #expect(try bytes(draft.account()) == bytes(rich))
        #expect(draft.revision == 7)
    }
    @Test func passkeyMetadataSurvivesSettingsEditingAndProvidesUniqueStableIdentifiers() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_100)
        let lastSignedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let first = try passkeyWithMetadata(
            passkey(1, id: UUID(uuidString: "ABCD1000-0000-4000-8000-000000000001")!),
            source: "created", createdAt: createdAt, lastSignedAt: lastSignedAt
        )
        let second = try passkeyWithMetadata(
            passkey(2, id: UUID(uuidString: "ABCD2000-0000-4000-8000-000000000002")!),
            source: "imported", createdAt: nil, lastSignedAt: nil
        )
        let stored = account("ada", passkeys: [first, second])

        try await withFixture { f in
            try await f.seed([stored])
            await f.model.load()
            let summaries = try #require(f.model.summaries.first).passkeys
            #expect(summaries.count == 2)
            let reflected: [[String: Any]] = summaries.map {
                Dictionary(uniqueKeysWithValues: Mirror(reflecting: $0).children.compactMap { child in
                    guard let label = child.label else { return nil }
                    return (label, child.value)
                })
            }
            func date(_ value: Any?) -> Date? {
                guard let value, let wrapped = Mirror(reflecting: value).children.first else { return nil }
                return wrapped.value as? Date
            }
            #expect(reflected[0]["shortID"] as? String == "ABCD1")
            #expect(reflected[1]["shortID"] as? String == "ABCD2")
            #expect(String(describing: reflected[0]["source"]).contains("created"))
            #expect(String(describing: reflected[1]["source"]).contains("imported"))
            #expect(date(reflected[0]["createdAt"]) == createdAt)
            #expect(date(reflected[0]["lastSignedAt"]) == lastSignedAt)
            #expect(reflected[1]["createdAt"] == nil && reflected[1]["lastSignedAt"] == nil)

            try await f.model.beginEditing(accountID: stored.id)
            f.model.draft?.displayName = "Edited"
            _ = try await f.model.commitDraft()
            let after = try await f.stored().accounts.first(where: { $0.id == stored.id })
            for (id, source, creation, signing) in [
                (first.id, "created", Optional(createdAt), Optional(lastSignedAt)),
                (second.id, "imported", Optional<Date>.none, Optional<Date>.none),
            ] {
                let actual = try #require(after?.passkeys.first(where: { $0.id == id }))
                let record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(actual)) as? [String: Any])
                #expect(record["source"] as? String == source)
                #expect((record["createdAt"] as? NSNumber)?.doubleValue == creation?.timeIntervalSinceReferenceDate)
                #expect((record["lastSignedAt"] as? NSNumber)?.doubleValue == signing?.timeIntervalSinceReferenceDate)
            }
        }
    }


    @Test func absentAndEmptyPasswordsSurviveAnUnrelatedEdit() async throws {
        try await withFixture { f in
            let absent = account("ada", password: nil, passkeys: [try passkey(1)])
            let empty = account("grace", password: "")
            try await f.seed([absent, empty])
            await f.model.load()

            for target in [absent, empty] {
                try await f.model.beginEditing(accountID: target.id)
                f.model.draft?.displayName = "Renamed \(target.username)"
                _ = try await f.model.commitDraft()
            }
            let after = try await f.stored().accounts
            #expect(after[0].password == nil)
            #expect(after[1].password == "")
            #expect(after[0].displayName == "Renamed ada" && after[1].displayName == "Renamed grace")
            #expect(after[0].passkeys.map(\.credentialID) == absent.passkeys.map(\.credentialID))
            #expect(after[0].passkeys.map(\.privateKeyPKCS8) == absent.passkeys.map(\.privateKeyPKCS8))
        }
    }

    @Test func standaloneCredentialsRemainEditable() async throws {
        try await withFixture { f in
            try await f.create()
            await f.model.load()
            let passkeyOnly = CredentialAccount(
                id: UUID(), username: "", displayName: "Example passkey", origins: [], loginURLs: [],
                password: nil, passkeys: [try passkey(4)], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
            )
            let totpOnly = CredentialAccount(
                id: UUID(), username: "", displayName: "Example code", origins: [], loginURLs: [],
                password: nil, passkeys: [], totp: rfcGenerator, exchangeAccountID: nil, exchangeItemID: nil
            )
            var revision = f.model.revision
            for record in [passkeyOnly, totpOnly] {
                revision = try await f.model.save(record, expectedRevision: revision).revision
            }
            await f.model.load()
            #expect(f.model.summaries.count == 2)
            #expect(f.model.summaries.map(\.hasPassword) == [false, false])

            for record in [passkeyOnly, totpOnly] {
                try await f.model.beginEditing(accountID: record.id)
                f.model.draft?.displayName = "Edited"
                _ = try await f.model.commitDraft()
            }
            let after = try await f.stored().accounts
            #expect(after.map(\.password) == [nil, nil])
            #expect(after.map(\.displayName) == ["Edited", "Edited"])
            #expect(after[0].passkeys.map(\.privateKeyPKCS8) == passkeyOnly.passkeys.map(\.privateKeyPKCS8))
            #expect(after[1].totp?.secret == Self.rfcSeed)
        }
    }

    @Test func removingAPasskeyKeepsTheOthersAndNeverEmptiesTheAccount() async throws {
        try await withFixture { f in
            let first = try passkey(1), second = try passkey(2)
            let two = account("", passkeys: [first, second])
            let only = CredentialAccount(
                id: UUID(), username: "", displayName: nil, origins: [], loginURLs: [],
                password: nil, passkeys: [try passkey(3)], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
            )
            try await f.seed([two, only])
            await f.model.load()

            try await f.model.beginEditing(accountID: two.id)
            f.model.draft?.removePasskey(first.id)
            _ = try await f.model.commitDraft()
            #expect(try await f.stored().accounts[0].passkeys.map(\.credentialID) == [second.credentialID])

            let before = try await f.stored()
            try await f.model.beginEditing(accountID: only.id)
            f.model.draft?.removePasskey(only.passkeys[0].id)
            await #expect(throws: (any Error).self) { _ = try await f.model.commitDraft() }
            #expect(f.model.draft != nil)
            #expect(try await f.stored().revision == before.revision)
        }
    }

    @Test func removeDeletesOnlyTheSelectedAccount() async throws {
        try await withFixture { f in
            let accounts = [account("ada", password: "a"), account("ada", password: "b"), account("Ada", password: "c")]
            try await f.seed(accounts)
            await f.model.load()

            let receipt = try await f.model.remove(accountID: accounts[1].id, expectedRevision: f.model.revision)
            #expect(receipt.revision == 2)
            let after = try await f.stored().accounts
            #expect(after.map(\.id) == [accounts[0].id, accounts[2].id])
            #expect(after.map(\.password) == ["a", "c"])

            await #expect(throws: (any Error).self) {
                _ = try await f.model.remove(accountID: UUID(), expectedRevision: receipt.revision)
            }
            #expect(try await f.stored().revision == receipt.revision)
        }
    }

    @Test func staleRevisionNeverOverwritesANewerVault() async throws {
        try await withFixture { f in
            let existing = account("ada", password: "old")
            try await f.seed([existing])
            await f.model.load()
            let stale = f.model.revision
            _ = try await f.manager.commit([existing, account("grace", password: "other")], expectedRevision: stale, authorizedEpoch: try #require(f.manager.authorizationEpoch))

            var changed = existing
            changed.password = "stale-write"
            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await f.model.save(changed, expectedRevision: stale)
            }
            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await f.model.remove(accountID: existing.id, expectedRevision: stale)
            }
            let after = try await f.stored()
            #expect(after.revision == 2)
            #expect(after.accounts.map(\.password) == ["old", "other"])
        }
    }

    @Test func confirmedRemovalUsesTheRevisionAndEpochItWasShownAt() async throws {
        try await withFixture { f in
            let existing = account("ada", password: "pw")
            try await f.seed([existing])
            await f.model.load()
            f.model.requestRemoval(accountID: existing.id)
            let pending = try #require(f.model.pendingRemoval)
            #expect(pending.revision == f.model.revision)

            _ = try await f.manager.commit([existing, account("grace", password: "other")], expectedRevision: pending.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))
            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await f.model.confirmRemoval(pending)
            }
            #expect(try await f.stored().accounts.count == 2)

            await f.model.load()
            f.model.requestRemoval(accountID: existing.id)
            let shown = try #require(f.model.pendingRemoval)
            f.manager.lock(reason: .manual)
            #expect(f.model.pendingRemoval == nil)
            try await f.unlock()
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await f.model.confirmRemoval(shown)
            }
            #expect(try await f.stored().accounts.count == 2)
        }
    }

    @Test func aCancelledTaskNeverCommitsCopiesOrRepopulates() async throws {
        try await withFixture { f in
            let existing = account("ada", password: "pw", totp: rfcGenerator)
            try await f.seed([existing])
            await f.model.load()
            f.model.hideSecrets()
            let sentinel = f.sentinel()
            var changed = existing
            changed.password = "cancelled-write"
            let revision = f.model.revision

            // Each task cancels itself before its first suspension; the manager stays authorized throughout.
            let model = f.model
            let operations: [@MainActor () async throws -> Void] = [
                { _ = try await model.save(changed, expectedRevision: revision) },
                { _ = try await model.remove(accountID: existing.id, expectedRevision: revision) },
                { try await model.copyPassword(accountID: existing.id) },
                { try await model.copyTOTP(accountID: existing.id) { 59 } },
                { try await model.revealPassword(accountID: existing.id) },
                { try await model.showTOTP(accountID: existing.id) },
                { try await model.beginEditing(accountID: existing.id) },
            ]
            for operation in operations {
                let task = Task { @MainActor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    try await operation()
                }
                await #expect(throws: CancellationError.self) { try await task.value }
            }
            #expect(f.manager.isUnlocked)
            #expect(f.pasteboard.string(forType: .string) == sentinel)
            #expect(f.model.revealedPassword == nil && f.model.totpCode(now: 59) == nil && f.model.draft == nil)
            let after = try await f.stored()
            #expect(after.revision == revision)
            #expect(after.accounts.map(\.password) == ["pw"])

            let loading = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                await model.load()
            }
            await loading.value
            #expect(f.model.summaries.count == 1) // the earlier session is untouched, not replaced
        }
    }

    // MARK: - Origins and TOTP setup

    @Test func originsAreExplicitHTTPSAndLoginURLsAreSanitized() throws {
        var draft = CredentialDraft(editing: nil, revision: 0)
        draft.username = "ada"
        draft.password = "pw"
        draft.websites = "https://user:hunter2@Example.test:443/login?token=1#frag\nhttps://example.test/other"
        draft.extraOrigins = "https://cdn.example.test"
        let built = try draft.account()
        let urls: [String] = built.loginURLs.map { $0.absoluteString }
        #expect(urls == ["https://example.test/login", "https://example.test/other"])
        #expect(built.origins == ["https://example.test", "https://cdn.example.test"])
        #expect(!urls.joined().contains("hunter2"))

        for (websites, extra) in [
            ("http://example.test/login", ""), ("example.test/login", ""), ("https://example.test", "http://other.test"),
            ("https://example.test", "other.test"), ("https://example.test", "https://user@other.test"),
        ] {
            var bad = draft
            bad.websites = websites
            bad.extraOrigins = extra
            #expect(throws: (any Error).self) { try bad.account() }
        }
    }

    @Test func totpSetupIsValidatedBeforeStorageAndNeverInventsOrigins() throws {
        var draft = CredentialDraft(editing: nil, revision: 0)
        draft.username = "ada"
        for rejected in ["123456", "", "not base32 !", "otpauth://hotp/Example:ada?secret=JBSWY3DPEHPK3PXP&counter=1"] {
            #expect(throws: (any Error).self) { try draft.setUpTOTP(rejected) }
        }
        #expect(throws: (any Error).self) { try draft.setUpTOTP("JBSWY3DPEHPK3PXP", period: 0) }
        #expect(throws: (any Error).self) { try draft.setUpTOTP("JBSWY3DPEHPK3PXP", digits: 11) }
        #expect(draft.totp == nil)

        try draft.setUpTOTP("otpauth://totp/Google:ada?secret=JBSWY3DPEHPK3PXP&issuer=Google&digits=8&period=60&algorithm=SHA256")
        #expect(draft.totp?.issuer == "Google")
        #expect(draft.totp?.digits == 8 && draft.totp?.period == 60 && draft.totp?.algorithm == TOTPAlgorithm.sha256)
        let built = try draft.account()
        #expect(built.origins.isEmpty && built.loginURLs.isEmpty)

        var manual = CredentialDraft(editing: nil, revision: 0)
        manual.username = "ada"
        try manual.setUpTOTP("JBSWY3DPEHPK3PXP")
        #expect(manual.totp?.digits == 6 && manual.totp?.period == 30 && manual.totp?.algorithm == TOTPAlgorithm.sha1)
    }

    @Test func invalidFormsDoNotMutateTheVault() async throws {
        try await withFixture { f in
            let existing = account("ada", password: "pw")
            try await f.seed([existing])
            await f.model.load()
            let before = try await f.stored()

            try await f.model.beginEditing(accountID: nil)
            f.model.draft?.websites = "http://insecure.test"
            await #expect(throws: (any Error).self) { _ = try await f.model.commitDraft() }
            f.model.draft?.websites = ""
            await #expect(throws: (any Error).self) { _ = try await f.model.commitDraft() } // nothing to save

            let after = try await f.stored()
            #expect(after.revision == before.revision)
            let afterBytes = try after.accounts.map(bytes)
            let beforeBytes = try before.accounts.map(bytes)
            #expect(afterBytes == beforeBytes)
        }
    }

    // MARK: - Copy and reveal

    @Test func copyPasswordCopiesOnlyTheSelectedAccountAndMarksItConcealed() async throws {
        try await withFixture { f in
            let first = account("ada", password: "first-password")
            let second = account("ada", password: "second-password")
            let none = account("", totp: rfcGenerator)
            try await f.seed([first, second, none])
            await f.model.load()

            try await f.model.copyPassword(accountID: second.id)
            #expect(f.pasteboard.string(forType: .string) == "second-password")
            #expect(f.pasteboard.types?.contains(Self.concealed) == true)

            let sentinel = f.sentinel()
            await #expect(throws: (any Error).self) { try await f.model.copyPassword(accountID: none.id) }
            await #expect(throws: (any Error).self) { try await f.model.copyPassword(accountID: UUID()) }
            #expect(f.pasteboard.string(forType: .string) == sentinel)
        }
    }

    @Test func copyComputesTheCurrentTOTPAtTheMomentOfCopy() async throws {
        try await withFixture { f in
            let record = account("ada", password: "pw", totp: rfcGenerator)
            try await f.seed([record])
            await f.model.load()

            // RFC 6238 SHA-1 vectors on either side of the 1_111_111_110 step boundary.
            try await f.model.copyTOTP(accountID: record.id) { 1_111_111_109 }
            #expect(f.pasteboard.string(forType: .string) == "07081804")
            try await f.model.copyTOTP(accountID: record.id) { 1_111_111_111 }
            #expect(f.pasteboard.string(forType: .string) == "14050471")
            #expect(f.pasteboard.types?.contains(Self.concealed) == true)

            let sentinel = f.sentinel()
            let passwordOnly = account("grace", password: "pw")
            _ = try await f.model.save(passwordOnly, expectedRevision: f.model.revision)
            await #expect(throws: (any Error).self) {
                try await f.model.copyTOTP(accountID: passwordOnly.id) { 59 }
            }
            #expect(f.pasteboard.string(forType: .string) == sentinel)
        }
    }

    @Test func shownTOTPTracksTimeWithoutAnotherVaultLookup() async throws {
        try await withFixture { f in
            let record = account("ada", totp: rfcGenerator)
            try await f.seed([record])
            await f.model.load()
            #expect(f.model.totpCode(now: 59) == nil)

            try await f.model.showTOTP(accountID: record.id)
            #expect(f.model.totpCode(now: 59)?.value == "94287082")
            #expect(f.model.totpCode(now: 1_111_111_109) == TOTPCode(value: "07081804", remainingSeconds: 1, expiresAt: 1_111_111_110))
            #expect(f.model.totpCode(now: 1_111_111_111)?.value == "14050471")
            #expect(f.model.totpCode(now: -1) == nil)
            f.model.hideSecrets()
            #expect(f.model.totpCode(now: 59) == nil)
        }
    }

    @Test func aCodeWhoseClockReadCrossesTheAuthorizationDeadlineNeverReachesThePasteboard() async throws {
        let profile = Profile(id: UUID(), name: "Settings", symbol: "key", color: .blue)
        let clock = TestClock()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
        let manager = try CredentialManager(profile: profile, directory: profile.supportDirectory, now: { clock.now })
        let model = CredentialSettingsModel(profile: profile, pasteboard: pasteboard, manager: manager)
        defer {
            manager.lock(reason: .manual)
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: profile.supportDirectory)
        }
        let proof = VaultUnlockProof(
            credentialID: Data(repeating: 1, count: 32),
            prfInput: Data(repeating: 2, count: 32),
            prf: SymmetricKey(size: .bits256)
        )
        try await manager.completeCreate(proof, access: manager.beginAccess())
        let record = account("ada", totp: rfcGenerator)
        _ = try await manager.commit([record], expectedRevision: 0, authorizedEpoch: try #require(manager.authorizationEpoch))
        await model.load()
        pasteboard.clearContents()
        pasteboard.setString("sentinel-not-a-secret", forType: .string)

        // The clock is read while the code is produced, after every suspension. It passes the 300 s deadline there.
        await #expect(throws: CredentialVaultError.unauthorized) {
            try await model.copyTOTP(accountID: record.id) {
                clock.advance(by: .seconds(301))
                return 59
            }
        }
        #expect(pasteboard.string(forType: .string) == "sentinel-not-a-secret")
        #expect(!model.isUnlocked)
    }

    // MARK: - Imported BasicAuth metadata

    private func basicAuthentication(
        descriptor: CredentialEditableFieldType?, password: Bool, username value: String = "ada"
    ) -> CredentialAccount {
        var record = account(value, password: password ? "pw" : nil)
        record.basicAuthenticationMetadata = CredentialBasicAuthenticationMetadata(
            username: descriptor.map { CredentialEditableFieldMetadata(id: Data([1]), label: "Login", fieldType: $0) },
            password: password ? CredentialEditableFieldMetadata(id: Data([2]), label: "Secret", fieldType: .concealedString) : nil
        )
        return record
    }

    @Test func concealedImportedUsernameStaysHiddenUntilExplicitReveal() async throws {
        try await withFixture { f in
            let concealed = basicAuthentication(descriptor: .concealedString, password: true, username: "hidden-login")
            let plain = basicAuthentication(descriptor: .string, password: true, username: "visible-login")
            let email = basicAuthentication(descriptor: .email, password: false, username: "visible@example.test")
            try await f.seed([concealed, plain, email])
            await f.model.load()

            #expect(f.model.summaries.map(\.usernameIsConcealed) == [true, false, false])
            #expect(f.model.summaries.map(\.username) == [nil, "visible-login", "visible@example.test"])
            // A username-only login is still a login record, so export can select it.
            #expect(f.model.summaries.map(\.hasLogin) == [true, true, true])
            #expect(f.model.summaries.map(\.hasPassword) == [true, true, false])
            #expect(f.model.revealedUsername == nil)

            try await f.model.revealUsername(accountID: concealed.id)
            #expect(f.model.revealedUsername == RevealedUsername(accountID: concealed.id, value: "hidden-login"))

            try await f.model.beginEditing(accountID: concealed.id)
            #expect(f.model.draft?.usernameIsConcealed == true)
            f.model.hideSecrets()
            #expect(f.model.revealedUsername == nil)

            f.manager.lock(reason: .manual)
            #expect(f.model.summaries.isEmpty && f.model.revealedUsername == nil && f.model.draft == nil)
        }
    }

    @Test func lockClearsARevealedConcealedUsername() async throws {
        try await withFixture { f in
            let concealed = basicAuthentication(descriptor: .concealedString, password: false, username: "hidden-login")
            try await f.seed([concealed])
            await f.model.load()
            try await f.model.revealUsername(accountID: concealed.id)
            #expect(f.model.revealedUsername?.value == "hidden-login")

            f.manager.lock(reason: .screenLock)
            #expect(f.model.revealedUsername == nil)
            try await f.unlock()
            #expect(f.model.revealedUsername == nil)
            await #expect(throws: CredentialVaultError.unauthorized) {
                try await f.model.revealUsername(accountID: concealed.id)
            }
        }
    }

    @Test func editingKeepsDescriptorsAndTheirIdentifiers() async throws {
        try await withFixture { f in
            let record = basicAuthentication(descriptor: .concealedString, password: true, username: "hidden-login")
            try await f.seed([record])
            await f.model.load()
            try await f.model.beginEditing(accountID: record.id)
            f.model.draft?.displayName = "Renamed"
            _ = try await f.model.commitDraft()

            let metadata = try #require(try await f.stored().accounts[0].basicAuthenticationMetadata)
            #expect(metadata.username?.id == Data([1]) && metadata.username?.label == "Login" && metadata.username?.fieldType == .concealedString)
            #expect(metadata.password?.id == Data([2]) && metadata.password?.label == "Secret" && metadata.password?.fieldType == .concealedString)
        }
    }

    @Test func descriptorPresenceFollowsExplicitlyAddedAndRemovedValues() async throws {
        try await withFixture { f in
            let withBoth = basicAuthentication(descriptor: .string, password: true)
            let usernameOnly = basicAuthentication(descriptor: .email, password: false, username: "ada@example.test")
            let plain = account("anchor", password: "anchor-password")
            try await f.seed([withBoth, usernameOnly, plain])
            await f.model.load()

            try await f.model.beginEditing(accountID: withBoth.id)
            f.model.draft?.password = nil
            _ = try await f.model.commitDraft()
            var stored = try await f.stored().accounts
            #expect(stored[0].password == nil && stored[0].basicAuthenticationMetadata?.password == nil)
            #expect(stored[0].basicAuthenticationMetadata?.username?.id == Data([1]))

            try await f.model.beginEditing(accountID: usernameOnly.id)
            f.model.draft?.password = "added-password"
            _ = try await f.model.commitDraft()
            stored = try await f.stored().accounts
            #expect(stored[1].password == "added-password")
            #expect(stored[1].basicAuthenticationMetadata?.password?.fieldType == .concealedString)
            #expect(stored[1].basicAuthenticationMetadata?.username?.id == Data([1]))
            #expect(stored[1].basicAuthenticationMetadata?.username?.fieldType == .email)

            try await f.model.beginEditing(accountID: usernameOnly.id)
            f.model.draft?.username = ""
            _ = try await f.model.commitDraft()
            stored = try await f.stored().accounts
            #expect(stored[1].username.isEmpty && stored[1].basicAuthenticationMetadata?.username == nil)
            #expect(stored[1].basicAuthenticationMetadata?.password != nil)
            #expect(stored[2].basicAuthenticationMetadata == nil)
        }
    }

    // MARK: - Lock and authorization

    @Test(arguments: settingsLockReasons)
    func lockClearsVisibleSecrets(reason: CredentialLockReason) async throws {
        try await withFixture { f in
            let record = account("ada", password: "visible-password", totp: rfcGenerator)
            try await f.seed([record])
            await f.model.load()
            try await f.model.revealPassword(accountID: record.id)
            try await f.model.showTOTP(accountID: record.id)
            try await f.model.beginEditing(accountID: record.id)
            #expect(f.model.summaries.count == 1 && f.model.isLoaded)
            #expect(f.model.revealedPassword == RevealedPassword(accountID: record.id, value: "visible-password"))
            #expect(f.model.totpCode(now: 59)?.value == "94287082")
            #expect(f.model.draft?.password == "visible-password")

            f.manager.lock(reason: reason)
            #expect(f.model.summaries.isEmpty && !f.model.isLoaded)
            #expect(f.model.revealedPassword == nil && f.model.totpCode(now: 59) == nil && f.model.draft == nil)
            let sentinel = f.sentinel()
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.revealPassword(accountID: record.id) }
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.copyPassword(accountID: record.id) }
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.model.copyTOTP(accountID: record.id) { 59 } }
            await #expect(throws: CredentialVaultError.unauthorized) { _ = try await f.model.save(record, expectedRevision: 1) }
            #expect(f.pasteboard.string(forType: .string) == sentinel)

            // A new unlock is a new authorization: nothing shown before the lock may reappear.
            try await f.unlock()
            #expect(f.manager.isUnlocked)
            #expect(f.model.summaries.isEmpty && !f.model.isLoaded)
            #expect(f.model.revealedPassword == nil && f.model.totpCode(now: 59) == nil && f.model.draft == nil)
            await f.model.load()
            #expect(f.model.summaries.count == 1)
            #expect(f.model.revealedPassword == nil && f.model.totpCode(now: 59) == nil && f.model.draft == nil)
        }
    }

    @Test func lockedModelLoadsNothingAndPrivateProfilesAreUnavailable() async throws {
        try await withFixture { f in
            try await f.create()
            f.manager.lock(reason: .manual)
            await f.model.load()
            #expect(!f.model.isLoaded && f.model.summaries.isEmpty)
            #expect(f.model.isAvailable)
        }

        let privateModel = CredentialSettingsModel(profile: .privateBrowsing(), pasteboard: NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)")))
        await privateModel.load()
        #expect(!privateModel.isAvailable && !privateModel.isLoaded)
        #expect(!FileManager.default.fileExists(atPath: Profile.privateBrowsing().supportDirectory.appendingPathComponent("Credentials.vault").path))
    }
}
