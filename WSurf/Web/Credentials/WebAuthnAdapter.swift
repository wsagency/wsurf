// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import AuthenticationServices
import Foundation
import os
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
    /// Tests answer a profile's ceremony prompts without a window (keyed by profile, like `VaultChoicePrompt.answersForTesting`);
    /// the real sheets are covered by the native tests.
    static var interactionForTesting: [UUID: @MainActor () -> any WebAuthnCeremonyInteraction] = [:]
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
        /// The page's document generation when the relay's message arrived: the request belongs to exactly that document.
        let generation: UInt64
        let parsed: WebAuthnWire.Parsed
        var task: Task<Void, Never>?
        var expiryTask: Task<Void, Never>?
        var started = false
        var cancelled = false
        /// The vault this ceremony runs against, set once at selection (after the route and any choice) and never rebound.
        weak var boundManager: CredentialManager?

        init(key: Key, page: BrowserPage, frame: BrowserFrame, parsed: WebAuthnWire.Parsed) {
            self.key = key
            self.page = page
            self.frame = frame
            profileID = page.profileID
            generation = page.credentialGeneration
            self.parsed = parsed
        }
    }

    // MARK: Installation and cancellation

    static func install(in page: BrowserPage) {
        guard !installedPages.contains(page) else { return }
        installedPages.add(page)
        // WebKit's vault serves only the main frame (`validateCredentialContextForDispatch`), so its frames get none of these
        // scripts and keep the engine's own `navigator.credentials`. Chromium serves a frame it has verified, so every
        // frame gets them there.
        let mainFrameOnly = page.chromium == nil
        page.installScript(
            WebAuthnScript.relay(nativeNonce: page.chromium == nil), in: world,
            injectionTime: .atDocumentStart, forMainFrameOnly: mainFrameOnly
        )
        // Document-start order is the contract: the frame registry, then the relay, then the route script, then the page
        // script. A page's profile never changes, so neither does its route, and the script is installed once.
        page.installScript(routeScript(for: page), in: world, injectionTime: .atDocumentStart, forMainFrameOnly: mainFrameOnly)
        page.installScript(WebAuthnScript.page, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: mainFrameOnly)
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

    /// One vault's access ended: only the ceremonies bound to that manager stop (same synchronous refusal as above). Another
    /// vault's lock leaves them running; a ceremony still choosing its vault is covered by `cancel(profileID:)`.
    static func cancel(manager: CredentialManager) {
        for entry in Array(entries.values) where entry.boundManager === manager {
            refuse(entry)
        }
    }

    /// The route announcement the page script obeys synchronously. Native decides it; the page can forge the hint, but native
    /// refuses any request it does not itself serve and never passes one that it serves to the engine. A page is private or
    /// it is not for its whole life, so the announcement never changes and its sequence is constant.
    private static let routeSequence = 0

    private static func routeMode(for page: BrowserPage) -> String { isHandled(by: page) ? "manager" : "legacy" }

    private static func routeScript(for page: BrowserPage) -> String {
        WebAuthnScript.route(routeMode(for: page), sequence: routeSequence)
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
        // authorize against: the engine's own WebAuthn (private pages) still passes the call through, the vault refuses it.
        guard !document.isEmpty || action == "request" || action == "route" else { return }
        let key = Key(page: ObjectIdentifier(page), document: document, request: id)
        switch action {
        case "cancel":
            if let entry = entries[key] {
                discard(entry)
            }
        case "route":
            // A document restored from the back/forward cache asks once for the route that owns it. Only the answer
            // (`legacy` or `manager`) goes back, to the frame that asked; it is a hint, never an authority.
            Task { _ = try? await page.callAsyncJavaScript(routeScript(for: page), in: message.frameInfo, contentWorld: world) }
        case "request":
            // Only the vault needs a verified document. WebKit: the request is served for the main frame whose
            // native-issued nonce it carries; a message from an older or replaced document, a subframe or an unknown frame
            // never reaches a prompt and gets one error aimed only at the document that asked. Chromium's frame comes from
            // its CDP-attributed message and is verified by the context. A private page passes every call through.
            var frame = message.frameInfo
            if document.isEmpty {
                guard !isHandled(by: page) else {
                    Pipeline.log.notice("webauthn: refused, unidentified document")
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
                    Pipeline.log.notice("webauthn: refused, not the current main frame")
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

    /// Whether the vault handles passkeys for this page. A private page has no vault, so the page script hands its calls to
    /// the engine's own WebAuthn.
    private static func isHandled(by page: BrowserPage) -> Bool {
        !page.isPrivate
    }

    /// The route decision the page script obeys. `legacy` is only ever said for a page the vault does not serve at all (a
    /// private page); that alone lets the engine's own WebAuthn run. A page the vault serves is `manager`, and it is
    /// enabled only when the vault's profile is this page's profile: a stale or foreign page is `manager` with
    /// `enabled: false`, which is a refusal, never legacy.
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
        // The page script asks for the route first and only sends a request to the vault when told so. A request that
        // still arrives for a page the vault does not serve (a forged hint on a private page) is refused, never handed to
        // the engine.
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
        // A conditional request is only a registered discovery: nothing is unlocked, asked or signed until the user picks
        // "Use a Passkey…" in the fill dropdown of a webauthn field (`startConditionalRequest`) and then explicitly accepts
        // the native offer that precedes any unlock. A click or a key in the field never starts it. It is pending in exactly
        // the same way whether or not the profile has a vault or a passkey for the site, so a page can learn neither.
        if parsed.mediation != .conditional {
            start(entry)
        }
    }

    /// The user chose the system's authenticator: the page's own call runs in the engine once, in place of the vault's answer (see
    /// the page script). It is only ever sent after one of our sheets was closed by that choice, never on the strength of what
    /// the vault does or does not hold. The entry is retired first, so its expiry and a later cancel find nothing, and the
    /// engine's own timeout and abort signal take over.
    private static func handOff(_ entry: Entry, page: BrowserPage, context: WebAuthnContext?) async {
        guard !entry.cancelled, entries[entry.key] === entry else { return }
        retire(entry)
        await deliver(["handoff": "modal"], key: entry.key, page: page, frame: entry.frame, entry: entry, context: context)
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

    // MARK: Conditional requests

    /// Whether the document in `frame` holds a conditional request that nothing has started: the fill dropdown of a webauthn
    /// field then offers "Use a Passkey…". Only the page's own requests are read, never a vault, so the row says nothing about
    /// the vault that the page does not already know.
    static func hasConditionalRequest(in page: BrowserPage, frame: BrowserFrame) -> Bool {
        conditionalEntry(in: page, frame: frame) != nil
    }

    /// The user picked "Use a Passkey…": that document's pending conditional request runs the ceremony, with every check of `run`.
    /// Only that native row calls this; nothing on the page can.
    @discardableResult
    static func startConditionalRequest(in page: BrowserPage, frame: BrowserFrame) -> Bool {
        guard let entry = conditionalEntry(in: page, frame: frame) else { return false }
        start(entry)
        return true
    }

    private static func conditionalEntry(in page: BrowserPage, frame: BrowserFrame) -> Entry? {
        guard !page.isClosed, isHandled(by: page) else { return nil }
        let identity = ObjectIdentifier(page)
        return entries.values.first { entry in
            entry.key.page == identity && entry.parsed.mediation == .conditional && !entry.started && !entry.cancelled
                && entry.generation == page.credentialGeneration && isSameDocument(entry.frame, frame, in: page)
        }
    }

    /// Whether the autofill script's `frame` is the document the request was registered for. Chromium names both by the same
    /// CDP frame and document. WebKit serves only the current main frame (`handle`), and the generation check ties it to the
    /// document that sent the request.
    private static func isSameDocument(_ served: BrowserFrame, _ frame: BrowserFrame, in page: BrowserPage) -> Bool {
        if page.chromium != nil {
            return served.chromiumID != nil && served.chromiumID == frame.chromiumID && served.documentID == frame.documentID
        }
        return served.isMainFrame && frame.isMainFrame && served.securityOrigin == frame.securityOrigin
            && PageFrameRegistry.shared.isCurrent(served, in: page)
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

    /// Windows with a ceremony in flight, and the entry whose run holds each: one per native window for its whole run (offer
    /// through delivery and the unconfirmed notice). A second request for the same window is refused at once, never queued
    /// behind the first, unless the first was cancelled (`run`); other windows are unaffected. The run holds the window strongly
    /// while it is listed, so its identity cannot be reused.
    private static var busyWindows: [ObjectIdentifier: Entry] = [:]
    /// Runs waiting for a cancelled run to leave their window. Tests read it to know the wait has begun.
    private(set) static var waitingRunsForTesting = 0

    private static func run(_ entry: Entry) async {
        guard let page = entry.page else { return }
        // The window is fixed when the run starts and rechecked before anything is shown, so a tab moved to another window
        // meanwhile can never redirect the prompt there.
        let startWindow = page.window
        var context: WebAuthnContext?
        var claimed: NSWindow?
        var receipt: (manager: CredentialManager, outcome: WebAuthnCeremonyOutcome)?
        defer { if let claimed { busyWindows[ObjectIdentifier(claimed)] = nil } }
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
            guard !page.isPrivate, native.profileID == page.profileID, let anchor = startWindow, page.window === anchor else {
                throw WebsiteAuthenticatorError.notAllowed
            }
            // A page that replaces its conditional request with a modal one cancels the first, whose run may still be closing
            // its sheet. The new run waits for that run to end instead of being refused for its window, then proves itself again.
            if let previous = busyWindows[ObjectIdentifier(anchor)], previous.cancelled, let task = previous.task {
                waitingRunsForTesting += 1
                await task.value
                waitingRunsForTesting -= 1
                try await requireLiveRequest(entry, page: page)
                try ensureCurrent(entry)
                guard native.credentialGeneration == entry.generation, page.credentialGeneration == entry.generation,
                      page.window === anchor else { throw WebsiteAuthenticatorError.notAllowed }
            }
            // Claimed in the same synchronous step that proved the window, before the first await that can launch a ceremony.
            // Busy: a modal request fails NotAllowed, a conditional one stays pending (`finish`).
            guard busyWindows[ObjectIdentifier(anchor)] == nil else { throw WebsiteAuthenticatorError.notAllowed }
            busyWindows[ObjectIdentifier(anchor)] = entry
            claimed = anchor
            let interaction: any WebAuthnCeremonyInteraction = interactionForTesting[page.profileID]?() ?? NativeWebAuthnInteraction()
            let chosen = try await vault(for: entry, native: native, in: anchor, interaction: interaction)
            // The route and the prompt suspended: the request must still be this live document, in this window, before any
            // manager is bound to it. Nothing suspends between these checks and the binding.
            try await requireLiveRequest(entry, page: page)
            try ensureCurrent(entry)
            guard native.credentialGeneration == entry.generation, page.credentialGeneration == entry.generation,
                  !page.isPrivate, page.window === anchor, let manager = chosen else { throw WebsiteAuthenticatorError.notAllowed }
            guard manager.profileID == native.profileID else { throw WebsiteAuthenticatorError.notAllowed }
            entry.boundManager = manager

            let outcome = try await WebsiteAuthenticator.perform(
                entry.parsed.request, context: native, manager: manager, in: anchor,
                conditional: entry.parsed.mediation == .conditional, interaction: interaction
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
        } catch WebsiteAuthenticatorError.handOff {
            // Nothing was written, signed or unlocked for it, and every sheet of ours is already closed.
            await handOff(entry, page: page, context: context)
        } catch {
            // Whatever ended the run (also a discarded entry, which `finish` ignores), a saved passkey is never lost silently.
            noteUnconfirmedReceipt()
            await finish(entry, page: page, context: context, error: error)
        }
    }

    /// The vault that answers the request, or `nil` when the choice came to nothing (a cancel). Throws `handOff` only when the user
    /// chose the system's authenticator in a sheet of ours, here (the vault prompt, or the step a profile with no vault shows) or in
    /// the ceremony; never on the strength of what a vault holds. It reads the vault list and the open vaults' contents, never a
    /// locked vault, and unlocks nothing.
    private static func vault(
        for entry: Entry, native: WebAuthnContext, in anchor: ASPresentationAnchor, interaction: some WebAuthnCeremonyInteraction
    ) async throws -> CredentialManager? {
        guard let profile = entry.page?.context.profile else { throw WebsiteAuthenticatorError.notAllowed }
        let route: VaultRoute
        switch entry.parsed.request.options {
        case .creation:
            // The context's origin is already validated (it may be http://localhost, which a password origin never is).
            route = await CredentialRouting.route(profile: profile, origin: native.origin, username: nil)
        case .assertion(let options):
            // A passkey belongs to its relying party: the same RP ID resolution the ceremony uses decides which vault holds it.
            guard let url = URL(string: native.origin),
                  let rpID = try? RelyingPartyPolicy.validate(rpID: options.rpID, origin: url) else {
                throw WebsiteAuthenticatorError.invalidRequest
            }
            route = await CredentialRouting.route(
                profile: profile, origin: native.origin, passkeyRPID: rpID, allowed: options.allowCredentials
            )
        }
        // No usable vault: the user is asked all the same, in the same words as by a vault with nothing for the request, so a page
        // cannot tell the two apart. The system's authenticator is the only way on.
        if case .unavailable = route {
            try await WebsiteAuthenticator.offerSystemAuthenticator(entry.parsed.request, context: native, in: anchor, interaction: interaction)
        }
        let chosen: CredentialManager?
        if case .needsUnlock(let only) = route {
            // One vault, locked: nothing to choose. The ceremony's own origin-bearing offer comes before its unlock, so no
            // nameless sheet is the first thing a page can show.
            chosen = try? CredentialManager.forVault(profile, vaultID: only.vaultID)
        } else {
            switch await route.select(profile: profile, offersHandOff: true, in: anchor) {
            case .vault(let manager):
                chosen = manager
            case .handOff:
                throw WebsiteAuthenticatorError.handOff
            case .none:
                chosen = nil
            }
        }
        return chosen
    }

    private static func ensureCurrent(_ entry: Entry) throws {
        try Task.checkCancellation()
        guard !entry.cancelled, entries[entry.key] === entry, entry.page?.isClosed == false else { throw CancellationError() }
    }

    private static func finish(_ entry: Entry, page: BrowserPage, context: WebAuthnContext?, error: any Error) async {
        guard !entry.cancelled, entries[entry.key] === entry else { return }
        // A user who declines the native offer or prompt, or has no passkey here, leaves a conditional discovery pending; the
        // dropdown offers it again, and nothing shows it by itself.
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
            // The case name only: the page is told just NotAllowedError, so this is the one record of why.
            Pipeline.log.notice("webauthn: refused, context \(String(describing: error), privacy: .public)")
            if case .insecureOrigin = error {
                return WebAuthnWire.PageError(name: "SecurityError", message: "This page cannot use passkeys.")
            }
            return WebAuthnWire.PageError(name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform.")
        case is CredentialVaultError, is CredentialManagerError:
            Pipeline.log.notice("webauthn: refused, \(String(describing: type(of: error)), privacy: .public)")
            return WebAuthnWire.PageError(name: "NotAllowedError", message: "The request is not allowed by the user agent or the platform.")
        default:
            return WebAuthnWire.pageError(error)
        }
    }

    // MARK: Delivery

    /// Hands one outcome to the relay in the captured frame. The relay accepts it once, for its own live document only.
    /// Everything that must still hold is checked by the engine's final-send check, after its last suspension: the request
    /// is still live, the sealed native context still matches its document, and — for a signed result — the page is still
    /// the vault's for the same profile and the vault authorization and content the signature was made under are still current.
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
                        guard !page.isPrivate, page.profileID == authority.manager.profileID,
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
