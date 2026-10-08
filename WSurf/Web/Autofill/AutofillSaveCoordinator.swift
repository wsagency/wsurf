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
    }
    private(set) var offers: [Offer] = []
    private(set) var isBusy = false
    private(set) var error: String?
    var isPopoverPresented = false
    private(set) var context: BrowserProfileContext?
    @ObservationIgnored weak var page: BrowserPage?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var dismissed: [AutofillSaveKind: Set<String>] = [:]
    @ObservationIgnored private let fingerprintKey = SymmetricKey(size: .bits256)
    @ObservationIgnored private var expiry: Task<Void, Never>?
    struct UsernameStep { let origin: String; let value: String; let documentID: String; let attemptID: UUID; let date = Date.now; var completed = false }
    @ObservationIgnored var username: UsernameStep?
    @ObservationIgnored let submissions = AutofillSubmissionTracker()

    var current: Offer? {
        offers.first
    }

    func attach(to page: BrowserPage, context: BrowserProfileContext) {
        clear(); self.page = page; self.context = context; submissions.attach(to: self); dismissed = [:]
    }
    func clear() {
        revision += 1; offers = []; isPopoverPresented = false; username = nil; submissions.clear(); error = nil
        expiry?.cancel(); expiry = nil
    }
    func refreshPolicy() {
        revision += 1; submissions.clear()
        guard let context else {
            offers = []
            username = nil
            isPopoverPresented = false
            return
        }
        offers.removeAll { !AutofillSaveCoordinator.shared.isEnabled($0.candidate.kind, context: context) }
        if offers.isEmpty {
            isPopoverPresented = false
        }
        if !AutofillSaveCoordinator.shared.isEnabled(.password, context: context) {
            username = nil
        }
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
    func offer(_ candidate: AutofillSaveCandidate, origin: String, documentID: String = "") async {
        guard let context, AutofillSaveCoordinator.shared.isEnabled(candidate.kind, context: context) else { return }
        let bytes = (try? JSONEncoder().encode([origin, candidate.kind.rawValue] + candidate.values)) ?? Data()
        let fingerprint = Data(HMAC<SHA256>.authenticationCode(for: bytes, using: fingerprintKey)).base64EncodedString()
        guard dismissed[candidate.kind]?.contains(fingerprint) != true, !offers.contains(where: { $0.fingerprint == fingerprint }) else { return }
        let revision = revision, profileID = context.profile.id
        let decision = await Task.detached { (try? AutofillSaveIndex.decision(for: candidate, origin: origin, profileID: profileID)) ?? .new }.value
        guard revision == self.revision, self.context === context, let page, page.context === context, !context.profile.isPrivate,
              page.url.flatMap(SavedPassword.origin(for:)) != nil,
              documentID.isEmpty ? true : await AutofillSaveCoordinator.shared.isLive(page: page, documentID: documentID, origin: origin),
              AutofillSaveCoordinator.shared.isEnabled(candidate.kind, context: context),
              dismissed[candidate.kind]?.contains(fingerprint) != true, !offers.contains(where: { $0.fingerprint == fingerprint }),
              decision != .unchanged, decision != .blocked else { return }
        let previous = current?.id
        offers.removeAll { $0.candidate.kind == candidate.kind }
        offers.append(Offer(candidate: candidate, origin: origin, isUpdate: decision == .update, fingerprint: fingerprint, documentID: documentID))
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
        guard !isBusy, current?.id == offer.id, let context else { return }
        isBusy = true; let profileID = context.profile.id; defer { isBusy = false }
        do {
            try await Task.detached { try AutofillSaveIndex.block(kind: offer.candidate.kind, origin: offer.origin, profileID: profileID) }.value
            if self.context === context && current?.id == offer.id {
                dismiss(offer)
            }
        } catch {
            if self.context === context && current?.id == offer.id {
                self.error = String(localized: "Couldn’t remember this choice. Try again.")
            }
        }
    }
    func save(_ offer: Offer, replacement: AutofillSaveCandidate? = nil) async {
        guard !isBusy, current?.id == offer.id, let context,
              AutofillSaveCoordinator.shared.isEnabled(offer.candidate.kind, context: context),
              let page, page.context === context, page.window != nil,
              await AutofillSaveCoordinator.shared.isLive(page: page, documentID: offer.documentID, origin: offer.origin) else { return }
        let candidate = replacement ?? offer.candidate
        guard candidate.kind == offer.candidate.kind else { return }
        if case .password(let password) = candidate, password.origin != offer.origin {
            return
        }
        isBusy = true; error = nil; let profileID = context.profile.id; defer { isBusy = false }
        do {
            switch candidate {
            case .password(let login):
                _ = try await AutofillVaults.passwords(for: profileID).update { SavedPassword.merging(login, into: $0) }
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
                  await AutofillSaveCoordinator.shared.isLive(page: page, documentID: offer.documentID, origin: offer.origin),
                  current?.id == offer.id else { return }
            dismiss(offer, rememberingChoice: false)
        } catch {
            if self.context === context && current?.id == offer.id {
                self.error = String(localized: "Couldn’t save these details. Try again.")
            }
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
    func resetDismissals(kind: AutofillSaveKind, context: BrowserProfileContext) {
        for session in sessions.objectEnumerator()?.allObjects as? [AutofillSaveSession] ?? []
        where session.context === context {
            session.resetDismissals(kind: kind)
        }
    }
    func rememberFilledUsername(_ value: String, origin: String, documentID: String, in page: BrowserPage) {
        guard !value.isEmpty, value.count <= 500, isEnabled(.password, context: page.context),
              let session = sessions.object(forKey: page), session.context === page.context else { return }
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
        let context = page.context
        guard let session = sessions.object(forKey: page), session.page === page, session.context === context else { return }
        let origin = frame.securityOrigin, topURL = page.url
        let secure = origin.protocol == "https" && !origin.host.isEmpty && topURL.flatMap(SavedPassword.origin(for:)) != nil
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
                  frame.securityOrigin.protocol == state.url.scheme, frame.securityOrigin.host == state.url.host?.lowercased(),
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
            frame.securityOrigin.protocol == expected.scheme?.lowercased()
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
        if source != "pagehide", isEnabled(.password, context: context),
           let value = body["username"] as? String, !value.isEmpty, value.count <= 500 {
            session.username = AutofillSaveSession.UsernameStep(
                origin: origin,
                value: value,
                documentID: documentID,
                attemptID: attemptID
            )
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
        session.submissions.stage(id: attemptID, documentID: documentID, formID: formID, origin: origin, candidates: candidates, frame: message.frameInfo, source: source)
    }
}
