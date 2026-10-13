// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Synchronization
import Testing

@testable import WSurf

/// How an import or export ends, through the real coordinator, manager and store (spec §13.5). The tests assert kinds,
/// actions, receipts and store bytes; the wording is production code's and never asserted here.
@MainActor
struct VaultTransferLifecycleTests {
    private let base = CredentialExchangeCoordinatorTests()

    /// Everything the coordinator's sink saw.
    @MainActor final class Inbox {
        var messages: [CredentialTransferMessage] = []
    }

    private func inbox(_ f: CredentialExchangeCoordinatorTests.Fixture) -> Inbox {
        let inbox = Inbox()
        f.coordinator.onMessage = { inbox.messages.append($0) }
        return inbox
    }

    /// Queues a token the caller keeps, claims it for `f.owner` and stages `data`.
    @discardableResult
    private func stage(_ data: ASExportedCredentialData, in f: CredentialExchangeCoordinatorTests.Fixture) async throws -> UUID {
        let token = UUID()
        #expect(f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
        try f.coordinator.claimImport(token: token, for: f.manager, owner: f.owner)
        try await f.coordinator.stage(data, into: f.manager, owner: f.owner)
        return token
    }

    /// The failure `commitImport` ended with; any other ending is recorded as an issue.
    private func endingFailure(of f: CredentialExchangeCoordinatorTests.Fixture) async -> CredentialTransferFailure? {
        do {
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            Issue.record("The import was expected not to return a receipt")
        } catch let failure as CredentialTransferFailure {
            return failure
        } catch {
            Issue.record("An ending must be a transfer failure, not \(type(of: error))")
        }
        return nil
    }

    /// An incoming update of `target` whose single conflict is resolved by replacing it.
    private func stageReplacement(of target: CredentialAccount, in f: CredentialExchangeCoordinatorTests.Fixture) async throws -> UUID {
        let token = try await stage(try base.exported([base.account(id: target.id, password: "incoming-pw")]), in: f)
        let conflict = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.conflicts.first)
        try f.coordinator.choose(.replace, for: conflict.incoming, owner: f.owner)
        return token
    }

    /// The exchange identity `handBuilt` gives its first item.
    private func identified(_ account: CredentialAccount) -> CredentialAccount {
        var account = account
        account.exchangeAccountID = Data([0xA0, 0x01])
        account.exchangeItemID = Data([0xB0, 1])
        return account
    }

    private func incomingLogin(in f: CredentialExchangeCoordinatorTests.Fixture) -> ASExportedCredentialData {
        base.handBuilt([base.item(id: 1, scoped: true, [base.password("incoming")])])
    }

    // MARK: - Header

    @Test func previewHeaderNamesProfileAndDestinationVault() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(1))
            try await stage(incomingLogin(in: f), in: f)

            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            let names = try await f.manager.displayNames()
            #expect(review.profileName == f.profile.name && review.profileName == names.profile)
            #expect(review.vaultName != nil && review.vaultName == names.vault)
        }
    }

    // MARK: - Writes between preview and apply

    @Test func unrelatedWriteBetweenPreviewAndApplyDoesNotDiscard() async throws {
        try await base.withFixture { f in
            let existing = base.neighbours(2)
            try await f.seed(existing)
            let inbox = inbox(f)
            try await stage(incomingLogin(in: f), in: f)
            _ = try await f.manager.commit(existing + [base.account(username: "newer", password: "newer")], expectedRevision: 2, authorizedEpoch: try #require(f.manager.authorizationEpoch))

            let receipt = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try await f.stored()
            #expect(receipt.revision == stored.revision && receipt.revision == 4)
            #expect(stored.accounts.count == existing.count + 2)
            #expect(stored.accounts.contains { $0.username == "newer" })
            #expect(inbox.messages.map(\.kind) == [.succeeded])
        }
    }

    @Test func touchedAccountWriteDiscardsWithTheDiscardedMessageAndWritesNothing() async throws {
        try await base.withFixture { f in
            let target = base.account(password: "old")
            try await f.seed([target] + base.neighbours(2))
            let inbox = inbox(f)
            let token = try await stageReplacement(of: target, in: f)

            var changed = try #require(try await f.stored().accounts.first { $0.id == target.id })
            changed.password = "changed-elsewhere"
            let accounts = try await f.stored().accounts.map { $0.id == target.id ? changed : $0 }
            _ = try await f.manager.commit(accounts, expectedRevision: try await f.stored().revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))
            let after = try f.diskBytes()

            let failure = await endingFailure(of: f)
            #expect(failure?.message.kind == .discarded && failure?.message.action == .exportAgain && failure?.message.receipt == nil)
            #expect(inbox.messages == failure.map { [$0.message] })
            #expect(try f.diskBytes() == after)
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(!f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
        }
    }

    // MARK: - After the last check

    @Test func unrelatedWriteAfterTheLastCheckIsPreservedAndTheImportSucceeds() async throws {
        try await base.withFixture { f in
            let existing = base.neighbours(2)
            try await f.seed(existing)
            try await stage(incomingLogin(in: f), in: f)
            f.coordinator.afterLastCheck = {
                _ = try? await f.manager.commit(existing + [self.base.account(username: "seam", password: "seam")], expectedRevision: 2, authorizedEpoch: f.manager.authorizationEpoch ?? 0)
            }

            let receipt = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let stored = try await f.stored()
            // Seam write 3, import write 4: one account write, no retry.
            #expect(receipt.revision == 4 && stored.revision == 4)
            #expect(stored.accounts.contains { $0.username == "seam" } && stored.accounts.contains { $0.password == "incoming" })
            #expect(stored.accounts.count == existing.count + 2)
        }
    }

    @Test func touchedAccountChangedAfterTheLastCheckWritesNothing() async throws {
        try await base.withFixture { f in
            let target = base.account(password: "old")
            try await f.seed([target] + base.neighbours(2))
            let inbox = inbox(f)
            let token = try await stageReplacement(of: target, in: f)
            f.coordinator.afterLastCheck = {
                guard let current = try? await f.stored(), let epoch = f.manager.authorizationEpoch else { return }
                var changed = current.accounts
                changed[changed.firstIndex { $0.id == target.id }!].password = "changed-at-the-seam"
                _ = try? await f.manager.commit(changed, expectedRevision: current.revision, authorizedEpoch: epoch)
            }

            let failure = await endingFailure(of: f)
            #expect(failure?.message.kind == .discarded && failure?.message.receipt == nil)
            #expect(inbox.messages.count == 1)
            let stored = try await f.stored()
            #expect(stored.revision == 3 && stored.accounts.first { $0.id == target.id }?.password == "changed-at-the-seam")
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(!f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
        }
    }

    @Test func aSameItemIdentityAddedAfterTheLastCheckWritesNothing() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(1))
            let inbox = inbox(f)
            try await stage(incomingLogin(in: f), in: f)
            f.coordinator.afterLastCheck = {
                guard let current = try? await f.stored(), let epoch = f.manager.authorizationEpoch else { return }
                _ = try? await f.manager.commit(
                    current.accounts + [self.identified(self.base.account(username: "racer", password: "racer"))],
                    expectedRevision: current.revision, authorizedEpoch: epoch
                )
            }

            let failure = await endingFailure(of: f)
            #expect(failure?.message.receipt == nil && failure?.message.action == .exportAgain)
            switch failure?.message.kind {
            case .discarded?, .applyFailed?:
                break
            default:
                Issue.record("A colliding identity must end as discarded or failed to apply, never as a landed write")
            }
            #expect(inbox.messages.count == 1)
            let stored = try await f.stored()
            #expect(stored.revision == 3 && !stored.accounts.contains { $0.password == "incoming" })
        }
    }

    // MARK: - Tokens and windows

    @Test(arguments: ["pending", "claimed", "staged"])
    func secondTokenIsNotSilentlyDropped(state: String) async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(1))
            let inbox = inbox(f)
            let first = UUID()
            #expect(f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: first)))
            if state != "pending" {
                try f.coordinator.claimImport(token: first, for: f.manager, owner: f.owner)
            }
            if state == "staged" {
                try await f.coordinator.stage(incomingLogin(in: f), into: f.manager, owner: f.owner)
            }

            #expect(!f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: UUID())))
            #expect(inbox.messages.count == 1)
            let message = try #require(inbox.messages.first)
            #expect(message.kind == .alreadyInProgress && message.action == .none && message.receipt == nil)
            #expect(f.coordinator.notice(for: f.owner) == message)
            #expect(f.coordinator.pendingToken == (state == "pending" ? first : nil))
            #expect(f.coordinator.hasStagedImport(for: f.manager, owner: f.owner) == (state == "staged"))

            f.coordinator.dismissNotice(for: nil)
            #expect(f.coordinator.notice(for: f.owner) == nil)
        }
    }

    @Test func twoWindowsOnlyTheFirstClaimerProceeds() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(1))
            let token = UUID()
            #expect(f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
            try f.coordinator.claimImport(token: token, for: f.manager, owner: f.owner)

            let second = UUID()
            #expect(throws: CredentialExchangeCoordinatorError.tokenMismatch) {
                try f.coordinator.claimImport(token: token, for: f.manager, owner: second)
            }
            await #expect(throws: CredentialExchangeCoordinatorError.wrongTarget) {
                try await f.coordinator.stage(incomingLogin(in: f), into: f.manager, owner: second)
            }
            try await f.coordinator.stage(incomingLogin(in: f), into: f.manager, owner: f.owner)
            #expect(f.coordinator.importReview(for: f.manager, owner: second) == nil)
            #expect(f.coordinator.importReview(for: f.manager, owner: f.owner) != nil)
        }
    }

    @Test func aSpentTokenIsRefusedAfterSuccess() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(1))
            let token = try await stage(incomingLogin(in: f), in: f)
            _ = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)

            #expect(!f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
            #expect(throws: CredentialExchangeCoordinatorError.tokenMismatch) {
                try f.coordinator.claimImport(token: token, for: f.manager, owner: f.owner)
            }
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
        }
    }

    // MARK: - Endings

    enum Ending: String, CaseIterable, Sendable {
        case lock, relock, cancel, staleTouchedAccount, collisionAtApply
    }

    @Test(arguments: Ending.allCases)
    func everyFailedCancelledOrStaleStateSaysDiscardedAndNeverErased(ending: Ending) async throws {
        try await base.withFixture { f in
            let target = base.account(password: "old")
            try await f.seed([target] + base.neighbours(2))
            let inbox = inbox(f)
            let token: UUID
            if ending == .collisionAtApply {
                token = try await stage(incomingLogin(in: f), in: f)
            } else {
                token = try await stageReplacement(of: target, in: f)
            }

            var failure: CredentialTransferFailure?
            switch ending {
            case .lock:
                f.manager.lock(reason: .manual)
            case .relock:
                f.manager.lock(reason: .manual)
                try await f.unlock(f.manager)
            case .cancel:
                #expect(f.coordinator.cancelImport(for: f.manager, owner: f.owner) == .reviewCancelled)
            case .staleTouchedAccount:
                let current = try await f.stored()
                var accounts = current.accounts
                accounts[accounts.firstIndex { $0.id == target.id }!].password = "elsewhere"
                _ = try await f.manager.commit(accounts, expectedRevision: current.revision, authorizedEpoch: try #require(f.manager.authorizationEpoch))
                failure = await endingFailure(of: f)
            case .collisionAtApply:
                f.coordinator.afterLastCheck = {
                    guard let current = try? await f.stored(), let epoch = f.manager.authorizationEpoch else { return }
                    _ = try? await f.manager.commit(
                        current.accounts + [self.identified(self.base.account(username: "racer", password: "racer"))],
                        expectedRevision: current.revision, authorizedEpoch: epoch
                    )
                }
                failure = await endingFailure(of: f)
            }
            let settled = try f.diskBytes()

            let message = try #require(inbox.messages.first)
            #expect(inbox.messages.count == 1)
            #expect(message.action == .exportAgain && message.receipt == nil)
            switch message.kind {
            case .discarded, .applyFailed:
                break
            default:
                Issue.record("\(ending) must end as discarded or failed to apply")
            }
            if let failure {
                #expect(failure.message == message)
            }
            #expect(!f.coordinator.hasStagedImport(for: f.manager, owner: f.owner))
            #expect(!f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
            #expect(try f.diskBytes() == settled)
        }
    }

    @Test func successCarriesTheReceiptAndTheResultList() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(2))
            let inbox = inbox(f)
            try await stage(incomingLogin(in: f), in: f)
            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))

            let receipt = try await f.coordinator.commitImport(into: f.manager, owner: f.owner)
            let message = try #require(inbox.messages.first)
            #expect(inbox.messages.count == 1 && message.kind == .succeeded && message.action == .none)
            let storedRevision = try await f.stored().revision
            #expect(message.receipt?.revision == receipt.revision && receipt.revision == storedRevision)
            let outcome = try #require(review.outcome)
            #expect(outcome.added == 1 && outcome.updated == 0)
            #expect(outcome.results.map(\.action) == [.added] && outcome.results.first?.kind == .password)
            #expect(!String(reflecting: outcome).contains("incoming"))
        }
    }

    @Test func allSkippedIsNothingImportedNotSuccess() async throws {
        try await base.withFixture { f in
            let target = base.account(password: "old")
            try await f.seed([target] + base.neighbours(1))
            let inbox = inbox(f)
            try await stage(try base.exported([base.account(id: target.id, password: "new")]), in: f)
            let conflict = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner)?.conflicts.first)
            try f.coordinator.choose(.skip, for: conflict.incoming, owner: f.owner)
            let before = try f.diskBytes()

            let failure = await endingFailure(of: f)
            #expect(failure?.message.kind == .nothingImported && failure?.message.receipt == nil)
            #expect(inbox.messages.count == 1 && inbox.messages.first?.kind == .nothingImported)
            #expect(try f.diskBytes() == before)
        }
    }

    @Test func lockDuringCommitReportsMayHaveLanded() async throws {
        let gate = VaultClockGate()
        try await base.withFixture(gate: gate) { f in
            try await f.seed(base.neighbours(2))
            let inbox = inbox(f)
            try await stage(incomingLogin(in: f), in: f)

            gate.holdImportWrite(of: f.coordinator)
            let commit = Task { @MainActor in try await f.coordinator.commitImport(into: f.manager, owner: f.owner) }
            gate.whenParked {
                f.manager.lock(reason: .manual)
                gate.release()
            }

            do {
                let receipt = try await commit.value
                // The write was already past its last authorization check: the receipt is the truth.
                #expect(receipt.revision == 3)
            } catch let failure as CredentialTransferFailure {
                #expect(failure.message.kind == .mayHaveLanded && failure.message.action == .checkSavedCredentials)
                #expect(failure.message.receipt == nil)
                #expect(inbox.messages == [failure.message])
            }
            #expect(gate.hasParked)
        }
    }

    @Test func resultsNameEveryCredentialsFateAndTheModelDropsThemOnLock() async throws {
        try await base.withFixture { f in
            let target = base.account(password: "old")
            try await f.seed([target] + base.neighbours(1))
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            let token = UUID()
            #expect(f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
            try f.coordinator.claimImport(token: token, for: f.manager, owner: model.owner)
            try await f.coordinator.stage(
                try base.exported([base.account(id: target.id, password: "new-secret-pw"), base.account(username: "fresh", password: "fresh-secret-pw")]),
                into: f.manager, owner: model.owner
            )
            let conflict = try #require(model.importReview?.conflicts.first)
            model.chooseImport(.replace, for: conflict.incoming)

            await model.commitImport()

            let results = try #require(model.lastImport?.results)
            #expect(results.count == 2 && Set(results.map(\.action)) == [.added, .updated])
            let shown = String(reflecting: results)
            #expect(!shown.contains("new-secret-pw") && !shown.contains("fresh-secret-pw"))
            f.manager.lock(reason: .manual)
            #expect(model.lastImport == nil)
            #expect(model.transferMessage?.kind == .succeeded)
        }
    }

    @Test func managerCommitAccountsRefusesAStaleEpochAndAStaleStampAndWritesNothing() async throws {
        try await base.withFixture { f in
            let target = base.account(password: "old")
            try await f.seed([target] + base.neighbours(1))
            let epoch = try #require(f.manager.authorizationEpoch)
            let stamp = try #require(try await f.stored().stamps[target.id])
            var replacement = target
            replacement.password = "new"
            let write = AccountWrite(accountID: target.id, expected: .stamp(stamp), replacement: replacement)
            let before = try f.diskBytes()

            await #expect(throws: CredentialVaultError.unauthorized) {
                _ = try await f.manager.commitAccounts([write], authorizedEpoch: epoch &+ 1)
            }
            let wrong = AccountWrite(accountID: target.id, expected: .absent, replacement: replacement)
            await #expect(throws: CredentialVaultError.staleRevision) {
                _ = try await f.manager.commitAccounts([wrong], authorizedEpoch: epoch)
            }
            #expect(try f.diskBytes() == before)

            _ = try await f.manager.commitAccounts([write], authorizedEpoch: epoch)
            #expect(try await f.stored().accounts.first { $0.id == target.id }?.password == "new")
        }
    }

    // MARK: - Review exposure

    @Test func reviewNeverExposesSecretValues() async throws {
        try await base.withFixture { f in
            let stored = base.account(password: "stored-password-secret", totp: base.generator("stored-seed-secret"))
            try await f.seed([stored] + base.neighbours(1))
            try await stage(try base.exported([base.account(id: stored.id, password: "incoming-password-secret", totp: base.generator("incoming-seed-secret"))]), in: f)

            let review = try #require(f.coordinator.importReview(for: f.manager, owner: f.owner))
            #expect(review.conflicts.count >= 2)
            var everything = String(reflecting: review)
            for record in review.candidates.flatMap(\.records) {
                everything += String(reflecting: record) + String(reflecting: record.incoming) + String(reflecting: record.existing as Any)
            }
            for secret in ["stored-password-secret", "incoming-password-secret", "stored-seed-secret", "incoming-seed-secret"] {
                #expect(!everything.contains(secret))
            }
        }
    }

    // MARK: - Export

    @Test func exportOutcomesEndInHandedToSystemOrUncertainNeverSucceeded() {
        let handed = CredentialExportOutcome.transferred.message
        #expect(handed?.kind == .handedToSystem && handed?.receipt == nil && handed?.kind != .succeeded)
        #expect(CredentialExportOutcome.uncertain.message?.kind == .exportUncertain)
        #expect(CredentialExportOutcome.cancelled.message == nil)
    }

    @Test func transferredRecordsHandoffStampAndHashOnlyAndNeverAdvancesTheBase() async throws {
        try await base.withFixture { f in
            let linked = base.account(username: "ada", password: "pw", totp: base.generator("seed"))
            let bystander = base.account(username: "bystander", password: "bystander-pw")
            try await f.seed([linked, bystander])
            let epoch = try #require(f.manager.authorizationEpoch)
            let selection = [CredentialExportSelection(accountID: linked.id, password: true, passkeyIDs: [], totp: false)]
            let (_, snapshot) = try await f.coordinator.prepare(
                selection: selection, expectedStamps: try await f.stored().stamps, format: .v1, from: f.manager, epoch: epoch
            )
            let handedAt = Date(timeIntervalSince1970: 1_800_000_000)
            f.coordinator.now = { handedAt }

            // An unrelated write after the selection check does not stop the stamp.
            var accounts = try await f.stored().accounts
            accounts[accounts.firstIndex { $0.id == bystander.id }!].password = "bystander-changed"
            _ = try await f.manager.commit(accounts, expectedRevision: try await f.stored().revision, authorizedEpoch: epoch)
            await f.coordinator.stampHandoff(selection, in: snapshot, from: f.manager, epoch: epoch)

            let after = try await f.stored().accounts
            let stamped = try #require(after.first { $0.id == linked.id })
            #expect(stamped.passwordEvents?.lastExportHandoffAt == handedAt)
            #expect(stamped.passwordEvents?.lastExportHandoffHash == (try CredentialContent.hash(.password(linked))))
            #expect(stamped.passwordEvents?.remoteLastObservedAt == nil && stamped.passwordEvents?.lastImportedAt == nil)
            #expect(stamped.totpEvents == nil, "A part that was not selected is not stamped")
            #expect(stamped.passwordBase == linked.passwordBase && stamped.totpBase == linked.totpBase && stamped.password == linked.password)
            #expect(after.first { $0.id == bystander.id }?.password == "bystander-changed")
        }
    }

    @Test func aChangedSelectedAccountIsNotStampedAfterTheHandoff() async throws {
        try await base.withFixture { f in
            let linked = base.account(username: "ada", password: "pw")
            try await f.seed([linked] + base.neighbours(1))
            let epoch = try #require(f.manager.authorizationEpoch)
            let selection = [CredentialExportSelection(accountID: linked.id, password: true, passkeyIDs: [], totp: false)]
            let (_, snapshot) = try await f.coordinator.prepare(
                selection: selection, expectedStamps: try await f.stored().stamps, format: .v1, from: f.manager, epoch: epoch
            )
            var accounts = try await f.stored().accounts
            accounts[accounts.firstIndex { $0.id == linked.id }!].password = "changed-during-the-sheet"
            _ = try await f.manager.commit(accounts, expectedRevision: try await f.stored().revision, authorizedEpoch: epoch)
            let before = try f.diskBytes()

            await f.coordinator.stampHandoff(selection, in: snapshot, from: f.manager, epoch: epoch)
            #expect(try f.diskBytes() == before)
        }
    }

    // MARK: - Model

    @Test func anExternalChangeToASelectedAccountSendsNothingRefreshesThePageAndTheRetrySends() async throws {
        try await base.withFixture { f in
            let target = base.account(username: "ada", password: "pw")
            try await f.seed([target] + base.neighbours(1))
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            await model.load()
            let epoch = try #require(f.manager.authorizationEpoch)
            let loaded = model.revision
            let sends = Mutex(0)
            f.coordinator.requestSystemExport = { _ in
                CredentialExchangeCoordinator.SystemExport(format: .v1, send: { _ in sends.withLock { $0 += 1 } })
            }
            let selection = [CredentialExportSelection(accountID: target.id, password: true, passkeyIDs: [], totp: false)]

            // Another writer changes the selected account; this model's own revision does not move.
            var changed = target
            changed.password = "changed-by-another-writer"
            var accounts = try await f.stored().accounts
            accounts[accounts.firstIndex { $0.id == target.id }!] = changed
            _ = try await f.manager.commit(accounts, expectedRevision: loaded, authorizedEpoch: epoch)
            let storedRevision = try await f.stored().revision
            #expect(model.revision == loaded && storedRevision != loaded)
            let before = try f.diskBytes()

            let first = await model.exportCredentials(selection: selection, epoch: epoch, in: NSWindow())
            #expect(first == nil && sends.withLock { $0 } == 0)
            #expect(model.transferMessage?.kind == .exportSelectionChanged && model.transferMessage?.action == CredentialTransferMessage.Action.none)
            #expect(try f.diskBytes() == before)
            // The page now shows what is stored, so the user can decide again on the same selection.
            #expect(model.revision == storedRevision)

            let retry = await model.exportCredentials(selection: selection, epoch: epoch, in: NSWindow())
            #expect(retry == .transferred && sends.withLock { $0 } == 1)
            #expect(model.transferMessage?.kind == .handedToSystem)
            let stamped = try #require(try await f.stored().accounts.first { $0.id == target.id })
            #expect(stamped.password == "changed-by-another-writer" && stamped.passwordEvents?.lastExportHandoffHash != nil)
        }
    }

    @Test func theModelShowsTheRefusalOfASecondTokenUntilItIsDismissed() async throws {
        try await base.withFixture { f in
            let model = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            try await f.seed(base.neighbours(1))
            #expect(f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: UUID())))
            #expect(!f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: UUID())))

            #expect(model.transferMessage?.kind == .alreadyInProgress)
            model.dismissTransferMessage()
            #expect(model.transferMessage == nil && f.coordinator.notice(for: model.owner) == nil)
        }
    }

    @Test func aLockedOutReviewIsDiscardedOnItsOwnWindowOnlyAndOnlyThatWindowDismissesIt() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(1))
            let windowA = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            let windowB = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            let token = UUID()
            #expect(f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
            try f.coordinator.claimImport(token: token, for: f.manager, owner: windowA.owner)
            try await f.coordinator.stage(incomingLogin(in: f), into: f.manager, owner: windowA.owner)

            f.manager.lock(reason: .manual)
            #expect(windowA.transferMessage?.kind == .discarded)
            #expect(windowB.transferMessage == nil)

            windowB.dismissTransferMessage()
            #expect(windowA.transferMessage?.kind == .discarded)
            windowA.dismissTransferMessage()
            #expect(windowA.transferMessage == nil)
        }
    }

    @Test func aNewTokenAtTheIntakeDoesNotEraseAnotherWindowsDiscardedNotice() async throws {
        try await base.withFixture { f in
            try await f.seed(base.neighbours(1))
            let windowA = CredentialSettingsModel(profile: f.profile, exchange: f.coordinator, manager: f.manager)
            let token = UUID()
            #expect(f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: token)))
            try f.coordinator.claimImport(token: token, for: f.manager, owner: windowA.owner)
            try await f.coordinator.stage(incomingLogin(in: f), into: f.manager, owner: windowA.owner)
            f.manager.lock(reason: .manual)

            #expect(f.coordinator.receive(CredentialExchangeCoordinatorTests.activity(token: UUID())))
            #expect(windowA.transferMessage?.kind == .discarded)
        }
    }
}
