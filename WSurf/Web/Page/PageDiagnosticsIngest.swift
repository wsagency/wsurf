// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

nonisolated extension PageDiagnostics {
    /// One record before the buffer assigns identity: the stream and its already-sanitized fields. `truncated` reports that
    /// ingest cut a message or URL to its byte bound. The native identity (`frameID`, `loaderID`, `contextID`) is the one
    /// observed when the event began, so the owner can reject an event whose document is no longer the current one.
    struct Entry: Equatable {
        let stream: Stream
        let fields: [String: PageDiagnostics.Field]
        var truncated = false
        var frameID: String?
        var loaderID: String?
        var contextID: Int?
    }

    fileprivate static let maxTextBytes = 4_096
    fileprivate static let maxURLBytes = 2_048
    fileprivate static let maxConsoleArguments = 16
    fileprivate static let methodCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Cuts `text` to at most `bytes` UTF-8 bytes on a unicode scalar boundary, touching only the kept prefix. Scalars, not
    /// characters: a single grapheme cluster can be arbitrarily many bytes.
    fileprivate static func clip(_ text: String, bytes: Int = maxTextBytes) -> (text: String, truncated: Bool) {
        var used = 0
        var end = text.unicodeScalars.startIndex
        while end < text.unicodeScalars.endIndex {
            let size = String(text.unicodeScalars[end]).utf8.count
            if used + size > bytes { return (String(text.unicodeScalars[..<end]), true) }
            used += size
            end = text.unicodeScalars.index(after: end)
        }
        return (text, false)
    }

    /// Bytes are checked first (O(1) on a native string), so a hostile string is never walked by `count` or the set test.
    fileprivate static func method(_ value: Any?) -> String? {
        guard let value = value as? String, (1...16).contains(value.utf8.count),
            value.unicodeScalars.allSatisfy(methodCharacters.contains)
        else { return nil }
        return value.uppercased()
    }

    fileprivate static func status(_ value: Any?) -> Int? {
        guard let value = value as? Int, (100...599).contains(value) else { return nil }
        return value
    }

    fileprivate static func duration(milliseconds: Double?) -> Int? {
        guard let ms = milliseconds, ms.isFinite, ms >= 0, ms < 1e9 else { return nil }
        return Int(ms.rounded())
    }

    fileprivate static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// A page-supplied URL, bounded before anything parses it: the raw string is cut to `maxURLBytes` first (a multi-megabyte
    /// string never reaches `URLComponents` or any join), then sanitized and cut again. `truncated` is set whenever bytes
    /// were cut, including when the cut prefix no longer parses and `text` is nil (dropped, not unknown).
    fileprivate static func boundedURL(_ raw: String) -> (text: String?, truncated: Bool) {
        let head = clip(raw, bytes: maxURLBytes)
        guard let clean = sanitize(url: head.text) else { return (nil, head.truncated) }
        let tail = clip(clean, bytes: maxURLBytes)
        return (tail.text, head.truncated || tail.truncated)
    }
}

/// Parses untrusted messages posted by the WebKit page hook. Anything that is not exactly the expected shape is dropped;
/// unknown keys (cookies, stacks, headers) are never copied.
nonisolated enum PageDiagnosticsHook {
    private static let levels: Set<String> = ["log", "info", "warn", "error", "debug"]
    private static let outcomes: Set<String> = ["completed", "failed", "aborted"]

    static func entry(from body: Any) -> PageDiagnostics.Entry? {
        guard let body = body as? [String: Any] else { return nil }
        switch body["k"] as? String {
        case "console": return console(body)
        case "net": return network(body)
        default: return nil
        }
    }

    private static func console(_ body: [String: Any]) -> PageDiagnostics.Entry? {
        guard let level = body["level"] as? String, levels.contains(level), let text = body["text"] as? String else { return nil }
        let message = PageDiagnostics.clip(text)
        var fields: [String: PageDiagnostics.Field] = ["level": .text(level), "text": .text(message.text), "source": "webkit-hook"]
        var truncated = message.truncated
        if let raw = body["url"] as? String {
            let url = PageDiagnostics.boundedURL(raw)
            fields["url"] = url.text.map { .text($0) }
            truncated = truncated || url.truncated
        }
        if let line = body["line"] as? Int, line >= 0 { fields["line"] = .number(line) }
        return .init(stream: .console, fields: fields, truncated: truncated)
    }

    /// `method` and `url` are absent when the hook could not know them without running page code (a Request, URL or
    /// RequestInit argument): unknown is never reported as a guess. `urlClipped` is the hook's own cut of a long URL.
    private static func network(_ body: [String: Any]) -> PageDiagnostics.Entry? {
        guard let via = body["via"] as? String, via == "fetch" || via == "xhr" else { return nil }
        let outcome = (body["outcome"] as? String).flatMap { outcomes.contains($0) ? $0 : nil } ?? "unknown"
        var fields: [String: PageDiagnostics.Field] = ["outcome": .text(outcome), "source": .text("webkit-\(via)")]
        fields["method"] = PageDiagnostics.method(body["method"]).map { .text($0) }
        let url = (body["url"] as? String).map(PageDiagnostics.boundedURL)
        fields["url"] = url?.text.map { .text($0) }
        fields["status"] = PageDiagnostics.status(body["status"]).map { .number($0) }
        fields["durationMs"] = PageDiagnostics.duration(milliseconds: body["ms"] as? Double).map { .number($0) }
        let truncated = (url?.truncated ?? false) || body["urlClipped"] as? Bool == true
        return .init(stream: .network, fields: fields, truncated: truncated)
    }

    // MARK: Page-side scripts

    /// Runs in the page world. Reports through a DOM event (an isolated-world relay forwards it to native), preserves every
    /// wrapped call's `this`, arguments, result and exceptions, and on the `-off` event stops reporting and restores only the
    /// wrappers it still owns (a page that wrapped over them keeps its own wrapper; ours is inert).
    ///
    /// The hook never runs page code to describe a value: console arguments are rendered from primitives only (every object,
    /// Error and Proxy is `[object]`; no `instanceof`, prototype walk, getter, `toString` or property read), and fetch /
    /// XMLHttpRequest metadata comes only from primitive string arguments. A `Request`, `URL` or `RequestInit` argument is
    /// never read, so that method or URL is reported as null (unknown), and `fetch(url)` with no init is the only way the
    /// method is known without a read. Status and abort reasons come from brand-checked native getters, which throw on a
    /// foreign object instead of running its code. Ceiling: builtins the page patched before the hook was installed cannot be
    /// told apart from the platform's.
    static func pageHook(event: String) -> String {
        """
        (() => {
          const EV = "\(event)";
          const apply = Reflect.apply, dispatch = document.dispatchEvent.bind(document), CE = CustomEvent, stringify = JSON.stringify;
          const now = performance.now.bind(performance), URLCtor = URL, slice = String.prototype.slice;
          const thenOf = Promise.prototype.then, addListener = EventTarget.prototype.addEventListener;
          const wmGet = WeakMap.prototype.get, wmSet = WeakMap.prototype.set;
          const getter = (ctor, key) => {
            try { return Object.getOwnPropertyDescriptor(ctor.prototype, key).get; } catch (e) { return undefined; }
          };
          const responseStatus = getter(globalThis.Response, 'status'), xhrStatus = getter(globalThis.XMLHttpRequest, 'status');
          const errorName = getter(globalThis.DOMException, 'name');
          const read = (get, object) => { try { return apply(get, object, []); } catch (e) { return null; } };
          const clip = (s, n) => s.length > n ? apply(slice, s, [0, n]) : s;
          let live = true;
          const emit = o => { if (live) try { dispatch(new CE(EV, { detail: stringify(o) })); } catch (e) {} };
          const restore = [];
          const wrap = (obj, key, make) => {
            const orig = obj[key];
            if (typeof orig !== 'function') return;
            const wrapped = make(orig);
            try { obj[key] = wrapped; restore.push(() => { if (obj[key] === wrapped) obj[key] = orig; }); } catch (e) {}
          };
          const text = v => {
            switch (typeof v) {
              case 'string': return v;
              case 'number': case 'boolean': case 'undefined': return '' + v;
              case 'bigint': return v + 'n';
              case 'function': return '[function]';
              case 'symbol': return '[symbol]';
            }
            return v === null ? 'null' : '[object]';
          };
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            wrap(console, level, orig => function (...args) {
              try {
                let out = '';
                for (let i = 0; i < 16 && i < args.length && out.length < 4096; i++) out += (i ? ' ' : '') + clip(text(args[i]), 4096);
                emit({ k: 'console', level, text: clip(out, 4096) });
              } catch (e) {}
              return apply(orig, this, args);
            });
          }
          // Only engine-dispatched events: a page-made event is untrusted, and `isTrusted` cannot be overridden on it.
          const onError = e => {
            try {
              if (e.isTrusted !== true || typeof e.message !== 'string') return;
              emit({ k: 'console', level: 'error', text: clip(e.message, 4096), url: typeof e.filename === 'string' ? clip(e.filename, 2048) : '', line: e.lineno | 0 });
            } catch (x) {}
          };
          const onRejection = e => {
            try { if (e.isTrusted === true) emit({ k: 'console', level: 'error', text: clip('Unhandled rejection: ' + text(e.reason), 4096) }); } catch (x) {}
          };
          window.addEventListener('error', onError, true);
          window.addEventListener('unhandledrejection', onRejection, true);
          // A primitive string URL resolved against the document base, cut before and after resolution (null: unknown).
          const known = x => {
            if (typeof x !== 'string') return null;
            let clipped = x.length > 2048, href = null;
            try { href = new URLCtor(clip(x, 2048), document.baseURI).href; } catch (e) {}
            if (href !== null && href.length > 2048) { href = clip(href, 2048); clipped = true; }
            return { href, clipped };
          };
          const verb = m => typeof m === 'string' && m.length <= 16 ? m : null;
          const net = (via, method, target, start, status, outcome) =>
            emit({ k: 'net', via, method, url: target ? target.href : null, urlClipped: target ? target.clipped : false, status, ms: now() - start, outcome });
          wrap(window, 'fetch', orig => function (...args) {
            const start = now();
            let method = null, target = null;
            try {
              if (typeof args[0] === 'string') { target = known(args[0]); if (args[1] == null) method = 'GET'; }
            } catch (e) {}
            const result = apply(orig, this, args);
            // Same fulfillment and rejection reach the page; only a foreign (non-Promise) result is returned untouched.
            try {
              return apply(thenOf, result, [
                r => { net('fetch', method, target, start, read(responseStatus, r), 'completed'); return r; },
                err => { net('fetch', method, target, start, null, read(errorName, err) === 'AbortError' ? 'aborted' : 'failed'); throw err; },
              ]);
            } catch (e) { return result; }
          });
          const states = new WeakMap(), proto = XMLHttpRequest.prototype;
          wrap(proto, 'open', orig => function (...args) {
            try { apply(wmSet, states, [this, { method: verb(args[0]), target: known(args[1]) }]); } catch (e) {}
            return apply(orig, this, args);
          });
          wrap(proto, 'send', orig => function (...args) {
            try {
              const state = apply(wmGet, states, [this]);
              if (state && !state.watched) {
                state.watched = true;
                const start = now(), self = this;
                apply(addListener, this, ['abort', () => { state.aborted = true; }]);
                apply(addListener, this, ['loadend', () => {
                  const status = read(xhrStatus, self);
                  net('xhr', state.method, state.target, start, status || null, status ? 'completed' : state.aborted ? 'aborted' : 'failed');
                }]);
              }
            } catch (e) {}
            return apply(orig, this, args);
          });
          const off = () => {
            live = false;
            document.removeEventListener(EV + '-off', off);
            window.removeEventListener('error', onError, true);
            window.removeEventListener('unhandledrejection', onRejection, true);
            for (let i = 0; i < restore.length; i++) restore[i]();
          };
          document.addEventListener(EV + '-off', off);
          return true;
        })();
        """
    }

    /// Runs in the isolated world: forwards the page hook's events to the native handler until the same `-off` event.
    /// Returns whether the native channel exists, so a failed attach is never mistaken for a live hook.
    static func relay(event: String, token: String, handler: String) -> String {
        """
        (() => {
          const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers["\(handler)"];
          if (!channel) return false;
          const forward = e => { try { const body = JSON.parse(e.detail); body.t = "\(token)"; channel.postMessage(body); } catch (err) {} };
          const off = () => {
            document.removeEventListener("\(event)", forward, true);
            document.removeEventListener("\(event)-off", off, true);
          };
          document.addEventListener("\(event)", forward, true);
          document.addEventListener("\(event)-off", off, true);
          return true;
        })();
        """
    }

    /// Tears down both scripts of one install through the DOM, so it works in either world and before the relay exists.
    static func off(event: String) -> String {
        "(() => { document.dispatchEvent(new CustomEvent(\"\(event)-off\")); return true; })();"
    }
}

/// Turns Chromium DevTools events into bounded records. Correlates one request across its events but only keeps
/// method, sanitized URL, status and timing: headers, bodies and cookies in the events are never read.
nonisolated final class ChromiumDiagnosticsMapper {
    private struct Pending {
        var method: String?
        var url: String?
        var urlTruncated = false
        var start: Double?
        var status: Int?
        var frameID: String?
        var loaderID: String?
    }

    private static let maxInFlight = 256
    private static let consoleLevels = ["log": "log", "debug": "debug", "info": "info", "error": "error", "assert": "error", "warning": "warn"]

    private var pending: [String: Pending] = [:]
    private var order: [String] = []
    /// In-flight requests dropped because more than `maxInFlight` were open at once. Their outcome is unknown; the owner
    /// surfaces this count in its read response instead of losing them silently.
    private(set) var lostInFlight = 0

    /// Forgets in-flight requests and the loss count: a finish event for a request that is gone maps to nothing. Call on
    /// each document change with the new document's identity, which keeps only that document's own requests (its
    /// main-document request and early subresources start before the commit is observed); without it, everything is
    /// forgotten (a new lease). Stale entries never occupy slots, and the loss count never carries into another document.
    func reset(keeping documentID: String? = nil) {
        pending = pending.filter { documentID != nil && $0.value.loaderID == documentID }
        order.removeAll { pending[$0] == nil }
        lostInFlight = 0
    }

    func entry(method: String, params: [String: Any]) -> PageDiagnostics.Entry? {
        switch method {
        case "Runtime.consoleAPICalled": return Self.console(params)
        case "Runtime.exceptionThrown": return Self.exception(params)
        case "Network.requestWillBeSent": return requestWillBeSent(params)
        case "Network.responseReceived":
            if let id = params["requestId"] as? String, pending[id] != nil {
                pending[id]?.status = PageDiagnostics.status((params["response"] as? [String: Any])?["status"])
            }
            return nil
        case "Network.loadingFinished": return finish(params, outcome: "completed")
        case "Network.loadingFailed": return finish(params, outcome: (params["canceled"] as? Bool) == true ? "aborted" : "failed")
        default: return nil
        }
    }

    // MARK: Console

    private static func console(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let type = params["type"] as? String, let level = consoleLevels[type], let args = params["args"] as? [[String: Any]] else { return nil }
        var text = ""
        var truncated = args.count > PageDiagnostics.maxConsoleArguments
        for arg in args.prefix(PageDiagnostics.maxConsoleArguments) {
            let separator = text.isEmpty ? "" : " "
            let room = PageDiagnostics.maxTextBytes - text.utf8.count - separator.utf8.count
            let piece = PageDiagnostics.clip(describe(arg), bytes: max(room, 0))
            text += separator + piece.text
            if piece.truncated { truncated = true; break }
        }
        return .init(
            stream: .console, fields: ["level": .text(level), "text": .text(text), "source": "cdp"], truncated: truncated,
            contextID: params["executionContextId"] as? Int)
    }

    /// Primitives only. Objects and functions are never rendered: their descriptions can embed arbitrary page data.
    private static func describe(_ arg: [String: Any]) -> String {
        switch arg["type"] as? String {
        case "string": return arg["value"] as? String ?? ""
        case "number":
            if let int = arg["value"] as? Int { return String(int) }
            if let double = arg["value"] as? Double { return String(double) }
            return arg["unserializableValue"] as? String ?? "[number]"
        case "boolean": return (arg["value"] as? Bool) == true ? "true" : "false"
        case "undefined": return "undefined"
        case "function": return "[function]"
        case "object":
            switch arg["subtype"] as? String {
            case "null": return "null"
            case "error": return PageDiagnostics.firstLine(arg["description"] as? String ?? "Error")
            default: return "[object omitted]"
            }
        default: return "[value omitted]"
        }
    }

    private static func exception(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let details = params["exceptionDetails"] as? [String: Any] else { return nil }
        let described = (details["exception"] as? [String: Any])?["description"] as? String
        let message = PageDiagnostics.clip(PageDiagnostics.firstLine(described ?? details["text"] as? String ?? "Uncaught"))
        var fields: [String: PageDiagnostics.Field] = ["level": "error", "text": .text(message.text), "source": "cdp"]
        var truncated = message.truncated
        if let raw = details["url"] as? String {
            let url = PageDiagnostics.boundedURL(raw)
            fields["url"] = url.text.map { .text($0) }
            truncated = truncated || url.truncated
        }
        if let line = details["lineNumber"] as? Int, line >= 0 { fields["line"] = .number(line + 1) }  // CDP lines are 0-based
        return .init(stream: .console, fields: fields, truncated: truncated, contextID: details["executionContextId"] as? Int)
    }

    // MARK: Network

    private func requestWillBeSent(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let id = params["requestId"] as? String, let request = params["request"] as? [String: Any] else { return nil }
        let timestamp = params["timestamp"] as? Double
        var hop: PageDiagnostics.Entry?
        if let redirect = params["redirectResponse"] as? [String: Any], var previous = pending[id] {
            previous.status = PageDiagnostics.status(redirect["status"])
            hop = Self.network(previous, end: timestamp, outcome: "completed")
        }
        let url = (request["url"] as? String).map(PageDiagnostics.boundedURL)
        let next = Pending(
            method: PageDiagnostics.method(request["method"]), url: url?.text, urlTruncated: url?.truncated ?? false, start: timestamp,
            frameID: params["frameId"] as? String, loaderID: params["loaderId"] as? String
        )
        if pending.updateValue(next, forKey: id) == nil {
            order.append(id)
            if order.count > Self.maxInFlight {
                pending[order.removeFirst()] = nil
                lostInFlight += 1
            }
        }
        return hop
    }

    private func finish(_ params: [String: Any], outcome: String) -> PageDiagnostics.Entry? {
        guard let id = params["requestId"] as? String, let request = pending.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        return Self.network(request, end: params["timestamp"] as? Double, outcome: outcome)
    }

    private static func network(_ request: Pending, end: Double?, outcome: String) -> PageDiagnostics.Entry {
        var fields: [String: PageDiagnostics.Field] = ["outcome": .text(outcome), "source": "cdp"]
        fields["method"] = request.method.map { .text($0) }
        fields["url"] = request.url.map { .text($0) }
        fields["status"] = request.status.map { .number($0) }
        if let start = request.start, let end {
            fields["durationMs"] = PageDiagnostics.duration(milliseconds: ((end - start) * 1000).rounded()).map { .number($0) }
        }
        return .init(stream: .network, fields: fields, truncated: request.urlTruncated, frameID: request.frameID, loaderID: request.loaderID)
    }
}
