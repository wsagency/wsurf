// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import WebKit

/// Routes `navigator.credentials` public-key calls from both engines to the native website authenticator.
///
/// The page-facing script only marshals; every authority input (origin, frame, policy, profile, anchor) is derived here
/// from native engine state. A request is registered by `(page, document, request)`; a result is delivered only through
/// the relay's document fence and a native check made at the moment of dispatch, so it can neither reach another
/// document nor arrive twice, and a result whose vault authority changed after it was made is refused.
@MainActor
enum WebAuthnAdapter {
    /// The engine's own isolated world, where the native frame nonce lives; the page world never sees it or the relay.
    private static let world = PageAutomationGuard.world
    private static let installedPages = NSHashTable<BrowserPage>.weakObjects()
    private static var entries: [Key: Entry] = [:]

    private struct Key: Hashable {
        let page: ObjectIdentifier
        let document: String
        let request: String
    }

    @MainActor
    private final class Entry {
        let key: Key
        weak var page: BrowserPage?
        let frame: BrowserFrame
        let profileID: UUID
        /// The profile context that owned the page when the request arrived; a provider change reaches only this one.
        let contextID: UUID
        /// The page's document generation when the relay's message arrived: the request belongs to exactly that document.
        let generation: UInt64
        let parsed: WebAuthnWire.Parsed
        var task: Task<Void, Never>?
        var expiryTask: Task<Void, Never>?
        var started = false
        var cancelled = false

        init(key: Key, page: BrowserPage, frame: BrowserFrame, parsed: WebAuthnWire.Parsed) {
            self.key = key
            self.page = page
            self.frame = frame
            profileID = page.profileID
            contextID = page.context.contextID
            generation = page.credentialGeneration
            self.parsed = parsed
        }
    }

    // MARK: Installation and cancellation

    static func install(in page: BrowserPage) {
        guard !installedPages.contains(page) else { return }
        installedPages.add(page)
        page.installScript(
            WebAuthnScript.relay(nativeNonce: page.chromium == nil), in: world,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        // Document-start order is the contract: the frame registry, then the relay, then the route script, then the page
        // script. `replaceScript` swaps the route script in its own position, so that order is preserved.
        let route = routeScript(for: page)
        routes.setObject(Route(source: route, mode: routeMode(for: page)), forKey: page)
        page.installScript(route, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.installScript(WebAuthnScript.page, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        page.addScriptMessageHandler(name: WebAuthnScript.handlerName, in: world) { message in
            handle(message)
        }
        // The page's own invalidation point (navigation, frame replacement, process loss, close): synchronous and before any
        // await, without touching the callbacks the tab owns.
        page.addCredentialInvalidationObserver { page, documentID in cancel(in: page, documentID: documentID) }
    }

    /// The page's documents are going away (`documentID` nil: all of them; otherwise only that retired document): every
    /// matching request is dropped synchronously. Invalidation starts at a provisional navigation, which can still fail and
    /// leave the original document alive, so the same captured fence also gets one non-secret refusal afterwards: the
    /// original document's promise ends, a replaced document ignores it.
    static func cancel(in page: BrowserPage, documentID: String?) {
        let identity = ObjectIdentifier(page)
        let retired = documentID.flatMap { $0.isEmpty ? nil : $0 }
        for entry in Array(entries.values) where entry.key.page == identity && (retired == nil || entry.frame.documentID == retired) {
            refuse(entry)
        }
    }

    /// The profile's vault access ended (lock, profile switch, erase): its pending ceremonies stop synchronously, before
    /// anything can suspend, and live documents learn it as one `NotAllowedError`. A registration whose write already
    /// landed keeps its receipt inside the ceremony.
    static func cancel(profileID: UUID) {
        for entry in Array(entries.values) where entry.profileID == profileID {
            refuse(entry)
        }
    }

    /// This context's password provider changed: none of its pending ceremonies may continue under the other authority, and
    /// every live document of its pages learns the provider that now owns its passkey calls. Other contexts are untouched.
    static func providerChanged(in context: BrowserProfileContext) {
        routeSequence += 1
        for entry in Array(entries.values) where entry.contextID == context.contextID {
            refuse(entry)
        }
        for page in installedPages.allObjects where !page.isClosed && page.context === context {
            reconcileRoute(of: page)
        }
    }

    /// The provider announcement the page script obeys synchronously. Native decides it; the page can forge the hint but
    /// native refuses any manager request it does not itself serve, and never passes a manager request to the engine.
    private static var routeSequence = 0

    private static func routeMode(for page: BrowserPage) -> String { isHandled(by: page) ? "manager" : "legacy" }

    private static func routeScript(for page: BrowserPage) -> String {
        WebAuthnScript.route(routeMode(for: page), sequence: routeSequence)
    }

    /// The one route script this page owns: its installed source and mode, replaced in place (never appended) when the mode
    /// changes. Changes made while a replacement is running are folded into the next pass of the same loop, so when every
    /// replacement succeeds the final state matches the latest provider. A failed replacement ends the loop with the old
    /// source and mode still recorded (see `reconcileRoute`).
    @MainActor
    private final class Route {
        var source: String
        var mode: String
        var dirty = false
        var running = false
        init(source: String, mode: String) {
            self.source = source
            self.mode = mode
        }
    }

    private static let routes = NSMapTable<BrowserPage, Route>.weakToStrongObjects()

    /// Documents created from now on get the replaced script at document start; documents already live are told directly
    /// after it landed (a cached document asks for itself when it is restored, see `handle`).
    private static func reconcileRoute(of page: BrowserPage) {
        guard let route = routes.object(forKey: page) else { return }
        route.dirty = true
        guard !route.running else { return }
        route.running = true
        Task {
            while route.dirty, !page.isClosed {
                route.dirty = false
                let mode = routeMode(for: page)
                guard mode != route.mode else { continue }
                let source = routeScript(for: page)
                // A failed replacement (page closed, old script no longer installed, a DevTools command refused) keeps the
                // recorded source and mode as they were, and nothing is pushed to live documents: the page stays on its
                // previous announcement until the next provider change tries again. Not retried here.
                do { try await page.replaceScript(route.source, with: source, in: world) } catch { break }
                route.source = source
                route.mode = mode
                _ = try? await page.callAsyncJavaScript(source, in: nil, contentWorld: world)
                for target in await PageFrameRegistry.shared.targets(in: page) {
                    _ = try? await page.callAsyncJavaScript(source, in: target.frame, contentWorld: world)
                }
            }
            route.running = false
        }
    }

    private static func refuse(_ entry: Entry) {
        discard(entry)
        guard let page = entry.page else { return }
        let key = entry.key, frame = entry.frame
        Task { await deliver(["error": errorPayload(WebsiteAuthenticatorError.notAllowed)], key: key, page: page, frame: frame) }
    }

    /// A modal request reached its deadline. Everything is invalidated and the run is cancelled synchronously, before any
    /// await; the page gets one non-secret failure afterwards. Cancellation is not rollback: a registration whose write
    /// already landed keeps its receipt (`run`).
    private static func expire(_ entry: Entry) {
        // Cleared first so `discard` cannot cancel the task that is running this.
        entry.expiryTask = nil
        guard !entry.cancelled, entries[entry.key] === entry else { return }
        refuse(entry)
    }

    private static func discard(_ entry: Entry) {
        entry.cancelled = true
        entry.task?.cancel()
        retire(entry)
    }

    /// The entry no longer waits for anything: its expiry task ends with it.
    private static func retire(_ entry: Entry) {
        entry.expiryTask?.cancel()
        entry.expiryTask = nil
        if entries[entry.key] === entry {
            entries[entry.key] = nil
        }
    }

    // MARK: Messages

    private static func handle(_ message: BrowserScriptMessage) {
        let page = message.page
        guard !page.isClosed, let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let document = body["document"] as? String, document.count <= 64,
              let id = body["id"] as? String, (1...80).contains(id.count) else { return }
        // An empty document is the relay saying its native handshake gave this document no identity. Never a frame to
        // authorize against: the legacy provider still passes the call through, the encrypted one refuses it.
        guard !document.isEmpty || action == "request" || action == "route" else { return }
        let key = Key(page: ObjectIdentifier(page), document: document, request: id)
        switch action {
        case "cancel":
            if let entry = entries[key] {
                discard(entry)
            }
        case "conditionalActivate":
            if let entry = entries[key], entry.parsed.mediation == .conditional {
                start(entry)
            }
        case "route":
            // A document restored from the back/forward cache asks once for the provider that owns it now. Only the answer
            // (`legacy` or `manager`) goes back, to the frame that asked; it is a hint, never an authority.
            Task { _ = try? await page.callAsyncJavaScript(routeScript(for: page), in: message.frameInfo, contentWorld: world) }
        case "request":
            // Only the encrypted provider needs a verified document. WebKit: the request is served for the main frame whose
            // native-issued nonce it carries; a message from an older or replaced document, a subframe or an unknown frame
            // never reaches a prompt and gets one error aimed only at the document that asked. Chromium's frame comes from
            // its CDP-attributed message and is verified by the context. The legacy provider passes every call through.
            var frame = message.frameInfo
            if document.isEmpty {
                guard !isHandled(by: page) else {
                    if body["operation"] as? String == "capabilities" {
                        Task {
                            await deliver(["result": ["provider": "manager", "enabled": false, "canVerifyUser": false]], key: key, page: page, frame: frame)
                        }
                    } else {
                        reject(key, page, frame, WebAuthnWire.PageError(
                            name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform."
                        ))
                    }
                    return
                }
            } else if isHandled(by: page), page.chromium == nil {
                guard let native = PageFrameRegistry.shared.currentMainFrame(
                    matching: message.frameInfo, documentNonce: document, in: page
                ) else {
                    reject(key, page, message.frameInfo, WebAuthnWire.PageError(
                        name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform."
                    ))
                    return
                }
                frame = native
            }
            if body["operation"] as? String == "capabilities" {
                answerCapabilities(key: key, page: page, frame: frame)
            } else {
                register(body, key: key, page: page, frame: frame)
            }
        default:
            return
        }
    }

    /// Whether the encrypted provider handles passkeys for this page. When it does not, the page script hands the call to
    /// the engine, so selecting the legacy provider changes nothing.
    private static func isHandled(by page: BrowserPage) -> Bool {
        page.context.settings.passwordProvider == .credentialManager && !page.isPrivate
    }

    /// The provider decision the page script obeys. `legacy` is only ever said for a page the encrypted provider does not
    /// serve at all (legacy provider selected, or a private page); that alone lets the engine's own WebAuthn run. A page
    /// the manager serves is `manager`, and it is enabled only when the manager's profile is this page's profile: a
    /// stale or foreign page is `manager` with `enabled: false`, which is a refusal, never legacy.
    private static func answerCapabilities(key: Key, page: BrowserPage, frame: BrowserFrame) {
        let handled = isHandled(by: page)
        let enabled = handled
        let canVerify = enabled && NativeWebAuthnInteraction().canVerifyUser
        Task {
            await deliver(
                ["result": ["provider": handled ? "manager" : "legacy", "enabled": enabled, "canVerifyUser": canVerify]],
                key: key, page: page, frame: frame
            )
        }
    }

    private static func register(_ body: [String: Any], key: Key, page: BrowserPage, frame: BrowserFrame) {
        guard entries[key] == nil else { return }
        // The page script asks for the provider first and only sends a request to the manager when told so. A request that
        // still arrives for a page the manager does not serve (the provider changed in between) is refused, never handed
        // to the engine.
        guard isHandled(by: page) else {
            reject(key, page, frame, WebAuthnWire.PageError(
                name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform."
            ))
            return
        }
        let parsed: WebAuthnWire.Parsed
        do { parsed = try WebAuthnWire.parse(body) } catch {
            reject(key, page, frame, WebAuthnWire.pageError(error))
            return
        }
        let entry = Entry(key: key, page: page, frame: frame, parsed: parsed)
        entries[key] = entry
        // A conditional request has no lifetime of its own (`deadline` is nil). Every other request expires natively at its
        // deadline whatever it is waiting for (unlock, a sheet, verification, delivery): one task, owned by the entry.
        if let deadline = parsed.request.deadline {
            entry.expiryTask = Task { [weak entry] in
                guard (try? await Task.sleep(until: deadline, clock: .continuous)) != nil, let entry else { return }
                expire(entry)
            }
        }
        // A conditional request is only a registered discovery: nothing is unlocked, asked or signed until the user
        // activates a webauthn field (reported by the relay only for a trusted gesture) and then explicitly accepts the
        // native offer that precedes any unlock.
        if parsed.mediation != .conditional {
            start(entry)
        }
    }

    private static func reject(_ key: Key, _ page: BrowserPage, _ frame: BrowserFrame, _ error: WebAuthnWire.PageError) {
        Task { await deliver(["error": ["name": error.name, "message": error.message]], key: key, page: page, frame: frame) }
    }

    // MARK: Ceremony

    private static func start(_ entry: Entry) {
        guard !entry.started, !entry.cancelled, entries[entry.key] === entry else { return }
        entry.started = true
        entry.task = Task { await run(entry) }
    }

    /// Read-only question to the relay of the document that sent the request: is this still your live document, holding
    /// this request? No page-supplied value is trusted; the identity compared is the relay's own.
    private static func requireLiveRequest(_ entry: Entry, page: BrowserPage) async throws {
        let documentID = entry.key.document, requestID = entry.key.request
        let pending: Bool
        do {
            pending = try await page.callAsyncJavaScript(
                "return globalThis.__wsurfWebAuthnFence?.isPending(documentID, id) === true;",
                in: entry.frame,
                contentWorld: world,
                prepareArguments: { ["documentID": documentID, "id": requestID] }
            ) as? Bool ?? false
        } catch { throw WebAuthnContextError.staleFrame }
        guard pending else { throw WebAuthnContextError.staleFrame }
    }

    /// Windows with a ceremony in flight: one per native window for its whole run (offer through delivery and the
    /// unconfirmed notice). A second request for the same window is refused at once, never queued behind the first; other
    /// windows are unaffected. The run holds the window strongly while it is listed, so its identity cannot be reused.
    private static var busyWindows = Set<ObjectIdentifier>()

    private static func run(_ entry: Entry) async {
        guard let page = entry.page else { return }
        // The window is fixed when the run starts and rechecked before anything is shown, so a tab moved to another window
        // meanwhile can never redirect the prompt there.
        let startWindow = page.window
        var context: WebAuthnContext?
        var claimed: NSWindow?
        var receipt: (manager: CredentialManager, outcome: WebAuthnCeremonyOutcome)?
        defer { if let claimed { busyWindows.remove(ObjectIdentifier(claimed)) } }
        /// In-memory notice (at most 16, lost on quit) for a registration that is saved although the page may not have it,
        /// plus the native sheet only in the window the ceremony ran in while the page is still in it. Runs at most once.
        func noteUnconfirmedReceipt() {
            guard let pending = receipt, let revision = pending.outcome.savedRevision else { return }
            receipt = nil
            pending.manager.noteUnconfirmedPasskey(rpID: pending.outcome.rpID, userName: pending.outcome.userName, revision: revision)
            if let anchor = claimed, page.window === anchor {
                NativeWebAuthnInteraction().reportUnconfirmedRegistration(
                    rpID: pending.outcome.rpID, userName: pending.outcome.userName, in: anchor
                )
            }
        }
        do {
            // The asking document must still be the live one and still hold exactly this request, before anything native
            // is built, prompted, unlocked or written. Asked of the frame the message came from; a replaced document,
            // an unreachable frame or any error refuses and never rebinds the request to another document.
            try await requireLiveRequest(entry, page: page)
            let native = try await page.credentialContext(for: entry.frame, operation: entry.parsed.operation)
            context = native
            try ensureCurrent(entry)
            // Matching origin is not identity: a context made for any other document generation than the one that sent
            // this request (replacement, restore, same-origin reload) never serves it.
            guard native.credentialGeneration == entry.generation, page.credentialGeneration == entry.generation else {
                throw WebAuthnContextError.staleFrame
            }
            try await requireLiveRequest(entry, page: page)
            try ensureCurrent(entry)
            guard native.credentialGeneration == entry.generation, page.credentialGeneration == entry.generation else {
                throw WebAuthnContextError.staleFrame
            }
            guard !page.isPrivate, native.profileID == page.profileID, page.context.settings.passwordProvider == .credentialManager,
                  let anchor = startWindow, page.window === anchor else {
                throw WebsiteAuthenticatorError.notAllowed
            }
            // Claimed in the same synchronous step that proved the window, before the first await that can launch a ceremony.
            // Busy: a modal request fails NotAllowed, a conditional one stays pending (`finish`).
            guard busyWindows.insert(ObjectIdentifier(anchor)).inserted else { throw WebsiteAuthenticatorError.notAllowed }
            claimed = anchor
            let manager = try CredentialManager.forProfile(page.context.profile)
            guard manager.profileID == native.profileID else { throw WebsiteAuthenticatorError.notAllowed }

            let outcome = try await WebsiteAuthenticator.perform(
                entry.parsed.request, context: native, manager: manager, in: anchor,
                conditional: entry.parsed.mediation == .conditional
            )
            // From here a landed registration is saved whatever happens to the page: its receipt is kept until the page
            // confirmably has the result, and survives a cancelled, expired or discarded entry.
            if outcome.savedRevision != nil {
                receipt = (manager, outcome)
            }
            try ensureCurrent(entry)
            let payload = try WebAuthnWire.resultJSON(outcome.result, operation: entry.parsed.operation)
            let delivered = await deliver(
                ["result": payload], key: entry.key, page: page, frame: entry.frame,
                entry: entry, context: native, authority: (manager, outcome)
            )
            retire(entry)
            if delivered {
                receipt = nil
            } else {
                // The page was not given the result (dispatch refused or the document is gone). The memory-only notice goes
                // first, never behind an await on a renderer that may not answer; then one non-secret failure so the page
                // does not wait for its timeout (a replaced document drops it at the fence).
                noteUnconfirmedReceipt()
                await deliver(["error": errorPayload(WebsiteAuthenticatorError.notAllowed)], key: entry.key, page: page, frame: entry.frame)
            }
        } catch {
            // Whatever ended the run (also a discarded entry, which `finish` ignores), a saved passkey is never lost silently.
            noteUnconfirmedReceipt()
            await finish(entry, page: page, context: context, error: error)
        }
    }

    private static func ensureCurrent(_ entry: Entry) throws {
        try Task.checkCancellation()
        guard !entry.cancelled, entries[entry.key] === entry, entry.page?.isClosed == false else { throw CancellationError() }
    }

    private static func finish(_ entry: Entry, page: BrowserPage, context: WebAuthnContext?, error: any Error) async {
        guard !entry.cancelled, entries[entry.key] === entry else { return }
        // A user who declines the native offer or prompt, or has no passkey here, leaves a conditional discovery pending.
        if entry.parsed.mediation == .conditional, case WebsiteAuthenticatorError.notAllowed = error {
            entry.started = false
            entry.task = nil
            return
        }
        retire(entry)
        await deliver(["error": errorPayload(error)], key: entry.key, page: page, frame: entry.frame, entry: entry, context: context)
    }

    private static func errorPayload(_ error: any Error) -> [String: String] {
        let mapped = pageError(error)
        return ["name": mapped.name, "message": mapped.message]
    }

    private static func pageError(_ error: any Error) -> WebAuthnWire.PageError {
        switch error {
        case let error as WebAuthnContextError:
            if case .insecureOrigin = error {
                return WebAuthnWire.PageError(name: "SecurityError", message: "This page cannot use passkeys.")
            }
            return WebAuthnWire.PageError(name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform.")
        case is CredentialVaultError, is CredentialManagerError:
            return WebAuthnWire.PageError(name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform.")
        default:
            return WebAuthnWire.pageError(error)
        }
    }

    // MARK: Delivery

    /// Hands one outcome to the relay in the captured frame. The relay accepts it once, for its own live document only.
    /// Everything that must still hold is checked by the engine's final-send check, after its last suspension: the request
    /// is still live, the sealed native context still matches its document, and — for a signed result — the provider is
    /// still the encrypted manager for the same profile and the vault authorization and content the signature was made
    /// under are still current.
    @discardableResult
    private static func deliver(
        _ value: [String: Any],
        key: Key,
        page: BrowserPage,
        frame: BrowserFrame,
        entry: Entry? = nil,
        context: WebAuthnContext? = nil,
        authority: (manager: CredentialManager, outcome: WebAuthnCeremonyOutcome)? = nil
    ) async -> Bool {
        guard !page.isClosed, let data = try? JSONSerialization.data(withJSONObject: value),
              let json = String(data: data, encoding: .utf8) else { return false }
        let documentID = key.document
        let requestID = key.request
        do {
            let accepted = try await page.callAsyncJavaScript(
                "return globalThis.__wsurfWebAuthnFence?.deliver(documentID, id, JSON.parse(value)) === true;",
                in: frame,
                contentWorld: world,
                prepareArguments: {
                    ["documentID": documentID, "id": requestID, "value": json]
                },
                dispatchCheck: {
                    if let entry, entry.cancelled {
                        throw CancellationError()
                    }
                    try context?.validateForDispatch()
                    if let authority {
                        // The deadline is rechecked at the send boundary: a signed result is never handed over late.
                        if let deadline = entry?.parsed.request.deadline, ContinuousClock.now >= deadline {
                            throw WebsiteAuthenticatorError.expired
                        }
                        guard page.context.settings.passwordProvider == .credentialManager,
                              page.profileID == authority.manager.profileID,
                              authority.manager.authorizationEpoch == authority.outcome.epoch else {
                            throw WebsiteAuthenticatorError.notAllowed
                        }
                        if authority.manager.stableGeneration != authority.outcome.generation {
                            throw WebsiteAuthenticatorError.notAllowed
                        }
                    }
                }
            )
            return accepted as? Bool ?? false
        } catch {
            return false
        }
    }
}
