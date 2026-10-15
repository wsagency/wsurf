// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import WSurf

// Real codec and real vault transitions, driven through the coordinator's production state machine. The
// native `ASCredentialImportManager`/`ASCredentialExportManager` calls are the only steps not exercised here:
// they need the OS chooser and an exact interactive approval, so nothing in this file is evidence of Apple
// provider behavior. `ASExportedCredentialData` values are real, produced by the real codec or built by hand.
@MainActor
struct CredentialExchangeCoordinatorTests {
    static let origin = "https://example.test"

    final class Fixture {
        let profile: Profile
        let otherProfile: Profile
        let coordinator = CredentialExchangeCoordinator()
        let manager: CredentialManager
        /// The settings model on whose behalf the coordinator is driven directly. Model-driven tests stage with
        /// their own model's owner instead.
        let owner = UUID()
        let other: CredentialManager

        let gate: VaultClockGate?
        /// Each manager's vault, created locked, with the passkey that unlocks it.
        private let vaults: [FixtureVault]
        /// Only with a `gate`: the store the gated manager reads, closed by `cleanup`.
        private let gatedStore: ProfileVaultStore?

        /// With a `gate`, the manager is private to this fixture and its store reads the gate's clock.
        @MainActor init(gate: VaultClockGate? = nil) async throws {
            let profile = Profile(id: UUID(), name: "Target", symbol: "key", color: .blue)
            let otherProfile = Profile(id: UUID(), name: "Other", symbol: "key", color: .green)
            let passkeys = VaultPasskeys()
            var gatedStore: ProfileVaultStore?
            let vault: FixtureVault
            let otherVault: FixtureVault
            do {
                if let gate {
                    let made = try await gate.makeVault(profile: profile, passkeys: passkeys)
                    vault = made.vault
                    gatedStore = made.store
                } else {
                    vault = try #require(try await VaultManagerFixture.make(profile: profile, passkeys: passkeys, vaults: [.locked]).vaults.first)
                }
                otherVault = try #require(try await VaultManagerFixture.make(profile: otherProfile, passkeys: passkeys, vaults: [.locked]).vaults.first)
            } catch {
                // No fixture is handed out: whatever it built is released here, including the first profile's gate entry.
                await gatedStore?.close()
                await VaultManagerFixture.cleanup(profile)
                await VaultManagerFixture.cleanup(otherProfile)
                throw error
            }
            self.profile = profile
            self.otherProfile = otherProfile
            self.gate = gate
            self.gatedStore = gatedStore
            self.vaults = [vault, otherVault]
            manager = vault.manager
            other = otherVault.manager
        }

        /// Unlocks `target`'s vault with its own passkey: a new authorization epoch every time.
        @MainActor func unlock(_ target: CredentialManager) async throws {
            try await VaultManagerFixture.unlock(try #require(vaults.first { $0.manager === target }))
        }

        /// Unlocks the target and, when there is anything to save, commits `accounts` as revision 1.
        @MainActor func seed(_ accounts: [CredentialAccount], into target: CredentialManager? = nil) async throws {
            let target = target ?? manager
            try await unlock(target)
            if !accounts.isEmpty {
                _ = try await target.commit(accounts, expectedRevision: try await target.snapshot().revision, authorizedEpoch: try #require(target.authorizationEpoch))
            }
        }

        @MainActor func stored(_ target: CredentialManager? = nil) async throws -> StoreSnapshot {
            try await (target ?? manager).snapshot()
        }

        /// Every stored row of `owner`'s vault: equal before and after means nothing was written.
        func diskBytes(_ owner: Profile? = nil) throws -> [String: Data] {
            let owner = owner ?? profile
            let vault = owner.id == profile.id ? vaults[0] : vaults[1]
            return try VaultManagerFixture.rows(of: vault.vaultID, in: owner)
        }

        /// Blocks the calling thread until the vault's rows differ from `before` (30 s at most): the commit has landed.
        @MainActor func waitForCommit(from before: [String: Data]) -> Bool {
            let deadline = ContinuousClock().now.advanced(by: .seconds(30))
            while ContinuousClock().now < deadline {
                if let current = try? diskBytes(), current != before {
                    return true
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return false
        }

        /// Queues `token`, claims it for `target` and stages `data`, the way the settings page does after the
        /// native fetch returns.
        @MainActor func stage(_ data: ASExportedCredentialData, into target: CredentialManager? = nil, owner: UUID? = nil) async throws {
            let target = target ?? manager
            let owner = owner ?? self.owner
            let token = UUID()
            #expect(coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)) == .accepted)
            try coordinator.claimImport(token: token, for: target, owner: owner)
            try await coordinator.stage(data, into: target, owner: owner)
        }

        @MainActor func cleanup() async {
            coordinator.cancelImport(for: manager, owner: owner)
            coordinator.cancelImport(for: other, owner: owner)
            gate?.release()
            if gate != nil {
                manager.lock(reason: .manual)
            }
            await gatedStore?.close()
            await VaultManagerFixture.cleanup(profile)
            await VaultManagerFixture.cleanup(otherProfile)
        }
    }

    func withFixture(gate: VaultClockGate? = nil, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await Fixture(gate: gate)
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    // MARK: - Builders

    static func activity(type: String = ASCredentialExchangeActivity, token: Any?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        if let token {
            activity.userInfo = [ASCredentialImportToken: token]
        }
        return activity
    }

    func account(
        id: UUID = UUID(),
        username: String = "ada",
        password: String? = "pw",
        passkeys: [WebsitePasskey] = [],
        totp: TOTPGenerator? = nil
    ) -> CredentialAccount {
        CredentialAccount(
            id: id,
            username: username,
            displayName: nil,
            origins: [Self.origin],
            loginURLs: [],
            password: password,
            passkeys: passkeys,
            totp: totp,
            exchangeAccountID: nil,
            exchangeItemID: nil
        )
    }

    func passkey(_ seed: UInt8) throws -> WebsitePasskey {
        WebsitePasskey(
            id: UUID(),
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

    func generator(_ seed: String = "coordinator-seed") -> TOTPGenerator {
        TOTPGenerator(secret: Data(seed.utf8), algorithm: .sha256, period: 45, digits: 8, issuer: "Example", userName: "ada")
    }

    /// The account counts of an import outcome, `[added, updated]`; its `results` list is asserted where it matters.
    func counts(_ outcome: CredentialImportOutcome?) -> [Int]? {
        outcome.map { [$0.added, $0.updated] }
    }

    func neighbours(_ count: Int) -> [CredentialAccount] {
        (0..<count).map { account(username: "neighbour-\($0)", password: "neighbour-pw-\($0)") }
    }

    /// Real codec output for `accounts`, as another app would export it.
    func exported(_ accounts: [CredentialAccount]) throws -> ASExportedCredentialData {
        try CredentialExchangeCodec.export(
            StoreSnapshot(vaultID: UUID(), revision: 0, accounts: accounts, blockedPasswordOrigins: [], stamps: [:]),
            selection: accounts.map {
                CredentialExportSelection(accountID: $0.id, password: $0.password != nil, passkeyIDs: Set($0.passkeys.map(\.id)), totp: $0.totp != nil)
            },
            format: .v1
        )
    }

    func handBuilt(_ items: [ASImportableItem]) -> ASExportedCredentialData {
        ASExportedCredentialData(
            accounts: [ASImportableAccount(id: Data([0xA0, 0x01]), userName: "ada", email: "ada@example.test", collections: [], items: items)],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func item(id: UInt8, scoped: Bool, url: String = "https://example.test/login", _ credentials: [ASImportableCredential], tags: [String] = []) -> ASImportableItem {
        ASImportableItem(
            id: Data([0xB0, id]),
            created: .distantPast,
            lastModified: .distantPast,
            title: "Item \(id)",
            subtitle: nil,
            favorite: false,
            scope: scoped ? ASImportableCredentialScope(urls: [URL(string: url)!], androidApps: []) : nil,
            credentials: credentials,
            tags: tags
        )
    }

    func password(_ value: String) -> ASImportableCredential {
        .basicAuthentication(.init(
            userName: .init(id: nil, fieldType: .string, value: "ada", label: nil),
            password: .init(id: nil, fieldType: .concealedString, value: value, label: nil)
        ))
    }

    func totpCredential(period: UInt16 = 30) -> ASImportableCredential {
        .totp(.init(secret: Data("hand-built-seed".utf8), period: period, digits: 6, userName: "ada", algorithm: .sha1, issuer: "Example"))
    }

    private func passkeyCredential() throws -> ASImportableCredential {
        .passkey(.init(
            credentialID: Data([0xC0, 0x01]),
            relyingPartyIdentifier: "example.test",
            userName: "ada",
            userDisplayName: "Ada",
            userHandle: Data([0x31]),
            key: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        ))
    }

    private func bytes(_ account: CredentialAccount) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(account)
    }

    // MARK: - Activity and token binding

    @Test func receiveQueuesOnlyTheExchangeActivityWithAUUIDToken() {
        let coordinator = CredentialExchangeCoordinator()
        let token = UUID()

        #expect(coordinator.receive(Self.activity(type: "com.example.other", token: token)) == .ignored)
        #expect(coordinator.receive(Self.activity(token: nil)) == .ignored)
        #expect(coordinator.receive(Self.activity(token: "not-a-uuid")) == .ignored)
        #expect(coordinator.pendingToken == nil)

        #expect(coordinator.receive(Self.activity(token: token)) == .accepted)
        #expect(coordinator.pendingToken == token)
        #expect(coordinator.receive(Self.activity(token: token)) == .ignored)
        #expect(coordinator.receive(Self.activity(token: UUID())) == .refused)
        #expect(coordinator.pendingToken == token)

        coordinator.discardPendingImport(token: token)
        #expect(coordinator.pendingToken == nil)
    }

    @Test func tokenProfileAndRevisionStayBound() async throws {
        try await withFixture { f in
            let existing = neighbours(3)
            try await f.seed(existing)
            try await f.unlock(f.other)
            let incoming = try exported([account(username: "grace", password: "incoming")])

            // A locked target never claims the token, and the queued token survives for a retry.
            f.manager.lock(reason: .manual)
            let queued = UUID()
            #expect(f.coordinator.receive(Self.activity(token: queued)) == .accepted)
            #expect(throws: CredentialVaultError.unauthorized) { try f.coordinator.claimImport(token: queued, for: f.manager, owner: f.owner) }
            #expect(f.coordinator.pendingToken == queued)
            try await f.unlock(f.manager)

            // A different token is not the queued one.
            #expect(throws: CredentialExchangeCoordinatorError.tokenMismatch) { try f.coordinator.claimImport(token: UUID(), for: f.manager, owner: f.owner) }
            #expect(f.coordinator.pendingToken == queued)

            // Claiming consumes the token: it can neither be claimed nor queued again.
            try f.coordinator.claimImport(token: queued, for: f.manager, owner: f.owner)
            #expect(f.coordinator.pendingToken == nil)
            #expect(throws: CredentialExchangeCoordinatorError.tokenMismatch) { try f.coordinator.claimImport(token: queued, for: f.manager, owner: f.owner) }
            #expect(f.coordinator.receive(Self.activity(token: queued)) == .ignored)

            // The claim is for this profile's manager only.
            let otherBefore = try f.diskBytes(f.otherProfile)
            await #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) { try await f.coordinator.stage(incoming, into: f.other, owner: f.owner) }
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner) == nil && !f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(try f.diskBytes(f.otherProfile) == otherBefore)

            // Revoked access between claim and staging.
            let revoked = UUID()
            #expect(f.coordinator.receive(Self.activity(token: revoked)) == .accepted)
            try f.coordinator.claimImport(token: revoked, for: f.manager, owner: f.owner)
            f.manager.lock(reason: .screenLock)
            await #expect(throws: CredentialTransferFailure.self) { try await f.coordinator.stage(incoming, into: f.manager, owner: f.owner) }
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))

            // A fresh unlock is a new authorization epoch, not the one the token was bound to.
            try await f.unlock(f.manager)
            let reunlocked = UUID()
            #expect(f.coordinator.receive(Self.activity(token: reunlocked)) == .accepted)
            try f.coordinator.claimImport(token: reunlocked, for: f.manager, owner: f.owner)
            f.manager.lock(reason: .manual)
            try await f.unlock(f.manager)
            await #expect(throws: CredentialTransferFailure.self) { try await f.coordinator.stage(incoming, into: f.manager, owner: f.owner) }
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))

            // Another writer's change to an account the import does not touch survives it: only the touched accounts are compared and written.
            try await f.stage(incoming)
            _ = try await f.manager.commit(existing + [account(username: "newer", password: "newer")], expectedRevision: 2, authorizedEpoch: try #require(f.manager.authorizationEpoch))
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let usernames = try await f.stored().accounts.map(\.username)
            #expect(usernames.contains("newer") && usernames.contains("grace"))
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    // MARK: - Commit

    @Test func aCancelledTaskNeverStartsTheCommit() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(2))
            let before = try f.diskBytes()

            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            let failure = await #expect(throws: CredentialTransferFailure.self) { _ = try await cancelled.value }
            #expect(failure?.message.kind == .discarded)
            #expect(try f.diskBytes() == before)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    // The write is real and parked inside the store, after the manager authorized it and before it writes.
    @Test(arguments: [true, false])
    func cancellingAnInFlightCommitBeforeTheWriteLandsPreservesTheVault(throughCoordinator: Bool) async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(2))
            let before = try f.diskBytes()
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))

            gate.holdImportWrite(of: f.coordinator)
            let committing = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager, owner: f.owner) }
            // The write is parked inside the vault: cancel first, then release. Nothing here touches the manager.
            gate.whenParked {
                if throughCoordinator {
                    f.coordinator.cancelImport(for: f.manager, owner: f.owner)
                } else {
                    committing.cancel()
                }
                gate.release()
            }

            let failure = await #expect(throws: CredentialTransferFailure.self) { _ = try await committing.value }
            // The write had started when the cancel arrived, so only "may have landed" is true, even though the vault is unchanged.
            #expect(failure?.message.kind == .mayHaveLanded)
            #expect(gate.hasParked)
            #expect(try f.diskBytes() == before)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    @Test func cancellationOnceTheCommitHasLandedStillReportsTheReceipt() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(2))
            let before = try f.diskBytes()
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))

            gate.holdImportWrite(of: f.coordinator)
            let committing = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager, owner: f.owner) }
            // The callback holds the main actor from the release until the cancel, so the commit task cannot finish
            // in between: it releases the parked write, waits for the store to commit its rows, then cancels.
            // The store's last cancellation poll is already behind the commit.
            let log = CallbackLog()
            gate.whenParked {
                gate.release()
                log.commitLanded = f.waitForCommit(from: before)
                committing.cancel()
            }

            let receipt = try await committing.value
            #expect(gate.hasParked && log.commitLanded)
            #expect(receipt.revision == 3)
            #expect(try f.diskBytes() != before)
            #expect(try await f.stored().revision == receipt.revision)
        }
    }

    @Test func invalidImportIsAllOrNothing() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(3))
            let before = try f.diskBytes()

            let mixed = handBuilt([
                item(id: 1, scoped: true, [password("valid")]),
                item(id: 2, scoped: true, [totpCredential(period: 0)]),
            ])
            do {
                try await f.stage(mixed)
                Issue.record("A malformed record must abort the whole import")
            } catch let failure as CredentialTransferFailure {
                // The message carries the position, reason and kind only, never the credential's content.
                guard case let .malformed(error) = failure.message.kind else {
                    Issue.record("A malformed record must end the transfer as malformed, with its position")
                    return
                }
                #expect(error.record.description.hasPrefix("account[0]/item[1]"))
                #expect(error.reason == .invalidData && error.credentialKind == .totp)
            }
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(try f.diskBytes() == before)
        }
    }

    @Test func unresolvedConflictsBlockTheCommitUntilEveryOneIsDecided() async throws {
        try await withFixture { f in
            let target = account(password: "old")
            try await f.seed([target] + neighbours(2))
            let before = try f.diskBytes()
            try await f.stage(try exported([account(id: target.id, password: "new")]))

            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.conflicts.count == 1 && !review.isResolved)
            await #expect(throws: CredentialExchangeCoordinatorError.unresolvedConflicts) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(try f.diskBytes() == before)
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))

            // A decision for something that isn't a conflict is refused.
            #expect(throws: CredentialExchangeCoordinatorError.unknownConflict) {
                try f.coordinator.choose(.replace, for: .totp(accountID: UUID()), owner: f.owner)
            }
        }
    }

    @Test(arguments: [CredentialImportChoice.skip, .replace, .addSeparately])
    func conflictChoicesChangeOnlyTheChosenCredential(choice: CredentialImportChoice) async throws {
        try await withFixture { f in
            let target = account(password: "old")
            let others = neighbours(9)
            try await f.seed([target] + others)
            let neighboursBefore = try others.map(bytes)
            try await f.stage(try exported([account(id: target.id, password: "new")]))

            let conflict = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.conflicts.first)
            try f.coordinator.choose(choice, for: conflict.incoming, owner: f.owner)
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.isResolved == true)

            if choice == .skip {
                let failure = await #expect(throws: CredentialTransferFailure.self) {
                    _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
                }
                #expect(failure?.message.kind == .nothingImported)
                #expect(f.coordinator.importReview(for: f.manager, owner: f.owner) != nil)
                #expect(try await f.stored().revision == 2)
                return
            }
            let receipt = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(receipt.revision == 3)
            let after = try await f.stored().accounts
            let neighboursAfter = try others.map { other in try bytes(try #require(after.first { $0.id == other.id })) }
            #expect(neighboursAfter == neighboursBefore)
            switch choice {
            case .replace:
                #expect(after.count == 10)
                #expect(after.first { $0.id == target.id }?.password == "new")
            case .addSeparately:
                #expect(after.count == 11)
                #expect(after.first { $0.id == target.id }?.password == "old")
                #expect(after.filter { $0.password == "new" }.count == 1)
            case .skip, .merge:
                Issue.record("Not a conflict choice exercised here")
            }
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    @Test func unlinkedImportAddsAccountsInOneRevision() async throws {
        try await withFixture { f in
            let existing = neighbours(4)
            try await f.seed(existing)
            let fresh = [
                account(username: "grace", password: "g", totp: generator()),
                account(username: "linus", password: "l", passkeys: [try passkey(7)]),
            ]
            try await f.stage(try exported(fresh))

            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.revision == 2 && review.candidates.count == 2 && review.isResolved)
            #expect(counts(review.outcome) == [2, 0])

            let receipt = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            #expect(receipt.revision == 3)
            let after = try await f.stored().accounts
            #expect(after.count == 6)
            for old in existing {
                #expect(try bytes(try #require(after.first { $0.id == old.id })) == bytes(old), "existing account changed")
            }
            let grace = try #require(after.first { $0.username == "grace" })
            #expect(grace.totp?.period == 45 && grace.totp?.digits == 8 && grace.totp?.algorithm == .sha256)
            let linus = try #require(after.first { $0.username == "linus" })
            #expect(linus.passkeys.first?.credentialID == Data(repeating: 7, count: 32))
        }
    }

    @Test func secretsWithoutAnApprovedOriginAreFlaggedForManualAssociation() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            let data = handBuilt([
                item(id: 1, scoped: false, [password("unscoped-password")]),
                item(id: 2, scoped: false, [totpCredential()]),
                item(id: 3, scoped: false, [try passkeyCredential()]),
                item(id: 4, scoped: true, [password("scoped-password")]),
            ])
            try await f.stage(data)

            let candidates = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates)
            #expect(candidates.count == 4)
            #expect(candidates.map(\.needsManualAssociation) == [true, true, false, false])
        }
    }

    @Test func aUsernameOnlyLoginWithoutAnApprovedOriginNeedsManualAssociation() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            let usernameOnly = ASImportableCredential.basicAuthentication(.init(
                userName: .init(id: nil, fieldType: .string, value: "ada", label: nil),
                password: nil
            ))
            try await f.stage(handBuilt([
                item(id: 1, scoped: false, [usernameOnly]),
                item(id: 2, scoped: true, [usernameOnly]),
            ]))

            let candidates = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates)
            #expect(candidates.map(\.needsManualAssociation) == [true, false])
        }
    }

    // MARK: - Choices on records that are not conflicts

    @Test func anyIncomingRecordCanBeSkippedAndNonConflictsNeedNoDecision() async throws {
        try await withFixture { f in
            let existing = neighbours(2)
            try await f.seed(existing)
            let before = try f.diskBytes()
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))

            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.isResolved && review.conflicts.isEmpty)
            #expect(counts(review.outcome) == [1, 0] && review.outcome?.results.map(\.action) == [.added])

            let record = try #require(review.candidates.first?.records.first)
            try f.coordinator.choose(.skip, for: record.incoming, owner: f.owner)
            #expect(counts(f.coordinator.importReview(for: f.manager, owner: f.owner)?.outcome) == [0, 0])
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.outcome?.results.map(\.action) == [.skipped])
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .nothingImported)
            #expect(try f.diskBytes() == before)
        }
    }

    @Test func mergingIntoAnAccountKeepsItsWebsitesAndShowsThemInFull() async throws {
        try await withFixture { f in
            var bare = account(username: "", password: nil, totp: generator("bare-seed"))
            bare.origins = [Self.origin, "https://other.test"]
            let neighbour = neighbours(1)
            try await f.seed([bare] + neighbour)
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))

            let record = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first)
            // Accounts that already hold a login are not offered; the rest state every website they work on.
            let targets = f.coordinator.mergeTargets(for: record.incoming, owner: f.owner)
            #expect(targets.map(\.accountID) == [bare.id])
            #expect(targets.first?.allowedOrigins == [Self.origin, "https://other.test"])

            try f.coordinator.choose(.merge(into: bare.id), for: record.incoming, owner: f.owner)
            #expect(counts(f.coordinator.importReview(for: f.manager, owner: f.owner)?.outcome) == [0, 1])
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            let after = try await f.stored().accounts
            #expect(after.count == 2)
            let merged = try #require(after.first { $0.id == bare.id })
            #expect(merged.password == "incoming")
            #expect(merged.totp?.secret == Data("bare-seed".utf8))
            #expect(merged.origins == [Self.origin, "https://other.test"])
            #expect(try bytes(try #require(after.first { $0.id == neighbour[0].id })) == bytes(neighbour[0]))
        }
    }

    @Test func choicesTheReviewDoesNotOfferAreRefusedWithoutChangingIt() async throws {
        try await withFixture { f in
            let neighbour = neighbours(1)
            try await f.seed(neighbour)
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            let record = try #require(review.candidates.first?.records.first)

            // Not a conflict, an unknown account, and an account that already has a login.
            for refused: CredentialImportChoice in [.replace, .merge(into: UUID()), .merge(into: neighbour[0].id)] {
                #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                    try f.coordinator.choose(refused, for: record.incoming, owner: f.owner)
                }
            }
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.outcome == review.outcome)
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first?.choice == nil)
        }
    }

    // MARK: - Superseded operations

    @Test func aSupersededStageCanNeitherConsumeNorClearItsSuccessor() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(1))
            let first = UUID()
            #expect(f.coordinator.receive(Self.activity(token: first)) == .accepted)
            try f.coordinator.claimImport(token: first, for: f.manager, owner: f.owner)
            let late = try exported([account(username: "late", password: "late-password")])

            gate.holdNextVaultRead()
            let superseded = Task { @MainActor in try await f.coordinator.stage(late, into: f.manager, owner: f.owner) }
            // The stage is parked inside its vault read and cannot resume before this callback returns: it cancels
            // the stale stage, releases its read, then claims for the successor. The claim reads the manager's
            // authorization, so it waits only for the released read to finish.
            let log = CallbackLog()
            gate.whenParked {
                f.coordinator.cancelImport(for: f.manager, owner: f.owner)
                gate.release()
                log.received = f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: log.token)) == .accepted
                do { try f.coordinator.claimImport(token: log.token, for: f.manager, owner: f.owner) } catch { log.error = error }
            }

            await #expect(throws: CancellationError.self) { try await superseded.value }
            #expect(gate.hasParked && log.received && log.error == nil)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))

            // The successor's claim is intact and it stages only its own data.
            try await f.coordinator.stage(try exported([account(username: "current", password: "current-password")]), into: f.manager, owner: f.owner)
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.map(\.summary.username) == ["current"])
        }
    }

    // MARK: - Merge and Add Separately

    @Test func mergingAnImportedItemIntoAPlainAccountKeepsTheItemsMetadata() async throws {
        try await withFixture { f in
            let bare = account(username: "", password: nil, totp: generator("bare-seed"))
            try await f.seed([bare])
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("incoming")], tags: ["work", "shared"])]))

            let record = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first)
            #expect(f.coordinator.mergeTargets(for: record.incoming, owner: f.owner).map(\.accountID) == [bare.id])
            try f.coordinator.choose(.merge(into: bare.id), for: record.incoming, owner: f.owner)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            let stored = try await f.stored()
            let merged = try #require(stored.accounts.first)
            #expect(merged.password == "incoming" && merged.totp?.secret == Data("bare-seed".utf8))
            #expect(merged.exchangeItemID == Data([0xB0, 1]))
            let reexported = try await f.coordinator.prepareExport(
                selection: [CredentialExportSelection(accountID: bare.id, password: true, passkeyIDs: [], totp: true)],
                expectedStamps: stored.stamps, format: .v1, from: f.manager, epoch: try #require(f.manager.authorizationEpoch)
            )
            let exportedItem = try #require(reexported.accounts.first?.items.first)
            #expect(exportedItem.id == Data([0xB0, 1]) && exportedItem.tags == ["work", "shared"])
        }
    }

    @Test func aMergeThatWouldDropAnotherImportedItemsMetadataIsNotOffered() async throws {
        try await withFixture { f in
            try await f.unlock(f.manager)
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("first")], tags: ["first"])]))
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let first = try #require(try await f.stored().accounts.first)

            try await f.stage(handBuilt([item(id: 2, scoped: true, [totpCredential()], tags: ["second"])]))
            let record = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first)
            #expect(f.coordinator.mergeTargets(for: record.incoming, owner: f.owner).isEmpty)
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                try f.coordinator.choose(.merge(into: first.id), for: record.incoming, owner: f.owner)
            }
            #expect(counts(f.coordinator.importReview(for: f.manager, owner: f.owner)?.outcome) == [1, 0])
        }
    }

    @Test func mergingOneCredentialOfACombinedItemKeepsTheItemsNameAndSplitsTheRest() async throws {
        try await withFixture { f in
            let destination = account(username: "", password: nil, passkeys: [try passkey(6)])
            try await f.seed([destination])
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("incoming"), totpCredential()], tags: ["work"])]))

            let records = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records)
            let login = try #require(records.first { $0.kind == .password })
            #expect(f.coordinator.mergeTargets(for: login.incoming, owner: f.owner).map(\.accountID) == [destination.id])
            // The full plan, with the code left to import by itself, is valid: the choice is accepted.
            try f.coordinator.choose(.merge(into: destination.id), for: login.incoming, owner: f.owner)
            #expect(counts(f.coordinator.importReview(for: f.manager, owner: f.owner)?.outcome) == [1, 1])

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try await f.stored().accounts
            #expect(stored.count == 2)
            let merged = try #require(stored.first { $0.id == destination.id })
            let separate = try #require(stored.first { $0.id != destination.id })
            #expect(merged.password == "incoming" && merged.displayName == "Item 1" && merged.exchangeItemID == Data([0xB0, 1]))
            #expect(separate.totp != nil && separate.displayName == "Item 1" && separate.exchangeItemID != merged.exchangeItemID)

            // Both still export, each under its own identifiers, with the item's tags.
            let reexported = try await f.coordinator.prepareExport(
                selection: stored.map { CredentialExportSelection(accountID: $0.id, password: $0.password != nil, passkeyIDs: [], totp: $0.totp != nil) },
                expectedStamps: try await f.stored().stamps, format: .v1, from: f.manager,
                epoch: try #require(f.manager.authorizationEpoch)
            )
            let items = reexported.accounts.flatMap(\.items)
            #expect(items.count == 2 && Set(items.map(\.id)).count == 2 && items.allSatisfy { $0.tags == ["work"] && $0.title == "Item 1" })
        }
    }

    @Test func aDifferentlyNamedAccountIsNotOfferedAsAMergeTarget() async throws {
        try await withFixture { f in
            var named = account(username: "", password: nil, passkeys: [try passkey(7)])
            named.displayName = "My own name"
            try await f.seed([named])
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("incoming")])]))

            let record = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first)
            #expect(f.coordinator.mergeTargets(for: record.incoming, owner: f.owner).isEmpty)
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                try f.coordinator.choose(.merge(into: named.id), for: record.incoming, owner: f.owner)
            }
        }
    }

    /// A stored passkey's cryptographic identity is fixed (§13.3): the credential ID is held, so the import can only
    /// be skipped. Replacing and adding are both refused and leave the review as it was.
    @Test func aPasskeyWhoseCredentialIDIsStoredCanOnlyBeSkipped() async throws {
        try await withFixture { f in
            let id = UUID()
            let stored = account(id: id, username: "", password: nil, passkeys: [try passkey(5)])
            try await f.seed([stored] + neighbours(1))
            let incomingKey = try passkey(5) // same credential ID and relying party, different key
            try await f.stage(try exported([account(id: id, username: "", password: nil, passkeys: [incomingKey])]))

            let record = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.conflicts.first)
            #expect(!record.canAddSeparately)
            #expect(f.coordinator.mergeTargets(for: record.incoming, owner: f.owner).isEmpty)
            for refused: CredentialImportChoice in [.addSeparately, .replace] {
                #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                    try f.coordinator.choose(refused, for: record.incoming, owner: f.owner)
                }
            }
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.isResolved == false)

            try f.coordinator.choose(.skip, for: record.incoming, owner: f.owner)
            // Skipping the only conflict leaves nothing to write: the vault is untouched.
            let before = try f.diskBytes()
            let failure = await #expect(throws: CredentialTransferFailure.self) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(failure?.message.kind == .nothingImported)
            #expect(try f.diskBytes() == before)
            let after = try await f.stored()
            #expect(after.revision == 2)
            #expect(after.accounts.count == 2)
            #expect(after.accounts.first { $0.id == id }?.passkeys.map(\.privateKeyPKCS8) == [stored.passkeys[0].privateKeyPKCS8])
        }
    }

    // MARK: - Lifecycle

    @Test func lockOrReunlockDropsTheStagedImport() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner) != nil)

            f.manager.lock(reason: .sleep)
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner) == nil && !f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))

            try await f.unlock(f.manager)
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner) == nil && !f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            await #expect(throws: CredentialExchangeCoordinatorError.noStagedImport) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            }
            #expect(try await f.stored().accounts.count == 1)
        }
    }

    @Test func reviewIsOnlyVisibleForTheBoundProfile() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.unlock(f.other)
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))

            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner) != nil)
            #expect(f.coordinator.importReview(for: f.other, owner: f.owner) == nil)
            let otherBefore = try f.diskBytes(f.otherProfile)
            await #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) {
                _ = try await f.coordinator.commitImport(into: f.other, owner: f.owner)
            }
            #expect(try f.diskBytes(f.otherProfile) == otherBefore)
        }
    }
}

// MARK: - Deterministic vault synchronization

/// Parks the store's thread the next time it reads the manager's clock. The store reads it off the main
/// thread, before it writes anything, so a parked operation is genuinely in flight; the manager's own reads
/// happen on the main thread and are never held.
///
/// A parked read can hold the store's operation lock, so another operation on the same store waits until the
/// read has been released. Nothing here awaits a suspended task to make progress: a plain thread notices the
/// park and runs the test's callback on the main queue, which releases the gate at the point the test needs.
nonisolated final class VaultClockGate: Sendable {
    private let armed = Mutex(false)
    private let didPark = Mutex(false)
    private let parked = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func holdNextVaultRead() {
        armed.withLock { $0 = true }
    }

    var hasParked: Bool {
        didPark.withLock { $0 }
    }

    func now() -> ContinuousClock.Instant {
        if !Thread.isMainThread, armed.withLock({ (state: inout Bool) -> Bool in
            defer { state = false }
            return state
        }) {
            didPark.withLock { $0 = true }
            parked.signal()
            // Bounded so a test that never gets to `release()` cannot keep the store's operation lock forever.
            _ = released.wait(timeout: .now() + 40)
        }
        return ContinuousClock().now
    }

    /// Once a held read is parked, runs `callback` once on the main actor, synchronously. The callback must call
    /// `release()` itself, in the order its test requires. If nothing parks within 30 seconds the callback is
    /// skipped and the gate released, and the test sees that through `hasParked`.
    func whenParked(_ callback: @escaping @MainActor @Sendable () -> Void) {
        Thread.detachNewThread {
            let reached = self.parked.wait(timeout: .now() + 30) == .success
            DispatchQueue.main.async {
                if reached {
                    MainActor.assumeIsolated { callback() }
                } else {
                    self.released.signal()
                }
            }
        }
    }

    func release() {
        released.signal()
    }
}

extension VaultClockGate {
    /// Holds the first vault read after the import's last re-check: the account write itself, not the fresh snapshot the
    /// re-check takes first.
    @MainActor func holdImportWrite(of coordinator: CredentialExchangeCoordinator) {
        coordinator.afterLastCheck = { [self] in holdNextVaultRead() }
    }
}

extension VaultClockGate {
    /// An unlockable vault of `profile` (in its real support directory) whose store and manager both read this gate's
    /// clock. The manager is private to the caller, not in the registry; the caller closes `store`.
    @MainActor func makeVault(profile: Profile, passkeys: VaultPasskeys) async throws -> (vault: FixtureVault, store: ProfileVaultStore) {
        nonisolated(unsafe) let defaults = ProfileSettingsStore.defaults(for: profile)
        let store = ProfileVaultStore(profileID: profile.id, directory: profile.supportDirectory, defaults: defaults, now: { self.now() })
        let proof = VaultFixtures.proof(UInt8(passkeys.registered.count + 1))
        passkeys.adopt(proof)
        let lease = VaultAccess(profileID: profile.id, epoch: 0, deadline: ContinuousClock().now.advanced(by: .seconds(300)))
        let vaultID = try await store.createVault(name: "Gated", unlock: proof, authorizedBy: .firstVault(lease: lease))
        let manager = VaultManagerFixture.manager(
            profileID: profile.id, vaultID: vaultID, store: store, passkeys: passkeys, now: { self.now() }
        )
        return (FixtureVault(manager: manager, vaultID: vaultID, proof: proof), store)
    }
}

/// What a main-actor callback run by `VaultClockGate.whenParked` observed.
@MainActor final class CallbackLog {
    let token = UUID()
    var received = false
    var commitLanded = false
    var error: (any Error)?
}
