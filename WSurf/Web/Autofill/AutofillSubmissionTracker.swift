// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

@MainActor
final class AutofillSubmissionTracker {
    struct PageState {
        let documentID: String
        let url: URL
        let ready: Bool
        let passwords: Int
        let challenges: Int
        let cards: Int
        let addresses: Int
        init?(_ value: Any?) {
            guard let value = value as? [String: Any], let documentID = value["documentID"] as? String, UUID(uuidString: documentID) != nil,
                  let rawURL = value["url"] as? String, let url = URL(string: rawURL), SavedPassword.origin(for: url) != nil,
                  let ready = value["ready"] as? Bool, let passwords = value["passwords"] as? Int, let challenges = value["challenges"] as? Int,
                  let cards = value["cards"] as? Int, let addresses = value["addresses"] as? Int, [passwords, challenges, cards, addresses].allSatisfy({ (0...400).contains($0) }) else { return nil }
            self.documentID = documentID; self.url = url; self.ready = ready; self.passwords = passwords; self.challenges = challenges; self.cards = cards; self.addresses = addresses
        }
        func stillContains(_ kind: AutofillSaveKind) -> Bool {
            switch kind {
            case .password:
                return passwords > 0 || challenges > 0
            case .card:
                return cards > 0
            case .contact:
                return addresses > 0
            }
        }
    }
    enum NavigationKind { case linkActivated, backForward, reload, formSubmitted, formResubmitted, other }
    /// How long an attempt may wait for proof that the login worked. A verification step (SMS, e-mail, push approval) can take minutes,
    /// so an attempt that has seen one waits longer.
    static let attemptLifetime: TimeInterval = 120
    static let verificationLifetime: TimeInterval = 300
    private struct Attempt {
        let id: UUID
        let context: BrowserProfileContext
        let documentID: String
        let formID: String
        let origin: String
        /// The page the login was typed on; after a navigation the tab no longer shows it.
        let loginURL: URL?
        let candidates: [AutofillSaveCandidate]
        let frame: BrowserFrame
        let created: Date
        var sawVerification = false
        var blockedByFieldNoted = false
        /// The document (and its origin) that replaced the login after a navigation. A same-document completion never sets them.
        var completionDocumentID: String?
        var completionOrigin: String?
        var completionObservedAt: Date?
        var lifetime: TimeInterval {
            sawVerification ? AutofillSubmissionTracker.verificationLifetime : AutofillSubmissionTracker.attemptLifetime
        }
        mutating func resetCompletion() {
            completionDocumentID = nil; completionOrigin = nil; completionObservedAt = nil
        }
    }
    private weak var session: AutofillSaveSession?
    private var attempts: [UUID: Attempt] = [:]
    private var formDepartures: [String: Date] = [:]
    private var polling: Task<Void, Never>?
    private var generation = 0
    /// Tests replace the clock that ages attempts.
    var now: () -> Date = { .now }

    func attach(to session: AutofillSaveSession) {
        self.session = session
    }
    func clear() {
        generation += 1
        attempts.removeAll()
        formDepartures.removeAll()
        polling?.cancel()
        polling = nil
    }

    func navigationRequested(isMainFrame: Bool, kind: NavigationKind, sourceURL: URL?) {
        switch kind {
        case .linkActivated, .backForward, .reload:
            if isMainFrame {
                clear()
                session?.username = nil
            }
        case .formSubmitted:
            if let url = sourceURL, let origin = SavedPassword.origin(for: url) {
                formDepartures = formDepartures.filter { Date.now.timeIntervalSince($0.value) < 5 }
                formDepartures[origin] = .now
            }
        default:
            break
        }
    }

    // Native WebKit delegate boundary; Chromium calls the engine-neutral overload above.
    func navigationRequested(_ action: WKNavigationAction) {
        let kind: NavigationKind
        switch action.navigationType {
        case .linkActivated:
            kind = .linkActivated
        case .backForward:
            kind = .backForward
        case .reload:
            kind = .reload
        case .formSubmitted:
            kind = .formSubmitted
        case .formResubmitted:
            kind = .formResubmitted
        default:
            kind = .other
        }
        let sourceURL = kind == .formSubmitted ? action.sourceFrame.request.url : nil
        navigationRequested(isMainFrame: action.targetFrame?.isMainFrame != false, kind: kind, sourceURL: sourceURL)
    }

    func stage(
        id: UUID, documentID: String, formID: String, origin: String, loginURL: URL? = nil,
        candidates: [AutofillSaveCandidate], frame: BrowserFrame, source: String
    ) {
        guard let context = session?.context, !candidates.isEmpty,
              ["submit", "interaction", "automatic", "pagehide"].contains(source) else { return }
        if source == "pagehide" { guard let date = formDepartures[origin], Date.now.timeIntervalSince(date) < 5 else { return } }
        attempts = attempts.filter { $0.value.documentID != documentID || $0.value.formID != formID }
        if attempts.count >= 12, let oldest = attempts.values.min(by: { $0.created < $1.created }) {
            attempts[oldest.id] = nil
        }
        let submittedAddresses = source == "submit" ? candidates.filter { $0.kind == .contact } : []
        if !submittedAddresses.isEmpty {
            session?.receive(submittedAddresses, origin: origin, documentID: documentID)
        }
        let pending = source == "submit" ? candidates.filter { $0.kind != .contact } : candidates
        guard !pending.isEmpty else { return }
        attempts[id] = Attempt(
            id: id, context: context, documentID: documentID, formID: formID, origin: origin, loginURL: loginURL,
            candidates: pending, frame: frame, created: now()
        )
        AutofillDiagnostics.note(.submissionPending, kind: candidates[0].kind); startPolling()
    }
    func discard(id: UUID, documentID: String, formID: String) {
        guard let attempt = attempts[id], attempt.documentID == documentID, attempt.formID == formID else { return }
        attempts[id] = nil
    }
    func complete(id: UUID, documentID: String, formID: String) {
        guard let attempt = attempts[id], attempt.documentID == documentID, attempt.formID == formID else { return }
        guard now().timeIntervalSince(attempt.created) < attempt.lifetime else {
            expire(attempt)
            return
        }
        finish(attempt)
    }
    /// How long the attempt may wait in total; tests read it to see whether a verification step was noticed.
    func lifetime(of id: UUID) -> TimeInterval? {
        attempts[id]?.lifetime
    }
    private func expire(_ attempt: Attempt) {
        attempts[attempt.id] = nil
        AutofillDiagnostics.note(.attemptExpired, kind: attempt.candidates[0].kind, count: Int(attempt.lifetime))
    }
    /// The offer follows the page the user sees now: after a navigation that is the document that replaced the login, which may be on
    /// another origin. The credential still belongs to the origin it was typed on.
    private func finish(_ attempt: Attempt) {
        attempts[attempt.id] = nil
        guard let session, session.context === attempt.context, session.page?.context === attempt.context else {
            AutofillDiagnostics.note(.offerDroppedNotLive, kind: attempt.candidates[0].kind)
            return
        }
        AutofillDiagnostics.note(.submissionCompleted, kind: attempt.candidates[0].kind)
        session.receive(
            attempt.candidates, origin: attempt.origin, documentID: attempt.completionDocumentID ?? attempt.documentID,
            liveOrigin: attempt.completionOrigin ?? attempt.origin, loginURL: attempt.loginURL
        )
    }

    private func startPolling() {
        guard polling == nil else { return }
        let generation = generation
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, generation == self.generation else { return }
                await inspectTransitions(generation: generation)
                guard generation == self.generation else { return }
                if attempts.isEmpty {
                    polling = nil
                    return
                }
            }
        }
    }
    private func inspectTransitions(generation: Int) async {
        for attempt in attempts.values where now().timeIntervalSince(attempt.created) >= attempt.lifetime {
            expire(attempt)
        }
        guard let session, let page = session.page, session.context === page.context,
              !page.isLoading, page.window != nil, !page.isHiddenOrHasHiddenAncestor, page.hasOnlySecureContent,
              let topURL = page.url, SavedPassword.origin(for: topURL) != nil else { return }
        for attempt in Array(attempts.values) {
            guard attempt.context === page.context, session.context === attempt.context else {
                attempts[attempt.id] = nil
                continue
            }
            // The login's frame may be gone (an iframe that was removed) or hold another document by now. After a navigation to another site,
            // WebKit's handle can stop running scripts and Chromium's goes stale: no answer here is not a verdict either way, the page
            // states below decide.
            let value = try? await page.callAsyncJavaScript("return globalThis.__wsurfAutofillForms?.summary();", arguments: [:], in: attempt.frame, contentWorld: AutofillPage.world)
            guard generation == self.generation, session.context === attempt.context, page.context === attempt.context,
                  attempts[attempt.id] != nil, page.url == topURL, !page.isLoading else { return }
            let state = PageState(value)
            if (state?.challenges ?? 0) > 0 {
                attempts[attempt.id]?.sawVerification = true
            }
            if let state, state.documentID == attempt.documentID {
                continue
            }
            let reported = await AutofillSaveCoordinator.shared.pageStates(in: page)
            if reported?.contains(where: { $0.challenges > 0 }) == true {
                attempts[attempt.id]?.sawVerification = true
            }
            guard let pages = reported, session.context === attempt.context, page.context === attempt.context,
                  let main = pages.first, pages.allSatisfy(\.ready), !pages.contains(where: { $0.documentID == attempt.documentID }) else {
                attempts[attempt.id]?.resetCompletion(); continue
            }
            // A post-login page that still shows a password or code field is not proof of anything yet (the next step of the login).
            let blocking = pages.filter { frameState in attempt.candidates.contains { frameState.stillContains($0.kind) } }
            guard blocking.isEmpty else {
                if !attempt.blockedByFieldNoted {
                    attempts[attempt.id]?.blockedByFieldNoted = true
                    AutofillDiagnostics.note(.completionBlockedByField, kind: attempt.candidates[0].kind, count: blocking.count)
                }
                attempts[attempt.id]?.resetCompletion(); continue
            }
            guard generation == self.generation, attempts[attempt.id] != nil, session.context === attempt.context,
                  page.context === attempt.context, page.url == topURL, !page.isLoading, page.hasOnlySecureContent else { return }
            let completion = state ?? main
            if let recorded = attempts[attempt.id], recorded.completionDocumentID == completion.documentID,
               let first = recorded.completionObservedAt, Date.now.timeIntervalSince(first) >= 1 {
                finish(recorded)
            } else {
                attempts[attempt.id]?.completionDocumentID = completion.documentID
                attempts[attempt.id]?.completionOrigin = SavedPassword.origin(for: completion.url)
                attempts[attempt.id]?.completionObservedAt = .now
            }
        }
    }
}
