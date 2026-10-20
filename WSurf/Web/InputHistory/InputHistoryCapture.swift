// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import WebKit

/// Takes what the person types into page fields from the page script and hands it to Input History.
///
/// - The script runs in the `WSurfAutofill` isolated world, in every frame of every page except those of a private profile, and
///   starts switched off. Native code switches it on for one frame when the profile records, the site is not excluded and this
///   copy of the app owns the session.
/// - A page process is never trusted. Every message is checked again here: the profile, the switch, the frame's own origin
///   against the address it reports, the site exclusions, the kind, the sizes, and card numbers. Query and fragment of an address
///   never reach the store.
/// - Nothing is recorded in a tab while the assistant or a connected app controls it (`BrowserTab.isUnderAssistantControl`). The
///   frames of that tab are switched off for as long as it lasts, which also drops what was typed before and not yet sent, so
///   text an agent types is not sent after its call ends. The cost: the person's own typing in that tab is not recorded either.
/// - Recording goes through `InputHistory.record`: sealed to a public key on a background queue, with no way to read an entry
///   back and no prompt. Nothing in this file logs, and a value is not kept after the call that hands it on.
@MainActor
final class InputHistoryCapture {
    static let shared = InputHistoryCapture()
    static let handlerName = "wsurfInputHistory"
    private static let world = AutofillPage.world
    private static let documentsPerPage = 100

    private struct Document {
        let frame: BrowserFrame
        let origin: BrowserSecurityOrigin
        /// What the script was last told. A refresh sends only a change.
        var isEnabled = false
    }

    /// The documents of one page that reported in, and its commit budget.
    private final class Registry {
        var documents: [String: Document] = [:]
        /// Whether the assistant or a connected app controls the tab of this page.
        var isUnderAssistantControl: @MainActor () -> Bool = { false }
        private var order: [String] = []
        private var windowStart: ContinuousClock.Instant?
        private var commits = 0

        func add(_ id: String, _ document: Document) {
            if documents.updateValue(document, forKey: id) == nil {
                order.append(id)
            }
            guard order.count > InputHistoryCapture.documentsPerPage else { return }
            // The newest main document stays: its fields are the ones being typed into.
            let victim = order.firstIndex { documents[$0]?.frame.isMainFrame == false } ?? 0
            documents[order.remove(at: victim)] = nil
        }

        func admitsCommit() -> Bool {
            let now = ContinuousClock.now
            if let windowStart, now - windowStart < InputHistoryRules.commitWindow {
                commits += 1
            } else {
                windowStart = now
                commits = 1
            }
            return commits <= InputHistoryRules.commitBudget
        }
    }

    /// False in a second copy of the app: it keeps nothing. Tests set it.
    var ownsSession: Bool
    private let history: @MainActor () -> InputHistory
    private let pages = NSMapTable<BrowserPage, Registry>.weakToStrongObjects()

    init(ownsSession: Bool = AppDatabase.ownsSession, history: @escaping @MainActor () -> InputHistory = { InputHistory.shared }) {
        self.ownsSession = ownsSession
        self.history = history
    }

    // MARK: - Installing

    /// A private profile gets no script and no handler. The script comes after `AutofillSaveCoordinator.install`, which defines the
    /// form model that it reads. Without that model the script does nothing. `isUnderAssistantControl` reports the tab's state.
    func install(in page: BrowserPage, isUnderAssistantControl: @escaping @MainActor () -> Bool = { false }) {
        guard !page.context.profile.isPrivate else { return }
        let isNew = pages.object(forKey: page) == nil
        let registry = pages.object(forKey: page) ?? Registry()
        registry.isUnderAssistantControl = isUnderAssistantControl
        pages.setObject(registry, forKey: page)
        page.installScript(InputHistoryScript.clientSource, in: Self.world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: Self.handlerName, in: Self.world) { [weak self] message in self?.receive(message) }
        if isNew {
            watchControl(of: page)
        }
    }

    /// Frames are switched off when the tab comes under control and on again when it ends. The tab's state is observable, so this
    /// needs no call from the code that sets it.
    private func watchControl(of page: BrowserPage) {
        guard let registry = pages.object(forKey: page) else { return }
        withObservationTracking {
            _ = registry.isUnderAssistantControl()
        } onChange: { [weak self, weak page] in
            // Re-armed once the change has landed. Until then `commit` still asks the tab itself, so nothing slips through.
            Task { @MainActor [weak self, weak page] in
                guard let self, let page, let registry = self.pages.object(forKey: page) else { return }
                self.applyPolicy(to: page, registry: registry)
                self.watchControl(of: page)
            }
        }
    }

    /// The switch, the exclusion list, or the session changed: every open frame learns whether it may record.
    func refreshPolicy() {
        for case let page as BrowserPage in pages.keyEnumerator().allObjects {
            if let registry = pages.object(forKey: page) {
                applyPolicy(to: page, registry: registry)
            }
        }
    }

    private func applyPolicy(to page: BrowserPage, registry: Registry) {
        for id in Array(registry.documents.keys) {
            applyPolicy(for: id, in: page, registry: registry)
        }
    }

    /// How many documents of the page have reported in. For tests.
    func documentCount(in page: BrowserPage) -> Int {
        pages.object(forKey: page)?.documents.count ?? 0
    }

    // MARK: - Policy

    private func excludedHosts(_ page: BrowserPage) -> [String] {
        InputHistoryRules.excludedHosts(page.context.settings.inputHistoryExcludedSites)
    }

    /// Whether this document may record: the profile has it on, this copy owns the session, and neither the page nor the frame
    /// is on the exclusion list.
    private func allows(_ document: Document, in page: BrowserPage, registry: Registry) -> Bool {
        let context = page.context
        guard ownsSession, !context.profile.isPrivate, context.settings.recordsInputHistory, !registry.isUnderAssistantControl(),
              document.frame.hasTrustedSecurityOrigin,
              document.origin.protocol == "http" || document.origin.protocol == "https" else { return false }
        let excluded = excludedHosts(page)
        if InputHistoryRules.isExcluded(document.origin.host, by: excluded) {
            return false
        }
        if !document.frame.isMainFrame {
            guard let top = InputHistoryRules.address(page.url), !InputHistoryRules.isExcluded(top.host, by: excluded) else { return false }
        }
        return true
    }

    private func applyPolicy(for id: String, in page: BrowserPage, registry: Registry) {
        guard var document = registry.documents[id] else { return }
        let wanted = allows(document, in: page, registry: registry)
        guard wanted != document.isEnabled else { return }
        document.isEnabled = wanted
        registry.documents[id] = document
        let frame = document.frame, context = page.context
        Task { [weak registry] in
            do {
                guard page.context === context else { return }
                _ = try await page.callAsyncJavaScript(
                    "globalThis.__wsurfInputHistory?.setPolicy(policy);",
                    arguments: ["policy": ["enabled": wanted]],
                    in: frame,
                    contentWorld: Self.world
                )
            } catch {
                // The frame is gone or not ready. The next refresh tries again, unless a newer one already changed the state.
                if registry?.documents[id]?.isEnabled == wanted {
                    registry?.documents[id]?.isEnabled = !wanted
                }
            }
        }
    }

    // MARK: - Messages

    func receive(_ message: BrowserScriptMessage) {
        let page = message.page
        guard !page.context.profile.isPrivate, let registry = pages.object(forKey: page),
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            ready(body, message, registry)
        case "commit":
            commit(body, message, registry)
        default:
            break
        }
    }

    private func ready(_ body: [String: Any], _ message: BrowserScriptMessage, _ registry: Registry) {
        let frame = message.frameInfo
        guard let documentID = body["documentID"] as? String, documentID.utf8.count == 36, UUID(uuidString: documentID) != nil,
              frame.hasTrustedSecurityOrigin, let raw = body["url"] as? String, raw.utf8.count <= 4_096,
              let url = URL(string: raw), InputHistoryRules.matches(frame.securityOrigin, url) else { return }
        registry.add(documentID, Document(frame: frame, origin: frame.securityOrigin))
        applyPolicy(for: documentID, in: message.page, registry: registry)
    }

    private func commit(_ body: [String: Any], _ message: BrowserScriptMessage, _ registry: Registry) {
        let page = message.page, frame = message.frameInfo, settings = page.context.settings
        guard ownsSession, settings.recordsInputHistory, !registry.isUnderAssistantControl(), frame.hasTrustedSecurityOrigin,
              let commit = InputHistoryRules.commit(from: body),
              let document = registry.documents[commit.documentID], document.origin == frame.securityOrigin,
              document.frame.isMainFrame == frame.isMainFrame,
              InputHistoryRules.matches(frame.securityOrigin, commit.url), let here = InputHistoryRules.address(commit.url),
              registry.admitsCommit() else { return }
        // A frame's own address is its script's word, checked against the origin the engine reports. The page above it is the
        // tab's address, except for the main frame, whose script knows it better than a tab still moving to it.
        let top: InputHistoryRules.Address
        if frame.isMainFrame {
            top = here
        } else {
            guard let address = InputHistoryRules.address(page.url) else { return }
            top = address
        }
        let excluded = excludedHosts(page)
        guard !InputHistoryRules.isExcluded(top.host, by: excluded), !InputHistoryRules.isExcluded(here.host, by: excluded) else { return }

        let store = history(), profile = page.context.profile
        if commit.cleared {
            store.forget(key: commit.key, profile: profile)
            return
        }
        guard !InputHistoryRules.looksLikeCardNumber(commit.value) else { return }
        let username = commit.username.flatMap { InputHistoryRules.looksLikeCardNumber($0) ? nil : $0 }
        let payload = InputHistoryPayload(
            url: top.location,
            frameOrigin: here.origin == top.origin ? nil : here.origin,
            title: frame.isMainFrame ? commit.title : page.title ?? "",
            label: commit.label,
            kind: commit.kind,
            value: commit.value,
            username: username
        )
        guard let checked = try? payload.validated() else { return }
        store.record(checked, key: commit.key, profile: profile, retention: settings.inputHistoryRetention)
    }
}
