// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import CryptoKit
import Security
import SwiftUI
import WebKit

@MainActor
final class AutofillSuggestions {
    static let shared = AutofillSuggestions()
    var openSettings: (() -> Void)?

    private final class Request {
        let page: BrowserPage
        let frame: BrowserFrame
        let token: String
        let kind: AutofillSaveKind
        let profileID: UUID
        let frameURL: URL
        let topURL: URL
        let world: WKContentWorld
        let bridge: String
        let documentID: String
        let formID: String
        let fieldID: String
        var rect = NSRect.zero
        /// Which store this request was made against, and what it asked for. Set once; a later change of either
        /// provider or vault state makes the request stale instead of redirecting it.
        let provider: PasswordProvider
        let field: CredentialAutofillField
        let enteredUsername: String?
        var epoch: UInt64?
        var revision: UInt64?

        init(page: BrowserPage, frame: BrowserFrame, token: String, kind: AutofillSaveKind,
             profileID: UUID, frameURL: URL, topURL: URL, world: WKContentWorld, bridge: String,
             documentID: String, formID: String, fieldID: String,
             provider: PasswordProvider, field: CredentialAutofillField, enteredUsername: String?) {
            self.page = page; self.frame = frame; self.token = token; self.kind = kind
            self.profileID = profileID; self.frameURL = frameURL; self.topURL = topURL
            self.world = world; self.bridge = bridge; self.documentID = documentID
            self.formID = formID; self.fieldID = fieldID
            self.provider = provider; self.field = field; self.enteredUsername = enteredUsername
        }
    }

    private var requests: [ObjectIdentifier: Request] = [:]
    private weak var page: BrowserPage?
    private var presentationID = UUID()
    private var panel: AutofillSuggestionPanel?
    private var suggestions: [AutofillSuggestion] = []
    private let selection = AutofillSuggestionSelection()
    private var choose: ((UUID) -> Void)?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var securityObservers: [NSObjectProtocol] = []
    private var navigation: NSKeyValueObservation?
    private var loading: NSKeyValueObservation?
    private var isFilling = false
    private var geometryWatch: Task<Void, Never>?
    private let passwordAuthentication = PasswordFillAuthenticationCache()

    private init() {
        for centerAndName in [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
            (DistributedNotificationCenter.default(), NSNotification.Name("com.apple.screenIsLocked")),
        ] {
            securityObservers.append(centerAndName.0.addObserver(forName: centerAndName.1, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.passwordAuthentication.clear() }
            })
        }
    }

    func reset() {
        dismiss()
        requests.removeAll()
        passwordAuthentication.clear()
    }

    func dismiss(in page: BrowserPage? = nil) {
        if let page, self.page !== page {
            return
        }
        presentationID = UUID()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil; self.page = nil; suggestions = []; choose = nil; selection.keyboardID = nil
        navigation = nil; loading = nil
        geometryWatch?.cancel(); geometryWatch = nil
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        eventMonitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    func receive(_ message: BrowserScriptMessage, kind: AutofillSaveKind, profileID: UUID,
                 world: WKContentWorld, bridge: String) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let token = body["token"] as? String, UUID(uuidString: token) != nil else { return }
        let page = message.page
        let key = ObjectIdentifier(page)
        if action == "dismiss" || action == "hide" {
            guard requests[key]?.token == token else { return }
            if action == "dismiss" { requests[key] = nil }
            dismiss(in: page)
            return
        }
        guard action == "select", !isFilling,
              let documentID = body["documentID"] as? String, UUID(uuidString: documentID) != nil,
              let formID = body["formID"] as? String, Int(formID) ?? 0 > 0,
              let fieldID = body["fieldID"] as? String, Int(fieldID) ?? 0 > 0,
              AutofillSaveCoordinator.shared.isEnabled(kind, profileID: profileID),
              profileID == page.profileID,
              let rawURL = body["url"] as? String, let frameURL = URL(string: rawURL),
              let topURL = page.url, SavedPassword.origin(for: topURL) != nil,
              let origin = SavedPassword.origin(for: frameURL), page.hasOnlySecureContent,
              message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == frameURL.host?.lowercased(),
              (message.frameInfo.securityOrigin.port == 0 ? 443 : message.frameInfo.securityOrigin.port) == (frameURL.port ?? 443),
              body["rect"] is [String: Double],
              Self.canPresent(in: page) else { return }
        let rawRect = body["rect"]
        if let old = requests[key], old.token == token, old.documentID == documentID {
            return
        }
        dismiss()
        let provider = kind == .password ? PasswordAutofill.shared.provider : .legacy
        let manager = provider == .credentialManager
        let enteredUsername = manager ? (body["username"] as? String).flatMap { $0.isEmpty || $0.count > 500 ? nil : $0 } : nil
        let request = Request(page: page, frame: message.frameInfo, token: token, kind: kind,
                              profileID: profileID, frameURL: frameURL, topURL: topURL, world: world,
                              bridge: bridge, documentID: documentID, formID: formID, fieldID: fieldID,
                              provider: provider, field: manager && body["field"] as? String == "totp" ? .totp : .password,
                              enteredUsername: enteredUsername)
        requests[key] = request; self.page = page
        let id = presentationID
        Task { [weak self, weak page] in
            guard let self, let page, id == self.presentationID,
                  let rect = try? await self.awaitRect(rawRect, requestPage: page, frame: message.frameInfo, frameURL: frameURL, world: world) else { return }
            request.rect = rect
            let records: [AutofillSuggestion]?
            if manager {
                records = await self.managerSuggestions(for: request, origin: origin, presentation: id)
            } else {
                records = try? await Task.detached {
                    try AutofillSaveIndex.suggestions(kind: kind, origin: origin, profileID: profileID)
                }.value
            }
            guard id == self.presentationID, let records, !records.isEmpty,
                  (try? await self.validate(request, in: page, requiresFocus: true)) != nil,
                  Self.canPresent(in: page) else { return }
            self.show(records, request: request, in: page)
        }
    }

    /// The one manager that may answer `request`: same provider, same profile, and still the unlock it was made under.
    private func manager(for request: Request) -> CredentialManager? {
        let profile = PasswordAutofill.shared.profile
        guard request.provider == .credentialManager, PasswordAutofill.shared.provider == .credentialManager,
              profile.id == request.profileID, let epoch = request.epoch,
              let manager = try? CredentialManager.forProfile(profile), manager.authorizationEpoch == epoch else { return nil }
        return manager
    }

    /// Account choices for `request`, read only while the vault is explicitly unlocked. Locked, stale or mis-originated
    /// requests get no dropdown; unlocking happens in settings. The picked-account lookup can invalidate the carry-over,
    /// so it runs only while this is still the page's current request and presentation.
    private func managerSuggestions(for request: Request, origin: String, presentation: UUID) async -> [AutofillSuggestion]? {
        let profile = PasswordAutofill.shared.profile
        guard request.provider == .credentialManager, PasswordAutofill.shared.provider == .credentialManager,
              profile.id == request.profileID, CredentialAccountSelection.origin(for: request.frameURL) == origin,
              let manager = try? CredentialManager.forProfile(profile), let epoch = manager.authorizationEpoch,
              let snapshot = try? await manager.snapshot(), manager.authorizationEpoch == epoch,
              PasswordAutofill.shared.provider == .credentialManager,
              presentation == presentationID, requests[ObjectIdentifier(request.page)] === request else { return nil }
        request.epoch = epoch; request.revision = snapshot.revision
        // Frame, focus and field must still be the ones asked about before the pick is read (and possibly invalidated).
        guard (try? await validate(request, in: request.page, requiresFocus: true)) != nil,
              presentation == presentationID, requests[ObjectIdentifier(request.page)] === request else { return nil }
        let pinned = AutofillSaveCoordinator.shared.session(for: request.page)?.selectedAccount(
            in: request.page, origin: origin, enteredUsername: request.enteredUsername, epoch: epoch)
        return CredentialAccountSelection.suggestions(
            snapshot.accounts, origin: origin, pageURL: request.topURL, entered: request.enteredUsername,
            field: request.field, pinned: pinned)
    }

    /// What may be delivered for `id` now: the account must still exist, still be associated with this origin, and the
    /// vault must be the same unlock and revision the choice was shown under. The returned generation is the vault
    /// content generation the answer is valid for: it was available (no write in flight) before the read and is
    /// unchanged after it, and the caller must see it unchanged again immediately before delivering.
    private func managerAccount(
        _ id: UUID, request: Request, origin: String
    ) async throws -> (account: CredentialAccount, generation: UInt64) {
        guard let manager = manager(for: request), let epoch = request.epoch,
              CredentialAccountSelection.origin(for: request.frameURL) == origin,
              let generation = manager.stableGeneration else { throw ContactAutofillError.changedPage }
        let snapshot = try await manager.snapshot()
        guard manager.authorizationEpoch == epoch, manager.stableGeneration == generation, snapshot.revision == request.revision,
              let account = snapshot.accounts.first(where: { $0.id == id }),
              account.origins.contains(origin) else { throw ContactAutofillError.changedPage }
        return (account, generation)
    }

    private func awaitRect(_ value: Any?, requestPage: BrowserPage, frame: BrowserFrame,
                           frameURL: URL, world: WKContentWorld) async throws -> NSRect {
        guard var values = value as? [String: Double] else { throw ContactAutofillError.noField }
        if values["embedded"] == 1 {
            guard !frame.isMainFrame, let origin = SavedPassword.origin(for: frameURL),
                  let x = values["x"], let y = values["y"], let width = values["width"], let height = values["height"],
                  let viewportWidth = values["viewportWidth"], let viewportHeight = values["viewportHeight"],
                  [x, y, width, height, viewportWidth, viewportHeight].allSatisfy(\.isFinite), viewportWidth > 0, viewportHeight > 0,
                  x >= 0, y >= 0, x + width <= viewportWidth, y + height <= viewportHeight else { throw ContactAutofillError.noField }
            let answer = try await requestPage.callAsyncJavaScript(
                "return globalThis.__wsurfAutofillSuggestions?.frameBounds(origin);",
                arguments: ["origin": origin], in: nil, contentWorld: world)
            guard let outer = answer as? [String: Double],
                  let frameX = outer["x"], let frameY = outer["y"], let frameWidth = outer["width"], let frameHeight = outer["height"],
                  let topWidth = outer["viewportWidth"], let topHeight = outer["viewportHeight"] else { throw ContactAutofillError.noField }
            values = ["x": frameX + x * frameWidth / viewportWidth, "y": frameY + y * frameHeight / viewportHeight,
                      "width": width * frameWidth / viewportWidth, "height": height * frameHeight / viewportHeight,
                      "viewportWidth": topWidth, "viewportHeight": topHeight, ]
        }
        guard let rect = Self.fieldRect(values, in: requestPage) else { throw ContactAutofillError.noField }
        return rect
    }

    private static func canPresent(in page: BrowserPage) -> Bool {
        NSApp.isActive && page.window?.isKeyWindow == true && !page.isHiddenOrHasHiddenAncestor
    }

    private static func isFocused(_ page: BrowserPage) -> Bool {
        guard canPresent(in: page), let responder = page.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: page)
    }

    private static func fieldRect(_ value: Any?, in page: BrowserPage) -> NSRect? {
        guard let values = value as? [String: Double],
              let x = values["x"], let y = values["y"], let width = values["width"], let height = values["height"],
              let viewportWidth = values["viewportWidth"], let viewportHeight = values["viewportHeight"],
              [x, y, width, height, viewportWidth, viewportHeight].allSatisfy(\.isFinite), width > 2, height > 2,
              viewportWidth > 0, viewportHeight > 0, width <= viewportWidth * 2, height <= viewportHeight,
              x >= 0, y >= 0, x < viewportWidth, y + height <= viewportHeight else { return nil }
        let sx = page.bounds.width / viewportWidth, sy = page.bounds.height / viewportHeight
        let rect = NSRect(x: x * sx, y: page.isFlipped ? y * sy : page.bounds.height - (y + height) * sy,
                          width: min(width, viewportWidth - x) * sx, height: height * sy)
        return page.visibleRect.contains(rect) ? rect : nil
    }

    private func show(_ records: [AutofillSuggestion], request: Request, in page: BrowserPage) {
        guard !records.isEmpty, let window = page.window, let origin = SavedPassword.origin(for: request.frameURL) else { return }
        let field = window.convertToScreen(page.convert(request.rect, to: nil))
        var area = window.convertToScreen(page.convert(page.visibleRect, to: nil)).intersection(window.frame)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(NSPoint(x: field.midX, y: field.midY)) }) ?? window.screen {
            area = area.intersection(screen.visibleFrame)
        }
        let width = min(360.0, area.width - 16), availableBelow = max(0, field.minY - area.minY - 12), availableAbove = max(0, area.maxY - field.maxY - 12)
        let desired = AutofillSuggestionLayout.height(for: records.count), below = availableBelow >= desired || (availableAbove < desired && availableBelow >= availableAbove)
        let height = min(desired, below ? availableBelow : availableAbove)
        guard width >= 200, height >= AutofillSuggestionLayout.minimumHeight else { return }
        let frame = NSRect(x: max(area.minX + 8, min(field.minX, area.maxX - width - 8)), y: below ? field.minY - height - 4 : field.maxY + 4, width: width, height: height)
        let panel = AutofillSuggestionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(String(localized: "Autofill suggestions"))
        let content = NSHostingView(rootView: AutofillSuggestionList(kind: request.kind, origin: origin, suggestions: records, selection: selection,
            choose: { [weak self] id in self?.choose?(id) }, manage: { [weak self] in self?.dismiss(); self?.openSettings?() })
            .frame(width: frame.width, height: frame.height, alignment: .topLeading).clipShape(.rect(cornerRadius: 10)))
        content.sizingOptions = []; content.safeAreaRegions = []; content.frame = NSRect(origin: .zero, size: frame.size); content.autoresizingMask = [.width, .height]
        panel.contentView = content; panel.contentMinSize = frame.size; panel.contentMaxSize = frame.size; panel.setFrame(frame, display: false)
        self.panel = panel; suggestions = records
        choose = { [weak self, weak page] id in guard let self, let page, records.contains(where: { $0.id == id }) else { return }; self.fill(id, request: request, in: page) }
        window.addChildWindow(panel, ordered: .above); panel.orderFront(nil)
        AutofillDiagnostics.note(.dropdownShown, kind: request.kind, count: records.count)
        observe(page, window: window)
        let id = presentationID
        geometryWatch = Task { [weak self, weak page] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                guard let self, let page, id == self.presentationID, self.panel?.isVisible == true else { return }
                do { try await self.validate(request, in: page, requiresFocus: true) } catch { if id == self.presentationID { self.dismiss() }; return }
            }
        }
    }

    private func observe(_ page: BrowserPage, window: NSWindow) {
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        }
        navigation = page.observe(\.url) { [weak self] _, _ in MainActor.assumeIsolated { self?.dismiss() } }
        loading = page.observe(\.isLoading) { [weak self] page, _ in MainActor.assumeIsolated { if page.isLoading { self?.dismiss() } } }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
            return consumed ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.window === panel {
            return event
        }
        if event.type == .leftMouseDown, let page, let request = requests[ObjectIdentifier(page)],
           event.window === page.window, request.rect.contains(page.convert(event.locationInWindow, from: nil)) {
            return event
        }
        guard event.type == .keyDown, let page, Self.isFocused(page) else { dismiss(); return event }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { dismiss(); return event }
        switch event.keyCode {
        case 125, 126:
            guard !suggestions.isEmpty else { return event }
            let index = selection.keyboardID.flatMap { id in suggestions.firstIndex { $0.id == id } }
            let next = index.map { ($0 + (event.keyCode == 125 ? 1 : -1) + suggestions.count) % suggestions.count } ?? (event.keyCode == 125 ? 0 : suggestions.count - 1)
            selection.keyboardID = suggestions[next].id
            return nil
        case 36, 76:
            guard let id = selection.keyboardID else {
                dismiss()
                return event
            }
            choose?(id)
            return nil
        case 53:
            dismiss()
            return nil
        default:
            dismiss()
            return event
        }
    }

    /// The one synchronous answer to "may this request still act?": still the page's current request, the same provider
    /// and (for the credential manager) the same unlock, the feature still on, and the page still what it was shown for.
    /// Nothing here suspends, so a caller that runs it right before delivering anything is not racing a lock or a
    /// provider switch. Page, field and frame identity are the job of the asynchronous checks in `validate`.
    private func requireAuthority(_ request: Request, in page: BrowserPage) throws {
        guard requests[ObjectIdentifier(page)] === request, request.profileID == page.profileID,
              request.kind != .password || request.provider == PasswordAutofill.shared.provider,
              request.provider == .legacy || manager(for: request) != nil,
              AutofillSaveCoordinator.shared.isEnabled(request.kind, profileID: request.profileID), page.url == request.topURL,
              page.hasOnlySecureContent, page.window != nil, !page.isHiddenOrHasHiddenAncestor else { throw ContactAutofillError.changedPage }
    }

    private func validate(_ request: Request, in page: BrowserPage, requiresFocus: Bool = false) async throws {
        try requireAuthority(request, in: page)
        if let chromium = page.chromium {
            guard try await chromium.isLive(frame: request.frame) else { throw ContactAutofillError.changedPage }
        }
        let valid = try await page.callAsyncJavaScript("""
            const model = globalThis.__wsurfAutofillForms;
            const active = globalThis.__wsurfAutofillSuggestions?.active();
            if (model?.documentID !== documentID || !active || model.id(active) !== fieldID || model.group(active)?.id !== formID) return null;
            if (requiresFocus && !document.hasFocus()) return null;
            return globalThis[bridge]?.bounds(token, url);
            """, arguments: ["bridge": request.bridge, "token": request.token, "url": request.frameURL.absoluteString,
                        "requiresFocus": requiresFocus, "documentID": request.documentID, "formID": request.formID, "fieldID": request.fieldID, ],
            in: request.frame, contentWorld: request.world)
        let rect = try await awaitRect(valid, requestPage: page, frame: request.frame, frameURL: request.frameURL, world: request.world)
        guard abs(rect.minX - request.rect.minX) < 2, abs(rect.minY - request.rect.minY) < 2,
              abs(rect.width - request.rect.width) < 2, abs(rect.height - request.rect.height) < 2,
              requests[ObjectIdentifier(page)] === request, page.url == request.topURL, page.hasOnlySecureContent else {
            throw ContactAutofillError.changedPage
        }
        if let chromium = page.chromium {
            guard try await chromium.isLive(frame: request.frame) else { throw ContactAutofillError.changedPage }
        }
        // The Chromium liveness answer above was the last suspension: re-establish authority on the way out.
        try requireAuthority(request, in: page)
    }

    private func fill(_ id: UUID, request: Request, in page: BrowserPage) {
        guard !isFilling else { return }
        isFilling = true; dismiss()
        Task { [weak self, weak page] in
            defer { self?.isFilling = false }
            guard let self, let page else { return }
            do {
                try await self.validate(request, in: page)
                var fields: [String: Any] = [:]
                switch request.kind {
                case .password:
                    guard let origin = SavedPassword.origin(for: request.frameURL) else { throw ContactAutofillError.changedPage }
                    // The credential manager's vault is not touched here; it is read after the final checks below.
                    if request.provider != .credentialManager {
                        let vault = AutofillVaults.passwords(for: request.profileID)
                        let documentID = try await self.topDocumentID(in: page, world: request.world)
                        let auth = try await self.passwordAuthentication.session(
                            for: page,
                            profileID: request.profileID,
                            documentID: documentID,
                            origin: origin,
                            create: { await vault.makeAuthenticationSession() }
                        )
                        let records: [SavedPassword]
                        do { records = try await vault.records(using: auth) } catch { self.passwordAuthentication.clear(in: page); throw error }
                        guard let login = records.first(where: { $0.id == id }), login.origin == origin else { throw ContactAutofillError.noField }
                        self.passwordAuthentication.markAuthenticated(auth, in: page)
                        fields = ["username": login.username, "password": login.password]
                    }
                case .card:
                    guard let card = try await AutofillVaults.cards(for: request.profileID).cards().first(where: { $0.id == id }), !card.isExpired() else { throw PaymentCardError.noField }
                    fields = ["number": card.number, "cardholder": card.cardholder, "securityCode": card.securityCode ?? "", "month": card.month ?? 0, "year": card.year ?? 0]
                case .contact:
                    guard let contact = try await AutofillVaults.contacts(for: request.profileID).records().first(where: { $0.id == id }) else { throw ContactAutofillError.noField }
                    fields = contact.fields
                }
                try await self.validate(request, in: page)
                // One transport for every fill: the page call's arguments are produced by the engine at its true dispatch
                // boundary (after its own last suspension, which for Chromium includes its internal awaits), never earlier.
                let prepare: @MainActor @Sendable () throws -> [String: Any]
                var filledUsername: String?
                if request.provider == .credentialManager {
                    // Read last: the vault answer is valid for one unlock, revision and write generation. Whatever is
                    // computed from it is delivered only if all of that, and the request's native authority, still hold
                    // at the dispatch boundary. Secrets and the fresh TOTP are materialised there, in Swift only.
                    guard let origin = SavedPassword.origin(for: request.frameURL), let manager = self.manager(for: request) else {
                        throw ContactAutofillError.changedPage
                    }
                    let (account, generation) = try await self.managerAccount(id, request: request, origin: origin)
                    let field = request.field
                    prepare = { [weak self, weak page] in
                        guard let self, let page else { throw ContactAutofillError.changedPage }
                        try self.requireAuthority(request, in: page)
                        guard self.manager(for: request) === manager, manager.stableGeneration == generation,
                              manager.authorizationEpoch == request.epoch else {
                            throw ContactAutofillError.changedPage
                        }
                        var delivered: [String: Any]
                        switch field {
                        case .totp:
                            guard let code = CredentialAccountSelection.totpCode(for: account, origin: origin, at: .now) else {
                                throw ContactAutofillError.noField
                            }
                            delivered = ["code": code]
                        case .password:
                            delivered = ["username": account.username]
                            if let password = account.password { delivered["password"] = password }
                        }
                        return Self.fillArguments(request, fields: delivered)
                    }
                    if request.field == .password { filledUsername = account.username }
                } else {
                    // Legacy, card and contact values were read before this point exactly as before; the copy is only read.
                    nonisolated(unsafe) let legacy = fields
                    prepare = { Self.fillArguments(request, fields: legacy) }
                    filledUsername = fields["username"] as? String
                }
                let delivered = try await page.callAsyncJavaScript(
                    "if (globalThis.__wsurfAutofillForms?.documentID !== documentID) return 0; return globalThis[bridge]?.fill(token, url, fields) || 0;",
                    in: request.frame,
                    contentWorld: request.world,
                    prepareArguments: prepare
                )
                guard (delivered as? Int ?? 0) > 0 else { throw ContactAutofillError.noField }
                try await self.validate(request, in: page)
                if request.kind == .password, request.field == .password, let username = filledUsername,
                   let origin = SavedPassword.origin(for: request.frameURL) {
                    AutofillSaveCoordinator.shared.rememberFilledUsername(
                        username,
                        origin: origin,
                        documentID: request.documentID,
                        in: page,
                        accountID: request.provider == .credentialManager ? id : nil,
                        epoch: request.epoch
                    )
                }
            } catch {
                let canceled: Bool
                switch error {
                case AutofillVaultError.keychain(let status), PaymentCardError.keychain(let status):
                    canceled = status == errSecUserCanceled || status == errSecAuthFailed
                case CredentialVaultError.unauthorized, CredentialVaultError.expired:
                    canceled = true
                default:
                    canceled = false
                }
                guard !canceled, self.requests[ObjectIdentifier(page)] === request,
                      AutofillSaveCoordinator.shared.isEnabled(request.kind, profileID: request.profileID),
                      page.url == request.topURL, let window = page.window,
                      !page.isHiddenOrHasHiddenAncestor else { return }
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t Fill Saved Details")
                alert.informativeText = String(localized: "Select the field again to try again.")
                await alert.beginSheetModal(for: window)
            }
        }
    }

    private static func fillArguments(_ request: Request, fields: [String: Any]) -> [String: Any] {
        [
            "bridge": request.bridge,
            "token": request.token,
            "url": request.frameURL.absoluteString,
            "fields": fields,
            "documentID": request.documentID,
        ]
    }

    private func topDocumentID(in page: BrowserPage, world: WKContentWorld) async throws -> String {
        let value = try await page.callAsyncJavaScript("return globalThis.__wsurfAutofillForms?.documentID;", arguments: [:], in: nil, contentWorld: world)
        guard let value = value as? String, UUID(uuidString: value) != nil else { throw ContactAutofillError.changedPage }
        return value
    }
}

final class PasswordFillAuthenticationCache {
    private final class Entry: NSObject {
        let profileID: UUID
        let documentID: String
        let origin: String
        let session: AutofillAuthenticationSession
        var expiresAt: Date?
        init(profileID: UUID, documentID: String, origin: String, session: AutofillAuthenticationSession) {
            self.profileID = profileID
            self.documentID = documentID
            self.origin = origin
            self.session = session
        }
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let duration: TimeInterval = 5 * 60
    private var generation = 0

    func session(for page: BrowserPage, profileID: UUID, documentID: String, origin: String,
                 now: Date = .now, create: () async -> AutofillAuthenticationSession) async throws -> AutofillAuthenticationSession {
        let key = ObjectIdentifier(page)
        if let entry = entries[key], entry.profileID == profileID, entry.documentID == documentID,
           entry.origin == origin, let expiry = entry.expiresAt, now < expiry {
            return entry.session
        }
        clear(in: page); let generation = generation; let session = await create()
        guard self.generation == generation else { session.invalidate(); throw ContactAutofillError.changedPage }
        entries[key] = Entry(profileID: profileID, documentID: documentID, origin: origin, session: session); return session
    }
    func markAuthenticated(_ session: AutofillAuthenticationSession, in page: BrowserPage, now: Date = .now) {
        let key = ObjectIdentifier(page)
        guard let entry = entries[key], entry.session === session else { return }
        if entry.expiresAt == nil {
            entry.expiresAt = now.addingTimeInterval(duration)
        }
    }
    func clear(in page: BrowserPage) {
        generation += 1
        entries.removeValue(forKey: ObjectIdentifier(page))?.session.invalidate()
    }
    func clear() {
        generation += 1
        entries.values.forEach { $0.session.invalidate() }
        entries.removeAll()
    }
}

private final class AutofillSuggestionPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }
    override var canBecomeMain: Bool {
        false
    }
}
