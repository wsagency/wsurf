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
        let context: BrowserProfileContext
        let frame: BrowserFrame
        let token: String
        let kind: AutofillSaveKind
        let frameURL: URL
        let topURL: URL
        let world: WKContentWorld
        let bridge: String
        let documentID: String
        let formID: String
        let fieldID: String
        var rect = NSRect.zero
        /// What this request asked for. Set once; a later change of vault state makes the request stale instead of redirecting it.
        let field: CredentialAutofillField
        let enteredUsername: String?
        /// Whether typing may start the dropdown's search: only in a username field. In a password or code field a search starts
        /// with a click on the search row, so typed password characters are never taken as a query.
        let typeToSearch: Bool
        /// One unlocked vault the request read, with the lease and revision it read it under.
        struct Grant {
            let epoch: UInt64
            let revision: UInt64
        }
        var grants: [UUID: Grant] = [:]
        /// What the panel returns (a fresh id per row) -> the owning vault and its account. Two vaults may hold the same account id.
        var rows: [UUID: (vaultID: UUID, accountID: UUID)] = [:]
        /// Rows that list an account of a sibling website (`CredentialAccountSelection.siblings`), not of the page's origin.
        var siblingRows: Set<UUID> = []
        /// The rows behind "Check other logins": titles and websites only. No secret is read until one of them is chosen.
        var siblings: [AutofillSuggestion] = []
        /// A row that is not an account, and what choosing it does.
        enum Action {
            case siblings
        }
        var actions: [UUID: Action] = [:]

        init(page: BrowserPage, context: BrowserProfileContext, frame: BrowserFrame, token: String, kind: AutofillSaveKind,
             frameURL: URL, topURL: URL, world: WKContentWorld, bridge: String,
             documentID: String, formID: String, fieldID: String,
             field: CredentialAutofillField, enteredUsername: String?, typeToSearch: Bool) {
            self.page = page; self.context = context; self.frame = frame; self.token = token; self.kind = kind
            self.frameURL = frameURL; self.topURL = topURL
            self.world = world; self.bridge = bridge; self.documentID = documentID
            self.formID = formID; self.fieldID = fieldID
            self.field = field; self.enteredUsername = enteredUsername; self.typeToSearch = typeToSearch
        }
    }

    private var requests: [ObjectIdentifier: Request] = [:]
    private weak var page: BrowserPage?
    private var presentationID = UUID()
    private var panel: AutofillSuggestionPanel?
    private var searchIndex: AutofillSuggestionSearch.Index?
    private let selection = AutofillSuggestionSelection()
    private var choose: ((UUID) -> Void)?
    private var eventMonitor: Any?
    /// Key codes whose key-down became search text. Their key-up is ours too: a page that saw only the key-up would learn the letter.
    private var heldKeys: Set<UInt16> = []
    private var keyUpMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var navigation: NSKeyValueObservation?
    private var loading: NSKeyValueObservation?
    private var isFilling = false
    private var geometryWatch: Task<Void, Never>?

    private init() {}

    func reset() {
        dismiss()
        requests.removeAll()
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
        panel = nil; self.page = nil; searchIndex = nil; choose = nil; selection.state = .init(rowCount: 0)
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

    func receive(_ message: BrowserScriptMessage, kind: AutofillSaveKind,
                 world: WKContentWorld, bridge: String) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let token = body["token"] as? String, UUID(uuidString: token) != nil else { return }
        let page = message.page
        let context = page.context
        let profileID = context.profile.id
        let key = ObjectIdentifier(page)
        if action == "dismiss" || action == "hide" {
            guard requests[key]?.token == token, requests[key]?.context === context else { return }
            if action == "dismiss" { requests[key] = nil }
            dismiss(in: page)
            return
        }
        guard action == "select", !isFilling,
              let documentID = body["documentID"] as? String, UUID(uuidString: documentID) != nil,
              let formID = body["formID"] as? String, Int(formID) ?? 0 > 0,
              let fieldID = body["fieldID"] as? String, Int(fieldID) ?? 0 > 0,
              AutofillSaveCoordinator.shared.isEnabled(kind, context: context),
              let rawURL = body["url"] as? String, let frameURL = URL(string: rawURL),
              let topURL = page.url, SavedPassword.origin(for: topURL) != nil,
              let origin = SavedPassword.origin(for: frameURL), page.hasOnlySecureContent,
              message.frameInfo.hasTrustedSecurityOrigin, message.frameInfo.securityOrigin.protocol == "https",
              message.frameInfo.securityOrigin.host == frameURL.host?.lowercased(),
              (message.frameInfo.securityOrigin.port == 0 ? 443 : message.frameInfo.securityOrigin.port) == (frameURL.port ?? 443),
              body["rect"] is [String: Double],
              Self.canPresent(in: page) else { return }
        let rawRect = body["rect"]
        if let old = requests[key], old.token == token, old.documentID == documentID {
            return
        }
        dismiss()
        let manager = kind == .password
        let enteredUsername = manager ? (body["username"] as? String).flatMap { $0.isEmpty || $0.count > 500 ? nil : $0 } : nil
        let request = Request(page: page, context: context, frame: message.frameInfo, token: token, kind: kind,
                              frameURL: frameURL, topURL: topURL, world: world,
                              bridge: bridge, documentID: documentID, formID: formID, fieldID: fieldID,
                              field: manager && body["field"] as? String == "totp" ? .totp : .password,
                              enteredUsername: enteredUsername, typeToSearch: manager && body["kind"] as? String == "username")
        requests[key] = request; self.page = page
        let id = presentationID
        Task { [weak self, weak page] in
            guard let self, let page, page.context === context, id == self.presentationID,
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
            guard page.context === context, id == self.presentationID, let records, !records.isEmpty,
                  (try? await self.validate(request, in: page, requiresFocus: true)) != nil,
                  Self.canPresent(in: page) else { return }
            self.show(records, request: request, in: page)
        }
    }

    /// The manager that may answer for `vaultID`: same profile, and still the unlock the request read it under.
    private func manager(for request: Request, vault vaultID: UUID) -> CredentialManager? {
        let context = request.context
        guard !context.profile.isPrivate, request.page.context === context, let epoch = request.grants[vaultID]?.epoch else { return nil }
        return CredentialManager.unlockedManagers(for: context.profile).first { $0.vaultID == vaultID && $0.authorizationEpoch == epoch }
    }

    /// Every vault the request read is still the unlock it was read under.
    private func managersAreCurrent(for request: Request) -> Bool {
        !request.grants.isEmpty && request.grants.keys.allSatisfy { manager(for: request, vault: $0) != nil }
    }

    /// Account choices for `request`: the union over the profile's unlocked vaults, each read under its own lease. A locked
    /// vault is never read; unlocking happens in settings. Locked, stale or mis-originated requests get no dropdown. The
    /// picked-account lookup can invalidate the carry-over, so it runs only while this is still the page's current request
    /// and presentation. With nothing for the exact origin, a password field gets one row that lists the accounts of sibling
    /// websites (`CredentialDropdown`); the default list itself never widens.
    private func managerSuggestions(for request: Request, origin: String, presentation: UUID) async -> [AutofillSuggestion]? {
        let context = request.context
        guard !context.profile.isPrivate, request.page.context === context,
              CredentialAccountSelection.origin(for: request.frameURL) == origin else { return nil }
        // Vaults in ordinal order; a vault the listing does not know (or a locked one) is never read.
        let listing = (try? await CredentialManager.store(for: context.profile).listing()) ?? []
        let unlocked = CredentialManager.unlockedManagers(for: context.profile)
        struct Read {
            let manager: CredentialManager
            let epoch: UInt64
            let snapshot: StoreSnapshot
            let label: String
        }
        var reads: [Read] = []
        for vault in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            if let manager = unlocked.first(where: { $0.vaultID == vault.vaultID }), let epoch = manager.authorizationEpoch,
               let snapshot = try? await manager.snapshot(), manager.authorizationEpoch == epoch {
                reads.append(Read(manager: manager, epoch: epoch, snapshot: snapshot, label: vault.name ?? String(localized: "Vault \(vault.ordinal)")))
            }
        }
        guard !reads.isEmpty, request.page.context === context,
              presentation == presentationID, requests[ObjectIdentifier(request.page)] === request else { return nil }
        request.grants = Dictionary(
            uniqueKeysWithValues: reads.map { ($0.manager.vaultID, Request.Grant(epoch: $0.epoch, revision: $0.snapshot.revision)) })
        // Frame, focus and field must still be the ones asked about before the pick is read (and possibly invalidated).
        guard (try? await validate(request, in: request.page, requiresFocus: true)) != nil,
              presentation == presentationID, requests[ObjectIdentifier(request.page)] === request else { return nil }
        // A picked account names exactly one lease (epochs are process-unique): ask on its owner's behalf while that lease is
        // live, otherwise on any live lease's, which retires the pick. A live pick answers alone, from its own vault.
        let session = AutofillSaveCoordinator.shared.session(for: request.page)
        let owner = reads.first { $0.epoch == session?.username?.epoch } ?? reads[0]
        let pinned = session?.selectedAccount(
            in: request.page, origin: origin, enteredUsername: request.enteredUsername, epoch: owner.epoch)
        var result: [AutofillSuggestion] = []
        for read in pinned == nil ? reads : [owner] {
            for row in CredentialAccountSelection.suggestions(
                read.snapshot.accounts, origin: origin, pageURL: request.topURL, entered: request.enteredUsername,
                field: request.field, pinned: pinned
            ) {
                let rowID = UUID()
                request.rows[rowID] = (read.manager.vaultID, row.id)
                // With several vaults open, a row says which one it is in.
                let detail = reads.count > 1 ? [row.detail, read.label].filter { !$0.isEmpty }.joined(separator: " · ") : row.detail
                result.append(AutofillSuggestion(id: rowID, title: row.title, detail: detail, origin: origin))
            }
        }
        guard result.isEmpty, request.field == .password else { return result }
        var siblings: [AutofillSuggestion] = []
        for read in reads {
            for (account, website) in CredentialAccountSelection.siblings(
                in: read.snapshot.accounts, origin: origin, entered: request.enteredUsername
            ) {
                let rowID = UUID()
                request.rows[rowID] = (read.manager.vaultID, account.id)
                request.siblingRows.insert(rowID)
                // A sibling row says which website the account is saved for, and with several vaults open, which vault.
                let host = String(website.dropFirst("https://".count))
                let detail = reads.count > 1 ? "\(host) · \(read.label)" : host
                siblings.append(AutofillSuggestion(
                    id: rowID, title: CredentialAccountSelection.title(account, origin: website), detail: detail, origin: origin
                ))
            }
        }
        guard case .siblings(let site) = CredentialDropdown.plan(
            exact: result.count, siblings: siblings.count, origin: origin, field: request.field
        ) else { return result }
        request.siblings = siblings
        let rowID = UUID()
        request.actions[rowID] = .siblings
        return [AutofillSuggestion(id: rowID, title: String(localized: "Check other logins for *.\(site)"), detail: "", origin: origin)]
    }

    /// What may be delivered for the row `rowID` now: the account must still exist in the vault that owns the row, still be
    /// associated with this origin (a sibling row: with a sibling website of it), and that vault must be the same unlock and
    /// revision the choice was shown under. The
    /// returned generation is the vault content generation the answer is valid for: it was available (no write in flight)
    /// before the read and is unchanged after it, and the caller must see it unchanged again immediately before delivering.
    private func managerAccount(
        _ rowID: UUID, request: Request, origin: String
    ) async throws -> (manager: CredentialManager, account: CredentialAccount, generation: UInt64) {
        guard let row = request.rows[rowID], let manager = manager(for: request, vault: row.vaultID),
              let grant = request.grants[row.vaultID],
              CredentialAccountSelection.origin(for: request.frameURL) == origin,
              let generation = manager.stableGeneration else { throw ContactAutofillError.changedPage }
        let snapshot = try await manager.snapshot()
        guard manager.authorizationEpoch == grant.epoch, manager.stableGeneration == generation,
              snapshot.vaultID == row.vaultID, snapshot.revision == grant.revision,
              let account = snapshot.accounts.first(where: { $0.id == row.accountID }),
              account.origins.contains(origin)
                || (request.siblingRows.contains(rowID) && CredentialAccountSelection.isSibling(account, of: origin)) else {
            throw ContactAutofillError.changedPage
        }
        return (manager, account, generation)
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
        let index = AutofillSuggestionSearch.Index(records, searchable: request.kind == .password)
        let desired = AutofillSuggestionLayout.height(for: records.count, searchable: index.isSearchable)
        let below = availableBelow >= desired || (availableAbove < desired && availableBelow >= availableAbove)
        let height = min(desired, below ? availableBelow : availableAbove)
        guard width >= 200, height >= AutofillSuggestionLayout.minimumHeight else { return }
        let frame = NSRect(x: max(area.minX + 8, min(field.minX, area.maxX - width - 8)), y: below ? field.minY - height - 4 : field.maxY + 4, width: width, height: height)
        let panel = AutofillSuggestionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel(String(localized: "Autofill suggestions"))
        selection.state = .init(rowCount: records.count)
        let content = NSHostingView(rootView: AutofillSuggestionList(kind: request.kind, origin: origin, suggestions: records, searchable: index.isSearchable,
            selection: selection, choose: { [weak self] id in self?.choose?(id) }, beginSearch: { [weak self] in self?.selection.state.beginSearching() },
            manage: { [weak self] in self?.dismiss(); self?.openSettings?() })
            .frame(width: frame.width, height: frame.height, alignment: .topLeading).clipShape(.rect(cornerRadius: 10)))
        content.sizingOptions = []; content.safeAreaRegions = []; content.frame = NSRect(origin: .zero, size: frame.size); content.autoresizingMask = [.width, .height]
        panel.contentView = content; panel.contentMinSize = frame.size; panel.contentMaxSize = frame.size; panel.setFrame(frame, display: false)
        self.panel = panel; searchIndex = index
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
        guard event.type == .keyDown, let page, let index = searchIndex, Self.isFocused(page) else { dismiss(); return event }
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { dismiss(); return event }
        let key = AutofillSuggestionSearch.KeyInput(event)
        let typeToSearch = requests[ObjectIdentifier(page)]?.typeToSearch == true && !Self.usesInputMethod(page)
        let (state, effect) = AutofillSuggestionSearch.reduce(selection.state, key, index: index, typeToSearch: typeToSearch)
        selection.state = state
        switch effect {
        case .consume:
            switch key {
            case .character, .backspace:
                hold(event.keyCode)
            default:
                break
            }
            return nil
        case .pass:
            return event
        case .dismissAndPass:
            dismiss()
            return event
        case .dismiss:
            dismiss()
            return nil
        case .choose(let id):
            choose?(id)
            return nil
        }
    }

    private func hold(_ keyCode: UInt16) {
        heldKeys.insert(keyCode)
        guard keyUpMonitor == nil else { return }
        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.release(event.keyCode) ?? false }
            return consumed ? nil : event
        }
    }

    private func release(_ keyCode: UInt16) -> Bool {
        let held = heldKeys.remove(keyCode) != nil
        if heldKeys.isEmpty, let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
        return held
    }

    /// An input method composes text from several key presses, so a raw key is not yet a character of the query. Only a plain keyboard
    /// layout starts a search by typing; with an input method a search starts with the click on the search row.
    private static func usesInputMethod(_ page: BrowserPage) -> Bool {
        guard let source = (page.window?.firstResponder as? NSView)?.inputContext?.selectedKeyboardInputSource else { return false }
        return !source.hasPrefix("com.apple.keylayout.")
    }

    /// The one synchronous answer to "may this request still act?": still the page's current request, (for a password) the
    /// same unlock, the feature still on, and the page still what it was shown for. Nothing here suspends, so a caller that
    /// runs it right before delivering anything is not racing a lock. Page, field and frame identity are the job of the
    /// asynchronous checks in `validate`.
    private func requireAuthority(_ request: Request, in page: BrowserPage) throws {
        guard requests[ObjectIdentifier(page)] === request, request.context === page.context,
              request.kind != .password || managersAreCurrent(for: request),
              AutofillSaveCoordinator.shared.isEnabled(request.kind, context: request.context), page.url == request.topURL,
              page.hasOnlySecureContent, page.window != nil, !page.isHiddenOrHasHiddenAncestor else { throw ContactAutofillError.changedPage }
    }

    private func validate(_ request: Request, in page: BrowserPage, requiresFocus: Bool = false) async throws {
        try requireAuthority(request, in: page)
        if let chromium = page.chromium {
            guard try await chromium.isLive(frame: request.frame), request.context === page.context else { throw ContactAutofillError.changedPage }
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
        guard request.context === page.context else { throw ContactAutofillError.changedPage }
        let rect = try await awaitRect(valid, requestPage: page, frame: request.frame, frameURL: request.frameURL, world: request.world)
        guard abs(rect.minX - request.rect.minX) < 2, abs(rect.minY - request.rect.minY) < 2,
              abs(rect.width - request.rect.width) < 2, abs(rect.height - request.rect.height) < 2,
              requests[ObjectIdentifier(page)] === request, request.context === page.context,
              page.url == request.topURL, page.hasOnlySecureContent else {
            throw ContactAutofillError.changedPage
        }
        if let chromium = page.chromium {
            guard try await chromium.isLive(frame: request.frame), request.context === page.context else { throw ContactAutofillError.changedPage }
        }
        // The Chromium liveness answer above was the last suspension: re-establish authority on the way out.
        try requireAuthority(request, in: page)
    }

    /// The "Check other logins" row: the same request now shows the sibling accounts it read. Nothing is read again, and no secret
    /// is touched, until one of them is chosen.
    private func showSiblings(_ request: Request, in page: BrowserPage) {
        let siblings = request.siblings
        guard !siblings.isEmpty, requests[ObjectIdentifier(page)] === request else { return }
        dismiss()
        self.page = page
        let id = presentationID
        Task { [weak self, weak page] in
            guard let self, let page, id == self.presentationID,
                  (try? await self.validate(request, in: page, requiresFocus: true)) != nil,
                  id == self.presentationID, Self.canPresent(in: page) else { return }
            self.show(siblings, request: request, in: page)
        }
    }

    private func fill(_ id: UUID, request: Request, in page: BrowserPage) {
        if request.actions[id] == .siblings {
            showSiblings(request, in: page)
            return
        }
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
                    // The vault is not touched here; it is read after the final checks below.
                    break
                case .card:
                    guard let card = try await AutofillVaults.cards(for: request.context.profile.id).cards().first(where: { $0.id == id }), !card.isExpired() else { throw PaymentCardError.noField }
                    fields = ["number": card.number, "cardholder": card.cardholder, "securityCode": card.securityCode ?? "", "month": card.month ?? 0, "year": card.year ?? 0]
                case .contact:
                    guard let contact = try await AutofillVaults.contacts(for: request.context.profile.id).records().first(where: { $0.id == id }) else { throw ContactAutofillError.noField }
                    fields = contact.fields
                }
                try await self.validate(request, in: page)
                // One transport for every fill: the page call's arguments are produced by the engine at its true dispatch
                // boundary (after its own last suspension, which for Chromium includes its internal awaits), never earlier.
                let prepare: @MainActor @Sendable () throws -> [String: Any]
                var filledUsername: String?
                if request.kind == .password {
                    let filled = try await self.managerFill(id, request: request, in: page)
                    prepare = filled.prepare
                    filledUsername = filled.username
                } else {
                    // Card and contact values were read before this point; the copy is only read.
                    nonisolated(unsafe) let values = fields
                    prepare = { [weak self, weak page] in
                        guard let self, let page else { throw ContactAutofillError.changedPage }
                        try self.requireAuthority(request, in: page)
                        return Self.fillArguments(request, fields: values)
                    }
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
                    let picked = request.rows[id]
                    AutofillSaveCoordinator.shared.rememberFilledUsername(
                        username,
                        origin: origin,
                        documentID: request.documentID,
                        in: page,
                        accountID: picked?.accountID,
                        epoch: picked.flatMap { request.grants[$0.vaultID]?.epoch }
                    )
                }
                // A login of a sibling website was just used here: offer to add this website to it, instead of a copy later.
                if request.kind == .password, request.field == .password, request.siblingRows.contains(id),
                   let picked = request.rows[id], let epoch = request.grants[picked.vaultID]?.epoch,
                   let origin = SavedPassword.origin(for: request.frameURL),
                   let session = AutofillSaveCoordinator.shared.session(for: page) {
                    let documentID = request.documentID
                    Task { await session.offerWebsite(accountID: picked.accountID, epoch: epoch, origin: origin, documentID: documentID) }
                }
            } catch {
                let canceled = Self.isUserCancellation(error)
                guard !canceled, self.requests[ObjectIdentifier(page)] === request,
                      AutofillSaveCoordinator.shared.isEnabled(request.kind, context: request.context),
                      page.url == request.topURL, let window = page.window,
                      !page.isHiddenOrHasHiddenAncestor else { return }
                let alert = NSAlert()
                alert.messageText = String(localized: "Couldn’t Fill Saved Details")
                alert.informativeText = String(localized: "Select the field again to try again.")
                await alert.beginSheetModal(for: window)
            }
        }
    }

    /// The encrypted-store branch of a fill: the vault answer is read here, last, and is valid for one unlock, revision and
    /// write generation. The returned closure delivers whatever is computed from it only if all of that, and the request's
    /// native authority, still hold at the engine's dispatch boundary. Secrets and the fresh TOTP are materialised there, in
    /// Swift only. The username is the one a later save may correlate with, and only for a password field.
    private func managerFill(
        _ id: UUID, request: Request, in page: BrowserPage
    ) async throws -> (prepare: @MainActor @Sendable () throws -> [String: Any], username: String?) {
        guard let origin = SavedPassword.origin(for: request.frameURL), let row = request.rows[id] else {
            throw ContactAutofillError.changedPage
        }
        let (manager, account, generation) = try await managerAccount(id, request: request, origin: origin)
        let field = request.field
        let epoch = request.grants[row.vaultID]?.epoch
        let prepare: @MainActor @Sendable () throws -> [String: Any] = { [weak self, weak page] in
            guard let self, let page else { throw ContactAutofillError.changedPage }
            try self.requireAuthority(request, in: page)
            guard self.manager(for: request, vault: row.vaultID) === manager, manager.stableGeneration == generation,
                  manager.authorizationEpoch == epoch else {
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
                if let password = account.password {
                    delivered["password"] = password
                }
            }
            return Self.fillArguments(request, fields: delivered)
        }
        return (prepare, field == .password ? account.username : nil)
    }

    /// A prompt the user dismissed or failed is not an error worth a second alert.
    private static func isUserCancellation(_ error: any Error) -> Bool {
        switch error {
        case AutofillVaultError.keychain(let status), PaymentCardError.keychain(let status):
            status == errSecUserCanceled || status == errSecAuthFailed
        case CredentialVaultError.unauthorized, CredentialVaultError.expired:
            true
        default:
            false
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
}

nonisolated extension AutofillSuggestionSearch.KeyInput {
    /// A key-down as the dropdown sees it. Function keys report private-use characters and Tab reports a control character: neither is text.
    init(_ event: NSEvent) {
        switch event.keyCode {
        case 125:
            self = .down
        case 126:
            self = .up
        case 36, 76:
            self = .enter
        case 53:
            self = .escape
        case 51:
            self = .backspace
        default:
            let isText = event.characters.map { text in
                text.count == 1 && text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }
            } ?? false
            self = isText ? .character(event.characters ?? "") : .other
        }
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
