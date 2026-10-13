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
    private var session: CredentialVaultSession?
    @ObservationIgnored private let exchange: CredentialExchangeCoordinator
    /// Identifies this model to the exchange coordinator. One profile has one shared manager but every settings page
    /// builds its own model, so the import this model began is the only one it may see, decide, commit or cancel.
    @ObservationIgnored let owner = UUID()
    /// The finished import's per-credential results, bound to the authorization they were produced under.
    private var importResult: (outcome: CredentialImportOutcome, epoch: UInt64)?
    /// What the last import did to each credential (titles and sites, never secret values). Dropped when the vault locks
    /// or re-unlocks, like every other name shown from it; the transfer message keeps only the counts.
    var lastImport: CredentialImportOutcome? {
        importResult.flatMap { $0.epoch == manager?.authorizationEpoch ? $0.outcome : nil }
    }
    /// How this window's last import or export ended (spec §13.5); `nil` before any, or after the user dismisses it.
    private var ownMessage: CredentialTransferMessage?

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

    /// A new passkey needs a first run, or room for another vault and an already unlocked one to approve it.
    var canCreateWithNewPasskey: Bool {
        switch openState {
        case .firstRun?:
            return true
        case .provisional?:
            return vaults.count < StoreFormat.activeVaultLimit
                && CredentialManager.unlockedAuthorizer(in: vaults, selected: manager, profile: profile) != nil
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
                    enrolled = try await store.enrolledPasskeys(of: listing)
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

    /// How the last transfer ended, or the coordinator's refusal of a second token (spec §13.5). Production wording, nothing
    /// secret; the page shows it until the user dismisses it.
    var transferMessage: CredentialTransferMessage? {
        ownMessage ?? (isAvailable ? exchange.notice(for: owner) : nil)
    }

    func dismissTransferMessage() {
        ownMessage = nil
        exchange.dismissNotice(for: owner)
    }

    /// The unlocked vault's name, for the transfer header; `nil` while it is locked.
    var vaultName: String? {
        vaults.first { $0.vaultID == manager?.vaultID }?.name
    }

    func beginImport() async {
        guard let token = exchange.pendingToken else { return }
        importResult = nil
        ownMessage = nil
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
        let epoch = manager?.authorizationEpoch
        var receipt: VaultCommitReceipt?
        ownMessage = nil
        let committed = await perform(describe: importMessage(for:)) { receipt = try await self.exchange.commitImport(into: $0, owner: self.owner) }
        guard committed, let receipt, let expected else { return }
        if let epoch, epoch == manager?.authorizationEpoch {
            importResult = (expected, epoch)
        }
        ownMessage = .succeeded(expected, receipt: receipt)
        await load()
    }

    /// Ends the review. The system's token for it was used up when the import began, so the message says the import was
    /// discarded and has to be sent again. Only a review that had no commit running can say nothing was saved: cancelling a
    /// commit asks the vault not to write, and a write that already started may still land (its own ending says so).
    @discardableResult
    func cancelImport() -> CredentialImportCancellation {
        guard let manager else { return .nothingOwned }
        let outcome = exchange.cancelImport(for: manager, owner: owner)
        if outcome == .reviewCancelled {
            ownMessage = .discarded()
        }
        return outcome
    }

    /// Declines the credentials another app is waiting to send, whether or not the vault is unlocked. `token` is the
    /// one the caller showed: a token that arrived since is not the one the user was looking at and is left queued.
    func discardPendingImport(token: UUID) {
        exchange.discardPendingImport(token: token)
    }

    /// `epoch` is the one the selection was made at; a lock or re-unlock rejects it, and so does a change to a selected
    /// account since the page last read it (a write to any other account does not). A cancel before any data was passed is
    /// `.cancelled` and leaves no status; every other result is recorded.
    func exportCredentials(
        selection: [CredentialExportSelection],
        epoch: UInt64,
        in anchor: ASPresentationAnchor
    ) async -> CredentialExportOutcome? {
        ownMessage = nil
        var outcome: CredentialExportOutcome?
        let sent = await perform {
            let stamps = try await self.exportStamps(epoch: epoch)
            outcome = try await self.exchange.exportCredentials(
                selection: selection, expectedStamps: stamps, epoch: epoch, from: $0, in: anchor
            )
        }
        // The page showed an older vault than the one on disk: read it again, or every retry would fail the same way.
        if !sent, ownMessage?.kind == .exportSelectionChanged {
            await load()
        }
        if let outcome, outcome != .cancelled {
            ownMessage = outcome.message
        }
        return outcome
    }

    /// The stamps the user's selection was made against. After this page's own write they are unknown, and a fresh read
    /// stands in for them only while the vault has not moved past the revision the page showed.
    private func exportStamps(epoch: UInt64) async throws -> [UUID: AccountStamp] {
        guard let live, live.epoch == epoch else { throw CredentialTransferFailure(message: .exportSelectionChanged()) }
        if live.stampsRevision == live.revision {
            return live.stamps
        }
        let (_, snapshot) = try await authorizedSnapshot(epoch: epoch)
        guard snapshot.revision == live.revision else {
            throw CredentialTransferFailure(message: .exportSelectionChanged())
        }
        return snapshot.stamps
    }

    // MARK: Private

    private var live: CredentialVaultSession? {
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

    private func update(_ epoch: UInt64, _ change: (inout CredentialVaultSession) -> Void) throws {
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
        } catch let failure as CredentialTransferFailure {
            ownMessage = failure.message
            return false
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
}
