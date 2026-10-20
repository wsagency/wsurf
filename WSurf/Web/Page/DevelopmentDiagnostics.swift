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
    /// What this capture was asked to record beyond metadata. Fixed when it starts; the policy decides, at every event, whether
    /// the Developer tier still allows it.
    let options: PageDiagnostics.DetailOptions
    /// Supplies the live policy (the Developer tier, the developer sites) and takes the options from this capture. Nil: none.
    var policyProvider: (@MainActor () -> PageDiagnostics.DetailPolicy)?
    /// Hides the secrets the connection typed. Applied to headers, bodies and previews before they are cut to their limits.
    var scrub: (String) -> String = { $0 }
    /// Bytes of body text this capture may still keep (`PageDiagnostics.Redaction.captureBodyBytes` in all).
    private(set) var bodyBudget = PageDiagnostics.Redaction.captureBodyBytes
    private var bodyFetches = 0
    private weak var page: BrowserPage?
    private weak var owner: DevelopmentOwner?
    /// Conceals the query of every URL this capture records (see `PageDiagnostics.QueryValues`). Its key belongs to one document:
    /// it is replaced when the document changes and when an agent navigates, so a tag matches only inside the document it was
    /// made in and a value an agent has the page request cannot be compared with one the previous page used.
    private(set) var queryValues = PageDiagnostics.QueryValues.tagged(SymmetricKey(size: .bits256))
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
    /// The hook as this capture installs it, in the document-start script and into a document that is already running.
    private var hookSource = ""
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

    init?(owner: DevelopmentOwner, page: BrowserPage, tabID: String, options: PageDiagnostics.DetailOptions = .init()) {
        guard let documentID = page.mainDocumentID else { return nil }
        self.owner = owner
        self.page = page
        self.options = options
        // A record with headers and bodies is larger than a metadata record, and the capture keeps its bodies besides.
        let limits = options.network
            ? (maxBytes: 2 * 1_048_576 + PageDiagnostics.Redaction.captureBodyBytes, maxRecordBytes: 96 * 1_024)
            : (maxBytes: 2 * 1_048_576, maxRecordBytes: options.console ? 16 * 1_024 : 8 * 1_024)
        buffer = PageDiagnostics.Buffer(
            connection: owner.connection, tab: tabID, documentID: documentID, maxBytes: limits.maxBytes, maxRecordBytes: limits.maxRecordBytes)
        mapper = ChromiumDiagnosticsMapper(queryValues: queryValues)
    }

    /// Set when the Developer tier stopped holding for the page: the detail capture ended for good, and what it had recorded was
    /// purged. Metadata goes on; call `resetDevelopment` and `startDiagnostics` again for a new capture with detail.
    private(set) var detailEnded = false

    /// The policy for this event: the options this capture was started with, under the tier as it is now. The first time the tier
    /// is found gone, detail ends and is purged, so a record made with it is never left to be read without it.
    private func currentPolicy() -> PageDiagnostics.DetailPolicy {
        guard options.isEnabled, !detailEnded, var policy = policyProvider?() else { return .off }
        guard policy.tier else {
            endDetail()
            return .off
        }
        policy.options = options
        return policy
    }

    /// Ends the detail capture and removes what it recorded (headers, bodies, previews, clear query values and the full console's
    /// extra stacks) from the buffer. Synchronous, and safe to repeat; a read without Developer access calls it before it matches
    /// anything, so a filter, a count or a page size is only ever worked out from records that no longer hold the detail.
    func endDetail() {
        guard !detailEnded else { return }
        detailEnded = true
        buffer.rewrite(withoutDetail)
    }

    /// `record` without the detail this capture's options added.
    func withoutDetail(_ record: PageDiagnostics.Record) -> PageDiagnostics.Record {
        PageDiagnostics.withoutDetail(record, options: options, queryValues: queryValues)
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
            options.isEnabled
                ? "Cookies are never captured, and nothing in the Developer tier's detail is kept after the capture ends."
                : "Header values, bodies, cookies and object contents are never captured.",
            "URL query values are concealed: a value that looks generated (a token, id or key) is a ~tag that matches only inside one document, "
                + "any other value shows only a length class (*short, *medium, *long); only plain parameter names stay"
                + (options.clearQueries ? ", except on requests to developer sites, where values are shown as written." : "."),
        ]
        gaps += detailGaps
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
                    + "plain data properties. A call without an Error has no stack unless the full console was asked for. "
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

    /// What the opt-in detail records and leaves out, for the engine of this capture.
    private var detailGaps: [String] {
        var gaps: [String] = []
        if options.network {
            gaps.append(
                "Headers and text bodies are recorded only for requests to developer sites while Developer access holds; every other request is recorded without them "
                    + "(its detail field says so). A header named like Authorization, Cookie, a token, key, secret or session, and any header whose value looks generated, shows only its name "
                    + "and \(PageDiagnostics.Redaction.hidden). Form fields, JSON keys and name=value pairs named like a password, token, secret, one-time code or card are hidden at any depth, "
                    + "JSON is re-encoded compactly, and values the connection typed as secrets are removed. A body is cut at \(PageDiagnostics.Redaction.maxBodyBytes / 1_024) KiB and this capture "
                    + "keeps \(PageDiagnostics.Redaction.captureBodyBytes / 1_048_576) MiB of bodies; binary and multipart bodies are summarized by type and size.")
            gaps.append(
                engine == "chromium"
                    ? "Chromium records the headers DevTools reports, including the ones the browser added on the wire (cookies show as names only), and the bodies of finished main-frame requests."
                    : "WebKit records what the page can see of fetch and XMLHttpRequest: the headers the page set itself (not the ones the browser adds, such as cookies and the user agent), "
                        + "the response headers it may read, and text bodies. A fetch of a Request object shows its address, method and headers but no body. "
                        + "A redirect that leaves the developer sites drops the record's detail. Resource loads, navigations, WebSockets and worker traffic have no headers or bodies.")
        }
        if options.console {
            gaps.append(
                "Full console: every call carries a stack (up to \(PageDiagnostics.maxFullStackFrames) frames) and objects appear in preview as bounded JSON "
                    + "(depth 3, up to \(PageDiagnostics.Redaction.maxPreviewBytes / 1_024) KB) with credential-named keys hidden"
                    + (engine == "chromium"
                        ? ", taken from the preview DevTools makes, which never calls a getter."
                        : ", read from the object's own data properties: an accessor shows as [getter] and is not called, but a Proxy's traps may run."))
        }
        return gaps
    }

    // MARK: Lifecycle

    /// False when Chromium did not start delivering console and exception events; the capture is then over.
    @discardableResult
    func start() async -> Bool {
        guard let page else { return false }
        if let chromium = page.chromium {
            mapper.reset()
            do {
                try await chromium.devTools.startDiagnostics(owner: self) { [weak self] method, params in
                    self?.receive(method: method, params: params)
                }
            } catch {
                return false
            }
        } else {
            // Documents that start after this point are hooked before their first script. The current one, already running,
            // is hooked by the follow-up below.
            hookSource = PageDiagnosticsHook.pageHook(event: event, detail: currentPolicy())
            page.installScript(hookSource, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            startScript = hookSource
            await follow()?.value
        }
        return true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        following = nil
        // Headers and bodies are not kept past the capture, whoever still holds the buffer.
        buffer.reset()
        guard let page else { return }
        page.chromium?.devTools.stopDiagnostics(owner: self)
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

    /// Starts a new key for the query tags. Records already in the buffer keep the tags they have.
    func rotateQueryKey() {
        queryValues = .tagged(SymmetricKey(size: .bits256))
        mapper.queryValues = queryValues
    }

    /// A navigation committed (called by the owning tab): follow the new document now instead of at the next read. Chromium
    /// adopts it immediately; WebKit attaches the hook as soon as the new main frame is registered.
    func documentMayHaveChanged() {
        _ = follow()
    }

    /// Safety net for reads: brings the capture to the page's current document. Returns false when the lease is gone or the
    /// new document is no longer authorized (the lease is released first).
    func sync() async -> Bool {
        if options.isEnabled {
            _ = currentPolicy()
        }
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
        rotateQueryKey()
        buffer.reset(documentID: current)
        mapper.reset(keeping: current)
        lostEarly = 0
        reattachments += 1
        return true
    }

    // MARK: Chromium

    private func receive(method: String, params: [String: Any]) {
        guard !stopped, let chromium = page?.chromium, page?.mainDocumentID != nil, adoptCurrentDocument() else { return }
        mapper.detail = currentPolicy()
        guard let entry = mapper.entry(method: method, params: params), belongsToDocument(entry, chromium.devTools) else { return }
        guard let fetch = entry.bodyFetch else {
            record(entry)
            return
        }
        complete(entry, fetch: fetch, devTools: chromium.devTools)
    }

    // MARK: Records

    /// Appends `entry`. A network record gets its headers and bodies only if the policy covers its address now, which is checked
    /// here, after whatever suspension came before, and not when the request began.
    private func record(_ entry: PageDiagnostics.Entry) {
        var fields = entry.fields
        var truncated = entry.truncated
        if entry.stream == .network, options.network {
            let policy = currentPolicy()
            if let input = entry.detail, policy.network(input.url) {
                let detail = PageDiagnostics.detailFields(input, options: options, budget: &bodyBudget, scrub: scrub)
                fields.merge(detail.fields) { $1 }
                truncated = truncated || detail.truncated
            } else {
                fields["detail"] = .text(noDetail(for: entry, policy))
            }
        }
        if options.clearQueries {
            for key in ["url", "redirectTo"] {
                if case .text(let address)? = fields[key] {
                    fields[key] = .text(scrub(address))
                }
            }
        }
        if case .text(let preview)? = fields["preview"] {
            fields["preview"] = .text(scrub(preview))
        }
        buffer.append(stream: entry.stream, timestamp: Date(), documentID: buffer.documentID, fields: fields, truncated: truncated)
    }

    private func noDetail(for entry: PageDiagnostics.Entry, _ policy: PageDiagnostics.DetailPolicy) -> String {
        if entry.fields["source"] == "webkit-resource" {
            return "not captured: resource loads have no headers or bodies on WebKit"
        }
        if detailEnded {
            return "not captured: detail ended when Developer access stopped holding for this page"
        }
        guard policy.tier else { return "not captured: Developer access does not hold for this page" }
        if case .text(let address)? = entry.fields["url"], let url = URL(string: address), !policy.isDeveloperSite(url) {
            return "not captured: not a developer site"
        }
        return "not captured: the request left the developer sites or could not be read"
    }

    /// Reads what DevTools holds for a finished request, then records it if the capture, the document and the policy still stand.
    private func complete(_ entry: PageDiagnostics.Entry, fetch: PageDiagnostics.BodyFetch, devTools: ChromiumDevTools) {
        guard bodyFetches < Self.maxConcurrentFetches else {
            var skipped = entry
            skipped.detail?.responseBody = fetch.response ? PageDiagnostics.RawBody(note: "not captured: too many bodies were being read") : nil
            record(skipped)
            return
        }
        bodyFetches += 1
        let (document, epoch) = (buffer.documentID, buffer.epoch)
        Task { [weak self] in
            var done = entry
            if fetch.response {
                done.detail?.responseBody = await Self.responseBody(fetch.requestID, mime: fetch.mimeType, devTools: devTools)
            }
            if fetch.requestPost {
                done.detail?.requestBody = await Self.requestBody(fetch.requestID, was: entry.detail?.requestBody, devTools: devTools)
            }
            guard let self else { return }
            bodyFetches -= 1
            guard !stopped, buffer.documentID == document, buffer.epoch == epoch else { return }
            record(done)
        }
    }

    private static let maxConcurrentFetches = 6

    private static func responseBody(_ id: String, mime: String?, devTools: ChromiumDevTools) async -> PageDiagnostics.RawBody {
        guard let result = try? await devTools.command("Network.getResponseBody", params: ["requestId": id]), let body = result["body"] as? String else {
            return PageDiagnostics.RawBody(contentType: mime, note: "not captured: Chromium no longer holds this body")
        }
        let text = result["base64Encoded"] as? Bool == true ? Data(base64Encoded: body).flatMap { String(data: $0, encoding: .utf8) } : body
        return PageDiagnostics.RawBody(
            text: text, contentType: mime, size: text?.utf8.count, note: text == nil ? "not captured: the body is not UTF-8 text" : nil)
    }

    private static func requestBody(_ id: String, was: PageDiagnostics.RawBody?, devTools: ChromiumDevTools) async -> PageDiagnostics.RawBody? {
        guard let result = try? await devTools.command("Network.getRequestPostData", params: ["requestId": id]), let post = result["postData"] as? String else {
            return was
        }
        return PageDiagnostics.RawBody(
            text: PageDiagnostics.clip(post, bytes: PageDiagnostics.Redaction.maxIntakeBytes).text, contentType: was?.contentType, size: post.utf8.count)
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
        guard await run(hookSource, in: .page, on: webKit), current() else { return }
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
        guard let entry = PageDiagnosticsHook.entry(from: body, queryValues: queryValues, detail: currentPolicy()) else { return }
        record(entry)
    }
}
