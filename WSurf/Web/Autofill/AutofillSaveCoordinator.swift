// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import CryptoKit
import Observation
import WebKit

@MainActor
@Observable
final class AutofillSaveSession: NSObject {
    nonisolated struct Offer: Identifiable, Sendable {
        let id = UUID()
        let candidate: AutofillSaveCandidate
        let origin: String
        let isUpdate: Bool
        let fingerprint: String
        /// The document the offer is bound to, and the origin it must still show. Usually the page the form was on; after a navigation,
        /// the page that replaced it (`origin` stays the credential's origin).
        let documentID: String
        let liveOrigin: String
        /// Password offers: what saving does, to which exact account, against which unlocked vault state.
        var plan: CredentialSavePlan?
        var managerEpoch: UInt64?
        var managerRevision: UInt64?
        var loginURL: URL?
        /// The profile has no vault yet: this offer saves nothing and only suggests setting one up (`save` and `never` refuse it).
        var needsVault = false
        /// The page the offer was made on has changed: nothing can be saved from it. It stays on screen only to say so, until it is
        /// dismissed or replaced by an offer from the page the user is on.
        var isGone = false
    }
    /// The page's website, to be added to a saved credential of a sibling website instead of saving a copy of that login. Identity
    /// only: no secret is held, and confirming reads the credential again under the unlock the offer was made under.
    nonisolated struct WebsiteOffer: Identifiable, Sendable {
        let id = UUID()
        /// The website to add: the page's origin.
        let origin: String
        let accountID: UUID
        /// What the dropdown calls the credential, and the username it must still have when the offer is confirmed.
        let name: String
        let username: String
        let managerEpoch: UInt64
        let documentID: String
        let liveOrigin: String
        let fingerprint: String

        var host: String {
            String(origin.dropFirst("https://".count))
        }
    }
    private(set) var offers: [Offer] = []
    private(set) var websiteOffer: WebsiteOffer?
    private(set) var isBusy = false
    private(set) var error: String?
    var isPopoverPresented = false
    private(set) var context: BrowserProfileContext?
    @ObservationIgnored weak var page: BrowserPage?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var dismissed: [AutofillSaveKind: Set<String>] = [:]
    @ObservationIgnored private let fingerprintKey = SymmetricKey(size: .bits256)
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private var choosing: Task<CredentialManager?, Never>?
    @ObservationIgnored private var accessGeneration = 0
    /// Whether the page still shows this document at this origin; tests replace it, since a loaded document is its only proof.
    @ObservationIgnored var liveness: (BrowserPage, String, String) async -> Bool = {
        await AutofillSaveCoordinator.shared.isLive(page: $0, documentID: $1, origin: $2)
    }
    /// `accountID` and what follows are only set when the user picked a credential manager account. They carry
    /// identity, never a secret or code, and `deadline` is fixed when the account is picked.
    struct UsernameStep {
        let origin: String; let value: String; let documentID: String; let attemptID: UUID; let date = Date.now; var completed = false
        var accountID: UUID?; var contextID: UUID?; var tab: ObjectIdentifier?
        var deadline: ContinuousClock.Instant?; var epoch: UInt64?
    }
    @ObservationIgnored var username: UsernameStep?
    @ObservationIgnored let submissions = AutofillSubmissionTracker()

    var current: Offer? {
        offers.first
    }

    func attach(to page: BrowserPage, context: BrowserProfileContext) {
        clear(); self.page = page; self.context = context; submissions.attach(to: self); dismissed = [:]
    }
    func clear() {
        revision += 1; offers = []; websiteOffer = nil; isPopoverPresented = false; username = nil; submissions.clear(); error = nil
        expiry?.cancel(); expiry = nil
        vaultAccessEnded()
    }
    /// Vault access ended (lock, sleep, profile switch, retire) or the offers were dropped: a vault choice still open is dismissed,
    /// and an answer already given is stale and unlocks nothing.
    func vaultAccessEnded() {
        accessGeneration &+= 1
        choosing?.cancel()
    }
    func refreshPolicy() {
        revision += 1; submissions.clear()
        guard let context else {
            offers = []
            websiteOffer = nil
            username = nil
            isPopoverPresented = false
            return
        }
        offers.removeAll { !AutofillSaveCoordinator.shared.isEnabled($0.candidate.kind, context: context) }
        if !AutofillSaveCoordinator.shared.isEnabled(.password, context: context) {
            websiteOffer = nil
        }
        if offers.isEmpty && websiteOffer == nil {
            isPopoverPresented = false
        }
        username?.accountID = nil
        if !AutofillSaveCoordinator.shared.isEnabled(.password, context: context) {
            username = nil
        }
    }

    /// The account picked earlier in this tab for this origin, while the user is still on the same username.
    /// Empty `enteredUsername` means the page has no username to compare, as on a verification-code step.
    /// A step in this tab that no longer matches (another username, origin, a lock or re-unlock, or the fixed
    /// deadline) invalidates the pick for good: only `selectAccount` can bring an account back. A query that
    /// describes another tab, or an unlock older than the pick, says nothing about this pick and leaves it alone,
    /// so callers must only ask on behalf of a request that is still live.
    func selectedAccount(
        in page: BrowserPage, origin: String, enteredUsername: String?,
        now: ContinuousClock.Instant = .now, epoch: UInt64? = nil
    ) -> UUID? {
        guard self.page === page, let context, page.context === context, let step = username, let accountID = step.accountID,
              step.contextID == context.contextID, step.tab == ObjectIdentifier(page) else { return nil }
        if let epoch, let picked = step.epoch, epoch < picked {
            return nil
        }
        guard let deadline = step.deadline, step.origin == origin, step.epoch == epoch, now < deadline,
              enteredUsername.map({ $0.isEmpty || $0 == step.value }) ?? true else {
            username?.accountID = nil
            return nil
        }
        return accountID
    }

    /// Remember which account the user just picked. The 300 second deadline starts here and later steps never extend it.
    func selectAccount(
        _ id: UUID, username: String, in page: BrowserPage, origin: String,
        now: ContinuousClock.Instant = .now, documentID: String = "", epoch: UInt64? = nil
    ) {
        guard self.page === page, let context, page.context === context, !username.isEmpty, username.count <= 500 else { return }
        var step = UsernameStep(origin: origin, value: username, documentID: documentID, attemptID: UUID())
        step.completed = true
        step.accountID = id; step.contextID = context.contextID; step.tab = ObjectIdentifier(page)
        step.deadline = now.advanced(by: .seconds(300)); step.epoch = epoch
        self.username = step
    }

    /// A username seen on a submitted or interacted step. The picked account rides along only for the same tab,
    /// context, origin and username, and keeps its original deadline; any other username starts a plain step.
    func stageUsername(_ value: String, origin: String, documentID: String, attemptID: UUID, in page: BrowserPage) {
        var step = UsernameStep(origin: origin, value: value, documentID: documentID, attemptID: attemptID)
        if let previous = username, previous.accountID != nil, previous.origin == origin, previous.value == value,
           let context, page.context === context, previous.contextID == context.contextID,
           previous.tab == ObjectIdentifier(page), self.page === page {
            step.accountID = previous.accountID; step.contextID = previous.contextID; step.tab = previous.tab
            step.deadline = previous.deadline; step.epoch = previous.epoch
        }
        username = step
    }

    func resetDismissals(kind: AutofillSaveKind) {
        dismissed[kind] = nil
    }
    func resetDismissalsForNavigation() {
        dismissed = [:]
    }

    func receive(
        _ candidates: [AutofillSaveCandidate], origin: String, documentID: String = "", liveOrigin: String? = nil, loginURL: URL? = nil
    ) {
        let revision = revision
        Task { [weak self] in
            guard let self else { return }
            for candidate in candidates {
                guard revision == self.revision else { return }
                await offer(candidate, origin: origin, documentID: documentID, liveOrigin: liveOrigin, loginURL: loginURL)
            }
        }
    }

    /// `epoch` and `revision` are nil while the route still needs the user's choice or an unlock: the vault is picked when they
    /// click Save or Never, and nothing is read from a locked vault before that.
    private struct ManagedSave {
        let plan: CredentialSavePlan
        let epoch: UInt64?
        let revision: UInt64?
        let loginURL: URL?
        var needsVault = false
    }

    private func managerOrigin(_ origin: String) -> String? {
        URL(string: origin).flatMap(CredentialAccountSelection.origin(for:)) == origin ? origin : nil
    }

    /// The one manager that owns `epoch`: epochs are process-unique, so another vault's epoch never selects it.
    private func manager(epoch: UInt64?) -> CredentialManager? {
        guard let epoch, let context, !context.profile.isPrivate, page?.context === context else { return nil }
        return CredentialManager.unlockedManagers(for: context.profile).first { $0.authorizationEpoch == epoch }
    }

    /// What the routed vault would do with `login`; `nil` when there is nothing to offer, including when the browser has no
    /// usable vault. `target` (the vault the user already chose) skips the route. The carry-over lookup can invalidate the
    /// picked account, so it runs only once the document is confirmed live and with no suspension between the last `revision`
    /// check and the lookup.
    private func managedPlan(
        for login: SavedPassword, origin: String, documentID: String, liveOrigin: String, loginURL loginPage: URL?,
        revision: Int, target: CredentialManager? = nil
    ) async -> ManagedSave? {
        guard let context, !context.profile.isPrivate,
              let page, page.context === context, let origin = managerOrigin(origin) else { return nil }
        if !documentID.isEmpty, await !liveness(page, documentID, liveOrigin) {
            AutofillDiagnostics.note(.offerDroppedNotLive, kind: .password)
            return nil
        }
        let route: VaultRoute
        if let target {
            route = .manager(target)
        } else {
            route = await CredentialRouting.route(profile: context.profile, origin: origin, username: login.username)
        }
        guard revision == self.revision, self.page === page else { return nil }
        // The page the form was on, not the one the tab shows by now.
        let loginURL = (loginPage ?? page.url).flatMap { CredentialAccountSelection.loginURL(for: $0, origin: origin) }
        let manager: CredentialManager
        switch route {
        case .unavailable:
            // A profile that has never had a vault is offered the setup, once in each run of the app. Every other reason a vault
            // is unavailable (an older format to upgrade, an unreadable store) is Settings' to explain, not a page's.
            guard AutofillSaveCoordinator.shared.shouldOfferVaultSetup(for: context.profile.id),
                  await CredentialRouting.profileNeedsFirstVault(context.profile) else { return nil }
            guard revision == self.revision, self.page === page else { return nil }
            return ManagedSave(plan: .create, epoch: nil, revision: nil, loginURL: nil, needsVault: true)
        case .needsChoice, .needsUnlock:
            return ManagedSave(plan: .create, epoch: nil, revision: nil, loginURL: loginURL)
        case .manager(let routed):
            manager = routed
        }
        guard let epoch = manager.authorizationEpoch, let snapshot = try? await manager.snapshot(),
              self.manager(epoch: epoch) === manager, revision == self.revision, self.page === page else { return nil }
        guard !snapshot.blockedPasswordOrigins.contains(origin) else {
            AutofillDiagnostics.note(.offerDroppedBlocked, kind: .password)
            return nil
        }
        let selected = selectedAccount(in: page, origin: origin, enteredUsername: login.username, epoch: epoch)
        let plan = CredentialAccountSelection.savePlan(for: login, origin: origin, accountID: selected, in: snapshot.accounts)
        guard plan != .unchanged, plan != .ambiguous else {
            AutofillDiagnostics.note(plan == .ambiguous ? .offerDroppedAmbiguous : .offerDroppedUnchanged, kind: .password)
            return nil
        }
        return ManagedSave(plan: plan, epoch: epoch, revision: snapshot.revision, loginURL: loginURL)
    }

    func offer(
        _ candidate: AutofillSaveCandidate, origin: String, documentID: String = "", liveOrigin: String? = nil, loginURL: URL? = nil,
        target: CredentialManager? = nil
    ) async {
        guard let context, AutofillSaveCoordinator.shared.isEnabled(candidate.kind, context: context) else { return }
        let liveOrigin = liveOrigin ?? origin
        let bytes = (try? JSONEncoder().encode([origin, candidate.kind.rawValue] + candidate.values)) ?? Data()
        let fingerprint = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: fingerprintKey)).base64EncodedString()
        guard !offers.contains(where: { $0.fingerprint == fingerprint && !$0.isGone }) else { return }
        guard dismissed[candidate.kind]?.contains(fingerprint) != true else {
            AutofillDiagnostics.note(.offerDroppedDismissed, kind: candidate.kind)
            return
        }
        let revision = revision, profileID = context.profile.id
        var managed: ManagedSave?
        let decision: AutofillSaveIndex.Decision
        if case .password(let login) = candidate {
            if target == nil, let sibling = await siblingAccount(for: login, origin: origin) {
                guard revision == self.revision else { return }
                await offerWebsite(
                    accountID: sibling.accountID, epoch: sibling.epoch, origin: origin, documentID: documentID, liveOrigin: liveOrigin
                )
                return
            }
            guard let found = await managedPlan(
                for: login, origin: origin, documentID: documentID, liveOrigin: liveOrigin, loginURL: loginURL, revision: revision, target: target
            ) else { return }
            managed = found
            decision = found.plan == .create ? .new : .update
        } else {
            decision = await Task.detached { (try? AutofillSaveIndex.decision(for: candidate, origin: origin, profileID: profileID)) ?? .new }.value
        }
        guard revision == self.revision, self.context === context, let page, page.context === context, !context.profile.isPrivate,
              page.url.flatMap(SavedPassword.origin(for:)) != nil else { return }
        if !documentID.isEmpty, await !liveness(page, documentID, liveOrigin) {
            AutofillDiagnostics.note(.offerDroppedNotLive, kind: candidate.kind)
            return
        }
        // The liveness check suspends: whatever it waited through (a clear, a policy change, another offer) is checked again.
        guard revision == self.revision, self.context === context, AutofillSaveCoordinator.shared.isEnabled(candidate.kind, context: context),
              !offers.contains(where: { $0.fingerprint == fingerprint && !$0.isGone }) else { return }
        guard dismissed[candidate.kind]?.contains(fingerprint) != true else {
            AutofillDiagnostics.note(.offerDroppedDismissed, kind: candidate.kind)
            return
        }
        guard decision != .unchanged, decision != .blocked else {
            AutofillDiagnostics.note(decision == .blocked ? .offerDroppedBlocked : .offerDroppedUnchanged, kind: candidate.kind)
            return
        }
        guard managed?.epoch.map({ manager(epoch: $0) != nil }) ?? true else { return }
        let previous = current?.id
        offers.removeAll { $0.candidate.kind == candidate.kind }
        if candidate.kind == .password {
            websiteOffer = nil
        }
        offers.append(Offer(
            candidate: candidate, origin: origin, isUpdate: decision == .update, fingerprint: fingerprint, documentID: documentID,
            liveOrigin: liveOrigin, plan: managed?.plan, managerEpoch: managed?.epoch, managerRevision: managed?.revision, loginURL: managed?.loginURL,
            needsVault: managed?.needsVault ?? false
        ))
        if managed?.needsVault == true {
            AutofillSaveCoordinator.shared.vaultSetupWasOffered(for: profileID)
        }
        if current?.id != previous {
            isPopoverPresented = true
            error = nil
        }
        AutofillDiagnostics.note(.saveOffered, kind: candidate.kind)
        scheduleExpiry()
    }
    /// An offer, or the note that its page changed, stays for two minutes.
    private func scheduleExpiry() {
        expiry?.cancel(); expiry = Task { [weak self] in try? await Task.sleep(for: .seconds(120)); guard !Task.isCancelled else { return }; self?.clear() }
    }
    func dismiss(_ offer: Offer, rememberingChoice: Bool = true) {
        if rememberingChoice {
            remember(offer.fingerprint, kind: offer.candidate.kind)
        }
        offers.removeAll { $0.id == offer.id }; isPopoverPresented = !offers.isEmpty; error = nil
    }
    private func remember(_ fingerprint: String, kind: AutofillSaveKind) {
        var values = dismissed[kind] ?? []
        if values.count >= 100 {
            values.removeAll()
        }
        values.insert(fingerprint)
        dismissed[kind] = values
    }

    // MARK: - Adding a website to a sibling's credential

    private func websiteFingerprint(origin: String, accountID: UUID) -> String {
        let bytes = (try? JSONEncoder().encode([origin, "website", accountID.uuidString])) ?? Data()
        return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: fingerprintKey)).base64EncodedString()
    }

    /// The one credential, in the profile's unlocked vaults, that `login` repeats exactly (username and password) on a sibling
    /// website of `origin` and that has room for `origin`, while no credential for `origin` itself has that username. Saving the
    /// login would make a copy of it, so adding the website is offered instead. Several such credentials are never guessed between.
    private func siblingAccount(for login: SavedPassword, origin: String) async -> (accountID: UUID, epoch: UInt64)? {
        guard let context, !context.profile.isPrivate, let page, page.context === context, let origin = managerOrigin(origin),
              CredentialAccountSelection.site(of: origin) != nil,
              let listing = try? await CredentialManager.store(for: context.profile).listing() else { return nil }
        let listed = Set(listing.map(\.vaultID))
        var found: [(accountID: UUID, epoch: UInt64)] = []
        for manager in CredentialManager.unlockedManagers(for: context.profile) where listed.contains(manager.vaultID) {
            guard let epoch = manager.authorizationEpoch, let snapshot = try? await manager.snapshot(),
                  manager.authorizationEpoch == epoch else { continue }
            if snapshot.accounts.contains(where: { $0.origins.contains(origin) && $0.username == login.username }) {
                return nil
            }
            for (account, _) in CredentialAccountSelection.siblings(in: snapshot.accounts, origin: origin, entered: nil)
            where account.username == login.username && account.password == login.password
                && CredentialAccountSelection.canAddWebsite(origin, to: account) {
                found.append((accountID: account.id, epoch: epoch))
            }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// Offers to add `origin` to the credential `accountID` of the vault leased under `epoch`: a credential of a sibling website
    /// that was just filled here, or whose login was just submitted here. Nothing is written until `addWebsite`, and only then.
    func offerWebsite(accountID: UUID, epoch: UInt64, origin: String, documentID: String, liveOrigin: String? = nil) async {
        guard let context, AutofillSaveCoordinator.shared.isEnabled(.password, context: context),
              let page, page.context === context, let origin = managerOrigin(origin), let manager = manager(epoch: epoch) else { return }
        let revision = revision
        let liveOrigin = liveOrigin ?? origin
        let fingerprint = websiteFingerprint(origin: origin, accountID: accountID)
        guard websiteOffer?.fingerprint != fingerprint else { return }
        guard dismissed[.password]?.contains(fingerprint) != true else {
            AutofillDiagnostics.note(.offerDroppedDismissed, kind: .password)
            return
        }
        guard let snapshot = try? await manager.snapshot(), self.manager(epoch: epoch) === manager, revision == self.revision else { return }
        guard !snapshot.blockedPasswordOrigins.contains(origin) else {
            AutofillDiagnostics.note(.offerDroppedBlocked, kind: .password)
            return
        }
        guard let account = snapshot.accounts.first(where: { $0.id == accountID }),
              CredentialAccountSelection.canAddWebsite(origin, to: account) else { return }
        if !documentID.isEmpty, await !liveness(page, documentID, liveOrigin) {
            AutofillDiagnostics.note(.offerDroppedNotLive, kind: .password)
            return
        }
        // The reads suspend: whatever they waited through (a clear, a policy change, a lock, another offer) is checked again.
        guard revision == self.revision, self.context === context, page.context === context, self.manager(epoch: epoch) === manager,
              AutofillSaveCoordinator.shared.isEnabled(.password, context: context), websiteOffer?.fingerprint != fingerprint,
              dismissed[.password]?.contains(fingerprint) != true else { return }
        offers.removeAll { $0.candidate.kind == .password }
        websiteOffer = WebsiteOffer(
            origin: origin, accountID: accountID,
            name: CredentialAccountSelection.title(account, origin: account.origins.first ?? origin), username: account.username,
            managerEpoch: epoch, documentID: documentID, liveOrigin: liveOrigin, fingerprint: fingerprint
        )
        isPopoverPresented = true
        error = nil
        AutofillDiagnostics.note(.saveOffered, kind: .password)
        scheduleExpiry()
    }

    /// Adds the offer's website to its credential through the vault's ordinary commit, so History keeps the earlier list of websites.
    /// Only the credential that was offered, only under the unlock it was offered under, and only while it still has room for it.
    func addWebsite(_ offer: WebsiteOffer) async {
        guard !isBusy, websiteOffer?.id == offer.id, let context, AutofillSaveCoordinator.shared.isEnabled(.password, context: context),
              let page, page.context === context, page.window != nil else { return }
        guard await liveness(page, offer.documentID, offer.liveOrigin) else {
            guard self.context === context, websiteOffer?.id == offer.id else { return }
            AutofillDiagnostics.note(.offerDroppedNotLive, kind: .password)
            error = String(localized: "This page changed, so nothing was saved.")
            return
        }
        guard self.context === context, websiteOffer?.id == offer.id else { return }
        isBusy = true; error = nil; defer { isBusy = false }
        do {
            guard let manager = manager(epoch: offer.managerEpoch) else { throw CredentialVaultError.unauthorized }
            let snapshot = try await manager.snapshot()
            guard self.manager(epoch: offer.managerEpoch) === manager else { throw CredentialVaultError.unauthorized }
            guard !snapshot.blockedPasswordOrigins.contains(offer.origin),
                  snapshot.accounts.first(where: { $0.id == offer.accountID })?.username == offer.username else {
                throw CredentialVaultError.staleRevision
            }
            let accounts = try CredentialAccountSelection.addingWebsite(offer.origin, to: offer.accountID, in: snapshot.accounts)
            _ = try await manager.commit(
                accounts, expectedRevision: snapshot.revision, authorizedEpoch: offer.managerEpoch, cause: CredentialChangeCause.addWebsite
            )
            guard self.context === context, websiteOffer?.id == offer.id else { return }
            dismissWebsite(offer, rememberingChoice: false)
        } catch {
            guard self.context === context, websiteOffer?.id == offer.id else { return }
            if Self.isLocked(error) {
                dismissWebsite(offer, rememberingChoice: false)
                return
            }
            self.error = String(localized: "Couldn’t add this website. Try again.")
        }
    }

    /// "Not Now": nothing is written, and the same website is not offered for the same credential again on this page.
    func dismissWebsite(_ offer: WebsiteOffer, rememberingChoice: Bool = true) {
        if rememberingChoice {
            remember(offer.fingerprint, kind: .password)
        }
        guard websiteOffer?.id == offer.id else { return }
        websiteOffer = nil; isPopoverPresented = !offers.isEmpty; error = nil
    }
    func never(_ offer: Offer) async {
        guard !offer.needsVault, !isBusy, current?.id == offer.id, let context else { return }
        isBusy = true; let profileID = context.profile.id; defer { isBusy = false }
        do {
            if offer.candidate.kind == .password {
                try await blockManaged(offer)
            } else {
                try await Task.detached { try AutofillSaveIndex.block(kind: offer.candidate.kind, origin: offer.origin, profileID: profileID) }.value
            }
            if self.context === context && current?.id == offer.id {
                dismiss(offer)
            }
        } catch {
            guard self.context === context && current?.id == offer.id else { return }
            if Self.isLocked(error) {
                dismiss(offer, rememberingChoice: false)
                return
            }
            self.error = String(localized: "Couldn’t remember this choice. Try again.")
        }
    }

    private static func isLocked(_ error: any Error) -> Bool {
        switch error {
        case CredentialVaultError.unauthorized, CredentialVaultError.expired:
            true
        default:
            false
        }
    }

    /// The vault a save or a "never" acts on. An offer made against one unlocked vault names it by its lease. An offer made while
    /// the route needed a choice or an unlock asks now, on the user's click, and unlocks the choice through that vault's manager;
    /// the page and the offer are checked again before the result is used.
    func target(for offer: Offer, username: String) async throws -> CredentialManager {
        if let epoch = offer.managerEpoch {
            guard let manager = manager(epoch: epoch) else { throw CredentialVaultError.unauthorized }
            return manager
        }
        guard let context, let page, let window = page.window, let origin = managerOrigin(offer.origin) else {
            throw CredentialVaultError.unauthorized
        }
        let generation = accessGeneration
        let route = await CredentialRouting.route(profile: context.profile, origin: origin, username: username)
        // The choice runs as a task `vaultAccessEnded` can cancel: a lock, profile switch or retire dismisses the open prompt.
        let picking = Task { await route.resolve(profile: context.profile, in: window) }
        choosing = picking
        let selected = await picking.value
        choosing = nil
        // Authority is checked again after every suspension, and the last check is synchronous with the unlock's start: a vault the
        // user locked (or whose profile was left) while choosing is never unlocked by that old answer.
        func authorized(_ chosen: CredentialManager) -> Bool {
            generation == accessGeneration && self.context === context && page.context === context && page.window === window
                && current?.id == offer.id && !context.profile.isPrivate && chosen.profileID == context.profile.id
        }
        guard let chosen = selected, authorized(chosen),
              await liveness(page, offer.documentID, offer.liveOrigin),
              authorized(chosen) else { throw CredentialVaultError.unauthorized }
        if !chosen.isUnlocked {
            do { try await chosen.unlock(in: window) } catch { throw CredentialVaultError.unauthorized }
        }
        guard generation == accessGeneration, manager(epoch: chosen.authorizationEpoch) === chosen,
              self.context === context, page.context === context, current?.id == offer.id else { throw CredentialVaultError.unauthorized }
        return chosen
    }

    private func blockManaged(_ offer: Offer) async throws {
        guard case .password(let login) = offer.candidate, let origin = managerOrigin(offer.origin) else {
            throw CredentialVaultError.unauthorized
        }
        let manager = try await target(for: offer, username: login.username)
        guard let epoch = offer.managerEpoch ?? manager.authorizationEpoch, self.manager(epoch: epoch) === manager else {
            throw CredentialVaultError.unauthorized
        }
        let snapshot = try await manager.snapshot()
        guard self.manager(epoch: epoch) === manager else { throw CredentialVaultError.unauthorized }
        _ = try await manager.updatePasswordSavePolicy(
            snapshot.blockedPasswordOrigins.union([origin]), expectedRevision: snapshot.revision, authorizedEpoch: epoch
        )
    }

    /// Saves only into the exact account the user was shown. Whatever was typed in the review form, a different target
    /// writes nothing here and is reported as `.needsReview` so the caller can show that target for confirmation.
    private func saveManaged(_ login: SavedPassword, offer: Offer, manager: CredentialManager) async throws -> CredentialSaveOutcome {
        guard let epoch = offer.managerEpoch ?? manager.authorizationEpoch, self.manager(epoch: epoch) === manager,
              let origin = managerOrigin(offer.origin) else { throw CredentialVaultError.unauthorized }
        let snapshot = try await manager.snapshot()
        guard self.manager(epoch: epoch) === manager else { throw CredentialVaultError.unauthorized }
        guard !snapshot.blockedPasswordOrigins.contains(origin) else { throw CredentialVaultError.staleRevision }
        return try await CredentialAccountSelection.commitSave(
            login, origin: origin, offered: offer.plan, loginURL: offer.loginURL, snapshot: snapshot, manager: manager, epoch: epoch
        )
    }

    func save(_ offer: Offer, replacement: AutofillSaveCandidate? = nil) async {
        guard !offer.needsVault, !isBusy, current?.id == offer.id, let context,
              AutofillSaveCoordinator.shared.isEnabled(offer.candidate.kind, context: context),
              let page, page.context === context, page.window != nil else { return }
        guard await liveness(page, offer.documentID, offer.liveOrigin) else {
            // The page the offer was made on is gone. Keep the offer, saveless, so the popover can say why instead of doing nothing.
            guard self.context === context, current?.id == offer.id, let index = offers.firstIndex(where: { $0.id == offer.id }) else { return }
            AutofillDiagnostics.note(.offerDroppedNotLive, kind: offer.candidate.kind)
            offers[index].isGone = true
            error = String(localized: "This page changed, so nothing was saved.")
            scheduleExpiry()
            return
        }
        guard self.context === context, current?.id == offer.id else { return }
        let candidate = replacement ?? offer.candidate
        guard candidate.kind == offer.candidate.kind else { return }
        if case .password(let password) = candidate, password.origin != offer.origin {
            return
        }
        isBusy = true; error = nil; let profileID = context.profile.id; defer { isBusy = false }
        do {
            switch candidate {
            case .password(let login):
                let manager = try await target(for: offer, username: login.username)
                if try await saveManaged(login, offer: offer, manager: manager) == .needsReview {
                    // The save would land somewhere other than what this offer showed: nothing was written. Show the
                    // new target through the normal offer so the user confirms that exact account.
                    guard self.context === context, current?.id == offer.id else { return }
                    dismiss(offer, rememberingChoice: false)
                    await self.offer(candidate, origin: offer.origin, documentID: offer.documentID, liveOrigin: offer.liveOrigin, loginURL: offer.loginURL, target: manager)
                    return
                }
            case .card(let card):
                _ = try await AutofillVaults.cards(for: profileID).importCards([card], preservingMissingSecurityCodes: replacement == nil)
            case .contact(let contact):
                _ = try await AutofillVaults.contacts(for: profileID).update { contacts in
                    guard !contacts.contains(where: { AutofillSaveCandidate.contact($0).values == candidate.values }) else { return contacts }
                    guard contacts.count < 100 else { throw AutofillVaultError.invalidData }
                    return contacts + [contact]
                }
            }
            guard self.context === context, page.context === context,
                  await liveness(page, offer.documentID, offer.liveOrigin),
                  current?.id == offer.id else { return }
            dismiss(offer, rememberingChoice: false)
        } catch {
            guard self.context === context && current?.id == offer.id else { return }
            if Self.isLocked(error) {
                dismiss(offer, rememberingChoice: false)
                return
            }
            self.error = String(localized: "Couldn’t save these details. Try again.")
        }
    }
}

@MainActor
final class AutofillSaveCoordinator {
    static let shared = AutofillSaveCoordinator()
    private static let world = AutofillPage.world
    private let sessions = NSMapTable<BrowserPage, AutofillSaveSession>.weakToWeakObjects()
    private var frames: [ObjectIdentifier: FrameList] = [:]
    private var observers: [NSObjectProtocol] = []
    private var sessionIsActive = true
    private var screenIsLocked = false

    private final class FrameList {
        var values: [String: BrowserFrame] = [:]
        var mainDocumentID: String?
    }

    private init() {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionIsActive = false; self?.clear(); self?.refreshPolicy() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionIsActive = true; self?.refreshPolicy() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenIsLocked = true; self?.clear(); self?.refreshPolicy() }
        })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenIsLocked = false; self?.refreshPolicy() }
        })
    }
    private func clear() {
        AutofillSuggestions.shared.reset(); frames.removeAll()
        for session in sessions.objectEnumerator()?.allObjects as? [AutofillSaveSession] ?? [] {
            session.clear()
        }
    }
    /// The profile's vault access ended: every pending vault choice of its pages, and an unlock the dropdown asked for, is withdrawn
    /// synchronously.
    func vaultAccessEnded(profileID: UUID) {
        AutofillSuggestions.shared.vaultAccessEnded(profileID: profileID)
        for session in sessions.objectEnumerator()?.allObjects as? [AutofillSaveSession] ?? []
        where session.context?.profile.id == profileID {
            session.vaultAccessEnded()
        }
    }
    func resetDismissals(kind: AutofillSaveKind, context: BrowserProfileContext) {
        for session in sessions.objectEnumerator()?.allObjects as? [AutofillSaveSession] ?? []
        where session.context === context {
            session.resetDismissals(kind: kind)
        }
    }
    func resetDismissals(kind: AutofillSaveKind, profileID: UUID) {
        for session in sessions.objectEnumerator()?.allObjects as? [AutofillSaveSession] ?? []
        where session.context?.profile.id == profileID {
            session.resetDismissals(kind: kind)
        }
    }

    /// Profiles that were offered the setup of their first vault in this run of the app. The offer is made once, so a page cannot
    /// nag; the next run (or a vault) starts over.
    private var vaultSetupOffered: Set<UUID> = []
    func shouldOfferVaultSetup(for profileID: UUID) -> Bool {
        !vaultSetupOffered.contains(profileID)
    }
    func vaultSetupWasOffered(for profileID: UUID) {
        vaultSetupOffered.insert(profileID)
    }
    func session(for page: BrowserPage) -> AutofillSaveSession? {
        sessions.object(forKey: page).flatMap { $0.context === page.context ? $0 : nil }
    }
    func rememberFilledUsername(
        _ value: String, origin: String, documentID: String, in page: BrowserPage, accountID: UUID? = nil, epoch: UInt64? = nil
    ) {
        guard !value.isEmpty, value.count <= 500, isEnabled(.password, context: page.context),
              let session = sessions.object(forKey: page), session.context === page.context else { return }
        if let accountID {
            session.selectAccount(accountID, username: value, in: page, origin: origin, documentID: documentID, epoch: epoch)
            return
        }
        var step = AutofillSaveSession.UsernameStep(origin: origin, value: value, documentID: documentID, attemptID: UUID()); step.completed = true; session.username = step
    }
    func isEnabled(_ kind: AutofillSaveKind, context: BrowserProfileContext) -> Bool {
        guard sessionIsActive, !screenIsLocked, !context.profile.isPrivate else { return false }
        switch kind {
        case .password:
            return PasswordAutofill.shared.isEnabled(in: context)
        case .card:
            return context.settings.fillsPaymentCards
        case .contact:
            return context.settings.fillsContacts
        }
    }

    func install(in page: BrowserPage, session: AutofillSaveSession) {
        session.attach(to: page, context: page.context); sessions.setObject(session, forKey: page)
        page.installScript(AutofillFormScript.source + AutofillSuggestionScript.source, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(AutofillSaveScript.clientSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: "wsurfAutofillSave", in: Self.world) { [weak self] message in self?.receive(message) }
    }

    func refreshPolicy() {
        AutofillSuggestions.shared.reset()
        for page in sessions.keyEnumerator().allObjects.compactMap({ $0 as? BrowserPage }) {
            sessions.object(forKey: page)?.refreshPolicy()
            for frame in frames[ObjectIdentifier(page)].map({ Array($0.values.values) }) ?? [] {
                applyPolicy(in: page, frame: frame)
            }
        }
    }
    private func applyPolicy(in page: BrowserPage, frame: BrowserFrame) {
        let context = page.context
        guard let session = sessions.object(forKey: page), session.page === page, session.context === context else { return }
        let origin = frame.securityOrigin, topURL = page.url
        let secure = frame.hasTrustedSecurityOrigin && origin.protocol == "https" && !origin.host.isEmpty && topURL.flatMap(SavedPassword.origin(for:)) != nil
        let policy = Dictionary(uniqueKeysWithValues: AutofillSaveKind.allCases.map { ($0.rawValue, secure && isEnabled($0, context: context)) })
        Task {
            do {
                guard page.context === context, session.context === context else { return }
                _ = try await page.callAsyncJavaScript("globalThis.__wsurfAutofillSave?.setPolicy(policy);", arguments: ["policy": policy], in: frame, contentWorld: Self.world)
            } catch {
                AutofillDiagnostics.policyFailed(.save, error: error, isMainFrame: frame.isMainFrame)
            }
        }
    }
    func pageStates(in page: BrowserPage) async -> [AutofillSubmissionTracker.PageState]? {
        let context = page.context
        guard let session = sessions.object(forKey: page), session.context === context,
              let list = frames[ObjectIdentifier(page)], let mainID = list.mainDocumentID, list.values[mainID] != nil else { return nil }
        let entries = [(mainID, list.values[mainID]!)] + list.values.filter { $0.key != mainID }
        var result: [AutofillSubmissionTracker.PageState] = []
        for (id, frame) in entries {
            let raw = try? await page.callAsyncJavaScript("return globalThis.__wsurfAutofillForms?.summary();", arguments: [:], in: frame, contentWorld: Self.world)
            guard page.context === context, session.context === context,
                  frames[ObjectIdentifier(page)] === list, list.mainDocumentID == mainID else { return nil }
            guard let state = AutofillSubmissionTracker.PageState(raw), state.documentID == id,
                  frame.hasTrustedSecurityOrigin, frame.securityOrigin.protocol == state.url.scheme, frame.securityOrigin.host == state.url.host?.lowercased(),
                  (frame.securityOrigin.port == 0 ? 443 : frame.securityOrigin.port) == (state.url.port ?? 443) else { if id == mainID { return nil }; list.values[id] = nil; continue }
            result.append(state)
        }
        return result
    }
    func isLive(page: BrowserPage, documentID: String, origin: String) async -> Bool {
        let context = page.context
        guard let session = sessions.object(forKey: page), session.context === context,
              !context.profile.isPrivate, page.hasOnlySecureContent,
              page.url.flatMap(SavedPassword.origin(for:)) != nil,
              let expected = URL(string: origin), SavedPassword.origin(for: expected) == origin else { return false }
        func matches(_ frame: BrowserFrame) -> Bool {
            frame.hasTrustedSecurityOrigin && frame.securityOrigin.protocol == expected.scheme?.lowercased()
                && frame.securityOrigin.host == expected.host?.lowercased()
                && (frame.securityOrigin.port == 0 ? 443 : frame.securityOrigin.port) == (expected.port ?? 443)
        }
        guard let list = frames[ObjectIdentifier(page)], let frame = list.values[documentID], matches(frame) else { return false }
        if let chromium = page.chromium {
            let live = (try? await chromium.isLive(frame: frame)) == true
            return live && page.context === context && session.context === context && frames[ObjectIdentifier(page)] === list
        }
        let current = try? await page.callAsyncJavaScript("return globalThis.__wsurfAutofillForms?.documentID;", arguments: [:], in: frame.isMainFrame ? nil : frame, contentWorld: Self.world)
        return page.context === context && session.context === context && frames[ObjectIdentifier(page)] === list && current as? String == documentID
    }
    /// Whether the tab registered this document. A login staged by a document that is already gone (the next page announced itself first)
    /// has nothing to be offered against, which is worth a trace.
    private func isRegistered(_ documentID: String, in key: ObjectIdentifier, action: String) -> Bool {
        let known = frames[key]?.values[documentID] != nil
        if !known, action == "stage" {
            AutofillDiagnostics.note(.stageDroppedUnknownDocument, kind: .password)
        }
        return known
    }
    private func receive(_ message: BrowserScriptMessage) {
        guard let session = sessions.object(forKey: message.page), let context = session.context, context === message.page.context,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        let page = message.page, key = ObjectIdentifier(page)
        if action == "ready" {
            AutofillDiagnostics.note(.saveScriptReady, kind: .password)
            guard let documentID = body["documentID"] as? String, UUID(uuidString: documentID) != nil else { return }
            let list = frames[key] ?? FrameList(); if message.frameInfo.isMainFrame, list.mainDocumentID != documentID { list.mainDocumentID = documentID; list.values = [:] }
            if list.values[documentID] == nil, list.values.count >= 100,
               let oldest = list.values.keys.first(where: { $0 != list.mainDocumentID }) {
                list.values[oldest] = nil
            }
            list.values[documentID] = message.frameInfo
            frames[key] = list
            applyPolicy(in: page, frame: message.frameInfo)
            return
        }
        guard page.window != nil, !page.isHiddenOrHasHiddenAncestor, page.hasOnlySecureContent,
              let documentID = body["documentID"] as? String, isRegistered(documentID, in: key, action: action),
              let topURL = page.url, SavedPassword.origin(for: topURL) != nil,
              let rawURL = body["url"] as? String, let url = URL(string: rawURL), let origin = SavedPassword.origin(for: url),
              message.frameInfo.hasTrustedSecurityOrigin, message.frameInfo.securityOrigin.protocol == "https", message.frameInfo.securityOrigin.host == url.host?.lowercased(),
              (message.frameInfo.securityOrigin.port == 0 ? 443 : message.frameInfo.securityOrigin.port) == (url.port ?? 443) else { return }
        if action == "diagnostic", let value = body["event"] as? String,
           let event = AutofillDiagnostics.Event(rawValue: value),
           [.editNoScope, .editDisabled, .editRecorded, .submitNoEdits, .submitInvalid, .submitCaptured, .captureAbandonedByLink, .captureUnsafeAction].contains(event) {
            AutofillDiagnostics.note(event, kind: .password)
            return
        }
        guard let rawAttemptID = body["attemptID"] as? String, let attemptID = UUID(uuidString: rawAttemptID), let formID = body["formID"] as? String, Int(formID) ?? 0 > 0 else { return }
        if action == "discard" {
            if session.username?.attemptID == attemptID {
                session.username = nil
            }
            session.submissions.discard(id: attemptID, documentID: documentID, formID: formID)
            return
        }
        if action == "complete" {
            if session.username?.attemptID == attemptID {
                session.username?.completed = true
            }
            session.submissions.complete(id: attemptID, documentID: documentID, formID: formID)
            return
        }
        guard action == "stage", let source = body["source"] as? String,
              ["submit", "interaction", "automatic", "pagehide"].contains(source) else { return }
        if source != "pagehide", isEnabled(.password, context: context),
           let value = body["username"] as? String, !value.isEmpty, value.count <= 500 {
            session.stageUsername(value, origin: origin, documentID: documentID, attemptID: attemptID, in: page)
        }
        var candidates: [AutofillSaveCandidate] = []
        if isEnabled(.password, context: context), let login = body["password"] as? [String: String], let password = login["password"] {
            var username = login["username"] ?? ""
            if username.isEmpty, let remembered = session.username, remembered.origin == origin,
               remembered.completed || remembered.documentID != documentID,
               Date.now.timeIntervalSince(remembered.date) < 300 {
                username = remembered.value
            }
            if let record = try? SavedPassword(website: origin, username: username, password: password) {
                candidates.append(.password(record))
            }
        }
        if isEnabled(.card, context: context),
           let values = body["card"] as? [String: String], values["cc-number"]?.count ?? 0 <= 32,
           let number = values["cc-number"], let month = values["cc-exp-month"].flatMap(Int.init),
           let year = values["cc-exp-year"].flatMap(Int.init),
           let card = try? PaymentCard(
               number: number,
               cardholder: values["cc-name"] ?? "",
               month: month,
               year: year,
               securityCode: values["cc-csc"]
           ), !card.isExpired() {
            candidates.append(.card(card))
        }
        if isEnabled(.contact, context: context),
           let values = body["contact"] as? [String: String],
           values.count <= 16, values.values.allSatisfy({ $0.count <= 500 }) {
            var contact = AutofillContact()
            contact.givenName = values["given-name"] ?? values["name"] ?? ""
            contact.familyName = values["family-name"] ?? ""
            contact.organization = values["organization"] ?? ""
            contact.email = values["email"] ?? ""
            contact.phone = values["tel"] ?? ""
            contact.street = values["street-address"] ?? [
                values["address-line1"],
                values["address-line2"],
                values["address-line3"],
            ].compactMap { $0 }.joined(separator: "\n")
            contact.city = values["address-level2"] ?? ""
            contact.region = values["address-level1"] ?? ""
            contact.postalCode = values["postal-code"] ?? ""
            contact.countryCode = (values["country"] ?? "").uppercased()
            if contact.isValid, (!contact.street.isEmpty && !contact.name.isEmpty) || !contact.email.isEmpty {
                candidates.append(.contact(contact))
            }
        }
        session.submissions.stage(
            id: attemptID, documentID: documentID, formID: formID, origin: origin, loginURL: url,
            candidates: candidates, frame: message.frameInfo, source: source
        )
    }
}
