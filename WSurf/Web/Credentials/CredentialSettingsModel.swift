// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Observation

// MARK: - Value types

nonisolated struct PasskeySummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let rpID: String
    let userName: String
}

/// Everything a row needs and nothing secret: passwords, TOTP seeds and passkey keys never leave the vault
/// snapshot. A `.concealedString` imported username is withheld until the user reveals it.
nonisolated struct CredentialSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let username: String?
    let usernameIsConcealed: Bool
    let displayName: String?
    let origins: [String]
    let hasPassword: Bool
    /// A stored login record: a password, or a username with or without one. The exchange codec's rule.
    let hasLogin: Bool
    let hasTOTP: Bool
    let passkeys: [PasskeySummary]

    init(_ account: CredentialAccount) {
        id = account.id
        usernameIsConcealed = account.basicAuthenticationMetadata?.username?.fieldType == .concealedString
        username = usernameIsConcealed || account.username.isEmpty ? nil : account.username
        displayName = account.displayName
        origins = account.origins
        hasPassword = account.password != nil
        hasLogin = account.password != nil || account.basicAuthenticationMetadata != nil || !account.username.isEmpty
        hasTOTP = account.totp != nil
        passkeys = account.passkeys.map { PasskeySummary(id: $0.id, rpID: $0.rpID, userName: $0.userName) }
    }

    /// What a row, a removal prompt or an import review calls this credential. An empty imported title counts as none.
    var title: String {
        if let displayName, !displayName.isEmpty {
            return displayName
        }
        return origins.lazy.compactMap { URL(string: $0)?.host }.first ?? username ?? String(localized: "Credential")
    }
}

nonisolated struct RevealedPassword: Equatable, Sendable {
    let accountID: UUID
    let value: String
}

nonisolated struct RevealedUsername: Equatable, Sendable {
    let accountID: UUID
    let value: String
}

/// A removal the user was shown, with the revision and authorization epoch it was shown at. It lives in the
/// epoch-bound session, so a lock or re-unlock discards it, and a confirmation carrying an old value is rejected.
nonisolated struct PendingRemoval: Equatable, Sendable {
    let summary: CredentialSummary
    let revision: UInt64
    let epoch: UInt64
}

nonisolated struct PendingUnlockRemoval: Equatable, Sendable {
    let credentialID: Data
    let epoch: UInt64
}

/// The one editor state. It starts from the stored account and only overwrites what the form exposes, so
/// passkeys, exchange metadata, descriptor ids/labels and nil-versus-empty passwords survive an edit.
nonisolated struct CredentialDraft: Sendable {
    var username: String
    var displayName: String?
    var password: String?
    var websites: String
    var extraOrigins: String
    private(set) var totp: TOTPGenerator?
    private(set) var passkeys: [WebsitePasskey]
    let revision: UInt64
    let usernameIsConcealed: Bool
    private let base: CredentialAccount?
    private let originalWebsites: String
    private let originalExtraOrigins: String

    init(editing account: CredentialAccount?, revision: UInt64) {
        let loginOrigins = Set(account?.loginURLs.compactMap { CredentialAccount.origin(for: $0) } ?? [])
        let websites = account?.loginURLs.map(\.absoluteString).joined(separator: "\n") ?? ""
        let extras = (account?.origins ?? []).filter { !loginOrigins.contains($0) }.joined(separator: "\n")
        base = account
        username = account?.username ?? ""
        displayName = account?.displayName
        password = account?.password
        totp = account?.totp
        passkeys = account?.passkeys ?? []
        usernameIsConcealed = account?.basicAuthenticationMetadata?.username?.fieldType == .concealedString
        self.websites = websites
        extraOrigins = extras
        originalWebsites = websites
        originalExtraOrigins = extras
        self.revision = revision
    }

    var accountID: UUID? {
        base?.id
    }
    var isNew: Bool {
        base == nil
    }

    var passkeySummaries: [PasskeySummary] {
        passkeys.map { PasskeySummary(id: $0.id, rpID: $0.rpID, userName: $0.userName) }
    }

    mutating func removePasskey(_ id: UUID) {
        passkeys.removeAll { $0.id == id }
    }

    mutating func removeTOTP() {
        totp = nil
    }

    /// Leaves the current generator untouched when `input` is not a valid secret or otpauth URI.
    mutating func setUpTOTP(
        _ input: String,
        algorithm: TOTPAlgorithm = .sha1,
        period: UInt16 = 30,
        digits: UInt16 = 6
    ) throws {
        totp = try TOTP.parse(
            input.trimmingCharacters(in: .whitespacesAndNewlines),
            algorithm: algorithm,
            period: period,
            digits: digits
        )
    }

    func account() throws -> CredentialAccount {
        var result = base ?? CredentialAccount(
            id: UUID(), username: "", displayName: nil, origins: [], loginURLs: [],
            password: nil, passkeys: [], totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
        if base == nil || websites != originalWebsites || extraOrigins != originalExtraOrigins {
            (result.origins, result.loginURLs) = try Self.parseSites(websites: websites, extraOrigins: extraOrigins)
        }

        let hadUsername = !(base?.username.isEmpty ?? true)
        let hadPassword = base?.password != nil
        if var metadata = base?.basicAuthenticationMetadata {
            if username.isEmpty, hadUsername {
                metadata.username = nil
            } else if !username.isEmpty, !hadUsername, metadata.username == nil {
                metadata.username = CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .string)
            }
            if password == nil, hadPassword {
                metadata.password = nil
            } else if password != nil, !hadPassword, metadata.password == nil {
                metadata.password = CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .concealedString)
            }
            result.basicAuthenticationMetadata = metadata
        }

        result.username = username
        result.displayName = displayName
        result.password = password
        result.passkeys = passkeys
        result.totp = totp
        try result.validate()
        return result
    }

    private static func parseSites(websites: String, extraOrigins: String) throws -> (origins: [String], loginURLs: [URL]) {
        var origins: [String] = []
        var loginURLs: [URL] = []
        for line in lines(websites) {
            guard let url = URL(string: line) else { throw CredentialVaultError.invalidData }
            let sanitized = try CredentialAccount.sanitizedLoginURL(url)
            guard let origin = CredentialAccount.origin(for: sanitized) else { throw CredentialVaultError.invalidData }
            if !loginURLs.contains(sanitized) {
                loginURLs.append(sanitized)
            }
            if !origins.contains(origin) {
                origins.append(origin)
            }
        }
        for line in lines(extraOrigins) {
            guard let url = URL(string: line), let origin = CredentialAccount.origin(for: url) else {
                throw CredentialVaultError.invalidData
            }
            if !origins.contains(origin) {
                origins.append(origin)
            }
        }
        return (origins, loginURLs)
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Model

/// Settings state for one profile's credential vault. Every secret it holds lives in `session`, which is tied
/// to one manager authorization epoch: the getters refuse a session from another epoch, and an observation of
/// `authorizationEpoch` drops the session itself the moment the manager locks or re-unlocks.
@MainActor
@Observable
final class CredentialSettingsModel {
    private struct Session {
        let epoch: UInt64
        var revision: UInt64
        var summaries: [CredentialSummary]
        var revealedPassword: RevealedPassword?
        var revealedUsername: RevealedUsername?
        var shownTOTP: (accountID: UUID, generator: TOTPGenerator)?
        var draft: CredentialDraft?
        var pendingRemoval: PendingRemoval?
        var pendingUnlockRemoval: PendingUnlockRemoval?

        init(epoch: UInt64, snapshot: VaultSnapshot) {
            self.epoch = epoch
            revision = snapshot.revision
            summaries = snapshot.accounts.map(CredentialSummary.init)
        }

        mutating func refresh(_ snapshot: VaultSnapshot) {
            if snapshot.revision != revision {
                revealedPassword = nil
                revealedUsername = nil
                shownTOTP = nil
            }
            revision = snapshot.revision
            summaries = snapshot.accounts.map(CredentialSummary.init)
        }
    }

    let profile: Profile
    private(set) var isBusy = false
    /// `nil` until discovered; stays `nil` (with `error` set) when the vault exists but can't be read.
    private(set) var vaultExists: Bool?
    var error: String?

    @ObservationIgnored private let manager: CredentialManager?
    @ObservationIgnored private let pasteboard: NSPasteboard
    private var session: Session?
    @ObservationIgnored private let exchange: CredentialExchangeCoordinator
    /// Identifies this model to the exchange coordinator. One profile has one shared manager but every settings page
    /// builds its own model, so the import this model began is the only one it may see, decide, commit or cancel.
    @ObservationIgnored let owner = UUID()
    private(set) var lastImport: CredentialImportOutcome?
    /// What the last export can truthfully say; see `CredentialExportOutcome`. `nil` before any export or after the
    /// user dismisses it. It is kept apart from the authorization session because it holds nothing secret and can
    /// arrive after a lock.
    private(set) var lastExport: CredentialExportOutcome?

    /// `manager` is a seam for tests that need their own clock; production always uses the profile's shared one.
    init(
        profile: Profile,
        pasteboard: NSPasteboard = .general,
        exchange: CredentialExchangeCoordinator = .shared,
        manager: CredentialManager? = nil
    ) {
        self.profile = profile
        self.exchange = exchange
        self.pasteboard = pasteboard
        if profile.isPrivate {
            self.manager = nil
        } else {
            self.manager = manager ?? (try? CredentialManager.forProfile(profile))
        }
        watchAuthorization()
    }

    // MARK: Observable state

    var isAvailable: Bool {
        manager != nil
    }
    var isUnlocked: Bool {
        manager?.isUnlocked ?? false
    }
    var isLoaded: Bool {
        live != nil
    }
    var revision: UInt64 {
        live?.revision ?? 0
    }
    var summaries: [CredentialSummary] {
        live?.summaries ?? []
    }
    var revealedPassword: RevealedPassword? {
        live?.revealedPassword
    }
    var revealedUsername: RevealedUsername? {
        live?.revealedUsername
    }
    var shownTOTPAccountID: UUID? {
        live?.shownTOTP?.accountID
    }
    var unlockCredentials: [VaultUnlock] {
        isUnlocked ? manager?.unlockCredentials ?? [] : []
    }
    /// The existence of a notice is shown while locked; its website and account are shown only after unlocking.
    var hasUnconfirmedPasskeys: Bool {
        manager?.unconfirmedPasskeys.isEmpty == false
    }
    var unconfirmedPasskeys: [UnconfirmedPasskey] {
        isUnlocked ? manager?.unconfirmedPasskeys ?? [] : []
    }
    func dismissUnconfirmedPasskeys() {
        manager?.dismissUnconfirmedPasskeys()
    }
    var pendingRemoval: PendingRemoval? {
        live?.pendingRemoval
    }
    var pendingUnlockRemoval: PendingUnlockRemoval? {
        live?.pendingUnlockRemoval
    }

    var draft: CredentialDraft? {
        get { live?.draft }
        set { if live != nil { session?.draft = newValue } }
    }

    /// Pure: the code for the shown account at `now`, from the generator cached for this authorization.
    func totpCode(now: TimeInterval) -> TOTPCode? {
        guard let generator = live?.shownTOTP?.generator else { return nil }
        return try? TOTP.code(generator, at: now)
    }

    func hideSecrets() {
        guard live != nil else { return }
        session?.revealedPassword = nil
        session?.revealedUsername = nil
        session?.shownTOTP = nil
    }

    func cancelEditing() {
        if live != nil {
            session?.draft = nil
        }
    }

    /// Forgets everything shown without touching the manager's authorization.
    func close() {
        session = nil
    }

    func lock() {
        session = nil
        manager?.lock(reason: .manual)
    }

    // MARK: Loading and editing

    func load() async {
        guard let manager else { return }
        guard let epoch = manager.authorizationEpoch else {
            session = nil
            await discoverVault(manager)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let snapshot = try await manager.snapshot()
            // Task cancellation is per UI task; the epoch check is the separate, global authorization check.
            guard !Task.isCancelled, manager.authorizationEpoch == epoch else { return }
            session = Session(epoch: epoch, snapshot: snapshot)
            error = nil
            vaultExists = true
        } catch {
            guard !Task.isCancelled, manager.authorizationEpoch == epoch else { return }
            session = nil
            self.error = Self.message(for: error)
        }
    }

    /// An unreadable vault is reported, never treated as an absent one: Create is offered only on a definite miss.
    private func discoverVault(_ manager: CredentialManager) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let exists = try await manager.vaultExists()
            guard !Task.isCancelled else { return }
            vaultExists = exists
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            vaultExists = nil
            self.error = Self.message(for: error)
        }
    }

    func attempt(_ work: () async throws -> Void) async {
        error = nil
        do { try await work() } catch { self.error = Self.message(for: error) }
    }

    var authorizationEpoch: UInt64? {
        manager?.authorizationEpoch
    }

    /// `nil` starts a new credential.
    func beginEditing(accountID: UUID?) async throws {
        let (epoch, snapshot) = try await authorizedSnapshot()
        var existing: CredentialAccount?
        if let accountID {
            guard let account = snapshot.accounts.first(where: { $0.id == accountID }) else {
                throw CredentialVaultError.invalidData
            }
            existing = account
        }
        let draft = CredentialDraft(editing: existing, revision: snapshot.revision)
        try update(epoch) {
            $0.refresh(snapshot)
            $0.draft = draft
        }
    }

    /// Builds and stores the draft's account. The draft stays open when anything fails.
    func commitDraft() async throws -> VaultCommitReceipt {
        guard let session = live, let draft = session.draft else { throw CredentialVaultError.invalidData }
        let receipt = try await save(draft.account(), expectedRevision: draft.revision)
        try? update(session.epoch) { $0.draft = nil }
        return receipt
    }

    /// Inserts or replaces the account with the same id; every other account is written back untouched.
    func save(_ account: CredentialAccount, expectedRevision: UInt64) async throws -> VaultCommitReceipt {
        try account.validate()
        let (epoch, snapshot) = try await authorizedSnapshot()
        guard snapshot.revision == expectedRevision else { throw CredentialVaultError.staleRevision }
        var accounts = snapshot.accounts
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        return try await write(accounts, expectedRevision: expectedRevision, epoch: epoch)
    }

    func remove(accountID: UUID, expectedRevision: UInt64, epoch bound: UInt64? = nil) async throws -> VaultCommitReceipt {
        let (epoch, snapshot) = try await authorizedSnapshot(epoch: bound)
        guard snapshot.revision == expectedRevision else { throw CredentialVaultError.staleRevision }
        guard snapshot.accounts.contains(where: { $0.id == accountID }) else { throw CredentialVaultError.invalidData }
        return try await write(snapshot.accounts.filter { $0.id != accountID }, expectedRevision: expectedRevision, epoch: epoch)
    }

    // MARK: Reveal and copy

    func revealPassword(accountID: UUID) async throws {
        let (epoch, snapshot) = try await authorizedSnapshot()
        guard let password = snapshot.accounts.first(where: { $0.id == accountID })?.password else {
            throw CredentialVaultError.invalidData
        }
        try update(epoch) { $0.revealedPassword = RevealedPassword(accountID: accountID, value: password) }
    }

    func revealUsername(accountID: UUID) async throws {
        let (epoch, snapshot) = try await authorizedSnapshot()
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }), !account.username.isEmpty else {
            throw CredentialVaultError.invalidData
        }
        try update(epoch) { $0.revealedUsername = RevealedUsername(accountID: accountID, value: account.username) }
    }

    func showTOTP(accountID: UUID) async throws {
        let (epoch, snapshot) = try await authorizedSnapshot()
        guard let generator = snapshot.accounts.first(where: { $0.id == accountID })?.totp else {
            throw CredentialVaultError.invalidData
        }
        try update(epoch) { $0.shownTOTP = (accountID, generator) }
    }

    func copyPassword(accountID: UUID) async throws {
        let (epoch, snapshot) = try await authorizedSnapshot()
        guard let password = snapshot.accounts.first(where: { $0.id == accountID })?.password else {
            throw CredentialVaultError.invalidData
        }
        try deliver(epoch: epoch) { password }
    }

    /// `now` is read after the last suspension so a step boundary crossed while waiting yields the new code.
    func copyTOTP(
        accountID: UUID,
        now: @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) async throws {
        let (epoch, snapshot) = try await authorizedSnapshot()
        guard let generator = snapshot.accounts.first(where: { $0.id == accountID })?.totp else {
            throw CredentialVaultError.invalidData
        }
        try deliver(epoch: epoch) { try TOTP.code(generator, at: now()).value }
    }

    // MARK: Native unlock management

    func createVault(in anchor: ASPresentationAnchor) async {
        if await perform({ try await $0.create(in: anchor) }) {
            await load()
        }
    }

    func unlock(in anchor: ASPresentationAnchor) async {
        if await perform({ try await $0.unlock(in: anchor) }) {
            await load()
        }
    }

    func addUnlock(in anchor: ASPresentationAnchor) async {
        _ = await perform { _ = try await $0.addUnlock(in: anchor) }
    }

    /// Presents a removal for confirmation, capturing the revision and authorization it is shown at.
    func requestRemoval(accountID: UUID) {
        guard let live, let summary = live.summaries.first(where: { $0.id == accountID }) else { return }
        session?.pendingRemoval = PendingRemoval(summary: summary, revision: live.revision, epoch: live.epoch)
    }

    func cancelRemoval() {
        if live != nil {
            session?.pendingRemoval = nil
        }
    }

    /// Writes against the revision and epoch captured when the removal was presented, never confirmation time.
    func confirmRemoval(_ pending: PendingRemoval) async throws -> VaultCommitReceipt {
        if live?.pendingRemoval == pending {
            session?.pendingRemoval = nil
        }
        return try await remove(accountID: pending.summary.id, expectedRevision: pending.revision, epoch: pending.epoch)
    }

    func requestUnlockRemoval(credentialID: Data) {
        guard let live, manager?.unlockCredentials.contains(where: { $0.credentialID == credentialID }) == true else { return }
        session?.pendingUnlockRemoval = PendingUnlockRemoval(credentialID: credentialID, epoch: live.epoch)
    }

    func cancelUnlockRemoval() {
        if live != nil {
            session?.pendingUnlockRemoval = nil
        }
    }

    func confirmUnlockRemoval(_ pending: PendingUnlockRemoval, in anchor: ASPresentationAnchor) async {
        if live?.pendingUnlockRemoval == pending {
            session?.pendingUnlockRemoval = nil
        }
        _ = await perform(epoch: pending.epoch) { _ = try await $0.removeUnlock(credentialID: pending.credentialID, in: anchor) }
    }

    // MARK: Credential exchange

    /// The system's import token, queued until the user starts the import from this profile's settings.
    var pendingImportToken: UUID? {
        isAvailable ? exchange.pendingToken : nil
    }

    var importReview: CredentialImportReview? {
        manager.flatMap { exchange.importReview(for: $0, owner: owner) }
    }

    func beginImport() async {
        guard let token = exchange.pendingToken else { return }
        lastImport = nil
        _ = await perform(describe: importMessage(for:)) { try await self.exchange.beginImport(token: token, into: $0, owner: self.owner) }
    }

    func chooseImport(_ choice: CredentialImportChoice, for incoming: CredentialIdentity) {
        do { try exchange.choose(choice, for: incoming, owner: owner) } catch { self.error = importMessage(for: error) }
    }

    /// Stored accounts the credential can be merged into, each with every website it would then work on.
    func mergeTargets(for incoming: CredentialIdentity) -> [CredentialImportReview.Target] {
        exchange.mergeTargets(for: incoming, owner: owner)
    }

    func commitImport() async {
        let expected = importReview?.outcome
        let committed = await perform(describe: importMessage(for:)) { _ = try await self.exchange.commitImport(into: $0, owner: self.owner) }
        guard committed else { return }
        lastImport = expected
        await load()
    }

    /// Ends the review. The system's token for it was used up when the import began, so the user is told that
    /// importing these credentials again means sending them again from the other app. Only a review that had no
    /// commit running can say nothing was saved: cancelling a commit asks the vault not to write, and a write that
    /// already started may still land.
    @discardableResult
    func cancelImport() -> CredentialImportCancellation {
        guard let manager else { return .nothingOwned }
        let outcome = exchange.cancelImport(for: manager, owner: owner)
        if outcome == .reviewCancelled {
            error = String(localized: "The import was cancelled and nothing was saved. To import these credentials, send them again from the other app.")
        }
        return outcome
    }

    /// Declines the credentials another app is waiting to send, whether or not the vault is unlocked. `token` is the
    /// one the caller showed: a token that arrived since is not the one the user was looking at and is left queued.
    func discardPendingImport(token: UUID) {
        exchange.discardPendingImport(token: token)
    }

    func dismissImportResult() {
        lastImport = nil
    }

    func dismissExportResult() {
        lastExport = nil
    }

    /// `revision` and `epoch` are the ones the selection was made at; a lock, re-unlock or later write rejects it.
    /// A cancel before any data was passed is `.cancelled` and leaves no status; every other result is recorded.
    func exportCredentials(
        selection: [CredentialExportSelection],
        expectedRevision: UInt64,
        epoch: UInt64,
        in anchor: ASPresentationAnchor
    ) async -> CredentialExportOutcome? {
        lastExport = nil
        var outcome: CredentialExportOutcome?
        _ = await perform(epoch: epoch) {
            outcome = try await self.exchange.exportCredentials(
                selection: selection, expectedRevision: expectedRevision, epoch: epoch, from: $0, in: anchor
            )
        }
        if let outcome, outcome != .cancelled {
            lastExport = outcome
        }
        return outcome
    }

    // MARK: Private

    private var live: Session? {
        guard let session, session.epoch == manager?.authorizationEpoch else { return nil }
        return session
    }

    /// Drops the session synchronously inside the manager's change notification, so no secret survives a lock
    /// or an unlock into a new epoch; the observation is re-armed once the change has landed.
    private func watchAuthorization() {
        guard let manager else { return }
        if let session, session.epoch != manager.authorizationEpoch {
            self.session = nil
        }
        withObservationTracking {
            _ = manager.authorizationEpoch
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.session = nil }
            Task { @MainActor [weak self] in self?.watchAuthorization() }
        }
    }

    private func authorizedSnapshot(epoch bound: UInt64? = nil) async throws -> (epoch: UInt64, snapshot: VaultSnapshot) {
        guard let manager, let epoch = manager.authorizationEpoch, bound == nil || bound == epoch else {
            throw CredentialVaultError.unauthorized
        }
        let snapshot = try await manager.snapshot()
        try Task.checkCancellation()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        return (epoch, snapshot)
    }

    private func update(_ epoch: UInt64, _ change: (inout Session) -> Void) throws {
        guard session?.epoch == epoch, manager?.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        change(&session!)
    }

    /// Nothing throws once the vault has committed: the receipt reflects what is on disk, and a lock that
    /// landed meanwhile has already dropped the session.
    private func write(_ accounts: [CredentialAccount], expectedRevision: UInt64, epoch: UInt64) async throws -> VaultCommitReceipt {
        guard let manager, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        // Last point before the durable write: a cancelled task or a changed authorization never commits.
        try Task.checkCancellation()
        let receipt = try await manager.commit(accounts, expectedRevision: expectedRevision, authorizedEpoch: epoch)
        try? update(epoch) {
            $0.revision = receipt.revision
            $0.summaries = accounts.map(CredentialSummary.init)
            $0.revealedPassword = nil
            $0.revealedUsername = nil
            $0.shownTOTP = nil
        }
        return receipt
    }

    /// The one clipboard exit. `produce` runs first, so whatever it costs (a code calculation, a clock read)
    /// is over before the last authorization and cancellation check; a failure leaves the pasteboard untouched.
    private func deliver(epoch: UInt64, _ produce: () throws -> String) throws {
        let value = try produce()
        try Task.checkCancellation()
        guard manager?.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        pasteboard.declareTypes([.string, Self.concealedType], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
    }

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private func perform(
        epoch bound: UInt64? = nil,
        describe: (any Error) -> String? = { CredentialSettingsModel.message(for: $0) },
        _ operation: (CredentialManager) async throws -> Void
    ) async -> Bool {
        guard let manager else { return false }
        if let bound, manager.authorizationEpoch != bound {
            error = Self.message(for: CredentialVaultError.unauthorized)
            return false
        }
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await operation(manager)
            return true
        } catch {
            if case CredentialVaultError.missingVault = error {
                vaultExists = false
            }
            self.error = describe(error)
            return false
        }
    }

    /// The system's token is used up once an import is claimed, and a review that ends takes its data with it. So
    /// a failure that leaves neither a queued token nor an open review can only be redone from the other app.
    private func importMessage(for error: any Error) -> String? {
        let staged = manager.map { exchange.hasStagedImport(for: $0, owner: owner) } ?? false
        return Self.importMessage(for: error, tokenSpent: exchange.pendingToken == nil && !staged)
    }

    static func importMessage(for error: any Error, tokenSpent: Bool) -> String? {
        guard tokenSpent else { return message(for: error) }
        let reason: String
        switch error {
        case is CancellationError:
            reason = String(localized: "it was cancelled")
        case CredentialVaultError.staleRevision:
            reason = String(localized: "your credentials changed while it was open")
        case CredentialVaultError.unauthorized, CredentialVaultError.expired:
            reason = String(localized: "your credentials were locked")
        case let error as CredentialExchangeError:
            reason = String(localized: "the credentials couldn’t be read (\(error.description))")
        case CredentialExchangeCoordinatorError.systemRejected:
            reason = String(localized: "the system couldn’t deliver the credentials")
        case CredentialExchangeCoordinatorError.tokenMismatch, CredentialExchangeCoordinatorError.wrongTarget,
             CredentialExchangeCoordinatorError.noStagedImport:
            reason = String(localized: "it was no longer open")
        default:
            reason = String(localized: "something went wrong")
        }
        return String(localized: "The import ended because \(reason), and nothing was saved. To import these credentials, send them again from the other app.")
    }

    static func message(for error: any Error) -> String? {
        switch error {
        case CredentialVaultError.staleRevision:
            return String(localized: "Your credentials changed elsewhere. Reload and try again.")
        case CredentialVaultError.unauthorized, CredentialVaultError.expired:
            return String(localized: "Credentials are locked.")
        case CredentialVaultError.missingVault:
            return String(localized: "No credential vault exists for this profile yet. Create one to continue.")
        case CredentialVaultError.alreadyExists:
            return String(localized: "A credential vault already exists for this profile. Unlock it instead.")
        case CredentialVaultError.noUnlocks:
            return String(localized: "The vault needs at least one unlock passkey.")
        case CredentialVaultError.invalidData:
            return String(localized: "Check the details and try again.")
        case CredentialVaultError.corruptVault:
            return String(localized: "The credential vault couldn’t be read. It may be damaged.")
        case CredentialVaultError.authenticationFailed, CredentialVaultError.wrongProfile:
            return String(localized: "That passkey can’t unlock this vault.")
        case CredentialManagerError.externalPasskeyRemains:
            return String(localized: "The passkey was created but setup didn’t finish. It still exists in your passkey provider; remove it there if you don’t want it.")
        case CredentialManagerError.registrationOutcomeUnknown:
            return String(localized: "Passkey registration was cancelled, but the provider may have created it. Check your passkey provider before trying again.")
        case PasskeyUnlockError.appCancelled:
            return nil
        case PasskeyUnlockError.failed(let domain, let code)
            where domain == ASAuthorizationError.errorDomain && code == ASAuthorizationError.Code.canceled.rawValue:
            return nil
        case PasskeyUnlockError.unsupportedPRF:
            return String(localized: "That passkey can’t protect the vault. Choose a passkey provider that supports the PRF extension.")
        case is CancellationError:
            return nil
        default:
            return exchangeMessage(for: error)
        }
    }

    private static func exchangeMessage(for error: any Error) -> String? {
        switch error {
        case let error as CredentialExchangeError:
            return String(localized: "The file couldn’t be imported (\(error.description)). Nothing was changed.")
        case CredentialExchangeCoordinatorError.tokenMismatch:
            return String(localized: "That import is no longer waiting. Start the transfer again from the other app.")
        case CredentialExchangeCoordinatorError.wrongTarget, CredentialExchangeCoordinatorError.noStagedImport:
            return String(localized: "The import is no longer open. To import these credentials, send them again from the other app.")
        case CredentialExchangeCoordinatorError.busy:
            return String(localized: "Another import is already in progress.")
        case CredentialExchangeCoordinatorError.unresolvedConflicts, CredentialExchangeCoordinatorError.unknownConflict:
            return String(localized: "Choose what to do with every conflict first.")
        case CredentialExchangeCoordinatorError.invalidChoice:
            return String(localized: "That choice isn’t available for this credential.")
        case CredentialExchangeCoordinatorError.nothingToImport:
            return String(localized: "There is nothing new to import.")
        case CredentialExchangeCoordinatorError.emptySelection:
            return String(localized: "Select at least one credential to export.")
        case CredentialExchangeCoordinatorError.systemRejected:
            return String(localized: "The system couldn’t complete the transfer.")
        default:
            return String(localized: "Couldn’t access credentials.")
        }
    }
}
