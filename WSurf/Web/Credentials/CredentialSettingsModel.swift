// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import Observation

// MARK: - Model

/// Settings state for one profile's credential vault. Every secret it holds lives in `session`, which is tied
/// to one manager authorization epoch: the getters refuse a session from another epoch, and an observation of
/// `authorizationEpoch` drops the session itself the moment the manager locks or re-unlocks.
@MainActor
@Observable
final class CredentialSettingsModel {
    let profile: Profile
    private(set) var isBusy = false
    /// `nil` until discovered; stays `nil` (with `error` set) when the vault exists but can't be read.
    private(set) var vaultExists: Bool?
    var error: String?
    /// Set when unlocking was refused because the vault is a v1 file (or an interrupted migration) and the user has not
    /// yet agreed to migrate it; no passkey prompt happened. Unlock again with `confirmMigration: true` after consent.
    private(set) var needsMigrationConfirmation = false
    /// The profile's active vaults as the last discovery listed them (names stay `nil` until a vault is unlocked). Internal for the model's extensions.
    var vaults: [VaultListing] = []
    /// The open state the last discovery read; `nil` before it and for a test-injected manager. Creating a vault is offered
    /// only from a confirmed state, never inferred from an empty list.
    private(set) var openState: StoreOpenState?
    /// Set when the store refused to open, or a later read found it closed. The page then shows only the exact paths and a re-check.
    private(set) var failClosed: StoreFailClosed?
    /// Every enrolled unlock passkey of every listed vault (plaintext discovery, no secret): the pair is the identity. Only the vault's
    /// id is kept; its name is read from `vaults` when asked, so a lock or an unlock cannot leave a second copy of it behind.
    private var enrolledPasskeys: [(vaultID: UUID, unlock: VaultUnlock)] = []
    private var storedDefaultVaultID: UUID?
    /// True while an unlock is verifying the vault (it took longer than the store's threshold); only meaningful during `unlock`.
    private(set) var isVerifying = false
    @ObservationIgnored private var unlockInFlight = false

    /// The one vault this page operates on; `nil` until discovery selects one, and while the profile has no vault.
    /// Read by `CredentialSettingsModel+Export`; only this class sets it.
    private(set) var manager: CredentialManager?
    /// `nil` for private browsing and for a test-injected manager (which owns its own store). Internal for the model's extensions.
    @ObservationIgnored let store: ProfileVaultStore?
    /// Test seam: managers made here use it instead of the system passkey UI, which the shared registry's managers always use.
    @ObservationIgnored private let native: VaultNativeUnlock?
    /// Internal for `CredentialSettingsModel+Copy`, the one clipboard exit.
    @ObservationIgnored let pasteboard: NSPasteboard
    /// How long a copy confirmation stays, and how long one that offers Undo does; seams so a test does not wait for the real time.
    @ObservationIgnored private let noticeDuration: Duration
    @ObservationIgnored private let undoNoticeDuration: Duration
    @ObservationIgnored private var noticeGeneration = 0
    /// What the last copy or list action did, for a moment ("Password Copied", "Moved 3 credentials to Trash."): the name of the
    /// part or a count, never a value.
    private(set) var notice: CredentialNotice?
    private var session: CredentialVaultSession?
    /// Internal for `CredentialSettingsModel+Export`.
    @ObservationIgnored let exchange: CredentialExchangeCoordinator
    /// Identifies this model to the exchange coordinator. One profile has one shared manager but every settings page
    /// builds its own model, so the import this model began is the only one it may see, decide, commit or cancel.
    @ObservationIgnored let owner = UUID()
    /// The one-time move of the passwords saved before Credential Manager (`CredentialSettingsModel+LegacyPasswords`).
    @ObservationIgnored let legacy: LegacyPasswordImport
    /// The finished import's per-credential results, bound to the authorization they were produced under.
    private var importResult: (outcome: CredentialImportOutcome, epoch: UInt64)?
    /// What the last import did to each credential (titles and sites, never secret values). Dropped when the vault locks
    /// or re-unlocks, like every other name shown from it; the transfer message keeps only the counts.
    var lastImport: CredentialImportOutcome? {
        importResult.flatMap { $0.epoch == manager?.authorizationEpoch ? $0.outcome : nil }
    }
    /// How this window's last import or export ended (spec §13.5) and the vault it happened in; the page shows it only while
    /// that vault is selected. `nil` before any, or after the user dismisses it.
    /// Internal for `CredentialSettingsModel+Export`, which records its own endings.
    var ownMessage: (message: CredentialTransferMessage, vaultID: UUID?)?
    /// The vault this page deleted last, until the user dismisses it. Internal for `CredentialSettingsModel+VaultDeletion`.
    var deletedVault: DeletedVault?

    /// `manager` and `native` are seams for tests that need their own clock or passkeys; production selects the profile's
    /// default vault (else the lowest-ordinal one) through the shared registry once `load()` has listed the vaults.
    init(
        profile: Profile,
        pasteboard: NSPasteboard = .general,
        exchange: CredentialExchangeCoordinator = .shared,
        manager: CredentialManager? = nil,
        native: VaultNativeUnlock? = nil,
        noticeDuration: Duration = .seconds(1.6),
        undoNoticeDuration: Duration = .seconds(4)
    ) {
        self.profile = profile
        self.exchange = exchange
        self.pasteboard = pasteboard
        self.noticeDuration = noticeDuration
        self.undoNoticeDuration = undoNoticeDuration
        self.native = native
        legacy = LegacyPasswordImport(profile: profile)
        if profile.isPrivate {
            self.manager = nil
            store = nil
        } else {
            self.manager = manager
            store = manager == nil ? try? CredentialManager.store(for: profile) : nil
        }
        watchAuthorization()
        watchListing()
    }

    // MARK: Observable state

    /// The enrolled passkeys of the vaults the page lists now, each with that vault's current listing.
    var existingPasskeys: [(vault: VaultListing, unlock: VaultUnlock)] {
        enrolledPasskeys.compactMap { item in
            vaults.first { $0.vaultID == item.vaultID }.map { (vault: $0, unlock: item.unlock) }
        }
    }

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
    var exportStamps: [UUID: AccountStamp]? {
        live?.knownStamps
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

    /// A new passkey needs a first run, or room for another vault and an already unlocked one to approve it.
    var canCreateWithNewPasskey: Bool {
        openState?.allowsNewPasskey(
            vaultCount: vaults.count,
            hasAuthorizer: CredentialManager.unlockedAuthorizer(in: vaults, selected: manager, profile: profile) != nil
        ) ?? false
    }

    var canCreateVault: Bool {
        openState?.allowsCreate(
            vaultCount: vaults.count, newPasskey: canCreateWithNewPasskey, hasEnrolledPasskey: !existingPasskeys.isEmpty
        ) ?? false
    }

    // MARK: Trash and editing (state)

    /// The loaded Trash entries, without the ones marked for deletion.
    var trashItems: [TrashItem] {
        guard let live else { return [] }
        let marked = Set(live.markedForDeletion)
        return marked.isEmpty ? live.trash : live.trash.filter { !marked.contains($0.id) }
    }
    /// The vault's verified Trash count without the entries marked for deletion, not the rows on screen; `nil` until the Trash has been loaded.
    var trashTotal: Int? {
        live?.counts.map { max($0.trash.trashEntry - (live?.markedForDeletion.count ?? 0), 0) }
    }
    /// How many Trash entries X has marked for deletion in this session.
    var markedCount: Int {
        live?.markedForDeletion.count ?? 0
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
        session?.hideSecrets()
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
            session = CredentialVaultSession(epoch: epoch, snapshot: snapshot)
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
        // An already unlocked vault is not discovered again by `load`, so its listing is read here.
        await refreshListing()
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
                    enrolledPasskeys = []
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
                    enrolled = try await store.enrolledPasskeys(of: listing)
                }
                guard !Task.isCancelled else { return }
                failClosed = nil
                vaults = listing
                enrolledPasskeys = enrolled.map { (vaultID: $0.vault.vaultID, unlock: $0.unlock) }
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
        enrolledPasskeys = []
        bind(nil)
        vaultExists = nil
        error = nil
    }

    private func bind(_ next: CredentialManager?) {
        if let manager, manager.vaultID != next?.vaultID {
            leave(manager)
        }
        manager = next
        session = nil
        needsMigrationConfirmation = false
        watchAuthorization()
    }

    /// The page leaves `old`: only this window's own import is cancelled there, and its ending shows again if the page returns.
    private func leave(_ old: CredentialManager) {
        let origin = exchange.importOrigin(for: old, owner: owner)
        guard exchange.cancelImport(for: old, owner: owner) == .reviewCancelled else { return }
        ownMessage = (.discarded(origin), old.vaultID)
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
        let saved = try draft.account()
        let started = session.knownStamps?[saved.id]
        let receipt = try await save(saved, expectedRevision: draft.revision)
        try? update(session.epoch) { $0.draft = nil }
        await recordSave(of: saved, from: draft.original, started: started, receipt: receipt, epoch: session.epoch)
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
        try await copy(.password, of: .stored(accountID))
    }

    /// `now` is read after the last suspension so a step boundary crossed while waiting yields the new code.
    func copyTOTP(
        accountID: UUID,
        now: @MainActor () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) async throws {
        try await copy(.code, of: .stored(accountID), now: now)
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
            let chosen = try await store.creationChoice(for: choice) {
                CredentialManager.unlockedAuthorizer(in: $0, selected: manager, profile: profile)
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
            if store != nil, openState?.isProvisional != true {
                await discoverVault()
            }
            await refreshListing()
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

    /// This window's own ending, only while the vault it happened in is the selected one.
    private var visibleEnding: CredentialTransferMessage? {
        ownMessage.flatMap { $0.vaultID == manager?.vaultID ? $0.message : nil }
    }

    /// Its own ending, else the refusal of a second token (spec §13.5). Production wording, nothing secret.
    var transferMessage: CredentialTransferMessage? {
        visibleEnding ?? (isAvailable ? exchange.refusal : nil)
    }

    /// Dismisses exactly what `transferMessage` shows, never a shadowed refusal or another vault's ending.
    func dismissTransferMessage() {
        guard visibleEnding != nil else { return exchange.dismissRefusal() }
        ownMessage = nil
    }

    /// Tells this window how an import it began in `manager`'s vault ended outside its own call; weak, bound to that vault.
    func importEnding(in manager: CredentialManager) -> CredentialExchangeCoordinator.Ending {
        { [weak self, vault = manager.vaultID] in self?.ownMessage = ($0, vault) }
    }

    /// The unlocked vault's name, for the transfer header; `nil` while it is locked, whatever an older listing still holds.
    var vaultName: String? {
        guard isUnlocked else { return nil }
        return vaults.first { $0.vaultID == manager?.vaultID }?.name
    }

    func beginImport() async {
        guard let token = exchange.pendingToken else { return }
        importResult = nil
        ownMessage = nil
        _ = await perform(describe: { self.importMessage(for: $0) }) { try await self.exchange.beginImport(token: token, into: $0, owner: self.owner, onEnding: self.importEnding(in: $0)) }
    }

    func commitImport() async {
        let expected = plannedImportOutcome()
        let epoch = manager?.authorizationEpoch
        var receipt: VaultCommitReceipt?
        let vault = manager?.vaultID
        // Read before the commit: a failed one drops the review, and its message must still name the right retry.
        let origin = currentImportOrigin()
        ownMessage = nil
        let committed = await perform(describe: { self.importMessage(for: $0, origin: origin) }) { receipt = try await self.exchange.commitImport(into: $0, owner: self.owner) }
        guard committed, let receipt, let expected else { return }
        if let epoch, epoch == manager?.authorizationEpoch {
            importResult = (expected, epoch)
        }
        ownMessage = (.succeeded(expected, receipt: receipt, origin: origin), vault)
        await load()
        await legacyImportCommitted(origin)
    }

    /// Ends the review. The system's token for it was used up when the import began, so the message says the import was
    /// discarded and has to be sent again. Only a review that had no commit running can say nothing was saved: cancelling a
    /// commit asks the vault not to write, and a write that already started may still land (its own ending says so).
    @discardableResult
    func cancelImport() -> CredentialImportCancellation {
        guard let manager else { return .nothingOwned }
        let origin = exchange.importOrigin(for: manager, owner: owner)
        let outcome = exchange.cancelImport(for: manager, owner: owner)
        if outcome == .reviewCancelled {
            ownMessage = (.discarded(origin), manager.vaultID)
        }
        return outcome
    }

    /// Declines the credentials another app is waiting to send, whether or not the vault is unlocked. `token` is the
    /// one the caller showed: a token that arrived since is not the one the user was looking at and is left queued.
    func discardPendingImport(token: UUID) {
        exchange.discardPendingImport(token: token)
    }

    /// Stages the password CSV at `url` for the same review a system import gets. The file is only read, never changed.
    /// `epoch` is the authorization the page had BEFORE its open panel: a lock or re-unlock while the panel was up stages nothing.
    func beginCSVImport(from url: URL, epoch: UInt64) async {
        importResult = nil
        ownMessage = nil
        _ = await perform(epoch: epoch) {
            let data: Data
            do {
                data = try CredentialCSV.read(url)
            } catch CredentialCSVError.cannotRead {
                throw CredentialTransferFailure(message: .csvNotOpened())
            } catch {
                throw CredentialTransferFailure(message: .csvUnreadable(line: nil))
            }
            try await self.exchange.beginCSVImport(data, into: $0, owner: self.owner, onEnding: self.importEnding(in: $0))
        }
    }

    // MARK: Private

    /// Internal for `CredentialSettingsModel+Export`.
    var live: CredentialVaultSession? {
        guard let session, session.epoch == manager?.authorizationEpoch else { return nil }
        return session
    }

    /// Drops the session synchronously inside the manager's change notification, so no secret survives a lock
    /// or an unlock into a new epoch; the observation is re-armed once the change has landed.
    private func watchAuthorization() {
        guard let manager else { return }
        if let session, session.epoch != manager.authorizationEpoch {
            self.session = nil
            importResult = nil
        }
        // A manager the page has since left is neither watched nor allowed to drop the new binding's session.
        withObservationTracking {
            _ = manager.authorizationEpoch
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.manager === manager else { return }
                self?.session = nil
                self?.importResult = nil
            }
            Task { @MainActor [weak self] in
                guard self?.manager === manager else { return }
                self?.watchAuthorization()
                await self?.refreshListing()
            }
        }
    }

    /// A lock or an unlock of ANY of the profile's vaults changes what the listing may show, and this page observes only its selected
    /// manager. So it also observes the shared counter: a lock drops the names of vaults that are no longer open at once, and every
    /// change reads the list again.
    private func watchListing() {
        withObservationTracking {
            _ = VaultStateChanges.shared.count(for: profile.id)
        } onChange: { [weak self] in
            MainActor.assumeIsolated { self?.hideNamesOfLockedVaults() }
            // Re-armed once the change has landed, so a second change in the same turn is caught here, not by the observation.
            Task { @MainActor [weak self] in
                self?.watchListing()
                self?.hideNamesOfLockedVaults()
                await self?.refreshListing()
            }
        }
    }

    /// A name is sealed while its vault is locked, so it does not stay in memory until the next read of the list.
    private func hideNamesOfLockedVaults() {
        var open = Set(CredentialManager.unlockedManagers(for: profile).map(\.vaultID))
        if let manager, manager.isUnlocked {
            open.insert(manager.vaultID)
        }
        let hidden = vaults.map { listing in
            open.contains(listing.vaultID) ? listing : VaultListing(
                vaultID: listing.vaultID, ordinal: listing.ordinal, name: nil, isUnlocked: false, isVerified: listing.isVerified
            )
        }
        if hidden != vaults {
            vaults = hidden
        }
    }

    /// Internal for `CredentialSettingsModel+Export`.
    func authorizedSnapshot(epoch bound: UInt64? = nil) async throws -> (epoch: UInt64, snapshot: StoreSnapshot) {
        guard let manager, let epoch = manager.authorizationEpoch, bound == nil || bound == epoch else {
            throw CredentialVaultError.unauthorized
        }
        let snapshot = try await manager.snapshot()
        try Task.checkCancellation()
        guard manager.authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
        return (epoch, snapshot)
    }

    func update(_ epoch: UInt64, _ change: (inout CredentialVaultSession) -> Void) throws {
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
        try? update(epoch) { $0.committed(accounts, revision: receipt.revision) }
        return receipt
    }

    /// Shows `text` above the list for a moment; the latest one wins. A notice that offers Undo stays longer. Internal for the model's extensions.
    func showNotice(_ text: LocalizedStringResource, undo: Bool = false, duration: Duration? = nil) {
        notice = CredentialNotice(text: String(localized: text), offersUndo: undo)
        noticeGeneration += 1
        let generation = noticeGeneration
        let lasts = duration ?? (undo ? undoNoticeDuration : noticeDuration)
        Task { [weak self] in
            try? await Task.sleep(for: lasts)
            guard let self, noticeGeneration == generation else { return }
            notice = nil
        }
    }

    /// Internal for `CredentialSettingsModel+Export`.
    func perform(
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

    /// The busy flag, the error and the migration-consent flag around one user action. Internal for the model's extensions.
    func guarded(
        describe: (any Error) -> String? = { CredentialSettingsModel.message(for: $0) },
        _ work: () async throws -> Void
    ) async -> Bool {
        let vault = manager?.vaultID
        isBusy = true
        error = nil
        needsMigrationConfirmation = false
        defer { isBusy = false }
        do {
            try await work()
            return true
        } catch let failure as CredentialTransferFailure {
            ownMessage = (failure.message, vault)
            return false
        } catch {
            if case CredentialStoreError.migrationNeedsConfirmation = error {
                needsMigrationConfirmation = true
            }
            self.error = noteClosed(error) ? nil : describe(error)
            return false
        }
    }

    /// Where this window's open import came from, which decides what a failed one tells the user to do to retry.
    /// Internal for `CredentialSettingsModel+ImportReview`.
    func currentImportOrigin() -> CredentialTransferMessage.Origin {
        manager.map { exchange.importOrigin(for: $0, owner: owner) } ?? .system
    }

    /// The system's token is used up once an import is claimed, and a review that ends takes its data with it. So
    /// a failure that leaves neither a queued token nor an open review can only be redone from the other app, or, for a
    /// CSV file, by choosing the file again.
    func importMessage(for error: any Error, origin: CredentialTransferMessage.Origin = .system) -> String? {
        let staged = manager.map { exchange.hasStagedImport(for: $0, owner: owner) } ?? false
        return Self.importMessage(for: error, tokenSpent: exchange.pendingToken == nil && !staged, origin: origin)
    }
}
