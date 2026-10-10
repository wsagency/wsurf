// SPDX-FileCopyrightText: 2026 WSurf contributors
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
    private static let origin = "https://example.test"

    private final class Fixture {
        let profile = Profile(id: UUID(), name: "Target", symbol: "key", color: .blue)
        let otherProfile = Profile(id: UUID(), name: "Other", symbol: "key", color: .green)
        let proof = VaultUnlockProof(
            credentialID: Data(repeating: 1, count: 32),
            prfInput: Data(repeating: 2, count: 32),
            prf: SymmetricKey(size: .bits256)
        )
        let coordinator = CredentialExchangeCoordinator()
        let manager: CredentialManager
        let other: CredentialManager

        let gate: VaultClockGate?

        /// With a `gate`, the manager is private to this fixture and its vault reads the gate's clock.
        @MainActor init(gate: VaultClockGate? = nil) throws {
            self.gate = gate
            if let gate {
                manager = try CredentialManager(profile: profile, directory: profile.supportDirectory, now: { gate.now() })
            } else {
                manager = try CredentialManager.forProfile(profile)
            }
            other = try CredentialManager.forProfile(otherProfile)
        }

        @MainActor func create(_ target: CredentialManager) async throws {
            try await target.completeCreate(proof, access: target.beginAccess())
        }

        @MainActor func unlock(_ target: CredentialManager) async throws {
            try await target.completeUnlock(credentialID: proof.credentialID, prf: proof.prf, access: target.beginAccess())
        }

        @MainActor func seed(_ accounts: [CredentialAccount], into target: CredentialManager? = nil) async throws {
            let target = target ?? manager
            try await create(target)
            if !accounts.isEmpty { _ = try await target.commit(accounts, expectedRevision: 0) }
        }

        @MainActor func stored(_ target: CredentialManager? = nil) async throws -> VaultSnapshot {
            try await (target ?? manager).snapshot()
        }

        func diskBytes(_ owner: Profile? = nil) throws -> Data {
            try Data(contentsOf: (owner ?? profile).supportDirectory.appendingPathComponent("Credentials.vault"))
        }

        /// Queues `token`, claims it for `target` and stages `data`, the way the settings page does after the
        /// native fetch returns.
        @MainActor func stage(_ data: ASExportedCredentialData, into target: CredentialManager? = nil) async throws {
            let target = target ?? manager
            let token = UUID()
            #expect(coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
            try coordinator.claimImport(token: token, for: target)
            try await coordinator.stage(data, into: target)
        }

        @MainActor func cleanup() async {
            coordinator.cancelImport(for: manager)
            coordinator.cancelImport(for: other)
            gate?.release()
            if gate != nil { manager.lock(reason: .manual) }
            await CredentialManager.retire(profileID: profile.id)
            await CredentialManager.retire(profileID: otherProfile.id)
            try? FileManager.default.removeItem(at: profile.supportDirectory)
            try? FileManager.default.removeItem(at: otherProfile.supportDirectory)
        }
    }

    private func withFixture(gate: VaultClockGate? = nil, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(gate: gate)
        do { try await body(fixture) } catch { await fixture.cleanup(); throw error }
        await fixture.cleanup()
    }

    // MARK: - Builders

    static func activity(type: String = ASCredentialExchangeActivity, token: Any?) -> NSUserActivity {
        let activity = NSUserActivity(activityType: type)
        if let token { activity.userInfo = [ASCredentialImportToken: token] }
        return activity
    }

    private func account(
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

    private func passkey(_ seed: UInt8) throws -> WebsitePasskey {
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

    private func generator(_ seed: String = "coordinator-seed") -> TOTPGenerator {
        TOTPGenerator(secret: Data(seed.utf8), algorithm: .sha256, period: 45, digits: 8, issuer: "Example", userName: "ada")
    }

    private func neighbours(_ count: Int) -> [CredentialAccount] {
        (0..<count).map { account(username: "neighbour-\($0)", password: "neighbour-pw-\($0)") }
    }

    /// Real codec output for `accounts`, as another app would export it.
    private func exported(_ accounts: [CredentialAccount]) throws -> ASExportedCredentialData {
        try CredentialExchangeCodec.export(
            VaultSnapshot(revision: 0, accounts: accounts, blockedPasswordOrigins: []),
            selection: accounts.map {
                CredentialExportSelection(accountID: $0.id, password: $0.password != nil, passkeyIDs: Set($0.passkeys.map(\.id)), totp: $0.totp != nil)
            },
            format: .v1
        )
    }

    private func handBuilt(_ items: [ASImportableItem]) -> ASExportedCredentialData {
        ASExportedCredentialData(
            accounts: [ASImportableAccount(id: Data([0xA0, 0x01]), userName: "ada", email: "ada@example.test", collections: [], items: items)],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func item(id: UInt8, scoped: Bool, url: String = "https://example.test/login", _ credentials: [ASImportableCredential], tags: [String] = []) -> ASImportableItem {
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

    private func password(_ value: String) -> ASImportableCredential {
        .basicAuthentication(.init(
            userName: .init(id: nil, fieldType: .string, value: "ada", label: nil),
            password: .init(id: nil, fieldType: .concealedString, value: value, label: nil)
        ))
    }

    private func totpCredential(period: UInt16 = 30) -> ASImportableCredential {
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

        #expect(!coordinator.receive(Self.activity(type: "com.example.other", token: token)))
        #expect(!coordinator.receive(Self.activity(token: nil)))
        #expect(!coordinator.receive(Self.activity(token: "not-a-uuid")))
        #expect(coordinator.pendingToken == nil)

        #expect(coordinator.receive(Self.activity(token: token)))
        #expect(coordinator.pendingToken == token)
        #expect(!coordinator.receive(Self.activity(token: token)))
        #expect(!coordinator.receive(Self.activity(token: UUID())))
        #expect(coordinator.pendingToken == token)

        coordinator.discardPendingImport()
        #expect(coordinator.pendingToken == nil)
    }

    @Test func tokenProfileAndRevisionStayBound() async throws {
        try await withFixture { f in
            let existing = neighbours(3)
            try await f.seed(existing)
            try await f.create(f.other)
            let incoming = try exported([account(username: "grace", password: "incoming")])

            // A locked target never claims the token, and the queued token survives for a retry.
            f.manager.lock(reason: .manual)
            let queued = UUID()
            #expect(f.coordinator.receive(Self.activity(token: queued)))
            #expect(throws: CredentialVaultError.unauthorized) { try f.coordinator.claimImport(token: queued, for: f.manager) }
            #expect(f.coordinator.pendingToken == queued)
            try await f.unlock(f.manager)

            // A different token is not the queued one.
            #expect(throws: CredentialExchangeCoordinatorError.tokenMismatch) { try f.coordinator.claimImport(token: UUID(), for: f.manager) }
            #expect(f.coordinator.pendingToken == queued)

            // Claiming consumes the token: it can neither be claimed nor queued again.
            try f.coordinator.claimImport(token: queued, for: f.manager)
            #expect(f.coordinator.pendingToken == nil)
            #expect(throws: CredentialExchangeCoordinatorError.tokenMismatch) { try f.coordinator.claimImport(token: queued, for: f.manager) }
            #expect(!f.coordinator.receive(Self.activity(token: queued)))

            // The claim is for this profile's manager only.
            let otherBefore = try f.diskBytes(f.otherProfile)
            await #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) { try await f.coordinator.stage(incoming, into: f.other) }
            #expect(f.coordinator.importReview == nil && !f.coordinator.hasStagedImport(for: f.manager))
            #expect(try f.diskBytes(f.otherProfile) == otherBefore)

            // Revoked access between claim and staging.
            let revoked = UUID()
            #expect(f.coordinator.receive(Self.activity(token: revoked)))
            try f.coordinator.claimImport(token: revoked, for: f.manager)
            f.manager.lock(reason: .screenLock)
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.coordinator.stage(incoming, into: f.manager) }
            #expect(!f.coordinator.hasStagedImport(for: f.manager))

            // A fresh unlock is a new authorization epoch, not the one the token was bound to.
            try await f.unlock(f.manager)
            let reunlocked = UUID()
            #expect(f.coordinator.receive(Self.activity(token: reunlocked)))
            try f.coordinator.claimImport(token: reunlocked, for: f.manager)
            f.manager.lock(reason: .manual)
            try await f.unlock(f.manager)
            await #expect(throws: CredentialVaultError.unauthorized) { try await f.coordinator.stage(incoming, into: f.manager) }
            #expect(!f.coordinator.hasStagedImport(for: f.manager))

            // A vault that changed after the preview is never overwritten by it.
            try await f.stage(incoming)
            _ = try await f.manager.commit(existing + [account(username: "newer", password: "newer")], expectedRevision: 1)
            let afterNewer = try f.diskBytes()
            await #expect(throws: CredentialVaultError.staleRevision) { _ = try await f.coordinator.commitImport(into: f.manager) }
            #expect(try f.diskBytes() == afterNewer)
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
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
                return try await f.coordinator.commitImport(into: f.manager)
            }
            await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
            #expect(try f.diskBytes() == before)
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
        }
    }

    // The write is real and parked inside the vault, after the manager authorized it and before it replaces the file.
    @Test(arguments: [true, false])
    func cancellingAnInFlightCommitBeforeTheFileIsReplacedPreservesTheVault(throughCoordinator: Bool) async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(2))
            let before = try f.diskBytes()
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))

            gate.holdNextVaultRead()
            let committing = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager) }
            // The write is parked inside the vault: cancel first, then release. Nothing here touches the manager.
            gate.whenParked {
                if throughCoordinator { f.coordinator.cancelImport(for: f.manager) } else { committing.cancel() }
                gate.release()
            }

            await #expect(throws: CancellationError.self) { _ = try await committing.value }
            #expect(gate.hasParked)
            #expect(try f.diskBytes() == before)
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
        }
    }

    @Test func cancellationOnceTheFileIsBeingReplacedStillReportsTheReceipt() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(2))
            let before = try f.diskBytes()
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            let file = f.profile.supportDirectory.appendingPathComponent("Credentials.vault")
            let watcher = try DirectoryChangeWatcher(f.profile.supportDirectory)
            defer { watcher.stop() }

            gate.holdNextVaultRead()
            let committing = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager) }
            // The callback holds the main actor from the release until the cancel, so the commit task cannot finish
            // in between: it releases the parked write, waits for the vault to replace the file, then cancels.
            // The vault's cancellation check is already behind the replacement.
            let log = CallbackLog()
            gate.whenParked {
                gate.release()
                log.committedFileChanged = watcher.waitForChange(of: file, from: before)
                committing.cancel()
            }

            let receipt = try await committing.value
            #expect(gate.hasParked && log.committedFileChanged)
            #expect(receipt.revision == 2)
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
            } catch let error as CredentialExchangeError {
                #expect(error.reason == .invalidData)
                #expect(error.record.description.hasPrefix("account[0]/item[1]"))
            }
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
            #expect(try f.diskBytes() == before)
        }
    }

    @Test func unresolvedConflictsBlockTheCommitUntilEveryOneIsDecided() async throws {
        try await withFixture { f in
            let target = account(password: "old")
            try await f.seed([target] + neighbours(2))
            let before = try f.diskBytes()
            try await f.stage(try exported([account(id: target.id, password: "new")]))

            let review = try #require(f.coordinator.importReview)
            #expect(review.conflicts.count == 1 && !review.isResolved)
            await #expect(throws: CredentialExchangeCoordinatorError.unresolvedConflicts) {
                _ = try await f.coordinator.commitImport(into: f.manager)
            }
            #expect(try f.diskBytes() == before)
            #expect(f.coordinator.hasStagedImport(for: f.manager))

            // A decision for something that isn't a conflict is refused.
            #expect(throws: CredentialExchangeCoordinatorError.unknownConflict) {
                try f.coordinator.choose(.replace, for: .totp(accountID: UUID()))
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

            let conflict = try #require(f.coordinator.importReview?.conflicts.first)
            try f.coordinator.choose(choice, for: conflict.incoming)
            #expect(f.coordinator.importReview?.isResolved == true)

            if choice == .skip {
                await #expect(throws: CredentialExchangeCoordinatorError.nothingToImport) {
                    _ = try await f.coordinator.commitImport(into: f.manager)
                }
                #expect(try await f.stored().revision == 1)
                return
            }
            let receipt = try await f.coordinator.commitImport(into: f.manager)
            #expect(receipt.revision == 2)
            let after = try await f.stored().accounts
            #expect(try after.filter { other in others.contains { $0.id == other.id } }.map(bytes) == neighboursBefore)
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
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
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

            let review = try #require(f.coordinator.importReview)
            #expect(review.revision == 1 && review.candidates.count == 2 && review.isResolved)
            #expect(review.outcome == CredentialImportOutcome(added: 2, updated: 0))

            let receipt = try await f.coordinator.commitImport(into: f.manager)
            #expect(receipt.revision == 2)
            let after = try await f.stored().accounts
            #expect(after.count == 6)
            #expect(try after.prefix(4).map(bytes) == existing.map(bytes))
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

            let candidates = try #require(f.coordinator.importReview?.candidates)
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

            let candidates = try #require(f.coordinator.importReview?.candidates)
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

            let review = try #require(f.coordinator.importReview)
            #expect(review.isResolved && review.conflicts.isEmpty)
            #expect(review.outcome == CredentialImportOutcome(added: 1, updated: 0))

            let record = try #require(review.candidates.first?.records.first)
            try f.coordinator.choose(.skip, for: record.incoming)
            #expect(f.coordinator.importReview?.outcome == CredentialImportOutcome(added: 0, updated: 0))
            await #expect(throws: CredentialExchangeCoordinatorError.nothingToImport) {
                _ = try await f.coordinator.commitImport(into: f.manager)
            }
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

            let record = try #require(f.coordinator.importReview?.candidates.first?.records.first)
            // Accounts that already hold a login are not offered; the rest state every website they work on.
            let targets = f.coordinator.mergeTargets(for: record.incoming)
            #expect(targets.map(\.accountID) == [bare.id])
            #expect(targets.first?.allowedOrigins == [Self.origin, "https://other.test"])

            try f.coordinator.choose(.merge(into: bare.id), for: record.incoming)
            #expect(f.coordinator.importReview?.outcome == CredentialImportOutcome(added: 0, updated: 1))
            _ = try await f.coordinator.commitImport(into: f.manager)

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
            let review = try #require(f.coordinator.importReview)
            let record = try #require(review.candidates.first?.records.first)

            // Not a conflict, an unknown account, and an account that already has a login.
            for refused: CredentialImportChoice in [.replace, .merge(into: UUID()), .merge(into: neighbour[0].id)] {
                #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                    try f.coordinator.choose(refused, for: record.incoming)
                }
            }
            #expect(f.coordinator.importReview?.outcome == review.outcome)
            #expect(f.coordinator.importReview?.candidates.first?.records.first?.choice == nil)
        }
    }

    // MARK: - Superseded operations

    @Test func aSupersededStageCanNeitherConsumeNorClearItsSuccessor() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(1))
            let first = UUID()
            #expect(f.coordinator.receive(Self.activity(token: first)))
            try f.coordinator.claimImport(token: first, for: f.manager)
            let late = try exported([account(username: "late", password: "late-password")])

            gate.holdNextVaultRead()
            let superseded = Task { @MainActor in try await f.coordinator.stage(late, into: f.manager) }
            // The stage is parked inside its vault read and cannot resume before this callback returns: it cancels
            // the stale stage, releases its read, then claims for the successor. The claim reads the manager's
            // authorization, so it waits only for the released read to finish.
            let log = CallbackLog()
            gate.whenParked {
                f.coordinator.cancelImport(for: f.manager)
                gate.release()
                log.received = f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: log.token))
                do { try f.coordinator.claimImport(token: log.token, for: f.manager) } catch { log.error = error }
            }

            await #expect(throws: CancellationError.self) { try await superseded.value }
            #expect(gate.hasParked && log.received && log.error == nil)
            #expect(!f.coordinator.hasStagedImport(for: f.manager))

            // The successor's claim is intact and it stages only its own data.
            try await f.coordinator.stage(try exported([account(username: "current", password: "current-password")]), into: f.manager)
            #expect(f.coordinator.importReview?.candidates.map(\.summary.username) == ["current"])
        }
    }

    // MARK: - Merge and Add Separately

    @Test func mergingAnImportedItemIntoAPlainAccountKeepsTheItemsMetadata() async throws {
        try await withFixture { f in
            let bare = account(username: "", password: nil, totp: generator("bare-seed"))
            try await f.seed([bare])
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("incoming")], tags: ["work", "shared"])]))

            let record = try #require(f.coordinator.importReview?.candidates.first?.records.first)
            #expect(f.coordinator.mergeTargets(for: record.incoming).map(\.accountID) == [bare.id])
            try f.coordinator.choose(.merge(into: bare.id), for: record.incoming)
            _ = try await f.coordinator.commitImport(into: f.manager)

            let stored = try await f.stored()
            let merged = try #require(stored.accounts.first)
            #expect(merged.password == "incoming" && merged.totp?.secret == Data("bare-seed".utf8))
            #expect(merged.exchangeItemID == Data([0xB0, 1]))
            let reexported = try await f.coordinator.prepareExport(
                selection: [CredentialExportSelection(accountID: bare.id, password: true, passkeyIDs: [], totp: true)],
                expectedRevision: stored.revision, format: .v1, from: f.manager, epoch: try #require(f.manager.authorizationEpoch)
            )
            let exportedItem = try #require(reexported.accounts.first?.items.first)
            #expect(exportedItem.id == Data([0xB0, 1]) && exportedItem.tags == ["work", "shared"])
        }
    }

    @Test func aMergeThatWouldDropAnotherImportedItemsMetadataIsNotOffered() async throws {
        try await withFixture { f in
            try await f.create(f.manager)
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("first")], tags: ["first"])]))
            _ = try await f.coordinator.commitImport(into: f.manager)
            let first = try #require(try await f.stored().accounts.first)

            try await f.stage(handBuilt([item(id: 2, scoped: true, [totpCredential()], tags: ["second"])]))
            let record = try #require(f.coordinator.importReview?.candidates.first?.records.first)
            #expect(f.coordinator.mergeTargets(for: record.incoming).isEmpty)
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                try f.coordinator.choose(.merge(into: first.id), for: record.incoming)
            }
            #expect(f.coordinator.importReview?.outcome == CredentialImportOutcome(added: 1, updated: 0))
        }
    }

    @Test func mergingOneCredentialOfACombinedItemKeepsTheItemsNameAndSplitsTheRest() async throws {
        try await withFixture { f in
            let destination = account(username: "", password: nil, passkeys: [try passkey(6)])
            try await f.seed([destination])
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("incoming"), totpCredential()], tags: ["work"])]))

            let records = try #require(f.coordinator.importReview?.candidates.first?.records)
            let login = try #require(records.first { $0.kind == .password })
            #expect(f.coordinator.mergeTargets(for: login.incoming).map(\.accountID) == [destination.id])
            // The full plan, with the code left to import by itself, is valid: the choice is accepted.
            try f.coordinator.choose(.merge(into: destination.id), for: login.incoming)
            #expect(f.coordinator.importReview?.outcome == CredentialImportOutcome(added: 1, updated: 1))

            _ = try await f.coordinator.commitImport(into: f.manager)
            let stored = try await f.stored().accounts
            #expect(stored.count == 2)
            let merged = try #require(stored.first { $0.id == destination.id })
            let separate = try #require(stored.first { $0.id != destination.id })
            #expect(merged.password == "incoming" && merged.displayName == "Item 1" && merged.exchangeItemID == Data([0xB0, 1]))
            #expect(separate.totp != nil && separate.displayName == "Item 1" && separate.exchangeItemID != merged.exchangeItemID)

            // Both still export, each under its own identifiers, with the item's tags.
            let reexported = try await f.coordinator.prepareExport(
                selection: stored.map { CredentialExportSelection(accountID: $0.id, password: $0.password != nil, passkeyIDs: [], totp: $0.totp != nil) },
                expectedRevision: try await f.stored().revision, format: .v1, from: f.manager,
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

            let record = try #require(f.coordinator.importReview?.candidates.first?.records.first)
            #expect(f.coordinator.mergeTargets(for: record.incoming).isEmpty)
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                try f.coordinator.choose(.merge(into: named.id), for: record.incoming)
            }
        }
    }

    @Test func aPasskeyWhoseCredentialIDIsStoredCanOnlyBeReplacedOrSkipped() async throws {
        try await withFixture { f in
            let id = UUID()
            let stored = account(id: id, username: "", password: nil, passkeys: [try passkey(5)])
            try await f.seed([stored] + neighbours(1))
            let incomingKey = try passkey(5) // same credential ID and relying party, different key
            try await f.stage(try exported([account(id: id, username: "", password: nil, passkeys: [incomingKey])]))

            let record = try #require(f.coordinator.importReview?.conflicts.first)
            #expect(!record.canAddSeparately)
            #expect(f.coordinator.mergeTargets(for: record.incoming).isEmpty)
            #expect(throws: CredentialExchangeCoordinatorError.invalidChoice) {
                try f.coordinator.choose(.addSeparately, for: record.incoming)
            }
            #expect(f.coordinator.importReview?.isResolved == false)

            try f.coordinator.choose(.replace, for: record.incoming)
            _ = try await f.coordinator.commitImport(into: f.manager)
            let after = try await f.stored().accounts
            #expect(after.count == 2)
            #expect(after.first { $0.id == id }?.passkeys.map(\.privateKeyPKCS8) == [incomingKey.privateKeyPKCS8])
        }
    }

    // MARK: - Lifecycle

    @Test func lockOrReunlockDropsTheStagedImport() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            #expect(f.coordinator.importReview != nil)

            f.manager.lock(reason: .sleep)
            #expect(f.coordinator.importReview == nil && !f.coordinator.hasStagedImport(for: f.manager))

            try await f.unlock(f.manager)
            #expect(f.coordinator.importReview == nil && !f.coordinator.hasStagedImport(for: f.manager))
            await #expect(throws: CredentialExchangeCoordinatorError.noStagedImport) {
                _ = try await f.coordinator.commitImport(into: f.manager)
            }
            #expect(try await f.stored().accounts.count == 1)
        }
    }

    @Test func reviewIsOnlyVisibleForTheBoundProfile() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.create(f.other)
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))

            #expect(f.coordinator.importReview(for: f.manager) != nil)
            #expect(f.coordinator.importReview(for: f.other) == nil)
            let otherBefore = try f.diskBytes(f.otherProfile)
            await #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) {
                _ = try await f.coordinator.commitImport(into: f.other)
            }
            #expect(try f.diskBytes(f.otherProfile) == otherBefore)
        }
    }

    // MARK: - Export

    @Test func exportContainsOnlySelectedCredentialsAndNeverChangesTheSource() async throws {
        try await withFixture { f in
            let key = try passkey(3)
            let linked = account(username: "ada", password: "linked-password", passkeys: [key], totp: generator("linked-seed"))
            let totpOwner = account(username: "grace", password: "grace-password", totp: generator("grace-seed"))
            let others = neighbours(8)
            try await f.seed([linked, totpOwner] + others)
            let before = try f.diskBytes()

            let data = try await f.coordinator.prepareExport(
                selection: [
                    CredentialExportSelection(accountID: linked.id, password: true, passkeyIDs: [key.id], totp: false),
                    CredentialExportSelection(accountID: totpOwner.id, password: false, passkeyIDs: [], totp: true),
                ],
                expectedRevision: 1,
                format: .v1,
                from: f.manager,
                epoch: try #require(f.manager.authorizationEpoch)
            )
            #expect(try f.diskBytes() == before)
            #expect(data.exporterRelyingPartyIdentifier == PasskeyVaultUnlocker.relyingParty)

            // Reimport into the other profile: exactly the selected credentials arrive, nothing else.
            try await f.create(f.other)
            try await f.stage(data, into: f.other)
            _ = try await f.coordinator.commitImport(into: f.other)
            let received = try await f.stored(f.other).accounts
            #expect(received.count == 2)
            let receivedLinked = try #require(received.first { $0.passkeys.first?.credentialID == key.credentialID })
            #expect(receivedLinked.password == "linked-password")
            #expect(receivedLinked.passkeys.first?.credentialID == key.credentialID)
            #expect(receivedLinked.totp == nil)
            let receivedTOTP = try #require(received.first { $0.totp?.secret == Data("grace-seed".utf8) })
            #expect(receivedTOTP.password == nil)
            #expect(receivedTOTP.totp?.secret == Data("grace-seed".utf8))
            #expect(receivedTOTP.totp?.period == 45 && receivedTOTP.totp?.digits == 8)

            // The source keeps every secret it had.
            let source = try await f.stored().accounts
            #expect(source.first { $0.id == linked.id }?.totp?.secret == Data("linked-seed".utf8))
            #expect(source.first { $0.id == totpOwner.id }?.password == "grace-password")
        }
    }

    @Test func exportRevalidatesSelectionRevisionAndAuthorization() async throws {
        try await withFixture { f in
            let only = account(password: "pw", totp: generator())
            try await f.seed([only])
            let selection = [CredentialExportSelection(accountID: only.id, password: true, passkeyIDs: [], totp: true)]
            let epoch = try #require(f.manager.authorizationEpoch)

            await #expect(throws: CredentialExchangeCoordinatorError.emptySelection) {
                _ = try await f.coordinator.prepareExport(
                    selection: [CredentialExportSelection(accountID: only.id, password: false, passkeyIDs: [], totp: false)],
                    expectedRevision: 1, format: .v1, from: f.manager, epoch: epoch
                )
            }
            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await f.coordinator.prepareExport(selection: selection, expectedRevision: 0, format: .v1, from: f.manager, epoch: epoch)
            }
            await #expect(throws: CredentialVaultError.invalidData) {
                _ = try await f.coordinator.prepareExport(
                    selection: [CredentialExportSelection(accountID: UUID(), password: true, passkeyIDs: [], totp: false)],
                    expectedRevision: 1, format: .v1, from: f.manager, epoch: epoch
                )
            }

            f.manager.lock(reason: .manual)
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await f.coordinator.prepareExport(selection: selection, expectedRevision: 1, format: .v1, from: f.manager, epoch: epoch)
            }
            try await f.unlock(f.manager)
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await f.coordinator.prepareExport(selection: selection, expectedRevision: 1, format: .v1, from: f.manager, epoch: epoch)
            }
        }
    }

    @Test func exportChecksSelectionCancellationAndAuthorizationBeforeTheSystemIsAsked() async throws {
        try await withFixture { f in
            let only = account(password: "pw")
            try await f.seed([only])
            let window = NSWindow()
            let selection = [CredentialExportSelection(accountID: only.id, password: true, passkeyIDs: [], totp: false)]
            let epoch = try #require(f.manager.authorizationEpoch)

            await #expect(throws: CredentialExchangeCoordinatorError.emptySelection) {
                _ = try await f.coordinator.exportCredentials(
                    selection: [CredentialExportSelection(accountID: only.id, password: false, passkeyIDs: [], totp: false)],
                    expectedRevision: 1, epoch: epoch, from: f.manager, in: window
                )
            }

            let cancelled = Task { @MainActor in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.coordinator.exportCredentials(
                    selection: selection, expectedRevision: 1, epoch: epoch, from: f.manager, in: window
                )
            }
            await #expect(throws: CancellationError.self) { _ = try await cancelled.value }

            f.manager.lock(reason: .manual)
            try await f.unlock(f.manager)
            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await f.coordinator.exportCredentials(
                    selection: selection, expectedRevision: 1, epoch: epoch, from: f.manager, in: window
                )
            }
        }
    }

    @Test func aUsernameOnlyLoginIsExportedWithoutAPasswordAndReimportsAsOne() async throws {
        try await withFixture { f in
            let usernameOnly = account(username: "ada", password: nil)
            try await f.seed([usernameOnly] + neighbours(1))
            let summary = CredentialSummary(usernameOnly)
            #expect(summary.hasLogin && !summary.hasPassword)

            let data = try await f.coordinator.prepareExport(
                selection: [CredentialExportSelection(accountID: usernameOnly.id, password: summary.hasLogin, passkeyIDs: [], totp: false)],
                expectedRevision: 1, format: .v1, from: f.manager, epoch: try #require(f.manager.authorizationEpoch)
            )
            guard case let .basicAuthentication(login)? = data.accounts.first?.items.first?.credentials.first else {
                Issue.record("A username-only login must export as basic authentication")
                return
            }
            #expect(login.userName?.value == "ada" && login.password == nil)

            try await f.create(f.other)
            try await f.stage(data, into: f.other)
            _ = try await f.coordinator.commitImport(into: f.other)
            let received = try #require(try await f.stored(f.other).accounts.first)
            #expect(received.username == "ada" && received.password == nil)
        }
    }

    // MARK: - System errors

    @Test func systemErrorsKeepNoDiagnosticsAndUserCancellationIsDistinct() throws {
        let secret = "hunter2-secret-password"
        let rejected = NSError(domain: "com.apple.example", code: 42, userInfo: [NSLocalizedDescriptionKey: secret])
        #expect(CredentialExchangeCoordinator.mapNative(rejected) as? CredentialExchangeCoordinatorError
            == .systemRejected(domain: "com.apple.example", code: 42))

        let canceled = NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue)
        #expect(CredentialExchangeCoordinator.isUserCancellation(canceled))
        #expect(CredentialExchangeCoordinator.isUserCancellation(CancellationError()))
        #expect(!CredentialExchangeCoordinator.isUserCancellation(rejected))
        #expect(CredentialSettingsModel.message(for: CancellationError()) == nil)

        let unsupported = CredentialExchangeError(record: .item(account: 0, item: 3), reason: .unsupported)
        let unsupportedMessage = try #require(CredentialSettingsModel.message(for: unsupported))
        #expect(unsupportedMessage.contains("item[3]"))
    }

    // MARK: - Export hand-off

    @Test func onceTheHandOffHasStartedNoFailureIsReportedAsNotTransferred() async {
        let completed = await CredentialExchangeCoordinator.handOff {}
        #expect(completed == .transferred)

        let canceled = NSError(domain: ASAuthorizationError.errorDomain, code: ASAuthorizationError.Code.canceled.rawValue)
        let failures: [any Error] = [CancellationError(), canceled, NSError(domain: "com.apple.example", code: 42)]
        for failure in failures {
            let outcome = await CredentialExchangeCoordinator.handOff { throw failure }
            #expect(outcome == .uncertain)
        }

        // The caller's own cancellation arriving while the system holds the data is the same uncertainty.
        let sending = Task { @MainActor in
            await CredentialExchangeCoordinator.handOff { try await Task.sleep(for: .seconds(60)) }
        }
        sending.cancel()
        let cancelled = await sending.value
        #expect(cancelled == .uncertain)
    }

    // MARK: - Review scope

    @Test(arguments: [true, false])
    func theReviewStatesTheWebsitesTheCommitWillGiveTheCredential(merge: Bool) async throws {
        try await withFixture { f in
            var bare = account(username: "", password: nil, totp: generator("bare-seed"))
            bare.origins = [Self.origin, "https://other.test"]
            try await f.seed([bare] + neighbours(1))
            var incoming = account(username: "grace", password: "incoming")
            incoming.origins = ["https://incoming.test"]
            try await f.stage(try exported([incoming]))

            let candidate = try #require(f.coordinator.importReview?.candidates.first)
            let record = try #require(candidate.records.first)
            #expect(candidate.summary.origins == ["https://incoming.test"])
            // Not linked to anything stored and not yet decided: a new account on exactly the exporter's websites.
            #expect(record.destination == .newAccount(origins: ["https://incoming.test"]))

            try f.coordinator.choose(merge ? .merge(into: bare.id) : .addSeparately, for: record.incoming)
            let destination = try #require(f.coordinator.importReview?.candidates.first?.records.first?.destination)
            _ = try await f.coordinator.commitImport(into: f.manager)

            let holder = try #require(try await f.stored().accounts.first { $0.password == "incoming" })
            switch destination {
            case let .existing(id, _, origins, ignored):
                #expect(merge && id == bare.id && holder.id == bare.id)
                // The stored account's websites are shown as they are, and the exporter's are named as not added.
                #expect(origins == bare.origins && holder.origins == bare.origins)
                #expect(ignored == ["https://incoming.test"])
            case let .newAccount(origins):
                #expect(!merge && holder.id != bare.id && holder.origins == origins)
            case .skipped:
                Issue.record("A merge or separate add is never reported as skipped")
            }
        }
    }

    @Test func refreshingAStoredItemNamesTheIgnoredWebsitesAndNeverAddsThem() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(handBuilt([item(id: 1, scoped: true, [password("first")])]))
            _ = try await f.coordinator.commitImport(into: f.manager)
            let linked = try #require(try await f.stored().accounts.first { $0.password == "first" })

            // The same exporter item again, now with a different website and a code the stored one lacks.
            try await f.stage(handBuilt([item(id: 1, scoped: true, url: "https://changed.test/login", [totpCredential()])]))
            let record = try #require(f.coordinator.importReview?.candidates.first?.records.first)
            #expect(record.kind == .totp && !record.isConflict)
            guard case let .existing(id, _, origins, ignored)? = record.destination else {
                Issue.record("A record of a stored item must show that account as its destination")
                return
            }
            #expect(id == linked.id && origins == linked.origins && ignored == ["https://changed.test"])

            _ = try await f.coordinator.commitImport(into: f.manager)
            let refreshed = try #require(try await f.stored().accounts.first { $0.id == linked.id })
            #expect(refreshed.totp != nil && refreshed.origins == linked.origins)
        }
    }

    // MARK: - Queued and ended imports in settings

    @Test func aQueuedImportCanBeDismissedWhileLockedAndStaysSpentWithoutTouchingAReview() async throws {
        try await withFixture { f in
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            let first = UUID()
            #expect(f.coordinator.receive(Self.activity(token: first)))
            #expect(!model.isUnlocked && model.pendingImportToken == first)

            model.discardPendingImport()
            #expect(model.pendingImportToken == nil)
            #expect(!f.coordinator.receive(Self.activity(token: first)))
            let second = UUID()
            #expect(f.coordinator.receive(Self.activity(token: second)))
            #expect(model.pendingImportToken == second)

            model.discardPendingImport()
            try await f.seed(neighbours(1))
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            // Dismissing with nothing queued leaves an import under review alone.
            model.discardPendingImport()
            #expect(f.coordinator.hasStagedImport(for: f.manager))
        }
    }

    // A second page for the same profile is not busy, so only what the coordinator says it ended can decide
    // whether "nothing was saved" is true.
    @Test func cancellingARunningCommitIsNeverReportedAsACancelledReview() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(1))
            let before = try f.diskBytes()
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            // Built once the manager's access is stable: a model made earlier still has a re-arm of its authorization
            // observation queued on the main actor when the gate parks the vault, and that read waits on the parked lock.
            let second = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)

            gate.holdNextVaultRead()
            let commit = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager) }
            let log = CallbackLog()
            gate.whenParked {
                log.received = !second.isBusy && second.cancelImport() == .commitCancellationRequested && second.error == nil
                gate.release()
            }
            await #expect(throws: CancellationError.self) { _ = try await commit.value }
            #expect(gate.hasParked && log.received)
            #expect(try f.diskBytes() == before)
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
        }
    }

    @Test func anotherProfilesModelCannotCancelAnImportItDoesNotOwn() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(1))
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            // Built after the seed, for the reason given on `cancellingARunningCommitIsNeverReportedAsACancelledReview`.
            let stale = CredentialSettingsModel(profile: f.otherProfile, exchange: f.coordinator, manager: f.other)
            let owner = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)

            // Closing the other profile's page leaves the review alone.
            #expect(stale.cancelImport() == .nothingOwned)
            #expect(f.coordinator.hasStagedImport(for: f.manager) && stale.error == nil)

            // So does it while the commit is parked inside its vault read: the write lands and its receipt returns.
            gate.holdNextVaultRead()
            let commit = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager) }
            let log = CallbackLog()
            gate.whenParked {
                log.received = stale.cancelImport() == .nothingOwned && stale.error == nil
                gate.release()
            }
            _ = try await commit.value
            #expect(gate.hasParked && log.received)
            #expect(try await f.stored().accounts.contains { $0.username == "grace" })

            // The owning profile's own cancel still ends its review.
            try await f.stage(try exported([account(username: "linus", password: "other")]))
            #expect(owner.cancelImport() == .reviewCancelled)
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
        }
    }

    @Test func anImportThatEndedLeavesNoQueuedTokenAndCancellationSaysWhatItEnded() async throws {
        try await withFixture { f in
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            // Locked: the claim is refused and the token stays queued.
            let queued = UUID()
            #expect(f.coordinator.receive(Self.activity(token: queued)))
            await model.beginImport()
            #expect(model.pendingImportToken == queued)
            model.discardPendingImport()

            // A review whose commit fails is gone with its token.
            let existing = neighbours(1)
            try await f.seed(existing)
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            _ = try await f.manager.commit(existing + [account(username: "newer", password: "newer")], expectedRevision: 1)
            await model.commitImport()
            #expect(!f.coordinator.hasStagedImport(for: f.manager) && f.coordinator.pendingToken == nil)

            // Cancelling an open review ends it, and cancelling nothing ends nothing.
            try await f.stage(try exported([account(username: "linus", password: "other")]))
            #expect(model.cancelImport() == .reviewCancelled)
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
            #expect(model.cancelImport() == .nothingOwned)
        }
    }

    // MARK: - Two settings models on one manager
    //
    // One profile has one shared manager and one coordinator, but every settings page (one per window) builds its own
    // model. The model that began the import owns it: another window's model on the same profile must neither see
    // the review nor decide, commit or cancel anything in it. `first` is the model whose page staged the import;
    // `stage` is the same coordinator path the settings page takes after the native fetch returns.

    private func twoModels(_ f: Fixture, staging data: ASExportedCredentialData) async throws
        -> (first: CredentialSettingsModel, second: CredentialSettingsModel, incoming: CredentialIdentity) {
        try await f.seed(neighbours(1))
        let first = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
        let second = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
        try await f.stage(data)
        let incoming = try #require(first.importReview?.candidates.first?.records.first?.incoming)
        return (first, second, incoming)
    }

    @Test func aSecondModelOnTheSameManagerCannotSeeAnImportItDidNotStage() async throws {
        try await withFixture { f in
            let (first, second, incoming) = try await twoModels(f, staging: try exported([account(username: "grace", password: "incoming")]))
            #expect(first.importReview != nil)
            #expect(second.importReview == nil)
            #expect(second.mergeTargets(for: incoming).isEmpty)
            #expect(f.coordinator.hasStagedImport(for: f.manager))
        }
    }

    @Test func aSecondModelOnTheSameManagerCannotDecideAnImportItDidNotStage() async throws {
        try await withFixture { f in
            let (first, second, incoming) = try await twoModels(f, staging: try exported([account(username: "grace", password: "incoming")]))
            second.chooseImport(.skip, for: incoming)
            #expect(first.importReview?.candidates.first?.records.first?.choice == nil)
            #expect(first.importReview?.candidates.first?.records.first?.destination != .skipped)
        }
    }

    @Test func aSecondModelOnTheSameManagerCannotCommitAnImportItDidNotStage() async throws {
        try await withFixture { f in
            let (first, second, _) = try await twoModels(f, staging: try exported([account(username: "grace", password: "incoming")]))
            await second.commitImport()
            #expect(try await f.stored().accounts.count == 1)
            #expect(second.lastImport == nil)
            #expect(f.coordinator.hasStagedImport(for: f.manager) && first.importReview != nil)
        }
    }

    @Test func aSecondModelOnTheSameManagerCannotCancelAnImportItDidNotStage() async throws {
        try await withFixture { f in
            let (first, second, _) = try await twoModels(f, staging: try exported([account(username: "grace", password: "incoming")]))
            #expect(second.cancelImport() == .nothingOwned)
            #expect(second.error == nil)
            #expect(f.coordinator.hasStagedImport(for: f.manager) && first.importReview != nil)
            // The model that staged it still ends it.
            #expect(first.cancelImport() == .reviewCancelled)
            #expect(!f.coordinator.hasStagedImport(for: f.manager))
        }
    }
}

// MARK: - Deterministic vault synchronization

/// Parks the vault actor's thread the next time it reads the manager's clock. The vault reads it off the main
/// thread, inside the access's authorization lock and before it writes anything, so a parked operation is
/// genuinely in flight; the manager's own reads happen on the main thread and are never held.
///
/// A parked read holds that authorization lock and the process-wide mutation lock, so reading the manager's
/// authorization (`authorizationEpoch`, `isUnlocked`, `claimImport`, ...) from the main actor blocks until the
/// read has been released and the vault operation finished. Nothing here awaits a suspended task to make
/// progress: a plain thread notices the park and runs the test's callback on the main queue, which releases the
/// gate at the point the test needs.
nonisolated final class VaultClockGate: Sendable {
    private let armed = Mutex(false)
    private let didPark = Mutex(false)
    private let parked = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func holdNextVaultRead() { armed.withLock { $0 = true } }
    var hasParked: Bool { didPark.withLock { $0 } }

    func now() -> ContinuousClock.Instant {
        if !Thread.isMainThread, armed.withLock({ (state: inout Bool) -> Bool in
            defer { state = false }
            return state
        }) {
            didPark.withLock { $0 = true }
            parked.signal()
            // Bounded so a test that never gets to `release()` cannot keep the process-wide mutation lock forever.
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
                if reached { MainActor.assumeIsolated { callback() } } else { self.released.signal() }
            }
        }
    }

    func release() { released.signal() }
}

/// What a main-actor callback run by `VaultClockGate.whenParked` observed.
@MainActor final class CallbackLog {
    let token = UUID()
    var received = false
    var committedFileChanged = false
    var error: (any Error)?
}

/// Signals when something has been written in `directory`, which is how the vault's atomic file replacement
/// shows. Events are delivered on a private queue that a saturated global queue cannot starve.
nonisolated final class DirectoryChangeWatcher: @unchecked Sendable {
    private let source: any DispatchSourceFileSystemObject
    private let changed: DispatchSemaphore

    init(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let changed = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write,
            // User-interactive, like the main thread that blocks on it, so the wait is not a priority inversion.
            queue: DispatchQueue(label: "credential-exchange-test.watcher", qos: .userInteractive)
        )
        source.setEventHandler { changed.signal() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        self.changed = changed
        source.resume()
    }

    /// Blocks the calling thread until `file` no longer holds `before`. Each directory event wakes it to look, so
    /// a temporary file appearing next to the vault does not count; only the replaced file does.
    func waitForChange(of file: URL, from before: Data) -> Bool {
        while changed.wait(timeout: .now() + 30) == .success {
            if let current = try? Data(contentsOf: file), current != before { return true }
        }
        return false
    }

    func stop() { source.cancel() }
}
