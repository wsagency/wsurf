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
    let createdAt: Date?
    let source: WebsitePasskeySource?
    let lastSignedAt: Date?

    init(_ passkey: WebsitePasskey) {
        id = passkey.id
        rpID = passkey.rpID
        userName = passkey.userName
        createdAt = passkey.createdAt
        source = passkey.source
        lastSignedAt = passkey.lastSignedAt
    }
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
        passkeys = account.passkeys.map { PasskeySummary($0) }
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
    /// How many unlock passkeys the vault keeps once this one is gone; the removal is confirmed with one of them.
    let remaining: Int

    /// What the confirmation says, from the same value that decides what it will do.
    var text: String {
        String(localized: """
            You’ll confirm with one of the \(remaining) remaining unlock passkeys. The passkey itself stays in your passkey \
            provider. Removing it does not change the vault’s encryption key. Someone with that passkey and an older vault \
            file can still decrypt later copies of this vault they obtain.
            """)
    }
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
        passkeys.map { PasskeySummary($0) }
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

    /// Whether saving would write the stored account back exactly as it is.
    var changesNothing: Bool {
        guard let base, let built = try? account() else { return false }
        return built == base
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

// MARK: - Vault, Trash and earlier-version state

/// A restore the vault refused, shown until it is dismissed or tried again. It offers only the same Trash copy again or
/// nothing: never another id, and never over what the vault already holds. It writes nothing.
nonisolated struct RestoreBlocked: Equatable, Sendable {
    enum Action: Hashable, Sendable { case retrySameCopy, dismiss }

    let entryID: UUID
    let block: UndeleteBlock

    /// In the order the page offers them.
    var actions: [Action] {
        [.retrySameCopy, .dismiss]
    }
}

/// A permanent delete the user was shown. It lives in the authorization session, so a lock, a re-unlock or a change of vault
/// drops it: a confirmation shown for one vault can never delete from another. `emptyAll` purges EVERY Trash entry at the
/// moment of the write and ignores `entryIDs`, so `count` is only what the vault held when the confirmation was shown.
nonisolated struct PendingPurge: Equatable, Sendable {
    struct Warning: Equatable, Sendable {
        /// A purge removes rows from the vault file only; it cannot reach copies saved elsewhere.
        let logicalOnly: Bool
        /// The copy made before this vault was upgraded, which still holds what is being purged.
        let preMigrationBackup: URL?
    }

    let entryIDs: [UUID]
    let emptyAll: Bool
    let count: Int
    let vaultID: UUID
    let epoch: UInt64
    let warning: Warning
}

nonisolated extension RecordSubject {
    /// Earlier versions restore only these. A passkey is never rolled back to an older key.
    var restoresFromEarlierVersions: Bool {
        self == .password || self == .totp || self == .metadata
    }
}

nonisolated extension VaultListing {
    /// A vault's name is sealed until it unlocks, so a locked one is told apart by its ordinal (1-based, never reused).
    var displayName: String {
        name ?? String(localized: "Vault \(ordinal)")
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
        /// Verified counts of the vault and its Trash, as of the last Trash load.
        var counts: (live: HistoryCounts, trash: HistoryCounts)?
        var trash: [TrashItem] = []
        /// The cursor of the next Trash page; only meaningful inside this session.
        var trashNext: Int?
        var restoreBlocked: RestoreBlocked?
        var pendingPurge: PendingPurge?
        var revisions: [RevisionItem] = []
        var revisionNext: Int?
        var versionsAccountID: UUID?

        init(epoch: UInt64, snapshot: StoreSnapshot) {
            self.epoch = epoch
            revision = snapshot.revision
            summaries = snapshot.accounts.map(CredentialSummary.init)
        }

        mutating func refresh(_ snapshot: StoreSnapshot) {
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
    /// Set when unlocking was refused because the vault is a v1 file (or an interrupted migration) and the user has not
    /// yet agreed to migrate it; no passkey prompt happened. Unlock again with `confirmMigration: true` after consent.
    private(set) var needsMigrationConfirmation = false
    /// The profile's active vaults as the last discovery listed them (names stay `nil` until a vault is unlocked).
    private(set) var vaults: [VaultListing] = []
    /// The open state the last discovery read; `nil` before it and for a test-injected manager. Creating a vault is offered
    /// only from a confirmed state, never inferred from an empty list.
    private(set) var openState: StoreOpenState?
    /// Set when the store refused to open, or a later read found it closed. The page then shows only the exact paths and a re-check.
    private(set) var failClosed: StoreFailClosed?
    /// Every enrolled unlock passkey of every listed vault (plaintext discovery, no secret): the pair is the identity.
    private(set) var existingPasskeys: [(vault: VaultListing, unlock: VaultUnlock)] = []
    private var storedDefaultVaultID: UUID?
    /// True while an unlock is verifying the vault (it took longer than the store's threshold); only meaningful during `unlock`.
    private(set) var isVerifying = false
    @ObservationIgnored private var unlockInFlight = false

    /// The one vault this page operates on; `nil` until discovery selects one, and while the profile has no vault.
    private var manager: CredentialManager?
    /// `nil` for private browsing and for a test-injected manager (which owns its own store).
    @ObservationIgnored private let store: ProfileVaultStore?
    /// Test seam: managers made here use it instead of the system passkey UI, which the shared registry's managers always use.
    @ObservationIgnored private let native: VaultNativeUnlock?
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

    /// `manager` and `native` are seams for tests that need their own clock or passkeys; production selects the profile's
    /// default vault (else the lowest-ordinal one) through the shared registry once `load()` has listed the vaults.
    init(
        profile: Profile,
        pasteboard: NSPasteboard = .general,
        exchange: CredentialExchangeCoordinator = .shared,
        manager: CredentialManager? = nil,
        native: VaultNativeUnlock? = nil
    ) {
        self.profile = profile
        self.exchange = exchange
        self.pasteboard = pasteboard
        self.native = native
        if profile.isPrivate {
            self.manager = nil
            store = nil
        } else {
            self.manager = manager
            store = manager == nil ? try? CredentialManager.store(for: profile) : nil
        }
        watchAuthorization()
    }

    // MARK: Observable state

    var isAvailable: Bool {
        manager != nil || store != nil
    }
    var selectedVaultID: UUID? {
        manager?.vaultID
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

    // MARK: Vaults

    /// The selected manager's own list, never a copy: a non-fatal note that never changes whether the vault opened.
    var scratchCleanupWarnings: [URL] {
        manager?.scratchCleanupWarnings ?? []
    }

    /// The vault autofill and saving use when they don't need to ask: the stored choice while it is still listed, else the
    /// lowest-numbered one.
    var defaultVaultID: UUID? {
        if let storedDefaultVaultID, vaults.contains(where: { $0.vaultID == storedDefaultVaultID }) {
            return storedDefaultVaultID
        }
        return vaults.min { $0.ordinal < $1.ordinal }?.vaultID
    }

    private var isProvisional: Bool {
        if case .provisional? = openState {
            true
        } else {
            false
        }
    }

    /// A new passkey needs a first run, or room for another vault and an already unlocked one to approve it.
    var canCreateWithNewPasskey: Bool {
        switch openState {
        case .firstRun?:
            return true
        case .provisional?:
            return vaults.count < StoreFormat.activeVaultLimit && unlockedAuthorizer(in: vaults) != nil
        default:
            return false
        }
    }

    var canCreateVault: Bool {
        switch openState {
        case .firstRun?:
            return true
        case .provisional?:
            return canCreateWithNewPasskey || (vaults.count < StoreFormat.activeVaultLimit && !existingPasskeys.isEmpty)
        default:
            return false
        }
    }

    // MARK: Trash and earlier versions (state)

    var trashItems: [TrashItem] {
        live?.trash ?? []
    }
    /// The vault's verified Trash count, not the rows on screen; `nil` until the Trash has been loaded.
    var trashTotal: Int? {
        live?.counts?.trash.trashEntry
    }
    var trashHasMore: Bool {
        live?.trashNext != nil
    }
    var restoreBlocked: RestoreBlocked? {
        live?.restoreBlocked
    }
    var pendingPurge: PendingPurge? {
        live?.pendingPurge
    }
    var revisionItems: [RevisionItem] {
        live?.revisions ?? []
    }
    var revisionHasMore: Bool {
        live?.revisionNext != nil
    }
    var versionsAccountID: UUID? {
        live?.versionsAccountID
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
        guard isAvailable else { return }
        if manager?.isUnlocked != true {
            session = nil
            await discoverVault()
        }
        guard let manager, let epoch = manager.authorizationEpoch else { return }
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
            self.error = noteClosed(error) ? nil : Self.message(for: error)
        }
    }

    /// Switches the page to exactly the vault asked for and loads it. A vault the last listing doesn't hold is refused, never
    /// replaced by another, and a locked vault stays locked.
    func select(vaultID: UUID) async {
        guard store != nil, vaultID != manager?.vaultID else { return }
        guard vaults.contains(where: { $0.vaultID == vaultID }) else {
            error = Self.message(for: CredentialStoreError.noSuchVault)
            return
        }
        do {
            bind(try vaultManager(vaultID))
        } catch {
            self.error = Self.message(for: error)
            return
        }
        await load()
    }

    /// Reads the store again from the start. It writes nothing: a closed store is only looked at, never repaired or reset.
    func retry() async {
        session = nil
        await discoverVault()
        if failClosed == nil {
            await load()
        }
    }

    /// The open state decides what the page offers: a closed store shows only its paths, a first run is the only place the
    /// first vault is created, and a v1 vault or interrupted migration is listed (never "missing") and asks for consent
    /// before it is upgraded. An unreadable store is reported, never treated as an absent one.
    private func discoverVault() async {
        isBusy = true
        defer { isBusy = false }
        do {
            var migrates = false
            if let store {
                let state = await store.openState()
                guard !Task.isCancelled else { return }
                openState = state
                switch state {
                case .failClosed(let closed):
                    enterFailClosed(closed)
                    return
                case .firstRun:
                    failClosed = nil
                    vaults = []
                    existingPasskeys = []
                    bind(nil)
                    vaultExists = false
                    error = nil
                    return
                case .legacy, .resumeMigration:
                    migrates = true
                case .provisional:
                    break
                }
                let listing = try await store.listing()
                let preferred = await store.defaultVaultID()
                var enrolled: [(vault: VaultListing, unlock: VaultUnlock)] = []
                if case .provisional = state {
                    enrolled = try await Self.enrolledPasskeys(of: listing, in: store)
                }
                guard !Task.isCancelled else { return }
                failClosed = nil
                vaults = listing
                existingPasskeys = enrolled
                storedDefaultVaultID = preferred
                // Past a first run a store holds at least one vault: an empty list is a read the page can't trust.
                guard let lowest = listing.min(by: { $0.ordinal < $1.ordinal }) else { throw CredentialStoreError.stateChanged }
                let candidates = [manager?.vaultID, preferred].compactMap { $0 }
                let listed = Set(listing.map(\.vaultID))
                let id = candidates.first { listed.contains($0) } ?? lowest.vaultID
                if id != manager?.vaultID {
                    bind(try vaultManager(id))
                }
                needsMigrationConfirmation = migrates
            }
            guard let manager else { return }
            try await manager.discoverUnlocks()
            guard !Task.isCancelled else { return }
            vaultExists = true
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            vaultExists = nil
            self.error = noteClosed(error) ? nil : Self.message(for: error)
        }
    }

    private static func enrolledPasskeys(
        of listing: [VaultListing], in store: ProfileVaultStore
    ) async throws -> [(vault: VaultListing, unlock: VaultUnlock)] {
        var found: [(vault: VaultListing, unlock: VaultUnlock)] = []
        for vault in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            for unlock in try await store.discovery(vaultID: vault.vaultID).unlocks {
                found.append((vault, unlock))
            }
        }
        return found
    }

    /// A store that refused to open replaces the page, wherever the refusal surfaced; nothing it held stays on screen.
    @discardableResult
    private func noteClosed(_ error: any Error) -> Bool {
        guard case CredentialStoreError.failClosed(let closed) = error else { return false }
        enterFailClosed(closed)
        return true
    }

    private func enterFailClosed(_ closed: StoreFailClosed) {
        failClosed = closed
        vaults = []
        existingPasskeys = []
        bind(nil)
        vaultExists = nil
        error = nil
    }

    private func bind(_ next: CredentialManager?) {
        manager = next
        session = nil
        needsMigrationConfirmation = false
        watchAuthorization()
    }

    private func vaultManager(_ vaultID: UUID) throws -> CredentialManager {
        guard let native, let store else { return try CredentialManager.forVault(profile, vaultID: vaultID) }
        return CredentialManager(profile: profile, vaultID: vaultID, store: store, native: native)
    }

    func attempt(_ work: () async throws -> Void) async {
        error = nil
        do { try await work() } catch { self.error = noteClosed(error) ? nil : Self.message(for: error) }
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
        // Saving what is already stored is no save: nothing is written, no revision is made, and a vault that changed
        // meanwhile has nothing to conflict with. The receipt names the revision the draft was made against.
        if draft.changesNothing {
            try? update(session.epoch) { $0.draft = nil }
            return VaultCommitReceipt(revision: draft.revision)
        }
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

    /// Creates a vault and leaves it LOCKED: nothing here unlocks it, so its first unlock is the user's own, with the vault's own
    /// passkey. Everything the choice depends on is read from the store again first, and nothing replaces what the user chose:
    /// an existing passkey that is no longer enrolled in its vault is refused, never swapped for another. The first vault is
    /// created only from a confirmed first run; a further one is authorized by the selected vault if it is unlocked, else the
    /// lowest-numbered unlocked one. A v1 vault or interrupted migration is listed, so it never offers Create.
    func createVault(name: String, choice: NewVaultChoice, in anchor: ASPresentationAnchor) async {
        guard let store else { return }
        var created: UUID?
        let succeeded = await guarded {
            var chosen = choice
            switch await store.openState() {
            case .firstRun:
                guard case .newPasskey = choice else { throw CredentialStoreError.noAuthority }
                chosen = .newPasskey(authorizedBy: nil)
            case .provisional:
                let listing = try await store.listing()
                guard listing.count < StoreFormat.activeVaultLimit else { throw CredentialStoreError.tooManyVaults }
                switch choice {
                case .newPasskey:
                    guard let source = unlockedAuthorizer(in: listing) else { throw CredentialStoreError.noAuthority }
                    chosen = .newPasskey(authorizedBy: source)
                case .existing(let sourceVaultID, let credentialID, let prfInput):
                    guard listing.contains(where: { $0.vaultID == sourceVaultID }),
                        try await store.discovery(vaultID: sourceVaultID).unlocks.contains(where: {
                            $0.credentialID == credentialID && $0.prfInput == prfInput
                        })
                    else { throw CredentialStoreError.passkeyUnusable }
                }
            case .legacy, .resumeMigration:
                throw CredentialStoreError.noAuthority
            case .failClosed(let closed):
                throw CredentialStoreError.failClosed(closed)
            }
            created = try await CredentialManager.createVault(profile: profile, name: name, choice: chosen, in: anchor, native: native)
        }
        guard succeeded, let created else { return }
        do {
            bind(try vaultManager(created))
        } catch {
            self.error = Self.message(for: error)
            return
        }
        await load()
    }

    /// The selected vault if it is unlocked, else the lowest-numbered listed vault that is.
    private func unlockedAuthorizer(in listing: [VaultListing]) -> CredentialManager? {
        if let manager, manager.isUnlocked, listing.contains(where: { $0.vaultID == manager.vaultID }) {
            return manager
        }
        let open = CredentialManager.unlockedManagers(for: profile)
        return listing.sorted { $0.ordinal < $1.ordinal }.lazy.compactMap { vault in open.first { $0.vaultID == vault.vaultID } }.first
    }

    /// `confirmMigration` is the user's explicit consent to migrate a v1 vault; without it the manager refuses before any
    /// passkey prompt and `needsMigrationConfirmation` is set.
    func unlock(in anchor: ASPresentationAnchor, confirmMigration: Bool = false, verifying: (@Sendable (Bool) -> Void)? = nil) async {
        unlockInFlight = true
        defer {
            unlockInFlight = false
            isVerifying = false
        }
        let report: @Sendable (Bool) -> Void = { [weak self] active in
            verifying?(active)
            Task { @MainActor in
                if self?.unlockInFlight == true {
                    self?.isVerifying = active
                }
            }
        }
        if await perform({ try await $0.unlock(in: anchor, confirmMigration: confirmMigration, verifying: report) }) {
            // An upgraded vault is a new state of the store: read it again before the page offers anything from the old one.
            if store != nil, !isProvisional {
                await discoverVault()
            }
            await load()
        }
    }

    func addUnlock(in anchor: ASPresentationAnchor) async {
        _ = await perform { _ = try await $0.addUnlock(in: anchor) }
    }

    /// Marks one of the profile's vaults as the one autofill and saving use without asking. Only a listed vault can be chosen.
    func setDefaultVault(_ vaultID: UUID) async {
        guard let store, vaults.contains(where: { $0.vaultID == vaultID }) else { return }
        await store.setDefaultVault(vaultID)
        storedDefaultVaultID = await store.defaultVaultID()
    }

    // MARK: Trash and earlier versions

    /// The first page of the vault's Trash and its verified counts. Everything lives in the authorization session, so a lock,
    /// a re-unlock or another vault starts again from nothing.
    func loadTrash() async throws {
        guard let live else { throw CredentialVaultError.unauthorized }
        try await fetchTrash(epoch: live.epoch)
    }

    func loadMoreTrash() async throws {
        guard let live, let after = live.trashNext, let manager else { return }
        let page = try await manager.trashPage(after: after)
        try Task.checkCancellation()
        try update(live.epoch) {
            guard $0.trashNext == after else { return }
            let known = Set($0.trash.map(\.id))
            $0.trash += page.items.filter { !known.contains($0.id) }
            $0.trashNext = page.next
        }
    }

    /// Restores a removed credential, or one removed password, code or passkey, as it was. The vault checks what the copy would
    /// collide with; a refusal writes nothing and is shown on the entry, which offers the same copy again or dismissing it.
    func restore(entryID: UUID) async {
        guard let live, let manager else { return }
        _ = await guarded {
            let (epoch, snapshot) = try await authorizedSnapshot(epoch: live.epoch)
            @MainActor func refuse(_ block: UndeleteBlock) throws {
                try update(epoch) { $0.restoreBlocked = RestoreBlocked(entryID: entryID, block: block) }
            }
            if let block = try await manager.previewUndelete(entryID: entryID).block {
                try refuse(block)
                return
            }
            do {
                _ = try await manager.undelete(entryID: entryID, expectedRevision: snapshot.revision, authorizedEpoch: epoch)
            } catch CredentialStoreError.undeleteBlocked(let block) {
                try refuse(block)
                return
            }
            try update(epoch) { $0.restoreBlocked = nil }
            try await reloadAfterWrite(epoch: epoch)
        }
    }

    func dismissRestoreBlock() {
        if live != nil {
            session?.restoreBlocked = nil
        }
    }

    /// `entryIDs` are Trash entries already listed; `emptyAll` ignores them and purges everything the Trash holds when the
    /// write happens. Nothing is deleted until `confirmPurge`, which asks for a fresh passkey assertion.
    func requestPurge(entryIDs: [UUID], emptyAll: Bool) {
        guard let live, let manager, let counts = live.counts else { return }
        let total = counts.trash.trashEntry
        let ids = emptyAll ? [] : entryIDs
        guard emptyAll ? total > 0 : !ids.isEmpty && ids.allSatisfy({ id in live.trash.contains { $0.id == id } }) else { return }
        session?.pendingPurge = PendingPurge(
            entryIDs: ids, emptyAll: emptyAll, count: emptyAll ? total : ids.count, vaultID: manager.vaultID, epoch: live.epoch,
            warning: PendingPurge.Warning(logicalOnly: true, preMigrationBackup: manager.preMigrationBackup)
        )
    }

    func cancelPurge() {
        if live != nil {
            session?.pendingPurge = nil
        }
    }

    /// The confirmation stays until the purge has actually run: a declined, cancelled or failed passkey assertion leaves it
    /// shown so the same purge can be confirmed again or cancelled. A tap while the purge is in flight does nothing, a success
    /// consumes the confirmation, and a lock, re-unlock or another vault drops it with the session.
    func confirmPurge(in anchor: ASPresentationAnchor) async {
        guard !isBusy else { return }
        guard let live, let pending = live.pendingPurge, pending.epoch == live.epoch, pending.vaultID == manager?.vaultID else {
            session?.pendingPurge = nil
            error = Self.message(for: CredentialVaultError.unauthorized)
            return
        }
        let purged = await perform(epoch: pending.epoch) {
            _ = try await $0.purge(entryIDs: pending.entryIDs, emptyAll: pending.emptyAll, in: anchor)
        }
        guard purged else { return }
        if self.live?.pendingPurge == pending {
            session?.pendingPurge = nil
        }
        _ = await guarded { try await reloadAfterWrite(epoch: pending.epoch) }
    }

    /// The first page of one credential's earlier versions.
    func loadVersions(accountID: UUID) async throws {
        guard let live else { throw CredentialVaultError.unauthorized }
        try await fetchVersions(accountID: accountID, epoch: live.epoch)
    }

    func loadMoreVersions() async throws {
        guard let live, let accountID = live.versionsAccountID, let after = live.revisionNext, let manager else { return }
        let page = try await manager.revisionPage(accountID: accountID, after: after)
        try Task.checkCancellation()
        try update(live.epoch) {
            guard $0.versionsAccountID == accountID, $0.revisionNext == after else { return }
            let known = Set($0.revisions.map(\.id))
            $0.revisions += page.items.filter { !known.contains($0.id) }
            $0.revisionNext = page.next
        }
    }

    func closeVersions() {
        if live != nil {
            session?.versionsAccountID = nil
            session?.revisions = []
            session?.revisionNext = nil
        }
    }

    /// Only a listed version of a password, one-time code or website details restores; a passkey never does, so this refuses
    /// before the vault is asked. The value being replaced is kept as a new earlier version.
    func restoreVersion(revisionID: UUID) async {
        guard let live, let manager, let item = live.revisions.first(where: { $0.id == revisionID }) else { return }
        guard item.subject.restoresFromEarlierVersions else {
            error = String(localized: "A passkey can’t be restored from an earlier version.")
            return
        }
        _ = await guarded {
            let (epoch, snapshot) = try await authorizedSnapshot(epoch: live.epoch)
            _ = try await manager.restoreRevision(revisionID: revisionID, expectedRevision: snapshot.revision, authorizedEpoch: epoch)
            try await reloadAfterWrite(epoch: epoch)
        }
    }

    private func fetchTrash(epoch: UInt64) async throws {
        guard let manager, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let page = try await manager.trashPage(after: nil)
        let counts = try await manager.historyCounts()
        try Task.checkCancellation()
        try update(epoch) {
            $0.trash = page.items
            $0.trashNext = page.next
            $0.counts = counts
            $0.restoreBlocked = nil
            $0.pendingPurge = nil
        }
    }

    private func fetchVersions(accountID: UUID, epoch: UInt64) async throws {
        guard let manager, manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        let page = try await manager.revisionPage(accountID: accountID, after: nil)
        try Task.checkCancellation()
        try update(epoch) {
            $0.versionsAccountID = accountID
            $0.revisions = page.items
            $0.revisionNext = page.next
        }
    }

    /// After a write this page made: the accounts as stored, and whichever history list is open, from its first page.
    private func reloadAfterWrite(epoch: UInt64) async throws {
        let (_, snapshot) = try await authorizedSnapshot(epoch: epoch)
        try update(epoch) { $0.refresh(snapshot) }
        if live?.counts != nil {
            try await fetchTrash(epoch: epoch)
        }
        if let accountID = live?.versionsAccountID {
            try await fetchVersions(accountID: accountID, epoch: epoch)
        }
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

    /// The last unlock passkey can't be removed: the vault would have no way to open.
    func requestUnlockRemoval(credentialID: Data) {
        guard let live, let unlocks = manager?.unlockCredentials, unlocks.contains(where: { $0.credentialID == credentialID }) else { return }
        guard unlocks.count > 1 else {
            error = Self.message(for: CredentialVaultError.noUnlocks)
            return
        }
        session?.pendingUnlockRemoval = PendingUnlockRemoval(credentialID: credentialID, epoch: live.epoch, remaining: unlocks.count - 1)
    }

    func cancelUnlockRemoval() {
        if live != nil {
            session?.pendingUnlockRemoval = nil
        }
    }

    /// Like the purge: the confirmation is kept until the removal has run, so a declined or failed assertion with one of the
    /// remaining passkeys can be retried. A removal that no longer applies (the passkey is already gone) is dropped.
    func confirmUnlockRemoval(_ pending: PendingUnlockRemoval, in anchor: ASPresentationAnchor) async {
        guard !isBusy, live?.pendingUnlockRemoval == pending else { return }
        let removed = await perform(epoch: pending.epoch) { _ = try await $0.removeUnlock(credentialID: pending.credentialID, in: anchor) }
        guard live?.pendingUnlockRemoval == pending else { return }
        if removed || !(manager?.unlockCredentials.contains { $0.credentialID == pending.credentialID } ?? false) {
            session?.pendingUnlockRemoval = nil
        }
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
        // A manager the page has since left is neither watched nor allowed to drop the new binding's session.
        withObservationTracking {
            _ = manager.authorizationEpoch
        } onChange: { [weak self] in
            MainActor.assumeIsolated { if self?.manager === manager { self?.session = nil } }
            Task { @MainActor [weak self] in if self?.manager === manager { self?.watchAuthorization() } }
        }
    }

    private func authorizedSnapshot(epoch bound: UInt64? = nil) async throws -> (epoch: UInt64, snapshot: StoreSnapshot) {
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
        return await guarded(describe: describe) { try await operation(manager) }
    }

    /// The busy flag, the error and the migration-consent flag around one user action.
    private func guarded(
        describe: (any Error) -> String? = { CredentialSettingsModel.message(for: $0) },
        _ work: () async throws -> Void
    ) async -> Bool {
        isBusy = true
        error = nil
        needsMigrationConfirmation = false
        defer { isBusy = false }
        do {
            try await work()
            return true
        } catch {
            if case CredentialStoreError.migrationNeedsConfirmation = error {
                needsMigrationConfirmation = true
            }
            self.error = noteClosed(error) ? nil : describe(error)
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
        case CredentialStoreError.migrationNeedsConfirmation:
            return String(localized: "This vault was saved by an older version of WSurf. Unlocking it upgrades it to the new format. Confirm to continue.")
        case CredentialStoreError.tooManyVaults:
            return String(localized: "This profile already has the most vaults it can hold.")
        case CredentialStoreError.noAuthority:
            return String(localized: "Unlock one of your vaults first. A new vault is created with the approval of a vault that is already open.")
        case CredentialStoreError.invalidVaultName:
            return String(localized: "Use a name of 1 to \(StoreFormat.nameLimit) characters.")
        case CredentialStoreError.passkeyUnusable:
            return String(localized: "That passkey is no longer enrolled in that vault. Choose a passkey again.")
        case CredentialStoreError.stateChanged:
            return String(localized: "Your credential files changed while WSurf was reading them. Check again.")
        case CredentialStoreError.noSuchVault:
            return String(localized: "That vault is no longer listed. Check again.")
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
