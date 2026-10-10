// SPDX-FileCopyrightText: 2026 WSurf contributors
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

nonisolated struct CredentialImportOutcome: Equatable, Sendable {
    let added: Int
    let updated: Int
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
}

nonisolated enum CredentialExchangeCoordinatorError: Error, Equatable, Sendable {
    case tokenMismatch
    case wrongTarget
    case busy
    case unresolvedConflicts
    case unknownConflict
    /// The choice is not offered for that record, or it would make the import inconsistent.
    case invalidChoice
    case nothingToImport
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
        var id: UUID { accountID }
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
        /// `nil` for an unresolved conflict, or an automatic import for any other record.
        var choice: CredentialImportChoice?
        var isConflict: Bool { existing != nil }
        var id: CredentialIdentity { incoming }
    }

    struct Candidate: Identifiable, Sendable {
        let summary: CredentialSummary
        /// Holds a login or TOTP seed but no approved website, so autofill never offers it until the user adds one.
        let needsManualAssociation: Bool
        let records: [Record]
        var id: UUID { summary.id }
    }

    let candidates: [Candidate]
    let revision: UInt64
    /// `nil` until every conflict has a decision.
    let outcome: CredentialImportOutcome?

    var conflicts: [Record] { candidates.flatMap(\.records).filter(\.isConflict) }
    var isResolved: Bool { conflicts.allSatisfy { $0.choice != nil } }
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

    private struct Claim {
        let token: UUID
        let manager: ObjectIdentifier
        let epoch: UInt64
    }

    private struct Session {
        let manager: CredentialManager
        let epoch: UInt64
        let generation: Int
        let preview: CredentialImportPreview
        var choices: [CredentialIdentity: CredentialImportChoice]
        var review: CredentialImportReview
    }

    private(set) var pendingToken: UUID?
    @ObservationIgnored private var consumed: Set<UUID> = []
    @ObservationIgnored private var claim: Claim?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var committing: (generation: Int, manager: ObjectIdentifier, task: Task<VaultCommitReceipt, any Error>)?
    private var session: Session?

    // MARK: Pending token

    /// Queues the token carried by the system's exchange activity. One import at a time, each token once.
    @discardableResult
    func receive(_ activity: NSUserActivity) -> Bool {
        guard activity.activityType == ASCredentialExchangeActivity,
              let token = activity.userInfo?[ASCredentialImportToken] as? UUID,
              pendingToken == nil, claim == nil, session == nil,
              !consumed.contains(token) else { return false }
        pendingToken = token
        return true
    }

    func discardPendingImport() {
        if let pendingToken { consumed.insert(pendingToken) }
        pendingToken = nil
    }

    /// Binds the queued token to `manager`'s current authorization. A locked manager leaves the token queued.
    func claimImport(token: UUID, for manager: CredentialManager) throws {
        guard pendingToken == token else { throw CredentialExchangeCoordinatorError.tokenMismatch }
        guard claim == nil, session == nil else { throw CredentialExchangeCoordinatorError.busy }
        guard let epoch = manager.authorizationEpoch else { throw CredentialVaultError.unauthorized }
        pendingToken = nil
        consumed.insert(token)
        claim = Claim(token: token, manager: ObjectIdentifier(manager), epoch: epoch)
    }

    // MARK: Import

    /// Whether `manager` has a staged import. Another profile's import is not its business.
    func hasStagedImport(for manager: CredentialManager) -> Bool { session?.manager === manager }

    var importReview: CredentialImportReview? { live?.review }

    func importReview(for manager: CredentialManager) -> CredentialImportReview? {
        guard let live, live.manager === manager else { return nil }
        return live.review
    }

    /// Fetches the system's payload for `token` and stages it for review.
    func beginImport(token: UUID, into manager: CredentialManager) async throws {
        try claimImport(token: token, for: manager)
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
    func stage(_ data: ASExportedCredentialData, into manager: CredentialManager) async throws {
        guard let bound = claim else { throw CredentialExchangeCoordinatorError.wrongTarget }
        try await stage(data, into: manager, bound: bound)
    }

    private func stage(_ data: ASExportedCredentialData, into manager: CredentialManager, bound: Claim) async throws {
        defer { release(bound.token) }
        guard claim?.token == bound.token else { throw CancellationError() }
        guard bound.manager == ObjectIdentifier(manager) else { throw CredentialExchangeCoordinatorError.wrongTarget }
        guard manager.authorizationEpoch == bound.epoch else { throw CredentialVaultError.unauthorized }
        session = nil
        let snapshot = try await manager.snapshot()
        try Task.checkCancellation()
        // cancelImport() or a newer claim landed while the vault was read: this operation no longer owns anything.
        guard claim?.token == bound.token else { throw CancellationError() }
        guard manager.authorizationEpoch == bound.epoch else { throw CredentialVaultError.unauthorized }

        let preview = try CredentialExchangeCodec.preview(data, against: snapshot)
        generation += 1
        let review = try Self.review(for: preview, choices: [:])
        session = Session(
            manager: manager, epoch: bound.epoch, generation: generation,
            preview: preview, choices: [:], review: review
        )
        watch(manager, generation: generation)
    }

    /// Decides one incoming credential. A refused choice leaves the review as it was.
    func choose(_ choice: CredentialImportChoice, for incoming: CredentialIdentity) throws {
        guard var live = self.live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard let record = live.review.candidates.flatMap(\.records).first(where: { $0.incoming == incoming }) else {
            throw CredentialExchangeCoordinatorError.unknownConflict
        }
        switch choice {
        case .replace:
            guard record.isConflict else { throw CredentialExchangeCoordinatorError.invalidChoice }
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
            live.review = try Self.review(for: live.preview, choices: choices)
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
    func mergeTargets(for incoming: CredentialIdentity) -> [CredentialImportReview.Target] {
        guard let live else { return [] }
        return Self.targets(for: incoming, in: live.preview)
    }

    /// Cancellation, a stale revision or a codec failure end the review; an unfinished review is kept.
    /// The write runs in a task `cancelImport()` and the caller's cancellation both reach, and it is the
    /// vault's own pre-write check that honours them. A receipt for a write that already landed is always
    /// returned, and nothing throws once the vault has committed.
    func commitImport(into manager: CredentialManager) async throws -> VaultCommitReceipt {
        guard let staged = live else { throw CredentialExchangeCoordinatorError.noStagedImport }
        guard staged.manager === manager else { throw CredentialExchangeCoordinatorError.wrongTarget }
        guard staged.review.isResolved else { throw CredentialExchangeCoordinatorError.unresolvedConflicts }
        guard committing == nil else { throw CredentialExchangeCoordinatorError.busy }

        let write: Task<VaultCommitReceipt, any Error>
        do {
            try Task.checkCancellation()
            guard manager.authorizationEpoch == staged.epoch else { throw CredentialVaultError.unauthorized }
            let plan = try Self.plan(staged.preview, choices: staged.choices)
            guard plan.outcome.added + plan.outcome.updated > 0 else {
                throw CredentialExchangeCoordinatorError.nothingToImport
            }
            let expected = staged.preview.revision
            write = Task { try await manager.commit(plan.accounts, expectedRevision: expected) }
        } catch CredentialExchangeCoordinatorError.nothingToImport {
            throw CredentialExchangeCoordinatorError.nothingToImport
        } catch {
            drop(staged.generation)
            throw error
        }
        committing = (staged.generation, ObjectIdentifier(manager), write)
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

    /// Ends whatever import `manager` has under way (claim, review or running commit). Another manager's claim,
    /// review and commit are left alone, so a closing or stale profile cannot cancel its successor's.
    @discardableResult
    func cancelImport(for manager: CredentialManager) -> CredentialImportCancellation {
        let id = ObjectIdentifier(manager)
        var outcome = CredentialImportCancellation.nothingOwned
        if let committing, committing.manager == id {
            committing.task.cancel()
            self.committing = nil
            outcome = .commitCancellationRequested
        }
        if session?.manager === manager {
            session = nil
            if outcome == .nothingOwned { outcome = .reviewCancelled }
        }
        if claim?.manager == id {
            claim = nil
            if outcome == .nothingOwned { outcome = .reviewCancelled }
        }
        return outcome
    }

    // MARK: Export

    /// Asks the system for a destination and format, then hands it exactly the selected credentials.
    func exportCredentials(
        selection: [CredentialExportSelection],
        expectedRevision: UInt64,
        epoch: UInt64,
        from manager: CredentialManager,
        in anchor: ASPresentationAnchor
    ) async throws -> CredentialExportOutcome {
        guard Self.isNonEmpty(selection) else { throw CredentialExchangeCoordinatorError.emptySelection }
        try Task.checkCancellation()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let exporter = ASCredentialExportManager(presentationAnchor: anchor)
        let options: ASCredentialExportManager.ExportOptions
        do {
            options = try await exporter.requestExport(for: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.isUserCancellation(error) { return .cancelled }
            throw Self.mapNative(error)
        }
        let data = try await prepareExport(
            selection: selection, expectedRevision: expectedRevision,
            format: options.formatVersion, from: manager, epoch: epoch
        )
        // Last point before the secrets leave the vault; everything before it is a clean cancel.
        try Task.checkCancellation()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        return await Self.handOff { try await exporter.exportCredentials(data) }
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
        expectedRevision: UInt64,
        format: ASExportedCredentialData.FormatVersion,
        from manager: CredentialManager,
        epoch: UInt64
    ) async throws -> ASExportedCredentialData {
        guard Self.isNonEmpty(selection) else { throw CredentialExchangeCoordinatorError.emptySelection }
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let snapshot = try await manager.snapshot()
        try Task.checkCancellation()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        guard snapshot.revision == expectedRevision else { throw CredentialVaultError.staleRevision }
        let data = try CredentialExchangeCodec.export(
            snapshot,
            selection: selection.filter { Self.isNonEmpty([$0]) },
            format: format
        )
        guard !data.accounts.isEmpty else { throw CredentialExchangeCoordinatorError.emptySelection }
        return data
    }

    // MARK: System errors

    static func isUserCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        let native = error as NSError
        return native.domain == ASAuthorizationError.errorDomain && native.code == ASAuthorizationError.Code.canceled.rawValue
    }

    /// Keeps the domain and code only: the system's own text can name what was being transferred.
    static func mapNative(_ error: any Error) -> any Error {
        if isUserCancellation(error) { return CancellationError() }
        let native = error as NSError
        return CredentialExchangeCoordinatorError.systemRejected(domain: native.domain, code: native.code)
    }

    // MARK: Private

    private var live: Session? {
        guard let session, session.epoch == session.manager.authorizationEpoch else { return nil }
        return session
    }

    private func release(_ token: UUID) {
        if claim?.token == token { claim = nil }
    }

    private func drop(_ generation: Int) {
        if session?.generation == generation { session = nil }
    }

    /// Drops the session synchronously inside the manager's change notification, so no secret survives a
    /// lock or an unlock into a new epoch. A later session installs its own observation.
    private func watch(_ manager: CredentialManager, generation: Int) {
        withObservationTracking {
            _ = manager.authorizationEpoch
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.drop(generation) }
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
        if hasLogin(account) { result.append(.password(accountID: account.id)) }
        result += account.passkeys.map { .passkey(accountID: account.id, passkeyID: $0.id) }
        if account.totp != nil { result.append(.totp(accountID: account.id)) }
        return result
    }

    private nonisolated static func accountID(_ identity: CredentialIdentity) -> UUID {
        switch identity {
        case let .password(id), let .totp(id): id
        case let .passkey(id, _): id
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
            case .skip: result.append(.keep(incoming: incoming))
            case .replace:
                guard let target = existing[incoming] else { return nil }
                result.append(.replace(incoming: incoming, target: target))
            case .addSeparately: result.append(.add(incoming: incoming, targetAccountID: nil))
            case let .merge(target): result.append(.add(incoming: incoming, targetAccountID: target))
            }
        }
        return result
    }

    private static func plan(
        _ preview: CredentialImportPreview,
        choices: [CredentialIdentity: CredentialImportChoice]
    ) throws -> (accounts: [CredentialAccount], outcome: CredentialImportOutcome) {
        guard let decisions = decisions(preview, choices) else {
            throw CredentialExchangeCoordinatorError.unresolvedConflicts
        }
        let accounts = try CredentialExchangeCodec.apply(preview, decisions: decisions)
        let before = Dictionary(preview.base.accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var added = 0
        var updated = 0
        for account in accounts {
            if let old = before[account.id] {
                if old != account { updated += 1 }
            } else {
                added += 1
            }
        }
        return (accounts, CredentialImportOutcome(added: added, updated: updated))
    }

    private static func review(
        for preview: CredentialImportPreview,
        choices: [CredentialIdentity: CredentialImportChoice]
    ) throws -> CredentialImportReview {
        let titles = Dictionary(
            (preview.base.accounts + preview.candidates).map { ($0.id, CredentialSummary($0).title) },
            uniquingKeysWith: { first, _ in first }
        )
        let existingByIncoming = Dictionary(preview.conflicts.map { ($0.incoming, $0.existing) }, uniquingKeysWith: { first, _ in first })
        func kind(_ identity: CredentialIdentity) -> CredentialImportReview.Record.Kind {
            switch identity {
            case .password: .password
            case .passkey: .passkey
            case .totp: .totp
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
                case .skip: return .skipped
                case .addSeparately: return .newAccount(origins: candidate.origins)
                case let .merge(target): return into(target)
                case .replace: return existing.flatMap { into(accountID($0)) }
                case nil:
                    if existing != nil { return nil }
                    return linked.flatMap(into) ?? .newAccount(origins: candidate.origins)
                }
            }
            let records = identities(in: candidate).map { incoming in
                let existing = existingByIncoming[incoming]
                let choice = choices[incoming]
                if existing != nil, choice == nil { resolved = false }
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
        if resolved { outcome = try plan(preview, choices: choices).outcome }
        return CredentialImportReview(candidates: candidates, revision: preview.revision, outcome: outcome)
    }
}
