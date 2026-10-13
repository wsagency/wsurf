// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Observation

// MARK: - Value types

/// What to do with one incoming credential. Conflicts (the exporter's item or passkey already exists here)
/// must be decided; every other record is imported automatically unless a choice is made for it.
nonisolated enum CredentialImportChoice: Sendable, Equatable {
    case skip
    /// Conflicts only: overwrite the stored credential the exporter's identifiers match.
    case replace
    /// Creates a new account for the credential.
    case addSeparately
    /// Puts the credential into an account the user picked. It takes that account's websites, which the review
    /// states in full (`CredentialImportReview.Target.allowedOrigins`).
    case merge(into: UUID)
}

/// What an import does, or did, to the vault. `added` and `updated` count accounts; `results` says what became of every
/// incoming credential. Display metadata only (kind, title, website): never a password, seed or key.
nonisolated struct CredentialImportOutcome: Equatable, Sendable {
    struct Result: Equatable, Sendable, Identifiable {
        enum Action: Equatable, Sendable { case added, updated, unchanged, skipped }
        let id: CredentialIdentity
        let kind: CredentialImportReview.Record.Kind
        let title: String
        let relyingParty: String?
        let action: Action
    }

    let added: Int
    let updated: Int
    var results: [Result] = []
}

/// What `cancelImport(for:)` ended. Cancelling a running commit only asks the vault not to write: a write that
/// already started may still land, so only `.reviewCancelled` means that nothing was written.
nonisolated enum CredentialImportCancellation: Equatable, Sendable {
    case nothingOwned
    /// A claim or review was dropped and no commit was running.
    case reviewCancelled
    case commitCancellationRequested
}

/// What an export attempt can say about itself. The system never reports whether the destination app received
/// anything, so `.transferred` means only that the system accepted the hand-off without an error.
nonisolated enum CredentialExportOutcome: Equatable, Sendable {
    /// The system's hand-off call completed without an error.
    case transferred
    /// The user backed out before any credential data was passed to the system.
    case cancelled
    /// The hand-off call had started and then failed or was cancelled. The data may or may not have left.
    case uncertain

    /// What the user is told for this outcome; a user cancel says nothing.
    var message: CredentialTransferMessage? {
        switch self {
        case .transferred:
            .handedToSystem()
        case .uncertain:
            .exportUncertain()
        case .cancelled:
            nil
        }
    }
}

nonisolated enum CredentialExchangeCoordinatorError: Error, Equatable, Sendable {
    case tokenMismatch
    case wrongTarget
    case busy
    case unresolvedConflicts
    case unknownConflict
    /// The choice is not offered for that record, or it would make the import inconsistent.
    case invalidChoice
    case noStagedImport
    case emptySelection
    /// Domain and code only: the system's own text can name what was being transferred.
    case systemRejected(domain: String, code: Int)
}

nonisolated struct CredentialImportReview: Sendable {
    /// An existing account an incoming credential could be merged into.
    struct Target: Identifiable, Sendable {
        let accountID: UUID
        let title: String
        /// Every website the credential works on once merged: the target's own, which the credential inherits.
        /// Nothing is added to the target, and the credential's own scope is not carried over.
        let allowedOrigins: [String]
        var id: UUID {
            accountID
        }
    }

    struct Record: Identifiable, Sendable {
        enum Kind: Sendable { case password, passkey, totp }

        /// Where the record ends up under its current choice, from the plan's own account data.
        enum Destination: Sendable, Equatable {
            case skipped
            /// A new account of its own, which works on the exporter's websites for the item (possibly none).
            case newAccount(origins: [String])
            /// A stored account. It keeps exactly its own websites: `ignoredOrigins` are the ones the exporter sent
            /// for this item that it does not already approve, and none of them are added.
            case existing(accountID: UUID, title: String, origins: [String], ignoredOrigins: [String])
        }

        let incoming: CredentialIdentity
        /// The stored credential the exporter's identifiers match. Non-nil makes this record a conflict.
        let existing: CredentialIdentity?
        let kind: Kind
        let title: String
        let existingTitle: String?
        /// A passkey's own website, which it keeps wherever it is saved. `nil` for other kinds.
        let relyingParty: String?
        /// `nil` while an unresolved conflict has no decision.
        let destination: Destination?
        /// `false` for a passkey whose credential ID a stored passkey already holds: the vault keeps those unique,
        /// so a second copy can't be added, and the choice is neither offered nor accepted.
        let canAddSeparately: Bool
        /// `true` for a login conflict whose stored account has a password but whose incoming login has none. Replacing
        /// takes the exporter's username and password as sent, so it removes the stored password; the review says so
        /// before the user chooses, and `.addSeparately` or `.skip` keep it.
        let removesStoredPasswordOnReplace: Bool
        /// What the vault already says about this credential: new, unchanged, changed on either side, previously removed,
        /// ambiguous, or a passkey with a conflicting key (never replaced).
        let classification: CredentialImportClass
        /// `nil` for an unresolved conflict, or an automatic import for any other record.
        var choice: CredentialImportChoice?
        var isConflict: Bool {
            existing != nil
        }
        var id: CredentialIdentity {
            incoming
        }
    }

    struct Candidate: Identifiable, Sendable {
        let summary: CredentialSummary
        /// Holds a login or TOTP seed but no approved website, so autofill never offers it until the user adds one.
        let needsManualAssociation: Bool
        let records: [Record]
        var id: UUID {
            summary.id
        }
    }

    /// Whose vault the credentials go into: the profile, and the vault when its name is readable.
    let profileName: String
    let vaultName: String?
    let candidates: [Candidate]
    let revision: UInt64
    /// `nil` until every conflict has a decision.
    let outcome: CredentialImportOutcome?

    var conflicts: [Record] {
        candidates.flatMap(\.records).filter(\.isConflict)
    }
    var isResolved: Bool {
        conflicts.allSatisfy { $0.choice != nil }
    }
}

// MARK: - Coordinator

/// Stages one system credential import at a time and mediates native export. A pending token becomes a claim
/// for one profile's manager, then a review session bound to that manager's authorization epoch: the
/// getters refuse a session from another epoch, and observing `authorizationEpoch` drops the session (and
/// the secrets in it) the moment the manager locks or re-unlocks.
///
/// Every step that suspends is bound to the token (claim) or generation (session) it started with, so a late
/// completion of a cancelled operation can neither consume nor clear its successor.
@MainActor
@Observable
final class CredentialExchangeCoordinator {
    static let shared = CredentialExchangeCoordinator()

    /// `owner` is the settings model that began the import. One profile has one shared manager, but every settings
    /// page builds its own model, so the manager alone does not say whose review this is.
    private struct Claim {
        let token: UUID
        let manager: ObjectIdentifier
        let owner: UUID
        let epoch: UInt64
    }

    /// What the review shows beyond the preview itself, read once when it is staged.
    private struct ReviewContext {
        let classes: [CredentialIdentity: CredentialImportClass]
        let profileName: String
        let vaultName: String?
    }

    private struct Session {
        let manager: CredentialManager
        let owner: UUID
        let epoch: UInt64
        let generation: Int
        let preview: CredentialImportPreview
        let context: ReviewContext
        var choices: [CredentialIdentity: CredentialImportChoice]
        var review: CredentialImportReview
    }

    /// The commit write in flight, kept so a cancel for the same manager and owner can stop it.
    private struct Commit {
        let generation: Int
        let manager: ObjectIdentifier
        let owner: UUID
        let task: Task<VaultCommitReceipt, any Error>
    }

    private(set) var pendingToken: UUID?
    @ObservationIgnored private var consumed: Set<UUID> = []
    @ObservationIgnored private var claim: Claim?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var committing: Commit?
    private var session: Session?

    /// The one sink for every ending or refusal (spec §13.5): each ending emits exactly one message. An operation one window
    /// started also throws `CredentialTransferFailure`, so that window is told without a sink routing the message to it.
    @ObservationIgnored var onMessage: (@MainActor (CredentialTransferMessage) -> Void)?
    /// Test seam: runs after the pre-commit re-check and before `commitAccounts`.
    @ObservationIgnored var afterLastCheck: (@MainActor () async -> Void)?
    /// The clock for the export hand-off stamp.
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// The last ending that has no window to throw to, with the window it belongs to: a lock that dropped one window's review
    /// (that window's `owner`), or a second token refused while one is open (no owner: it belongs to the intake). One slot, so
    /// a newer notice replaces an older one. Read it with `notice(for:)`.
    private var notice: (message: CredentialTransferMessage, owner: UUID?)?

    /// What `owner` is told about the last unowned ending: its own, or the intake's refusal; never another window's.
    func notice(for owner: UUID) -> CredentialTransferMessage? {
        guard let notice, notice.owner == nil || notice.owner == owner else { return nil }
        return notice.message
    }

    /// Whether the intake's refusal of a second token is showing, for the intake to decide to bring the credential page forward.
    var hasRefusal: Bool {
        notice != nil && notice?.owner == nil
    }

    // MARK: Pending token

    /// Queues the token carried by the system's exchange activity. One import at a time, each token once. A new token that
    /// arrives while another is pending, claimed or staged is refused and says so; the open import is untouched.
    @discardableResult
    func receive(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == ASCredentialExchangeActivity,
              let token = activity.userInfo?[ASCredentialImportToken] as? UUID,
              token != pendingToken, !consumed.contains(token) else { return false }
        guard pendingToken == nil, claim == nil, session == nil else {
            let message = CredentialTransferMessage.alreadyInProgress()
            notice = (message: message, owner: nil)
            onMessage?(message)
            return false
        }
        dismissNotice(for: nil)
        pendingToken = token
        return true
    }

    /// Clears the notice if it is the intake's or `owner`'s; another window's ending stays. Pass `nil` for the intake.
    func dismissNotice(for owner: UUID?) {
        if let notice, notice.owner == nil || notice.owner == owner {
            self.notice = nil
        }
    }

    /// Declines the queued token the caller rendered. A button drawn for an earlier token must not decline a later one.
    func discardPendingImport(token: UUID) {
        guard pendingToken == token else { return }
        consumed.insert(token)
        pendingToken = nil
    }

    /// Binds the queued token to `manager`'s current authorization. A locked manager leaves the token queued.
    func claimImport(token: UUID, for manager: CredentialManager, owner: UUID) throws {
        guard pendingToken == token else { throw CredentialExchangeCoordinatorError.tokenMismatch }
        guard claim == nil, session == nil else { throw CredentialExchangeCoordinatorError.busy }
        guard let epoch = manager.authorizationEpoch else { throw CredentialVaultError.unauthorized }
        pendingToken = nil
        consumed.insert(token)
        claim = Claim(token: token, manager: ObjectIdentifier(manager), owner: owner, epoch: epoch)
    }

    // MARK: Import

    /// Whether `owner` has a staged import on `manager`. Another profile's, or another window's, is not its business.
    func hasStagedImport(for manager: CredentialManager, owner: UUID) -> Bool {
        session?.manager === manager && session?.owner == owner
    }

    func importReview(for manager: CredentialManager, owner: UUID) -> CredentialImportReview? {
        guard let live, live.manager === manager, live.owner == owner else { return nil }
        return live.review
    }

    /// Fetches the system's payload for `token` and stages it for review.
    func beginImport(token: UUID, into manager: CredentialManager, owner: UUID) async throws {
        try claimImport(token: token, for: manager, owner: owner)
        guard let bound = claim, bound.token == token else { throw CredentialExchangeCoordinatorError.busy }
        let data: ASExportedCredentialData
        do {
            data = try await ASCredentialImportManager().importCredentials(token: token)
        } catch {
            release(token)
            throw Self.mapNative(error)
        }
        try await stage(data, into: manager, bound: bound)
    }

    /// Parses `data` against the vault as it is now. Nothing is written; any malformed record rejects it all.
    func stage(_ data: ASExportedCredentialData, into manager: CredentialManager, owner: UUID) async throws {
        guard let bound = claim, bound.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        try await stage(data, into: manager, bound: bound)
    }

    /// A cancel, lock or lease loss while this operation still owns the claim discards the import: the token is spent and
    /// nothing was written. One that follows `cancelImport` is the cancel's own ending and says nothing more.
    private func stage(_ data: ASExportedCredentialData, into manager: CredentialManager, bound: Claim) async throws {
        defer { release(bound.token) }
        do {
            try await stageClaimed(data, into: manager, bound: bound)
        } catch {
            guard claim?.token == bound.token else { throw error }
            switch error {
            case is CancellationError, CredentialVaultError.unauthorized, CredentialVaultError.expired:
                throw end(.discarded())
            default:
                throw error
            }
        }
    }

    private func stageClaimed(_ data: ASExportedCredentialData, into manager: CredentialManager, bound: Claim) async throws {
        guard claim?.token == bound.token else { throw CancellationError() }
        guard bound.manager == ObjectIdentifier(manager) else { throw CredentialExchangeCoordinatorError.wrongTarget }
        guard manager.authorizationEpoch == bound.epoch else { throw CredentialVaultError.unauthorized }
        session = nil
        let snapshot = try await manager.snapshot()
        let removed = try await manager.removedIdentifiers()
        let names = try await manager.displayNames()
        try Task.checkCancellation()
        // cancelImport() or a newer claim landed while the vault was read: this operation no longer owns anything.
        guard claim?.token == bound.token else { throw CancellationError() }
        guard manager.authorizationEpoch == bound.epoch else { throw CredentialVaultError.unauthorized }

        let preview: CredentialImportPreview
        do {
            preview = try CredentialExchangeCodec.preview(data, against: snapshot)
        } catch let error as CredentialExchangeError {
            throw end(.malformed(record: error.record))
        }
        let destination = ImportDestinationView(accounts: snapshot.accounts, removed: removed)
        var classes: [CredentialIdentity: CredentialImportClass] = [:]
        for candidate in preview.candidates {
            for incoming in Self.identities(in: candidate) {
                classes[incoming] = try CredentialExchangeCodec.classify(incoming, in: preview, destination: destination)
            }
        }
        let context = ReviewContext(classes: classes, profileName: names.profile, vaultName: names.vault)
        generation += 1
        let review = try Self.review(for: preview, choices: [:], context)
        session = Session(
            manager: manager, owner: bound.owner, epoch: bound.epoch, generation: generation,
            preview: preview, context: context, choices: [:], review: review
        )
        watch(manager, generation: generation)
    }

    /// Decides one incoming credential. A refused choice leaves the review as it was.
    func choose(_ choice: CredentialImportChoice, for incoming: CredentialIdentity, owner: UUID) throws {
        guard var live = self.live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard live.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        guard let record = live.review.candidates.lazy.flatMap(\.records).first(where: { $0.incoming == incoming }) else {
            throw CredentialExchangeCoordinatorError.unknownConflict
        }
        // A passkey whose key conflicts with the stored one is only ever skipped.
        if record.classification == .passkeyHardConflict, choice != .skip {
            throw CredentialExchangeCoordinatorError.invalidChoice
        }
        switch choice {
        case .replace:
            // A passkey is never replaced: the vault keeps its credential ID unique, and a conflicting key is not ours to overwrite.
            guard record.isConflict, record.kind != .passkey else { throw CredentialExchangeCoordinatorError.invalidChoice }
        case let .merge(target):
            guard Self.targets(for: incoming, in: live.preview).contains(where: { $0.accountID == target }) else {
                throw CredentialExchangeCoordinatorError.invalidChoice
            }
        case .addSeparately:
            guard record.canAddSeparately else { throw CredentialExchangeCoordinatorError.invalidChoice }
        case .skip:
            break
        }
        var choices = live.choices
        choices[incoming] = choice
        do {
            live.review = try Self.review(for: live.preview, choices: choices, live.context)
        } catch CredentialVaultError.invalidData, CredentialVaultError.duplicateIdentifier {
            throw CredentialExchangeCoordinatorError.invalidChoice
        } catch {
            drop(live.generation)
            throw error
        }
        live.choices = choices
        session = live
    }

    /// Existing accounts `incoming` can be merged into: the ones that don't already hold that kind of credential.
    func mergeTargets(for incoming: CredentialIdentity, owner: UUID) -> [CredentialImportReview.Target] {
        guard let live, live.owner == owner else { return [] }
        return Self.targets(for: incoming, in: live.preview)
    }

    /// Applies the reviewed import with one per-account write bound to the stamps of the accounts it touches, so a write to
    /// any other account never discards it. Every ending emits exactly one message (spec §13.5) and every ending but a
    /// receipt throws it as a `CredentialTransferFailure`. A cancel, lock, epoch change or changed touched account
    /// before the write, or a refusal the store proves rolled back, drops the review as discarded or failed: nothing was
    /// written. Any other error once the write began says it may have landed. A returned receipt is never turned into an
    /// error. An import that would change nothing is `nothingImported` and keeps the review.
    func commitImport(into manager: CredentialManager, owner: UUID) async throws -> VaultCommitReceipt {
        guard let staged = live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard staged.manager === manager, staged.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        guard staged.review.isResolved, let outcome = staged.review.outcome else { throw CredentialExchangeCoordinatorError.unresolvedConflicts }
        guard committing == nil else { throw CredentialExchangeCoordinatorError.busy }

        let plan: (touched: [CredentialAccount], outcome: CredentialImportOutcome)
        do {
            try Task.checkCancellation()
            guard manager.authorizationEpoch == staged.epoch else { throw CredentialVaultError.unauthorized }
            plan = try Self.plan(staged.preview, choices: staged.choices)
        } catch {
            drop(staged.generation)
            throw end(Self.messageBeforeWrite(error, operation: String(localized: "Preparing the imported credentials")))
        }
        guard !plan.touched.isEmpty else { throw end(.nothingImported()) }

        let write = Task { try await self.applyImport(plan.touched, outcome: outcome, staged: staged) }
        committing = Commit(generation: staged.generation, manager: ObjectIdentifier(manager), owner: owner, task: write)
        defer { if committing?.generation == staged.generation { committing = nil } }
        do {
            let receipt = try await withTaskCancellationHandler { try await write.value } onCancel: { write.cancel() }
            drop(staged.generation)
            return receipt
        } catch {
            drop(staged.generation)
            throw error
        }
    }

    /// The re-check and the write of one import. The authoritative comparison is inside `commitAccounts`; the fresh read
    /// only discards early, before anything starts.
    private func applyImport(
        _ touched: [CredentialAccount], outcome: CredentialImportOutcome, staged: Session
    ) async throws -> VaultCommitReceipt {
        let writes: [AccountWrite]
        do {
            try Task.checkCancellation()
            let fresh = try await staged.manager.snapshot()
            try Task.checkCancellation()
            guard staged.manager.authorizationEpoch == staged.epoch else { throw CredentialVaultError.unauthorized }
            writes = try touched.map { account in
                guard let bound = staged.preview.base.stamps[account.id] else {
                    guard fresh.stamps[account.id] == nil else { throw CredentialVaultError.staleRevision }
                    return AccountWrite(accountID: account.id, expected: .absent, replacement: account)
                }
                guard fresh.stamps[account.id] == bound else { throw CredentialVaultError.staleRevision }
                return AccountWrite(accountID: account.id, expected: .stamp(bound), replacement: account)
            }
            await afterLastCheck?()
        } catch {
            throw end(Self.messageBeforeWrite(error, operation: String(localized: "Checking the vault before saving")))
        }
        let receipt: VaultCommitReceipt
        do {
            receipt = try await staged.manager.commitAccounts(writes, authorizedEpoch: staged.epoch)
        } catch {
            throw end(Self.messageAfterWriteStarted(error))
        }
        onMessage?(.succeeded(outcome, receipt: receipt))
        return receipt
    }

    /// No write has started: a cancel, lock, lease loss or changed touched account only discards; anything else the plan or the
    /// vault refused is a failure to apply. Either way nothing was written.
    private static func messageBeforeWrite(_ error: any Error, operation: String) -> CredentialTransferMessage {
        switch error {
        case is CancellationError, CredentialVaultError.unauthorized, CredentialVaultError.expired, CredentialVaultError.staleRevision:
            .discarded()
        default:
            .applyFailed(operation: operation)
        }
    }

    /// `commitAccounts` has begun. Only what its transaction proves rolled back says nothing was written: a stamp or
    /// absence mismatch (`staleRevision`) and the capacity, collision and malformed refusals, which are all raised before the
    /// first row is written. Every other error, cancellation and lease loss included, may follow a durable write.
    private static func messageAfterWriteStarted(_ error: any Error) -> CredentialTransferMessage {
        switch error {
        case CredentialVaultError.staleRevision:
            .discarded()
        case CredentialVaultError.duplicateIdentifier, CredentialStoreError.limit, CredentialStoreError.malformed:
            .applyFailed(operation: String(localized: "Saving the imported credentials"))
        default:
            .mayHaveLanded()
        }
    }

    /// Ends whatever import `owner` has under way on `manager` (claim, review or running commit). Another model's
    /// or manager's claim, review and commit are left alone, so a second window or a closing or stale profile
    /// cannot cancel the one that is actually reviewing.
    @discardableResult
    func cancelImport(for manager: CredentialManager, owner: UUID) -> CredentialImportCancellation {
        let id = ObjectIdentifier(manager)
        var outcome = CredentialImportCancellation.nothingOwned
        if let committing, committing.manager == id, committing.owner == owner {
            committing.task.cancel()
            self.committing = nil
            outcome = .commitCancellationRequested
        }
        if let session, session.manager === manager, session.owner == owner {
            self.session = nil
            if outcome == .nothingOwned {
                outcome = .reviewCancelled
            }
        }
        if let claim, claim.manager == id, claim.owner == owner {
            self.claim = nil
            if outcome == .nothingOwned {
                outcome = .reviewCancelled
            }
        }
        if outcome == .reviewCancelled {
            onMessage?(.discarded())
        }
        return outcome
    }

    // MARK: Export

    /// What the system's export manager gave back once the user chose a destination: the format it wants and the call that takes the data.
    struct SystemExport: Sendable {
        let format: ASExportedCredentialData.FormatVersion
        let send: @Sendable (ASExportedCredentialData) async throws -> Void
    }

    /// The only native step of an export. Tests replace it to count what would have been sent; nothing else differs.
    @ObservationIgnored var requestSystemExport: @MainActor (ASPresentationAnchor) async throws -> SystemExport = { anchor in
        // The exporter is used by nothing else once `send` owns it, and `send` runs once, off the main actor, as before.
        nonisolated(unsafe) let exporter = ASCredentialExportManager(presentationAnchor: anchor)
        let options = try await exporter.requestExport(for: nil)
        return SystemExport(format: options.formatVersion, send: { try await exporter.exportCredentials($0) })
    }

    /// Asks the system for a destination and format, then hands it exactly the selected credentials. `expectedStamps` are the
    /// stamps of the selected accounts when the user chose them: a change to one of them, or a lock, sends nothing and says
    /// the selection changed, while a write to any other account does not matter. A user cancel before any data was passed
    /// returns `.cancelled` and says nothing; every other ending emits one message, and a failure throws it.
    func exportCredentials(
        selection: [CredentialExportSelection],
        expectedStamps: [UUID: AccountStamp],
        epoch: UInt64,
        from manager: CredentialManager,
        in anchor: ASPresentationAnchor
    ) async throws -> CredentialExportOutcome {
        guard Self.isNonEmpty(selection) else { throw CredentialExchangeCoordinatorError.emptySelection }
        try Task.checkCancellation()
        do {
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            let system: SystemExport
            do {
                system = try await requestSystemExport(anchor)
            } catch {
                if Self.isUserCancellation(error) {
                    return .cancelled
                }
                throw Self.mapNative(error)
            }
            let (data, snapshot) = try await prepare(
                selection: selection, expectedStamps: expectedStamps, format: system.format, from: manager, epoch: epoch
            )
            // Last point before the secrets leave the vault; everything before it is a clean cancel.
            try Task.checkCancellation()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            let outcome = await Self.handOff { try await system.send(data) }
            if outcome == .transferred {
                await stampHandoff(selection, in: snapshot, from: manager, epoch: epoch)
            }
            if let message = outcome.message {
                onMessage?(message)
            }
            return outcome
        } catch is CancellationError {
            throw CancellationError()
        } catch CredentialExchangeCoordinatorError.emptySelection {
            throw CredentialExchangeCoordinatorError.emptySelection
        } catch {
            switch error {
            case CredentialVaultError.unauthorized, CredentialVaultError.expired, CredentialVaultError.staleRevision:
                throw end(.exportSelectionChanged())
            default:
                throw end(.exportNotSent())
            }
        }
    }

    /// Runs the system call that takes the credential data. Once it has started, a thrown error or a cancellation
    /// says nothing about whether the data left, so every failure is `.uncertain` rather than a cancel or a
    /// rejection, and nothing is retried. Success means the system's call completed, not that the other app has
    /// accepted or imported anything.
    static func handOff(_ send: sending @concurrent () async throws -> Void) async -> CredentialExportOutcome {
        do {
            try await send()
            return .transferred
        } catch {
            return .uncertain
        }
    }

    /// Re-reads the vault under the authorization the selection was made in; the source is never modified.
    func prepareExport(
        selection: [CredentialExportSelection],
        expectedStamps: [UUID: AccountStamp],
        format: ASExportedCredentialData.FormatVersion,
        from manager: CredentialManager,
        epoch: UInt64
    ) async throws -> ASExportedCredentialData {
        try await prepare(selection: selection, expectedStamps: expectedStamps, format: format, from: manager, epoch: epoch).data
    }

    func prepare(
        selection: [CredentialExportSelection],
        expectedStamps: [UUID: AccountStamp],
        format: ASExportedCredentialData.FormatVersion,
        from manager: CredentialManager,
        epoch: UInt64
    ) async throws -> (data: ASExportedCredentialData, snapshot: StoreSnapshot) {
        guard Self.isNonEmpty(selection) else { throw CredentialExchangeCoordinatorError.emptySelection }
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let snapshot = try await manager.snapshot()
        try Task.checkCancellation()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let chosen = selection.filter { Self.isNonEmpty([$0]) }
        for entry in chosen {
            let known = expectedStamps[entry.accountID]
            // An account neither the selection nor the vault knows is a bad request; one that changed or vanished is a stale selection.
            guard known != nil || snapshot.stamps[entry.accountID] != nil else { throw CredentialVaultError.invalidData }
            guard let known, snapshot.stamps[entry.accountID] == known else { throw CredentialVaultError.staleRevision }
        }
        let data = try CredentialExchangeCodec.export(snapshot, selection: chosen, format: format)
        guard !data.accounts.isEmpty else { throw CredentialExchangeCoordinatorError.emptySelection }
        return (data, snapshot)
    }

    /// Records that the system took these parts: their time and canonical content hash in the part's events, never a remote
    /// base. It runs after the hand-off and bound to the stamps the data was read at, through the per-account write, so an
    /// unrelated write does not stop it and a changed account is left alone. Whether it lands changes nothing the user is told.
    func stampHandoff(
        _ selection: [CredentialExportSelection], in snapshot: StoreSnapshot, from manager: CredentialManager, epoch: UInt64
    ) async {
        let handedAt = now()
        var writes: [AccountWrite] = []
        for entry in selection where Self.isNonEmpty([entry]) {
            guard var account = snapshot.accounts.first(where: { $0.id == entry.accountID }),
                  let stamp = snapshot.stamps[account.id] else { continue }
            let original = account
            func mark(_ events: CredentialEvents?, _ part: CredentialPart) -> CredentialEvents? {
                guard let hash = try? CredentialContent.hash(part) else { return events }
                var result = events ?? CredentialEvents()
                result.lastExportHandoffAt = handedAt
                result.lastExportHandoffHash = hash
                return result
            }
            if entry.password, Self.hasLogin(original) {
                account.passwordEvents = mark(account.passwordEvents, .password(original))
            }
            if entry.totp, original.totp != nil {
                account.totpEvents = mark(account.totpEvents, .totp(original))
            }
            for index in account.passkeys.indices where entry.passkeyIDs.contains(account.passkeys[index].id) {
                account.passkeys[index].events = mark(account.passkeys[index].events, .passkey(original.passkeys[index]))
            }
            if account != original {
                writes.append(AccountWrite(accountID: account.id, expected: .stamp(stamp), replacement: account))
            }
        }
        guard !writes.isEmpty else { return }
        _ = try? await manager.commitAccounts(writes, authorizedEpoch: epoch)
    }

    // MARK: System errors

    static func isUserCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let native = error as NSError
        return native.domain == ASAuthorizationError.errorDomain && native.code == ASAuthorizationError.Code.canceled.rawValue
    }

    /// Keeps the domain and code only: the system's own text can name what was being transferred.
    static func mapNative(_ error: any Error) -> any Error {
        if isUserCancellation(error) {
            return CancellationError()
        }
        let native = error as NSError
        return CredentialExchangeCoordinatorError.systemRejected(domain: native.domain, code: native.code)
    }

    // MARK: Private

    private var live: Session? {
        guard let session, session.epoch == session.manager.authorizationEpoch else { return nil }
        return session
    }

    private func release(_ token: UUID) {
        if claim?.token == token {
            claim = nil
        }
    }

    private func drop(_ generation: Int) {
        if session?.generation == generation {
            session = nil
        }
    }

    /// Delivers `message` once and returns the error that carries it to the window that owns the operation.
    private func end(_ message: CredentialTransferMessage) -> CredentialTransferFailure {
        onMessage?(message)
        return CredentialTransferFailure(message: message)
    }

    /// Ends the review when the manager locks or re-unlocks: the copy is dropped and nobody else will say so. A running
    /// commit reports its own ending instead.
    private func lose(_ generation: Int) {
        guard let lost = session, lost.generation == generation else { return }
        let owner = lost.owner
        session = nil
        if committing?.generation != generation {
            let message = CredentialTransferMessage.discarded()
            notice = (message: message, owner: owner)
            onMessage?(message)
        }
    }

    /// Drops the session synchronously inside the manager's change notification, so no secret survives a
    /// lock or an unlock into a new epoch. A later session installs its own observation.
    private func watch(_ manager: CredentialManager, generation: Int) {
        withObservationTracking {
            _ = manager.authorizationEpoch
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.lose(generation) }
        }
    }

    private static func isNonEmpty(_ selection: [CredentialExportSelection]) -> Bool {
        selection.contains { $0.password || $0.totp || !$0.passkeyIDs.isEmpty }
    }

    // The codec treats an account as holding a login when any of these is present, so a username-only
    // record counts. Mirrors its rule so records, warnings and merge targets agree with what it will do.
    private static func hasLogin(_ account: CredentialAccount) -> Bool {
        account.password != nil || account.basicAuthenticationMetadata != nil || !account.username.isEmpty
    }

    private static func identities(in account: CredentialAccount) -> [CredentialIdentity] {
        var result: [CredentialIdentity] = []
        if hasLogin(account) {
            result.append(.password(accountID: account.id))
        }
        result += account.passkeys.map { .passkey(accountID: account.id, passkeyID: $0.id) }
        if account.totp != nil {
            result.append(.totp(accountID: account.id))
        }
        return result
    }

    private nonisolated static func accountID(_ identity: CredentialIdentity) -> UUID {
        switch identity {
        case let .password(id), let .totp(id):
            id
        case let .passkey(id, _):
            id
        }
    }

    private static func targets(
        for incoming: CredentialIdentity,
        in preview: CredentialImportPreview
    ) -> [CredentialImportReview.Target] {
        guard let source = preview.candidates.first(where: { $0.id == accountID(incoming) }) else { return [] }
        func accepts(_ account: CredentialAccount) -> Bool {
            guard CredentialExchangeCodec.canMerge(source, into: account) else { return false }
            switch incoming {
            case .password:
                return !hasLogin(account)
            case .passkey:
                return !credentialIDIsStored(incoming, in: preview)
            case .totp:
                return account.totp == nil
            }
        }
        return preview.base.accounts.filter(accepts).map { account in
            CredentialImportReview.Target(
                accountID: account.id,
                title: CredentialSummary(account).title,
                allowedOrigins: account.origins
            )
        }
    }

    /// Whether `incoming` is a passkey whose credential ID is already held by a stored passkey.
    private static func credentialIDIsStored(_ incoming: CredentialIdentity, in preview: CredentialImportPreview) -> Bool {
        guard case let .passkey(accountID, passkeyID) = incoming,
              let value = preview.candidates.first(where: { $0.id == accountID })?.passkeys.first(where: { $0.id == passkeyID })
        else { return false }
        return preview.base.accounts.contains { $0.passkeys.contains { $0.credentialID == value.credentialID } }
    }

    /// The decisions to hand the codec, or `nil` while a conflict is undecided. Choices on records that are not
    /// conflicts go to the codec as they are: it accepts an explicit decision for any incoming credential.
    private static func decisions(
        _ preview: CredentialImportPreview,
        _ choices: [CredentialIdentity: CredentialImportChoice]
    ) -> [CredentialImportDecision]? {
        let existing = Dictionary(preview.conflicts.map { ($0.incoming, $0.existing) }, uniquingKeysWith: { first, _ in first })
        guard existing.keys.allSatisfy({ choices[$0] != nil }) else { return nil }
        var result: [CredentialImportDecision] = []
        for (incoming, choice) in choices {
            switch choice {
            case .skip:
                result.append(.keep(incoming: incoming))
            case .replace:
                guard let target = existing[incoming] else { return nil }
                result.append(.replace(incoming: incoming, target: target))
            case .addSeparately:
                result.append(.add(incoming: incoming, targetAccountID: nil))
            case let .merge(target):
                result.append(.add(incoming: incoming, targetAccountID: target))
            }
        }
        return result
    }

    private static func plan(
        _ preview: CredentialImportPreview,
        choices: [CredentialIdentity: CredentialImportChoice]
    ) throws -> (touched: [CredentialAccount], outcome: CredentialImportOutcome) {
        guard let decisions = decisions(preview, choices) else {
            throw CredentialExchangeCoordinatorError.unresolvedConflicts
        }
        let accounts = try CredentialExchangeCodec.apply(preview, decisions: decisions)
        let before = Dictionary(preview.base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var touched: [CredentialAccount] = []
        var added = 0
        var updated = 0
        for account in accounts {
            if let old = before[account.id] {
                if old != account {
                    updated += 1
                    touched.append(account)
                }
            } else {
                added += 1
                touched.append(account)
            }
        }
        return (touched, CredentialImportOutcome(added: added, updated: updated))
    }

    private static func review(
        for preview: CredentialImportPreview,
        choices: [CredentialIdentity: CredentialImportChoice],
        _ context: ReviewContext
    ) throws -> CredentialImportReview {
        let titles = Dictionary(
            (preview.base.accounts + preview.candidates).map { ($0.id, CredentialSummary($0).title) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByIncoming = Dictionary(preview.conflicts.map { ($0.incoming, $0.existing) }, uniquingKeysWith: { first, _ in first })
        func kind(_ identity: CredentialIdentity) -> CredentialImportReview.Record.Kind {
            switch identity {
            case .password:
                .password
            case .passkey:
                .passkey
            case .totp:
                .totp
            }
        }
        let stored = Dictionary(preview.base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var resolved = true
        let candidates = preview.candidates.map { candidate in
            let linked = CredentialExchangeCodec.linkedAccountID(for: candidate, in: preview.base.accounts)
            // Mirrors what `CredentialExchangeCodec.apply` does with each decision: a stored account keeps its own
            // websites, and only a new account takes the exporter's.
            func destination(
                _ existing: CredentialIdentity?,
                _ choice: CredentialImportChoice?
            ) -> CredentialImportReview.Record.Destination? {
                func into(_ id: UUID) -> CredentialImportReview.Record.Destination? {
                    guard let account = stored[id] else { return nil }
                    return .existing(
                        accountID: id,
                        title: CredentialSummary(account).title,
                        origins: account.origins,
                        ignoredOrigins: candidate.origins.filter { !account.origins.contains($0) }
                    )
                }
                switch choice {
                case .skip:
                    return .skipped
                case .addSeparately:
                    return .newAccount(origins: candidate.origins)
                case let .merge(target):
                    return into(target)
                case .replace:
                    return existing.flatMap { into(accountID($0)) }
                case nil:
                    if existing != nil {
                        return nil
                    }
                    return linked.flatMap(into) ?? .newAccount(origins: candidate.origins)
                }
            }
            let records = identities(in: candidate).map { incoming in
                let existing = existingByIncoming[incoming]
                let choice = choices[incoming]
                if existing != nil, choice == nil {
                    resolved = false
                }
                let relyingParty: String?
                if case let .passkey(_, passkeyID) = incoming {
                    relyingParty = candidate.passkeys.first { $0.id == passkeyID }?.rpID
                } else {
                    relyingParty = nil
                }
                return CredentialImportReview.Record(
                    incoming: incoming,
                    existing: existing,
                    kind: kind(incoming),
                    title: titles[candidate.id] ?? "",
                    existingTitle: existing.flatMap { titles[accountID($0)] },
                    relyingParty: relyingParty,
                    destination: destination(existing, choice),
                    canAddSeparately: !credentialIDIsStored(incoming, in: preview),
                    removesStoredPasswordOnReplace: kind(incoming) == .password
                        && candidate.password == nil
                        && existing.flatMap { stored[accountID($0)]?.password } != nil,
                    classification: context.classes[incoming] ?? .ambiguous,
                    choice: choice
                )
            }
            return CredentialImportReview.Candidate(
                summary: CredentialSummary(candidate),
                needsManualAssociation: candidate.origins.isEmpty && (hasLogin(candidate) || candidate.totp != nil),
                records: records
            )
        }
        var outcome: CredentialImportOutcome?
        if resolved {
            let planned = try plan(preview, choices: choices)
            let changed = Set(planned.touched.map(\.id))
            outcome = planned.outcome
            outcome?.results = candidates.flatMap(\.records).map { record in
                let action: CredentialImportOutcome.Result.Action
                switch record.destination {
                case .skipped, nil:
                    action = .skipped
                case .newAccount:
                    action = .added
                case let .existing(accountID, _, _, _):
                    action = record.classification != .unchanged && changed.contains(accountID) ? .updated : .unchanged
                }
                return CredentialImportOutcome.Result(
                    id: record.incoming, kind: record.kind, title: record.title, relyingParty: record.relyingParty, action: action
                )
            }
        }
        return CredentialImportReview(
            profileName: context.profileName, vaultName: context.vaultName,
            candidates: candidates, revision: preview.revision, outcome: outcome
        )
    }
}
