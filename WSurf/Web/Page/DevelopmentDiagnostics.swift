// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

/// Console and network capture for one development lease. Nothing is installed or recorded until `start()`, and `stop()`
/// removes everything `start()` installed. Chromium subscribes to events its DevTools session already receives; WebKit gets a
/// hook injected into this page's current document only (never a user script on the shared content controller).
@MainActor
final class DevelopmentDiagnostics {
    private static let handlerName = "wsurfDiagnostics"

    let buffer: PageDiagnostics.Buffer
    private weak var page: BrowserPage?
    private weak var owner: DevelopmentOwner?
    private let mapper = ChromiumDiagnosticsMapper()
    private var token = ""
    private var stopped = false
    /// Events before the current capture, and between a navigation and re-attachment, are never available.
    private(set) var reattachments = 0

    init?(owner: DevelopmentOwner, page: BrowserPage, tabID: String) {
        guard let documentID = page.mainDocumentID else { return nil }
        self.owner = owner
        self.page = page
        buffer = PageDiagnostics.Buffer(connection: owner.connection, tab: tabID, documentID: documentID)
    }

    var engine: String { page?.chromium != nil ? "chromium" : "webkit" }

    var sources: [String] {
        engine == "chromium"
            ? ["DevTools Runtime.consoleAPICalled/exceptionThrown and Network request events of the main frame"]
            : ["Injected page hook: console, uncaught errors, unhandled rejections, fetch and XMLHttpRequest of the current document"]
    }

    var gaps: [String] {
        var gaps = ["Nothing before startDiagnostics is available.", "Header values, bodies, cookies and object contents are never captured."]
        if engine == "chromium" {
            gaps.append("Subframes, workers and extension worlds are not captured.")
        } else {
            gaps.append("After a navigation the hook is re-attached on the next read; earlier events of the new document, workers, iframes and resource loads are not captured.")
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
            await installHook(on: page)
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        guard let page else { return }
        page.chromium?.devTools.diagnosticsSink = nil
        if page.webKit != nil {
            page.removeScriptMessageHandler(name: Self.handlerName, in: PageAutomationGuard.world)
            Task { [weak page] in
                _ = try? await page?.evaluateJavaScript(
                    "window.__wsurfDiagOff && window.__wsurfDiagOff();", in: nil, contentWorld: PageAutomationGuard.world)
            }
        }
    }

    /// Follows the document: a new document clears the buffer (new epoch, old cursors invalid) and, on WebKit, re-attaches the
    /// hook. Returns false when the new document is no longer authorized, after releasing the lease.
    func sync() async -> Bool {
        guard !stopped, let page, let owner else { return false }
        guard let current = page.mainDocumentID else { return true }
        guard current != buffer.documentID else { return true }
        guard owner.isAuthorized() else {
            owner.requestRelease?(.documentDenied)
            return false
        }
        buffer.reset(documentID: current)
        reattachments += 1
        if page.webKit != nil { await installHook(on: page) }
        return !stopped
    }

    // MARK: Chromium

    private func receive(method: String, params: [String: Any]) {
        guard !stopped, let chromium = page?.chromium, let current = page?.mainDocumentID else { return }
        if current != buffer.documentID {
            guard owner?.isAuthorized() == true else {
                owner?.requestRelease?(.documentDenied)
                return
            }
            buffer.reset(documentID: current)
            reattachments += 1
        }
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

    var lostInFlight: Int { mapper.lostInFlight }

    // MARK: WebKit

    private func installHook(on page: BrowserPage) async {
        token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let event = "wsurf-diag-" + token
        let expected = token
        page.addScriptMessageHandler(name: Self.handlerName, in: PageAutomationGuard.world) { [weak self] message in
            self?.receive(message: message, expectedToken: expected)
        }
        _ = try? await page.evaluateJavaScript(Self.pageHook(event: event), in: nil, contentWorld: .page)
        _ = try? await page.evaluateJavaScript(
            Self.relay(event: event, token: token, handler: Self.handlerName), in: nil, contentWorld: PageAutomationGuard.world)
    }

    private func receive(message: BrowserScriptMessage, expectedToken: String) {
        guard !stopped, token == expectedToken, message.frameInfo.isMainFrame, let page, page.mainDocumentID == buffer.documentID,
            let body = message.body as? [String: Any], body["t"] as? String == expectedToken,
            let entry = PageDiagnosticsHook.entry(from: body)
        else { return }
        buffer.append(
            stream: entry.stream, timestamp: Date(), documentID: buffer.documentID, fields: entry.fields, truncated: entry.truncated)
    }

    /// Runs in the page world. Reports through a DOM event (an isolated-world relay forwards it to native), preserves the
    /// wrapped call's behavior and result, and restores every original when the `-off` event arrives.
    private static func pageHook(event: String) -> String {
        """
        (() => {
          const EV = "\(event)";
          const dispatch = document.dispatchEvent.bind(document), CE = CustomEvent, stringify = JSON.stringify;
          const emit = o => { try { dispatch(new CE(EV, { detail: stringify(o) })); } catch (e) {} };
          const restore = [];
          const wrap = (obj, key, make) => {
            const orig = obj[key];
            if (typeof orig !== 'function') return;
            const wrapped = make(orig);
            try { obj[key] = wrapped; restore.push(() => { if (obj[key] === wrapped) obj[key] = orig; }); } catch (e) {}
          };
          const text = v => {
            try {
              switch (typeof v) {
                case 'string': return v;
                case 'number': case 'boolean': case 'undefined': return String(v);
                case 'bigint': return v + 'n';
                case 'function': return '[function]';
                case 'symbol': return '[symbol]';
              }
              if (v === null) return 'null';
              if (v instanceof Error) return String(v.name) + ': ' + String(v.message).split('\\n')[0];
              return '[object]';
            } catch (e) { return '[unreadable]'; }
          };
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            wrap(console, level, orig => function (...args) {
              try { emit({ k: 'console', level, text: args.slice(0, 16).map(text).join(' ').slice(0, 4096) }); } catch (e) {}
              return orig.apply(this, args);
            });
          }
          const onError = e => {
            if (!(e instanceof ErrorEvent)) return;
            emit({ k: 'console', level: 'error', text: String(e.message).slice(0, 4096), url: String(e.filename || ''), line: e.lineno | 0 });
          };
          const onRejection = e => emit({ k: 'console', level: 'error', text: ('Unhandled rejection: ' + text(e.reason)).slice(0, 4096) });
          window.addEventListener('error', onError, true);
          window.addEventListener('unhandledrejection', onRejection, true);
          const net = (via, method, url, start, status, outcome) =>
            emit({ k: 'net', via, method, url, status, ms: performance.now() - start, outcome });
          wrap(window, 'fetch', orig => function (input, init) {
            const start = performance.now();
            let method = 'GET', url = '';
            try {
              const req = input instanceof Request ? input : null;
              method = String((init && init.method) || (req && req.method) || 'GET');
              url = String(req ? req.url : input);
            } catch (e) {}
            // Returning a derived promise keeps the page's own rejection (and unhandledrejection) semantics intact.
            return orig.apply(this, arguments).then(
              r => { net('fetch', method, url, start, r.status, 'completed'); return r; },
              err => { net('fetch', method, url, start, null, err && err.name === 'AbortError' ? 'aborted' : 'failed'); throw err; });
          });
          const K = Symbol();
          const proto = XMLHttpRequest.prototype;
          wrap(proto, 'open', orig => function (method, url) {
            try { this[K] = { method: String(method), url: String(url) }; } catch (e) {}
            return orig.apply(this, arguments);
          });
          wrap(proto, 'send', orig => function () {
            const state = this[K];
            if (state && !state.watched) {
              state.watched = true;
              const start = performance.now();
              this.addEventListener('abort', () => { state.aborted = true; });
              this.addEventListener('loadend', () =>
                net('xhr', state.method, state.url, start, this.status || null, this.status ? 'completed' : state.aborted ? 'aborted' : 'failed'));
            }
            return orig.apply(this, arguments);
          });
          const off = () => {
            document.removeEventListener(EV + '-off', off);
            window.removeEventListener('error', onError, true);
            window.removeEventListener('unhandledrejection', onRejection, true);
            restore.forEach(f => f());
          };
          document.addEventListener(EV + '-off', off);
        })();
        """
    }

    /// Runs in the isolated world: forwards the page hook's events to the native handler and tears the hook down.
    private static func relay(event: String, token: String, handler: String) -> String {
        """
        (() => {
          if (window.__wsurfDiagOff) window.__wsurfDiagOff();
          const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers["\(handler)"];
          if (!channel) return;
          const forward = e => { try { const body = JSON.parse(e.detail); body.t = "\(token)"; channel.postMessage(body); } catch (err) {} };
          document.addEventListener("\(event)", forward, true);
          window.__wsurfDiagOff = () => {
            document.removeEventListener("\(event)", forward, true);
            document.dispatchEvent(new CustomEvent("\(event)-off"));
            delete window.__wsurfDiagOff;
          };
        })();
        """
    }
}
