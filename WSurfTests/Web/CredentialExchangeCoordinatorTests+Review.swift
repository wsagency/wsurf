// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Testing

@testable import WSurf

// Export, review scope and ownership tests of `CredentialExchangeCoordinatorTests`; the fixture and builders live
// in the main file.
@MainActor
extension CredentialExchangeCoordinatorTests {
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
            _ = try await f.coordinator.commitImport(into: f.other, owner: f.owner)
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
            _ = try await f.coordinator.commitImport(into: f.other, owner: f.owner)
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

            let candidate = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first)
            let record = try #require(candidate.records.first)
            #expect(candidate.summary.origins == ["https://incoming.test"])
            // Not linked to anything stored and not yet decided: a new account on exactly the exporter's websites.
            #expect(record.destination == .newAccount(origins: ["https://incoming.test"]))

            try f.coordinator.choose(merge ? .merge(into: bare.id) : .addSeparately, for: record.incoming, owner: f.owner)
            let destination = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first?.destination)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

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
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let linked = try #require(try await f.stored().accounts.first { $0.password == "first" })

            // The same exporter item again, now with a different website and a code the stored one lacks.
            try await f.stage(handBuilt([item(id: 1, scoped: true, url: "https://changed.test/login", [totpCredential()])]))
            let record = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first)
            #expect(record.kind == .totp && !record.isConflict)
            guard case let .existing(id, _, origins, ignored)? = record.destination else {
                Issue.record("A record of a stored item must show that account as its destination")
                return
            }
            #expect(id == linked.id && origins == linked.origins && ignored == ["https://changed.test"])

            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
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

            model.discardPendingImport(token: first)
            #expect(model.pendingImportToken == nil)
            #expect(!f.coordinator.receive(Self.activity(token: first)))
            let second = UUID()
            #expect(f.coordinator.receive(Self.activity(token: second)))
            #expect(model.pendingImportToken == second)

            model.discardPendingImport(token: second)
            try await f.seed(neighbours(1))
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            // Dismissing with nothing queued leaves an import under review alone.
            model.discardPendingImport(token: second)
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    // A second page for the same profile is not busy, so only what the coordinator says it ended can decide
    // whether "nothing was saved" is true.
    @Test func cancellingARunningCommitIsNeverReportedAsACancelledReview() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(1))
            let before = try f.diskBytes()
            // Built once the manager's access is stable: a model made earlier still has a re-arm of its authorization
            // observation queued on the main actor when the gate parks the vault, and that read waits on the parked lock.
            // It owns the import it cancels: a commit can only be cancelled by the model that began it.
            let second = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            try await f.stage(try exported([account(username: "grace", password: "incoming")]), owner: second.owner)

            gate.holdNextVaultRead()
            let commit = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager, owner: second.owner) }
            let log = CallbackLog()
            gate.whenParked {
                log.received = !second.isBusy && second.cancelImport() == .commitCancellationRequested && second.error == nil
                gate.release()
            }
            await #expect(throws: CancellationError.self) { _ = try await commit.value }
            #expect(gate.hasParked && log.received)
            #expect(try f.diskBytes() == before)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: second.owner))
        }
    }

    @Test func anotherProfilesModelCannotCancelAnImportItDoesNotOwn() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(1))
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            // Built after the seed, for the reason given on `cancellingARunningCommitIsNeverReportedAsACancelledReview`.
            let stale = CredentialSettingsModel(profile: f.otherProfile, exchange: f.coordinator, manager: f.other)
            let owning = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)

            // Closing the other profile's page leaves the review alone.
            #expect(stale.cancelImport() == .nothingOwned)
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner) && stale.error == nil)

            // So does it while the commit is parked inside its vault read: the write lands and its receipt returns.
            gate.holdNextVaultRead()
            let commit = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager, owner: f.owner) }
            let log = CallbackLog()
            gate.whenParked {
                log.received = stale.cancelImport() == .nothingOwned && stale.error == nil
                gate.release()
            }
            _ = try await commit.value
            #expect(gate.hasParked && log.received)
            #expect(try await f.stored().accounts.contains { $0.username == "grace" })

            // The owning profile's own cancel still ends its review.
            try await f.stage(try exported([account(username: "linus", password: "other")]), owner: owning.owner)
            #expect(owning.cancelImport() == .reviewCancelled)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: owning.owner))
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
            model.discardPendingImport(token: queued)

            // A review whose commit fails is gone with its token.
            let existing = neighbours(1)
            try await f.seed(existing)
            try await f.stage(try exported([account(username: "grace", password: "incoming")]), owner: model.owner)
            _ = try await f.manager.commit(existing + [account(username: "newer", password: "newer")], expectedRevision: 1, authorizedEpoch: try #require(f.manager.authorizationEpoch))
            await model.commitImport()
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: model.owner) && f.coordinator.pendingToken == nil)

            // Cancelling an open review ends it, and cancelling nothing ends nothing.
            try await f.stage(try exported([account(username: "linus", password: "other")]), owner: model.owner)
            #expect(model.cancelImport() == .reviewCancelled)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: model.owner))
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
        try await f.stage(data, owner: first.owner)
        let incoming = try #require(first.importReview?.candidates.first?.records.first?.incoming)
        return (first, second, incoming)
    }

    @Test func aSecondModelOnTheSameManagerCannotSeeAnImportItDidNotStage() async throws {
        try await withFixture { f in
            let (first, second, incoming) = try await twoModels(f, staging: try exported([account(username: "grace", password: "incoming")]))
            #expect(first.importReview != nil)
            #expect(second.importReview == nil)
            #expect(second.mergeTargets(for: incoming).isEmpty)
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: first.owner))
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: second.owner))
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
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: first.owner) && first.importReview != nil)
        }
    }

    @Test func aSecondModelOnTheSameManagerCannotCancelAnImportItDidNotStage() async throws {
        try await withFixture { f in
            let (first, second, _) = try await twoModels(f, staging: try exported([account(username: "grace", password: "incoming")]))
            #expect(second.cancelImport() == .nothingOwned)
            #expect(second.error == nil)
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: first.owner) && first.importReview != nil)
            // The model that staged it still ends it.
            #expect(first.cancelImport() == .reviewCancelled)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: first.owner))
        }
    }

    // MARK: - Ownership and stale dismissals

    @Test func aDismissForAnEarlierTokenLeavesTheTokenQueuedSince() {
        let coordinator = CredentialExchangeCoordinator()
        let first = UUID()
        let second = UUID()
        #expect(coordinator.receive(Self.activity(token: first)))
        coordinator.discardPendingImport(token: first)
        #expect(coordinator.receive(Self.activity(token: second)))

        // A button drawn for the first token is clicked after the second arrived.
        coordinator.discardPendingImport(token: first)
        #expect(coordinator.pendingToken == second)

        coordinator.discardPendingImport(token: second)
        #expect(coordinator.pendingToken == nil)
        #expect(!coordinator.receive(Self.activity(token: second)))
    }

    @Test func aClaimIsStagedOnlyByTheOwnerThatMadeIt() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            let token = UUID()
            #expect(f.coordinator.receive(Self.activity(token: token)))
            try f.coordinator.claimImport(token: token, for: f.manager, owner: f.owner)
            let data = try exported([account(username: "grace", password: "incoming")])
            let stranger = UUID()

            await #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) {
                try await f.coordinator.stage(data, into: f.manager, owner: stranger)
            }
            #expect(f.coordinator.cancelImport(for: f.manager, owner: stranger) == .nothingOwned)

            // The refusal left the claim with its owner, who can still stage.
            try await f.coordinator.stage(data, into: f.manager, owner: f.owner)
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    // The model-level tests above see only that a stranger's call changed nothing; the coordinator is what says why.
    @Test func aStrangerOwnerIsRefusedAsTheWrongTargetNotAsBusyOrMissing() async throws {
        try await withFixture { f in
            try await f.seed(neighbours(1))
            try await f.stage(try exported([account(username: "grace", password: "incoming")]))
            let record = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first)
            let stranger = UUID()

            #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) {
                try f.coordinator.choose(.skip, for: record.incoming, owner: stranger)
            }
            await #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) {
                _ = try await f.coordinator.commitImport(into: f.manager, owner: stranger)
            }
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner)?.candidates.first?.records.first?.choice == nil)
        }
    }

    @Test func aNonOwnerOnTheSameManagerCannotCancelACommitParkedInTheVault() async throws {
        let gate = VaultClockGate()
        try await withFixture(gate: gate) { f in
            try await f.seed(neighbours(1))
            // Built after the seed, for the reason given on `cancellingARunningCommitIsNeverReportedAsACancelledReview`.
            let owning = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            let second = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            try await f.stage(try exported([account(username: "grace", password: "incoming")]), owner: owning.owner)

            gate.holdNextVaultRead()
            let commit = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager, owner: owning.owner) }
            let log = CallbackLog()
            gate.whenParked {
                log.received = second.cancelImport() == .nothingOwned && second.error == nil
                gate.release()
            }
            let receipt = try await commit.value
            #expect(gate.hasParked && log.received)

            // The write the other window tried to cancel landed, and its receipt is the stored revision.
            let stored = try await f.stored()
            #expect(receipt.revision == 2 && stored.revision == receipt.revision)
            #expect(stored.accounts.contains { $0.username == "grace" })
        }
    }
}
