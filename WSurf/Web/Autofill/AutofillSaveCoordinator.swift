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
        let documentID: String
        /// Password offers carry the store they were made for; a switch of provider retires them.
        var provider: PasswordProvider = .legacy
        /// Manager offers: what saving does, to which exact account, against which unlocked vault state.
        var plan: CredentialSavePlan?
        var managerEpoch: UInt64?
        var managerRevision: UInt64?
        var loginURL: URL?
    }
    private(set) var offers: [Offer] = []
    private(set) var isBusy = false
    private(set) var error: String?
    var isPopoverPresented = false
    private(set) var profileID = Profile.privateID
    @ObservationIgnored weak var page: BrowserPage?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var dismissed: [AutofillSaveKind: Set<String>] = [:]
    @ObservationIgnored private let fingerprintKey = SymmetricKey(size: .bits256)
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// `accountID` and what follows are only set when the user picked a credential manager account. They carry
    /// identity, never a secret or code, and `deadline` is fixed when the account is picked.
    struct UsernameStep {
        let origin: String; let value: String; let documentID: String; let attemptID: UUID; let date = Date.now; var completed = false
        var accountID: UUID?; var profileID: UUID?; var tab: ObjectIdentifier?
        var deadline: ContinuousClock.Instant?; var epoch: UInt64?
    }
    @ObservationIgnored var username: UsernameStep?
    @ObservationIgnored let submissions = AutofillSubmissionTracker()

    var current: Offer? {
        offers.first
    }

    func attach(to page: BrowserPage, profileID: UUID) {
        clear(); self.page = page; self.profileID = profileID; submissions.attach(to: self); dismissed = [:]
    }
    func clear() {
        revision += 1; offers = []; isPopoverPresented = false; username = nil; submissions.clear(); error = nil
        expiry?.cancel(); expiry = nil
    }
    func refreshPolicy() {
        revision += 1; submissions.clear()
        let provider = PasswordAutofill.shared.provider
        offers.removeAll {
            !AutofillSaveCoordinator.shared.isEnabled($0.candidate.kind, profileID: profileID)
                || ($0.candidate.kind == .password && $0.provider != provider)
        }
        if offers.isEmpty {
            isPopoverPresented = false
        }
        username?.accountID = nil
        if !AutofillSaveCoordinator.shared.isEnabled(.password, profileID: profileID) {
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
        guard self.page === page, page.profileID == profileID, let step = username, let accountID = step.accountID,
              step.profileID == profileID, step.tab == ObjectIdentifier(page) else { return nil }
        if let epoch, let picked = step.epoch, epoch < picked { return nil }
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
        guard self.page === page, page.profileID == profileID, !username.isEmpty, username.count <= 500 else { return }
        var step = UsernameStep(origin: origin, value: username, documentID: documentID, attemptID: UUID())
        step.completed = true
        step.accountID = id; step.profileID = profileID; step.tab = ObjectIdentifier(page)
        step.deadline = now.advanced(by: .seconds(300)); step.epoch = epoch
        self.username = step
    }

    /// A username seen on a submitted or interacted step. The picked account rides along only for the same tab,
    /// profile, origin and username, and keeps its original deadline; any other username starts a plain step.
    func stageUsername(_ value: String, origin: String, documentID: String, attemptID: UUID, in page: BrowserPage) {
        var step = UsernameStep(origin: origin, value: value, documentID: documentID, attemptID: attemptID)
        if let previous = username, previous.accountID != nil, previous.origin == origin, previous.value == value,
           previous.profileID == profileID, previous.tab == ObjectIdentifier(page), self.page === page {
            step.accountID = previous.accountID; step.profileID = previous.profileID; step.tab = previous.tab
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

    func receive(_ candidates: [AutofillSaveCandidate], origin: String, documentID: String = "") {
        let revision = revision
        Task { [weak self] in
            guard let self else { return }
            for candidate in candidates {
                guard revision == self.revision else { return }
                await offer(candidate, origin: origin, documentID: documentID)
            }
        }
    }
    private struct ManagedSave {
        let plan: CredentialSavePlan
        let epoch: UInt64
        let revision: UInt64
        let loginURL: URL?
    }

    private func managerOrigin(_ origin: String) -> String? {
        URL(string: origin).flatMap(CredentialAccountSelection.origin(for:)) == origin ? origin : nil
    }

    private func manager(epoch: UInt64?) -> CredentialManager? {
        let profile = PasswordAutofill.shared.profile
        guard let epoch, profile.id == profileID, PasswordAutofill.shared.provider == .credentialManager,
              let manager = try? CredentialManager.forProfile(profile), manager.authorizationEpoch == epoch else { return nil }
        return manager
    }

    /// What the unlocked vault would do with `login`; `nil` when there is nothing to offer, including when locked.
    /// The carry-over lookup can invalidate the picked account, so it runs only once the document is confirmed live
    /// and with no suspension between the last `revision` check and the lookup.
    private func managedPlan(for login: SavedPassword, origin: String, documentID: String, revision: Int) async -> ManagedSave? {
        let profile = PasswordAutofill.shared.profile
        guard profile.id == profileID, let page, let origin = managerOrigin(origin),
              documentID.isEmpty ? true : await AutofillSaveCoordinator.shared.isLive(page: page, documentID: documentID, origin: origin),
              let manager = try? CredentialManager.forProfile(profile), let epoch = manager.authorizationEpoch,
              let snapshot = try? await manager.snapshot(), self.manager(epoch: epoch) != nil,
              revision == self.revision, self.page === page,
              !snapshot.blockedPasswordOrigins.contains(origin) else { return nil }
        let selected = selectedAccount(in: page, origin: origin, enteredUsername: login.username, epoch: epoch)
        let plan = CredentialAccountSelection.savePlan(for: login, origin: origin, accountID: selected, in: snapshot.accounts)
        guard plan != .unchanged, plan != .ambiguous else { return nil }
        return ManagedSave(
            plan: plan, epoch: epoch, revision: snapshot.revision,
            loginURL: page.url.flatMap { CredentialAccountSelection.loginURL(for: $0, origin: origin) }
        )
    }

    func offer(_ candidate: AutofillSaveCandidate, origin: String, documentID: String = "") async {
        guard AutofillSaveCoordinator.shared.isEnabled(candidate.kind, profileID: profileID) else { return }
        let bytes = (try? JSONEncoder().encode([origin, candidate.kind.rawValue] + candidate.values)) ?? Data()
        let fingerprint = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: fingerprintKey)).base64EncodedString()
        guard dismissed[candidate.kind]?.contains(fingerprint) != true, !offers.contains(where: { $0.fingerprint == fingerprint }) else { return }
        let revision = revision, profileID = profileID
        let provider = candidate.kind == .password ? PasswordAutofill.shared.provider : .legacy
        var managed: ManagedSave?
        let decision: AutofillSaveIndex.Decision
        if provider == .credentialManager, case .password(let login) = candidate {
            guard let found = await managedPlan(for: login, origin: origin, documentID: documentID, revision: revision) else { return }
            managed = found
            decision = found.plan == .create ? .new : .update
        } else {
            decision = await Task.detached { (try? AutofillSaveIndex.decision(for: candidate, origin: origin, profileID: profileID)) ?? .new }.value
        }
        guard revision == self.revision, let page, page.profileID == profileID, !page.isPrivate,
              page.url.flatMap(SavedPassword.origin(for:)) != nil,
              candidate.kind != .password || PasswordAutofill.shared.provider == provider,
              documentID.isEmpty ? true : await AutofillSaveCoordinator.shared.isLive(page: page, documentID: documentID, origin: origin),
              AutofillSaveCoordinator.shared.isEnabled(candidate.kind, profileID: profileID),
              dismissed[candidate.kind]?.contains(fingerprint) != true, !offers.contains(where: { $0.fingerprint == fingerprint }),
              decision != .unchanged, decision != .blocked,
              managed.map({ manager(epoch: $0.epoch) != nil }) ?? true else { return }
        let previous = current?.id
        offers.removeAll { $0.candidate.kind == candidate.kind }
        offers.append(Offer(
            candidate: candidate, origin: origin, isUpdate: decision == .update, fingerprint: fingerprint, documentID: documentID,
            provider: provider, plan: managed?.plan, managerEpoch: managed?.epoch, managerRevision: managed?.revision,
            loginURL: managed?.loginURL
        ))
        if current?.id != previous {
            isPopoverPresented = true
        }
        AutofillDiagnostics.note(.saveOffered, kind: candidate.kind)
        expiry?.cancel(); expiry = Task { [weak self] in try? await Task.sleep(for: .seconds(120)); guard !Task.isCancelled else { return }; self?.clear() }
    }
    func dismiss(_ offer: Offer, rememberingChoice: Bool = true) {
        if rememberingChoice {
            var values = dismissed[offer.candidate.kind] ?? []
            if values.count >= 100 {
                values.removeAll()
            }
            values.insert(offer.fingerprint)
            dismissed[offer.candidate.kind] = values
        }
        offers.removeAll { $0.id == offer.id }; isPopoverPresented = !offers.isEmpty; error = nil
    }
    func never(_ offer: Offer) async {
        guard !isBusy, current?.id == offer.id else { return }
        isBusy = true; let profileID = profileID; defer { isBusy = false }
        do {
            if offer.provider == .credentialManager {
                try await blockManaged(offer)
            } else {
                try await Task.detached { try AutofillSaveIndex.block(kind: offer.candidate.kind, origin: offer.origin, profileID: profileID) }.value
            }
            if self.profileID == profileID && current?.id == offer.id {
                dismiss(offer)
            }
        } catch {
            guard self.profileID == profileID && current?.id == offer.id else { return }
            if Self.isLocked(error) { dismiss(offer, rememberingChoice: false); return }
            self.error = String(localized: "Couldn’t remember this choice. Try again.")
        }
    }

    private static func isLocked(_ error: any Error) -> Bool {
        switch error {
        case CredentialVaultError.unauthorized, CredentialVaultError.expired: true
        default: false
        }
    }

    private func blockManaged(_ offer: Offer) async throws {
        guard let manager = self.manager(epoch: offer.managerEpoch), let epoch = offer.managerEpoch,
              let origin = managerOrigin(offer.origin) else { throw CredentialVaultError.unauthorized }
        let snapshot = try await manager.snapshot()
        guard self.manager(epoch: epoch) != nil else { throw CredentialVaultError.unauthorized }
        _ = try await manager.updatePasswordSavePolicy(snapshot.blockedPasswordOrigins.union([origin]), expectedRevision: snapshot.revision)
    }

    /// Saves only into the exact account the user was shown. Whatever was typed in the review form, a different target
    /// writes nothing here and is reported as `.needsReview` so the caller can show that target for confirmation.
    private func saveManaged(_ login: SavedPassword, offer: Offer) async throws -> CredentialSaveOutcome {
        guard let manager = self.manager(epoch: offer.managerEpoch), let epoch = offer.managerEpoch,
              let origin = managerOrigin(offer.origin) else { throw CredentialVaultError.unauthorized }
        let snapshot = try await manager.snapshot()
        guard self.manager(epoch: epoch) != nil else { throw CredentialVaultError.unauthorized }
        guard !snapshot.blockedPasswordOrigins.contains(origin) else { throw CredentialVaultError.staleRevision }
        return try await CredentialAccountSelection.commitSave(
            login, origin: origin, offered: offer.plan, loginURL: offer.loginURL, snapshot: snapshot, manager: manager
        )
    }

    func save(_ offer: Offer, replacement: AutofillSaveCandidate? = nil) async {
        guard !isBusy, current?.id == offer.id, AutofillSaveCoordinator.shared.isEnabled(offer.candidate.kind, profileID: profileID),
              offer.candidate.kind != .password || offer.provider == PasswordAutofill.shared.provider,
              let page, page.window != nil, await AutofillSaveCoordinator.shared.isLive(page: page, documentID: offer.documentID, origin: offer.origin) else { return }
        let candidate = replacement ?? offer.candidate
        guard candidate.kind == offer.candidate.kind else { return }
        if case .password(let password) = candidate, password.origin != offer.origin {
            return
        }
        isBusy = true; error = nil; let profileID = profileID; defer { isBusy = false }
        do {
            switch candidate {
            case .password(let login):
                if offer.provider == .credentialManager {
                    if try await saveManaged(login, offer: offer) == .needsReview {
                        // The save would land somewhere other than what this offer showed: nothing was written. Show the
                        // new target through the normal offer so the user confirms that exact account.
                        guard self.profileID == profileID, current?.id == offer.id else { return }
                        dismiss(offer, rememberingChoice: false)
                        await self.offer(candidate, origin: offer.origin, documentID: offer.documentID)
                        return
                    }
                } else {
                    _ = try await AutofillVaults.passwords(for: profileID).update { SavedPassword.merging(login, into: $0) }
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
            guard await AutofillSaveCoordinator.shared.isLive(page: page, documentID: offer.documentID, origin: offer.origin),
                  self.profileID == profileID, current?.id == offer.id else { return }
            dismiss(offer, rememberingChoice: false)
        } catch {
            guard self.profileID == profileID && current?.id == offer.id else { return }
            if Self.isLocked(error) { dismiss(offer, rememberingChoice: false); return }
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
    private(set) var profileID = Profile.originalID

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
    func use(profileID: UUID) {
        clear(); self.profileID = profileID; refreshPolicy()
    }
    private func clear() {
        AutofillSuggestions.shared.reset(); frames.removeAll()
        for session in sessions.objectEnumerator()?.allObjects as? [AutofillSaveSession] ?? [] {
            session.clear()
        }
    }
    func resetDismissals(kind: AutofillSaveKind, profileID: UUID) {
        for session in sessions.objectEnumerator()?.allObjects as? [AutofillSaveSession] ?? []
        where session.profileID == profileID {
            session.resetDismissals(kind: kind)
        }
    }
    func session(for page: BrowserPage) -> AutofillSaveSession? {
        sessions.object(forKey: page)
    }
    func rememberFilledUsername(
        _ value: String, origin: String, documentID: String, in page: BrowserPage, accountID: UUID? = nil, epoch: UInt64? = nil
    ) {
        guard !value.isEmpty, value.count <= 500, isEnabled(.password, profileID: page.profileID), let session = sessions.object(forKey: page) else { return }
        if let accountID {
            session.selectAccount(accountID, username: value, in: page, origin: origin, documentID: documentID, epoch: epoch)
            return
        }
        var step = AutofillSaveSession.UsernameStep(origin: origin, value: value, documentID: documentID, attemptID: UUID()); step.completed = true; session.username = step
    }
    func isEnabled(_ kind: AutofillSaveKind, profileID: UUID) -> Bool {
        guard sessionIsActive, !screenIsLocked, profileID == self.profileID, profileID != Profile.privateID else { return false }
        switch kind {
        case .password:
            return PasswordAutofill.shared.isEnabled
        case .card:
            return BrowserSettings.shared.fillsPaymentCards
        case .contact:
            return BrowserSettings.shared.fillsContacts
        }
    }

    func install(in page: BrowserPage, session: AutofillSaveSession) {
        session.attach(to: page, profileID: profileID); sessions.setObject(session, forKey: page)
        page.installScript(AutofillFormScript.source + AutofillSuggestionScript.source, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(AutofillSaveScript.clientSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: "wsurfAutofillSave", in: Self.world) { [weak self] message in self?.receive(message) }
    }
    func refreshPolicy() {
        AutofillSuggestions.shared.reset()
        for session in sessions.objectEnumerator()?.allObjects as? [AutofillSaveSession] ?? [] {
            session.refreshPolicy()
        }
        for (key, list) in frames {
            guard let page = sessions.keyEnumerator().allObjects.compactMap({ $0 as? BrowserPage })
                .first(where: { ObjectIdentifier($0) == key }) else { continue }
            for frame in list.values.values {
                applyPolicy(in: page, frame: frame)
            }
        }
    }
    private func applyPolicy(in page: BrowserPage, frame: BrowserFrame) {
        guard let session = sessions.object(forKey: page), session.page === page else { return }
        let origin = frame.securityOrigin, topURL = page.url
        let secure = origin.protocol == "https" && !origin.host.isEmpty && topURL.flatMap(SavedPassword.origin(for:)) != nil
        let policy = Dictionary(uniqueKeysWithValues: AutofillSaveKind.allCases.map { ($0.rawValue, secure && isEnabled($0, profileID: session.profileID)) })
        Task { _ = try? await page.callAsyncJavaScript("globalThis.__wsurfAutofillSave?.setPolicy(policy);", arguments: ["policy": policy], in: frame, contentWorld: Self.world) }
    }
    func pageStates(in page: BrowserPage) async -> [AutofillSubmissionTracker.PageState]? {
        guard let list = frames[ObjectIdentifier(page)], let mainID = list.mainDocumentID, list.values[mainID] != nil else { return nil }
        let entries = [(mainID, list.values[mainID]!)] + list.values.filter { $0.key != mainID }
        var result: [AutofillSubmissionTracker.PageState] = []
        for (id, frame) in entries {
            let raw = try? await page.callAsyncJavaScript("return globalThis.__wsurfAutofillForms?.summary();", arguments: [:], in: frame, contentWorld: Self.world)
            guard frames[ObjectIdentifier(page)] === list, list.mainDocumentID == mainID else { return nil }
            guard let state = AutofillSubmissionTracker.PageState(raw), state.documentID == id,
                  frame.securityOrigin.protocol == state.url.scheme, frame.securityOrigin.host == state.url.host?.lowercased(),
                  (frame.securityOrigin.port == 0 ? 443 : frame.securityOrigin.port) == (state.url.port ?? 443) else { if id == mainID { return nil }; list.values[id] = nil; continue }
            result.append(state)
        }
        return result
    }
    func isLive(page: BrowserPage, documentID: String, origin: String) async -> Bool {
        guard page.profileID == profileID, !page.isPrivate, page.hasOnlySecureContent,
              page.url.flatMap(SavedPassword.origin(for:)) != nil,
              let expected = URL(string: origin), SavedPassword.origin(for: expected) == origin else { return false }
        func matches(_ frame: BrowserFrame) -> Bool {
            frame.securityOrigin.protocol == expected.scheme?.lowercased()
                && frame.securityOrigin.host == expected.host?.lowercased()
                && (frame.securityOrigin.port == 0 ? 443 : frame.securityOrigin.port) == (expected.port ?? 443)
        }
        guard let list = frames[ObjectIdentifier(page)], let frame = list.values[documentID], matches(frame) else { return false }
        if let chromium = page.chromium {
            return (try? await chromium.isLive(frame: frame)) == true
        }
        let current = try? await page.callAsyncJavaScript("return globalThis.__wsurfAutofillForms?.documentID;", arguments: [:], in: frame.isMainFrame ? nil : frame, contentWorld: Self.world)
        return current as? String == documentID
    }
    private func receive(_ message: BrowserScriptMessage) {
        guard let session = sessions.object(forKey: message.page), session.profileID == profileID,
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
              let documentID = body["documentID"] as? String, frames[key]?.values[documentID] != nil,
              let topURL = page.url, SavedPassword.origin(for: topURL) != nil,
              let rawURL = body["url"] as? String, let url = URL(string: rawURL), let origin = SavedPassword.origin(for: url),
              message.frameInfo.securityOrigin.protocol == "https", message.frameInfo.securityOrigin.host == url.host?.lowercased(),
              (message.frameInfo.securityOrigin.port == 0 ? 443 : message.frameInfo.securityOrigin.port) == (url.port ?? 443) else { return }
        if action == "diagnostic", let value = body["event"] as? String,
           let event = AutofillDiagnostics.Event(rawValue: value),
           [.editNoScope, .editDisabled, .editRecorded, .submitNoEdits, .submitInvalid, .submitCaptured].contains(event) {
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
        if source != "pagehide", isEnabled(.password, profileID: session.profileID),
           let value = body["username"] as? String, !value.isEmpty, value.count <= 500 {
            session.stageUsername(value, origin: origin, documentID: documentID, attemptID: attemptID, in: page)
        }
        var candidates: [AutofillSaveCandidate] = []
        if isEnabled(.password, profileID: session.profileID), let login = body["password"] as? [String: String], let password = login["password"] {
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
        if isEnabled(.card, profileID: session.profileID),
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
        if isEnabled(.contact, profileID: session.profileID),
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
        session.submissions.stage(id: attemptID, documentID: documentID, formID: formID, origin: origin, candidates: candidates, frame: message.frameInfo, source: source)
    }
}
