// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Observation

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

    /// Tells the window that began an import how it ended when that happened outside its own call (a lock that dropped its
    /// review). The window builds it with a weak capture of itself and the vault it began in, so a window that is gone hears
    /// nothing and another window never does.
    typealias Ending = @MainActor (CredentialTransferMessage) -> Void

    /// `owner` is the settings model that began the import. One profile has one shared manager, but every settings
    /// page builds its own model, so the manager alone does not say whose review this is.
    private struct Claim {
        let token: UUID
        let manager: ObjectIdentifier
        let owner: UUID
        let epoch: UInt64
        let ending: Ending?
        var origin = CredentialTransferMessage.Origin.system
    }

    private enum Source {
        case system(ASExportedCredentialData)
        case csv(Data)
        /// The passwords saved before Credential Manager.
        case legacy([SavedPassword])

        var origin: CredentialTransferMessage.Origin {
            switch self {
            case .system:
                .system
            case .csv:
                .csvFile
            case .legacy:
                .legacyPasswords
            }
        }

        /// The rows of a CSV file or of the old list, staged against the vault. A system import is staged by the codec instead.
        func stagedRows(against snapshot: StoreSnapshot) throws -> CredentialCSVImport.Staged {
            switch self {
            case let .csv(data):
                try CredentialCSVImport.stage(data, against: snapshot)
            case let .legacy(records):
                try CredentialCSVImport.stage(legacy: records, against: snapshot)
            case .system:
                throw CredentialCSVError.missingColumns
            }
        }
    }

    /// What the review shows beyond the preview itself, read once when it is staged. Internal for `CredentialExchangeCoordinator+Review`.
    struct ReviewContext {
        let classes: [CredentialIdentity: CredentialImportClass]
        let profileName: String
        let vaultName: String?
        let csvReport: CredentialCSVReport?
        let origin: CredentialTransferMessage.Origin
        /// CSV rows that must be decided although they are not conflicts with one stored credential.
        var needsChoice: Set<CredentialIdentity> = []
        var csvLines: [CredentialIdentity: Int] = [:]
    }

    /// The staged import. Internal for `CredentialExchangeCoordinator+Review`, which keeps its choices and its review in step.
    struct Session {
        let manager: CredentialManager
        let owner: UUID
        let ending: Ending?
        let epoch: UInt64
        let generation: Int
        let preview: CredentialImportPreview
        let context: ReviewContext
        let index: ReviewIndex
        var choices: [CredentialIdentity: CredentialImportChoice]
        /// The stored credential each `.replace` choice overwrites, mapped to the incoming one that replaces it.
        var replaced: [CredentialIdentity: CredentialIdentity]
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
    /// Internal for `CredentialExchangeCoordinator+Review`, which edits it in place.
    var session: Session?

    /// The one sink for every ending or refusal (spec §13.5): each ending emits exactly one message. An operation one window
    /// started also throws `CredentialTransferFailure`, so that window is told without a sink routing the message to it.
    @ObservationIgnored var onMessage: (@MainActor (CredentialTransferMessage) -> Void)?
    /// Test seam: runs after the pre-commit re-check and before `commitAccounts`.
    @ObservationIgnored var afterLastCheck: (@MainActor () async -> Void)?
    /// The clock for the export hand-off stamp.
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    /// The refusal of a second token while one is open. It belongs to no window (the token is the system's), so it is the only
    /// ending kept here; every window's own ending lives in that window.
    private(set) var refusal: CredentialTransferMessage?

    func dismissRefusal() {
        refusal = nil
    }

    // MARK: Pending token

    /// What `receive` did with an activity: queued its token, refused it because another import is open (said so, once), or
    /// ignored it (not an exchange activity, or a token already queued or spent), which says nothing and opens nothing.
    enum ReceiveResult: Equatable {
        case accepted, refused, ignored
    }

    /// Queues the token carried by the system's exchange activity. One import at a time, each token once. A new token that
    /// arrives while another is pending, claimed or staged is refused and says so; the open import is untouched.
    @discardableResult
    func receive(_ activity: NSUserActivity) -> ReceiveResult {
        guard activity.activityType == ASCredentialExchangeActivity,
              let token = activity.userInfo?[ASCredentialImportToken] as? UUID,
              token != pendingToken, !consumed.contains(token) else { return .ignored }
        guard pendingToken == nil, claim == nil, session == nil else {
            let message = CredentialTransferMessage.alreadyInProgress()
            refusal = message
            onMessage?(message)
            return .refused
        }
        refusal = nil
        pendingToken = token
        return .accepted
    }

    /// Declines the queued token the caller rendered. A button drawn for an earlier token must not decline a later one.
    func discardPendingImport(token: UUID) {
        guard pendingToken == token else { return }
        consumed.insert(token)
        pendingToken = nil
    }

    /// Binds the queued token to `manager`'s current authorization. A locked manager leaves the token queued.
    func claimImport(token: UUID, for manager: CredentialManager, owner: UUID, onEnding: Ending? = nil) throws {
        guard pendingToken == token else { throw CredentialExchangeCoordinatorError.tokenMismatch }
        guard claim == nil, session == nil else { throw CredentialExchangeCoordinatorError.busy }
        guard let epoch = manager.authorizationEpoch else { throw CredentialVaultError.unauthorized }
        pendingToken = nil
        consumed.insert(token)
        claim = Claim(token: token, manager: ObjectIdentifier(manager), owner: owner, epoch: epoch, ending: onEnding)
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
    func beginImport(token: UUID, into manager: CredentialManager, owner: UUID, onEnding: @escaping Ending) async throws {
        try claimImport(token: token, for: manager, owner: owner, onEnding: onEnding)
        guard let bound = claim, bound.token == token else { throw CredentialExchangeCoordinatorError.busy }
        let data: ASExportedCredentialData
        do {
            data = try await ASCredentialImportManager().importCredentials(token: token)
        } catch {
            release(token)
            throw Self.mapNative(error)
        }
        try await stage(.system(data), into: manager, bound: bound)
    }

    /// Parses `data` against the vault as it is now. Nothing is written; any malformed record rejects it all.
    func stage(_ data: ASExportedCredentialData, into manager: CredentialManager, owner: UUID) async throws {
        guard let bound = claim, bound.owner == owner else { throw CredentialExchangeCoordinatorError.wrongTarget }
        try await stage(.system(data), into: manager, bound: bound)
    }

    /// Stages a password CSV the user picked. It needs no system token: it takes the claim directly, under the same
    /// one-import-at-a-time rule, bound to the manager's current authorization. Nothing is written.
    func beginCSVImport(_ data: Data, into manager: CredentialManager, owner: UUID, onEnding: @escaping Ending) async throws {
        try await begin(.csv(data), into: manager, owner: owner, onEnding: onEnding)
    }

    /// Stages the passwords saved before Credential Manager for the same review, by the same rules as a CSV file: no token, one
    /// import at a time, bound to the manager's current authorization. Nothing is written, and the old list is never touched.
    func beginLegacyImport(_ records: [SavedPassword], into manager: CredentialManager, owner: UUID, onEnding: @escaping Ending) async throws {
        try await begin(.legacy(records), into: manager, owner: owner, onEnding: onEnding)
    }

    private func begin(_ source: Source, into manager: CredentialManager, owner: UUID, onEnding: @escaping Ending) async throws {
        guard claim == nil, session == nil else { throw CredentialExchangeCoordinatorError.busy }
        guard let epoch = manager.authorizationEpoch else { throw CredentialVaultError.unauthorized }
        let bound = Claim(token: UUID(), manager: ObjectIdentifier(manager), owner: owner, epoch: epoch, ending: onEnding, origin: source.origin)
        claim = bound
        try await stage(source, into: manager, bound: bound)
    }

    /// A cancel, lock or lease loss while this operation still owns the claim discards the import: the token is spent and
    /// nothing was written. One that follows `cancelImport` is the cancel's own ending and says nothing more.
    private func stage(_ source: Source, into manager: CredentialManager, bound: Claim) async throws {
        defer { release(bound.token) }
        do {
            try await stageClaimed(source, into: manager, bound: bound)
        } catch {
            guard claim?.token == bound.token else { throw error }
            switch error {
            case is CancellationError, CredentialVaultError.unauthorized, CredentialVaultError.expired:
                throw end(.discarded(source.origin))
            default:
                throw error
            }
        }
    }

    private func stageClaimed(_ source: Source, into manager: CredentialManager, bound: Claim) async throws {
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
        var classes: [CredentialIdentity: CredentialImportClass] = [:]
        var csvReport: CredentialCSVReport?
        var needsChoice: Set<CredentialIdentity> = []
        var csvLines: [CredentialIdentity: Int] = [:]
        switch source {
        case let .system(data):
            do {
                preview = try CredentialExchangeCodec.preview(data, against: snapshot)
            } catch let error as CredentialExchangeError {
                throw end(.malformed(error))
            }
            let destination = ImportDestinationView(accounts: snapshot.accounts, removed: removed)
            for candidate in preview.candidates {
                for incoming in Self.identities(in: candidate) {
                    classes[incoming] = try CredentialExchangeCodec.classify(incoming, of: candidate, destination: destination)
                }
            }
        case .csv, .legacy:
            do {
                let staged = try source.stagedRows(against: snapshot)
                preview = staged.preview
                classes = staged.classes
                needsChoice = staged.needsChoice
                csvLines = staged.lines
                csvReport = staged.report
            } catch let error as CredentialCSVError {
                // The old list has no file to be unreadable; what it can fail on is the vault's room (`tooManyAccounts`).
                guard source.origin != .legacyPasswords else { throw end(.applyFailed(operation: String(localized: "Import"), .legacyPasswords)) }
                if case let .unreadable(line) = error {
                    throw end(.csvUnreadable(line: line))
                }
                throw end(.csvUnreadable(line: nil))
            }
        }
        let context = ReviewContext(
            classes: classes, profileName: names.profile, vaultName: names.vault, csvReport: csvReport, origin: source.origin,
            needsChoice: needsChoice, csvLines: csvLines
        )
        generation += 1
        let index = ReviewIndex(preview, context)
        let choices = index.defaultChoices()
        session = Session(
            manager: manager, owner: bound.owner, ending: bound.ending, epoch: bound.epoch, generation: generation,
            preview: preview, context: context, index: index, choices: choices,
            replaced: index.replacements(in: choices), review: index.makeReview(choices: choices)
        )
        watch(manager, generation: generation)
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
        guard staged.review.isResolved else { throw CredentialExchangeCoordinatorError.unresolvedConflicts }
        guard committing == nil else { throw CredentialExchangeCoordinatorError.busy }

        let plan: (touched: [CredentialAccount], outcome: CredentialImportOutcome)
        do {
            try Task.checkCancellation()
            guard manager.authorizationEpoch == staged.epoch else { throw CredentialVaultError.unauthorized }
            plan = try Self.planned(staged)
        } catch CredentialVaultError.invalidData, CredentialVaultError.duplicateIdentifier {
            // The choices don't fit together (for example two items merged into one login): the user changes one and tries again.
            throw CredentialExchangeCoordinatorError.invalidChoice
        } catch {
            drop(staged.generation)
            throw end(Self.messageBeforeWrite(error, operation: String(localized: "Preparing the imported credentials"), staged.context.origin))
        }
        guard !plan.touched.isEmpty else { throw end(.nothingImported()) }

        let write = Task { try await self.applyImport(plan.touched, outcome: plan.outcome, staged: staged) }
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
            throw end(Self.messageBeforeWrite(error, operation: String(localized: "Checking the vault before saving"), staged.context.origin))
        }
        let receipt: VaultCommitReceipt
        do {
            receipt = try await staged.manager.commitAccounts(writes, authorizedEpoch: staged.epoch)
        } catch {
            throw end(Self.messageAfterWriteStarted(error, staged.context.origin))
        }
        onMessage?(.succeeded(outcome, receipt: receipt, origin: staged.context.origin))
        return receipt
    }

    /// No write has started: a cancel, lock, lease loss or changed touched account only discards; anything else the plan or the
    /// vault refused is a failure to apply. Either way nothing was written.
    private static func messageBeforeWrite(
        _ error: any Error, operation: String, _ origin: CredentialTransferMessage.Origin
    ) -> CredentialTransferMessage {
        switch error {
        case is CancellationError, CredentialVaultError.unauthorized, CredentialVaultError.expired, CredentialVaultError.staleRevision:
            .discarded(origin)
        default:
            .applyFailed(operation: operation, origin)
        }
    }

    /// `commitAccounts` has begun. Only what its transaction proves rolled back says nothing was written: a stamp or
    /// absence mismatch (`staleRevision`) and the capacity, collision and malformed refusals, which are all raised before the
    /// first row is written. Every other error, cancellation and lease loss included, may follow a durable write.
    private static func messageAfterWriteStarted(_ error: any Error, _ origin: CredentialTransferMessage.Origin) -> CredentialTransferMessage {
        switch error {
        case CredentialVaultError.staleRevision:
            .discarded(origin)
        case CredentialVaultError.duplicateIdentifier, CredentialStoreError.limit, CredentialStoreError.malformed:
            .applyFailed(operation: String(localized: "Saving the imported credentials"), origin)
        default:
            .mayHaveLanded(origin)
        }
    }

    /// Which import `owner` has on `manager` (a claim or a review), so an ending says the retry that is true for it.
    func importOrigin(for manager: CredentialManager, owner: UUID) -> CredentialTransferMessage.Origin {
        if let session, session.manager === manager, session.owner == owner {
            return session.context.origin
        }
        if let claim, claim.manager == ObjectIdentifier(manager), claim.owner == owner {
            return claim.origin
        }
        return .system
    }

    /// Ends whatever import `owner` has under way on `manager` (claim, review or running commit). Another model's
    /// or manager's claim, review and commit are left alone, so a second window or a closing or stale profile
    /// cannot cancel the one that is actually reviewing.
    @discardableResult
    func cancelImport(for manager: CredentialManager, owner: UUID) -> CredentialImportCancellation {
        let origin = importOrigin(for: manager, owner: owner)
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
            onMessage?(.discarded(origin))
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
        let (chosen, snapshot) = try await checkedSelection(selection, expectedStamps: expectedStamps, from: manager, epoch: epoch)
        let data = try CredentialExchangeCodec.export(snapshot, selection: chosen, format: format)
        guard !data.accounts.isEmpty else { throw CredentialExchangeCoordinatorError.emptySelection }
        return (data, snapshot)
    }

    /// Reads the vault under the authorization the selection was made in and proves the selection still matches it: one
    /// account that changed or vanished since its stamp was taken is a stale selection, and nothing may be written for it.
    private func checkedSelection(
        _ selection: [CredentialExportSelection],
        expectedStamps: [UUID: AccountStamp],
        from manager: CredentialManager,
        epoch: UInt64
    ) async throws -> (chosen: [CredentialExportSelection], snapshot: StoreSnapshot) {
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
        return (chosen, snapshot)
    }

    /// Writes the selected logins as a plain-text password CSV at `url`, which the user already chose (and confirmed
    /// replacing) in the save panel. The stamps are re-proved against the vault HERE, after that panel, and the file is
    /// written with nothing suspended in between: a changed account, a lock or a cancel writes nothing and leaves whatever is
    /// at `url` as it was. Returns the CSV rows written. No hand-off stamp is recorded: a file is not an exchange.
    func exportCSV(
        selection: [CredentialExportSelection],
        expectedStamps: [UUID: AccountStamp],
        epoch: UInt64,
        from manager: CredentialManager,
        to url: URL
    ) async throws -> Int {
        do {
            // A file holds passwords and their notes only: a passkey or code part of the selection is neither checked nor written.
            let passwords = selection.filter(\.password).map {
                CredentialExportSelection(accountID: $0.accountID, password: true, passkeyIDs: [], totp: false, notes: $0.notes)
            }
            let (chosen, snapshot) = try await checkedSelection(passwords, expectedStamps: expectedStamps, from: manager, epoch: epoch)
            let exported = try CredentialCSVExport.encode(snapshot, selection: chosen)
            try Task.checkCancellation()
            guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            try CredentialCSV.save(exported.data, to: url)
            onMessage?(.csvExported(rows: exported.rows))
            return exported.rows
        } catch is CancellationError {
            throw CancellationError()
        } catch CredentialExchangeCoordinatorError.emptySelection {
            throw CredentialExchangeCoordinatorError.emptySelection
        } catch CredentialCSVError.notWritten {
            throw end(.csvNotSaved())
        } catch {
            switch error {
            case CredentialVaultError.unauthorized, CredentialVaultError.expired, CredentialVaultError.staleRevision:
                throw end(.exportSelectionChanged())
            default:
                throw end(.exportNotSent())
            }
        }
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

    var live: Session? {
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

    /// Ends the review when the manager locks or re-unlocks: the copy is dropped and the window that began it is told once.
    /// A running commit reports its own ending instead.
    private func lose(_ generation: Int) {
        guard let lost = session, lost.generation == generation else { return }
        session = nil
        if committing?.generation != generation {
            let message = CredentialTransferMessage.discarded(lost.context.origin)
            lost.ending?(message)
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
        selection.contains { $0.password || $0.totp || $0.notes || !$0.passkeyIDs.isEmpty }
    }
}
