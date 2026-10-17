// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CryptoKit
import Foundation
import WebKit

/// Console and network capture for one development lease. Nothing is installed or recorded until `start()`, and `stop()`
/// removes everything `start()` installed. Chromium subscribes to events its DevTools session already receives. WebKit gets the
/// hook injected into this page's current document, and a copy of it as a main-frame document-start user script on this page's
/// own content controller, so the documents that follow are hooked before their first script runs and the hook buffers (at
/// most 128 events) until the relay attaches. The script is removed again by `stop()`. A popup the page opens shares the
/// controller and so runs the buffering hook, but no relay ever attaches there: its events stay in the popup.
///
/// The capture follows the document from native boundaries, not from reads: the owner calls `documentMayHaveChanged()` when
/// a navigation commits, WebKit then waits for the new document's frame registration (its native nonce) and attaches the
/// relay, and `sync()` on a read is only the safety net.
@MainActor
final class DevelopmentDiagnostics {
    let buffer: PageDiagnostics.Buffer
    private weak var page: BrowserPage?
    private weak var owner: DevelopmentOwner?
    /// Query values in every URL this capture records become tags of this key. The key exists for this capture only, so equal
    /// values correlate inside it and nowhere else.
    private let queryValues = PageDiagnostics.QueryValues.tagged(SymmetricKey(size: .bits256))
    private let mapper: ChromiumDiagnosticsMapper
    /// Unique per capture. The controller registration can be shared with sibling views and other captures, so a capture
    /// may only ever remove a registration whose name it alone owns.
    private let handlerName = "wsurfDiag" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    /// This capture's secret. A message is accepted only when it carries it.
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    /// The DOM event name of this capture's hook, in every document: the document-start script, a late install and the relay
    /// all address one hook through it, and `stop()` tears it down through it.
    private let event = "wsurf-diag-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    /// The document-start script this capture added to the page's content controller, until `stop()` removes it.
    private var startScript: String?
    /// The document (registry nonce) the live hook was verified against. Nil: no hook is known to be attached.
    private var hookDocumentID: String?
    private var handlerRegistered = false
    /// Single flight: at most one WebKit follow-up runs; it re-reads the document after each await.
    private var following: Task<Void, Never>?
    private var stopped = false
    /// Document changes this capture followed (each one cleared the buffer and started a new epoch).
    private(set) var reattachments = 0
    /// Events of the current document that the page-side start-up buffer had to drop before the relay attached.
    private(set) var lostEarly = 0

    init?(owner: DevelopmentOwner, page: BrowserPage, tabID: String) {
        guard let documentID = page.mainDocumentID else { return nil }
        self.owner = owner
        self.page = page
        buffer = PageDiagnostics.Buffer(connection: owner.connection, tab: tabID, documentID: documentID)
        mapper = ChromiumDiagnosticsMapper(queryValues: queryValues)
    }

    var engine: String { page?.chromium != nil ? "chromium" : "webkit" }

    var sources: [String] {
        engine == "chromium"
            ? ["DevTools Runtime.consoleAPICalled/exceptionThrown and Network request events of the main frame"]
            : [
                "Injected page hook: console, uncaught errors, unhandled rejections, fetch and XMLHttpRequest of the document, "
                    + "installed at document start for every document after startDiagnostics",
                "PerformanceObserver resource entries of the document: images, scripts, stylesheets, fonts and frames",
            ]
    }

    var gaps: [String] {
        var gaps = [
            "Nothing before startDiagnostics is available.",
            "Header values, bodies, cookies and object contents are never captured. Query values are shown as ~tags (equal values share a tag within this capture only); parameter names stay.",
        ]
        if engine == "chromium" {
            gaps.append("Subframes, workers and extension worlds are not captured.")
            gaps.append(
                "Requests still in flight when the document changes are dropped unless they belong to the new document, "
                    + "and the redirect hops of a main-frame navigation that happen before its document commits are not recorded (only the final request is).")
            gaps.append("Stacks cover the first \(PageDiagnostics.maxStackFrames) frames of warnings, errors and uncaught exceptions; async parent stacks are not followed.")
        } else {
            gaps.append(
                "A navigation's first events are kept by a page-side buffer of at most 128 events until the new document's frame registration completes, "
                    + "then delivered in order with the time they were delivered; events beyond the buffer are counted in lostEarly. "
                    + "The previous document's records are discarded. A page that was already loaded when startDiagnostics ran is captured from that point only.")
            gaps.append(
                "Console objects and proxies are not read and appear as [object]; an Error appears as its name and message and contributes its stack when they are "
                    + "plain data properties. A call without an Error has no stack. "
                    + "fetch reports a URL only for a string URL argument, and a method only for fetch(url) without an init (GET); "
                    + "a Request, URL or RequestInit argument is not read, so its method or URL is absent (unknown). "
                    + "XMLHttpRequest reports method and URL when passed as strings. fetch and XMLHttpRequest records carry status, media type and timing but no size, "
                    + "and redirect hops are not visible. Resource loads carry type (from their initiator and file extension), size when the server exposes it, and timing; "
                    + "they have no method or redirect information. Workers and iframes are not captured.")
            if hookDocumentID != buffer.documentID {
                gaps.append(
                    "The hook is not attached to the current document (its frame registration is pending or the install failed); "
                        + "the page keeps at most 128 events for it until it attaches, and a failed install loses them.")
            }
        }
        return gaps
    }

    // MARK: Lifecycle

    func start() async {
        guard let page else { return }
        if let chromium = page.chromium {
            mapper.reset()
            chromium.devTools.diagnosticsSink = { [weak self] method, params in self?.receive(method: method, params: params) }
        } else {
            // Documents that start after this point are hooked before their first script. The current one, already running,
            // is hooked by the follow-up below.
            let source = PageDiagnosticsHook.pageHook(event: event)
            page.installScript(source, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            startScript = source
            await follow()?.value
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        following = nil
        guard let page else { return }
        page.chromium?.devTools.diagnosticsSink = nil
        guard let webKit = page.webKit else { return }
        // No later document gets the script; documents that already ran it are turned off through the DOM below.
        if let startScript {
            page.removeScript(startScript, in: .page)
            self.startScript = nil
        }
        // Synchronous and ordered after any hook script this capture already issued, so a hook still being installed is
        // torn down too (its install rechecks `stopped` and never issues the relay). It needs neither the relay nor a
        // content-world global.
        Self.tearDown(event, in: webKit)
        guard handlerRegistered else { return }
        page.removeScriptMessageHandler(name: handlerName, in: PageAutomationGuard.world)
        webKit.configuration.userContentController.removeScriptMessageHandler(forName: handlerName, contentWorld: PageAutomationGuard.world)
    }

    /// A navigation committed (called by the owning tab): follow the new document now instead of at the next read. Chromium
    /// adopts it immediately; WebKit attaches the hook as soon as the new main frame is registered.
    func documentMayHaveChanged() {
        _ = follow()
    }

    /// Safety net for reads: brings the capture to the page's current document. Returns false when the lease is gone or the
    /// new document is no longer authorized (the lease is released first).
    func sync() async -> Bool {
        await follow()?.value
        return !stopped
    }

    /// Binds the capture to the page's current document. A new document clears the buffer (new epoch, old cursors invalid)
    /// and the Chromium request correlation (stale in-flight entries and the loss count never carry over). A nil identity is
    /// pending, not synced. Returns false when stopped or when the new document is denied (the lease is released first).
    private func adoptCurrentDocument() -> Bool {
        guard !stopped, let page, let owner else { return false }
        guard let current = page.mainDocumentID, current != buffer.documentID else { return true }
        guard owner.isAuthorized() else {
            owner.requestRelease?(.documentDenied)
            stop()
            return false
        }
        buffer.reset(documentID: current)
        mapper.reset(keeping: current)
        lostEarly = 0
        reattachments += 1
        return true
    }

    // MARK: Chromium

    private func receive(method: String, params: [String: Any]) {
        guard !stopped, let chromium = page?.chromium, page?.mainDocumentID != nil, adoptCurrentDocument() else { return }
        guard let entry = mapper.entry(method: method, params: params), belongsToDocument(entry, chromium.devTools) else { return }
        buffer.append(
            stream: entry.stream, timestamp: Date(), documentID: buffer.documentID, fields: entry.fields, truncated: entry.truncated)
    }

    /// Only the main frame's page world of the current document: console and exceptions through their execution context,
    /// requests through the frame and loader that started them.
    private func belongsToDocument(_ entry: PageDiagnostics.Entry, _ devTools: ChromiumDevTools) -> Bool {
        if let contextID = entry.contextID {
            guard let unique = devTools.uniqueIDByExecutionID[contextID], let context = devTools.contextsByUniqueID[unique],
                context.worldName.isEmpty, devTools.framesByID[context.frameID]?.isMainFrame == true
            else { return false }
            return context.documentID == buffer.documentID
        }
        guard let frameID = entry.frameID, devTools.framesByID[frameID]?.isMainFrame == true else { return false }
        return entry.loaderID == buffer.documentID
    }

    var lostInFlight: Int {
        mapper.lostInFlight
    }

    // MARK: WebKit

    private func follow() -> Task<Void, Never>? {
        guard !stopped, let page else { return nil }
        guard page.webKit != nil else {
            _ = adoptCurrentDocument()
            return nil
        }
        if let following {
            return following
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await followWebKit()
        }
        following = task
        return task
    }

    /// Runs until the hook is attached to the document the page is on, or that document's registration is pending. The
    /// clearing of `following` follows the last check without a suspension, so an event arriving meanwhile is never lost.
    /// Each pass is gated on a document change or a successful wait, so a failing install is not retried in a loop: the
    /// next commit or read retries it.
    private func followWebKit() async {
        defer { following = nil }
        while adoptCurrentDocument(), let page {
            guard let current = page.mainDocumentID else {
                awaitRegistration(on: page)
                return
            }
            if hookDocumentID == current {
                return
            }
            await installHook(on: page, document: current)
            guard !stopped, page.mainDocumentID != current else { return }
        }
    }

    /// The new document's own readiness promise resolves once native acknowledged its main frame (the nonce
    /// `mainDocumentID` reads). Not part of the single flight: a document that dies before resolving ends the wait without
    /// blocking the next one, and a wait that ends without a registered frame does not re-trigger itself.
    private func awaitRegistration(on page: BrowserPage) {
        guard let webKit = page.webKit else { return }
        Task { [weak self, weak webKit] in
            let ready = try? await webKit?.callAsyncJavaScript(
                "return (await globalThis.\(PageFrameRegistry.readyName)) === true;", in: nil, contentWorld: PageAutomationGuard.world)
            guard let self, !stopped, ready as? Bool == true, self.page?.mainDocumentID != nil else { return }
            documentMayHaveChanged()
        }
    }

    /// Attaches the relay to `document`, evaluating the hook first when the document-start script did not run there (the
    /// document that was loaded when the capture began). Both scripts are idempotent for this capture's event, so a document
    /// that already has them is left as it is. Every await is followed by a recheck of the lease and the document; a superseded
    /// install touches nothing, because a hook of this capture may by now be live in the document that replaced it.
    private func installHook(on page: BrowserPage, document: String) async {
        guard let webKit = page.webKit else { return }
        if !handlerRegistered {
            handlerRegistered = true
            page.addScriptMessageHandler(name: handlerName, in: PageAutomationGuard.world, bridge: false) { [weak self] message in
                self?.receive(message: message)
            }
        }
        hookDocumentID = nil
        let event = event
        func current() -> Bool {
            !stopped && page.mainDocumentID == document
        }
        guard await run(PageDiagnosticsHook.pageHook(event: event), in: .page, on: webKit), current() else { return }
        guard await run(PageDiagnosticsHook.relay(event: event, token: token, handler: handlerName), in: PageAutomationGuard.world, on: webKit) else {
            if current() {
                Self.tearDown(event, in: webKit)
            }
            return
        }
        guard current() else { return }
        hookDocumentID = document
    }

    /// Native-owned housekeeping, not agent automation: it goes straight to the web view so the task-local automation guard
    /// of whoever happened to trigger it can neither block an install nor leave a hook behind.
    private func run(_ script: String, in world: WKContentWorld, on webKit: WKWebView) async -> Bool {
        (try? await webKit.evaluateJavaScript(script, in: nil, contentWorld: world)) as? Bool == true
    }

    private static func tearDown(_ event: String, in webKit: WKWebView) {
        webKit.evaluateJavaScript(PageDiagnosticsHook.off(event: event), in: nil, in: PageAutomationGuard.world, completionHandler: nil)
    }

    private func receive(message: BrowserScriptMessage) {
        guard !stopped, message.frameInfo.isMainFrame, let page, page.mainDocumentID == buffer.documentID,
            let body = message.body as? [String: Any], body["t"] as? String == token
        else { return }
        if let lost = PageDiagnosticsHook.lostEarly(from: body) {
            lostEarly += lost
            return
        }
        guard let entry = PageDiagnosticsHook.entry(from: body, queryValues: queryValues) else { return }
        buffer.append(
            stream: entry.stream, timestamp: Date(), documentID: buffer.documentID, fields: entry.fields, truncated: entry.truncated)
    }
}
