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
    private struct Attempt {
        let id: UUID; let documentID: String; let formID: String; let origin: String; let candidates: [AutofillSaveCandidate]; let frame: BrowserFrame
        let created = Date.now; var completionDocumentID: String?; var completionObservedAt: Date?
    }
    private weak var session: AutofillSaveSession?
    private var attempts: [UUID: Attempt] = [:]
    private var formDepartures: [String: Date] = [:]
    private var polling: Task<Void, Never>?
    private var generation = 0

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

    func stage(id: UUID, documentID: String, formID: String, origin: String, candidates: [AutofillSaveCandidate], frame: BrowserFrame, source: String) {
        guard !candidates.isEmpty, ["submit", "interaction", "automatic", "pagehide"].contains(source) else { return }
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
        attempts[id] = Attempt(id: id, documentID: documentID, formID: formID, origin: origin, candidates: pending, frame: frame)
        AutofillDiagnostics.note(.submissionPending, kind: candidates[0].kind); startPolling()
    }
    func discard(id: UUID, documentID: String, formID: String) {
        guard let attempt = attempts[id], attempt.documentID == documentID, attempt.formID == formID else { return }
        attempts[id] = nil
    }
    func complete(id: UUID, documentID: String, formID: String) {
        guard let attempt = attempts[id], attempt.documentID == documentID, attempt.formID == formID,
              Date.now.timeIntervalSince(attempt.created) < 120 else { return }
        finish(attempt)
    }
    private func finish(_ attempt: Attempt) {
        attempts[attempt.id] = nil
        guard let session else { return }
        AutofillDiagnostics.note(.submissionCompleted, kind: attempt.candidates[0].kind)
        session.receive(attempt.candidates, origin: attempt.origin, documentID: attempt.documentID)
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
        attempts = attempts.filter { Date.now.timeIntervalSince($0.value.created) < 120 }
        guard let page = session?.page, !page.isLoading, page.window != nil, !page.isHiddenOrHasHiddenAncestor, page.hasOnlySecureContent,
              let topURL = page.url, SavedPassword.origin(for: topURL) != nil else { return }
        for attempt in Array(attempts.values) {
            if let chromium = page.chromium, (try? await chromium.isLive(frame: attempt.frame)) != true {
                attempts[attempt.id] = nil
                continue
            }
            let value = try? await page.callAsyncJavaScript("return globalThis.__wsurfAutofillForms?.summary();", arguments: [:], in: attempt.frame, contentWorld: AutofillPage.world)
            guard generation == self.generation, attempts[attempt.id] != nil, page.url == topURL, !page.isLoading else { return }
            let state = PageState(value)
            if let state, state.documentID == attempt.documentID {
                continue
            }
            if attempt.frame.isMainFrame && state == nil {
                continue
            }
            guard let pages = await AutofillSaveCoordinator.shared.pageStates(in: page), let main = pages.first, pages.allSatisfy(\.ready),
                  !pages.contains(where: { $0.documentID == attempt.documentID }), attempt.candidates.allSatisfy({ candidate in !pages.contains { $0.stillContains(candidate.kind) } }) else {
                attempts[attempt.id]?.completionDocumentID = nil; attempts[attempt.id]?.completionObservedAt = nil; continue
            }
            guard generation == self.generation, attempts[attempt.id] != nil, page.url == topURL, !page.isLoading, page.hasOnlySecureContent else { return }
            let completionID = state?.documentID ?? main.documentID
            if let recorded = attempts[attempt.id], recorded.completionDocumentID == completionID,
               let first = recorded.completionObservedAt, Date.now.timeIntervalSince(first) >= 1 {
                finish(recorded)
            } else {
                attempts[attempt.id]?.completionDocumentID = completionID
                attempts[attempt.id]?.completionObservedAt = .now
            }
        }
    }
}
