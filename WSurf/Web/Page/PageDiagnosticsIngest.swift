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
        /// Headers and bodies the request may show, raw until the owner has checked the policy again and made the fields.
        var detail: DetailInput?
        /// Bodies a Chromium request still has to fetch before its record is complete.
        var bodyFetch: BodyFetch?
    }

    /// What the owner fetches from DevTools for a finished request: its response body, and its request body when the event held none.
    struct BodyFetch: Equatable, Sendable {
        let requestID: String
        var response: Bool
        var requestPost: Bool
        /// The response's media type, which the body is read under.
        var mimeType: String?
    }

    static let maxTextBytes = 4_096
    static let maxURLBytes = 2_048
    static let maxConsoleArguments = 16
    static let methodCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Cuts `text` to at most `bytes` UTF-8 bytes on a unicode scalar boundary, touching only the kept prefix. Scalars, not
    /// characters: a single grapheme cluster can be arbitrarily many bytes.
    static func clip(_ text: String, bytes: Int = maxTextBytes) -> (text: String, truncated: Bool) {
        var used = 0
        var end = text.unicodeScalars.startIndex
        while end < text.unicodeScalars.endIndex {
            let size = String(text.unicodeScalars[end]).utf8.count
            if used + size > bytes {
                return (String(text.unicodeScalars[..<end]), true)
            }
            used += size
            end = text.unicodeScalars.index(after: end)
        }
        return (text, false)
    }

    /// Bytes are checked first (O(1) on a native string), so a hostile string is never walked by `count` or the set test.
    static func method(_ value: Any?) -> String? {
        guard let value = value as? String, (1...16).contains(value.utf8.count),
            value.unicodeScalars.allSatisfy(methodCharacters.contains)
        else { return nil }
        return value.uppercased()
    }

    static func status(_ value: Any?) -> Int? {
        guard let value = value as? Int, (100...599).contains(value) else { return nil }
        return value
    }

    static func duration(milliseconds: Double?) -> Int? {
        guard let ms = milliseconds, ms.isFinite, ms >= 0, ms < 1e9 else { return nil }
        return Int(ms.rounded())
    }

    static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// A page-supplied URL, bounded before anything parses it: the raw string is cut to `maxURLBytes` first (a multi-megabyte
    /// string never reaches `URLComponents` or any join), then sanitized and cut again. `truncated` is set whenever bytes
    /// were cut, including when the cut prefix no longer parses and `text` is nil (dropped, not unknown), and when the query
    /// kept fewer parameters or shorter names than the URL had.
    static func boundedURL(_ raw: String, _ queryValues: QueryValues) -> (text: String?, truncated: Bool) {
        let head = clip(raw, bytes: maxURLBytes)
        guard let clean = sanitized(url: head.text, queryValues: queryValues) else { return (nil, head.truncated) }
        let tail = clip(clean.text, bytes: maxURLBytes)
        return (tail.text, head.truncated || clean.cut || tail.truncated)
    }

    // MARK: Resource facts

    /// The resource types a network record's `type` can have: Chromium's DevTools set, lowercased. WebKit reports `fetch`,
    /// `xhr`, and the others from the resource entries it can map.
    static let resourceTypes: Set<String> = [
        "document", "stylesheet", "image", "media", "font", "script", "texttrack", "xhr", "fetch", "prefetch", "eventsource", "websocket",
        "manifest", "signedexchange", "ping", "cspviolationreport", "preflight", "other",
    ]

    /// A DevTools resource type; one outside the known set is `other`, a non-string is unknown.
    static func resourceType(_ value: Any?) -> String? {
        guard let raw = value as? String, raw.utf8.count <= 32 else { return nil }
        let type = raw.lowercased()
        return resourceTypes.contains(type) ? type : "other"
    }

    /// The type of a WebKit resource-timing entry from its initiator, refined by file extension where the initiator (`link`,
    /// `css`) covers several kinds. `fetch` and `xmlhttprequest` are never mapped: the page hook already records those calls.
    static func resourceType(initiator: String, url: String?) -> String {
        switch initiator {
        case "img", "image", "input":
            return "image"
        case "script":
            return "script"
        case "iframe", "frame", "navigation":
            return "document"
        case "video", "audio", "track":
            return "media"
        case "beacon":
            return "ping"
        case "link", "css":
            let path = url.flatMap { URLComponents(string: $0)?.path.lowercased() } ?? ""
            switch path.split(separator: ".").last.map(String.init) {
            case "css":
                return "stylesheet"
            case "js", "mjs":
                return "script"
            case "woff", "woff2", "ttf", "otf":
                return "font"
            case "png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "ico":
                return "image"
            default:
                return "other"
            }
        default:
            return "other"
        }
    }

    private static let mediaTypeCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")

    /// The media type of a `Content-Type` value, without parameters (a charset, a boundary), lowercased and shaped
    /// `type/subtype`; anything else is unknown. The value is checked by byte count first, so it is never walked when long.
    static func mediaType(_ value: Any?) -> String? {
        guard let raw = value as? String, raw.utf8.count <= 256 else { return nil }
        let essence = (raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let parts = essence.split(separator: "/", omittingEmptySubsequences: false)
        guard essence.utf8.count <= 100, parts.count == 2,
            parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(mediaTypeCharacters.contains) })
        else { return nil }
        return essence
    }

    /// A byte count: a non-negative whole number the page or DevTools gave, or unknown (never `0` for "not exposed").
    static func byteCount(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int >= 0 ? int : nil
        }
        guard let double = value as? Double, double.isFinite, double >= 0, double < 1e12 else { return nil }
        return Int(double)
    }

    // MARK: Stacks

    static let maxStackFrames = 10
    static let maxStackBytes = 2_048
    /// The Developer tier's full console keeps longer stacks.
    static let maxFullStackFrames = 30
    static let maxFullStackBytes = 6_144
    static let maxStackSourceBytes = 4_096
    static let maxFullStackSourceBytes = 8_192
    static let maxFunctionBytes = 64

    struct StackFrame: Equatable {
        var function = ""
        var url: String?
        var line: Int?
        var column: Int?
    }

    /// One `function (url:line:column)` line per frame. URLs are sanitized like every other URL in a record; a function name is
    /// page text, cut to `maxFunctionBytes` with control characters blanked. At most `maxStackFrames` frames and
    /// `maxStackBytes` bytes are kept, and `truncated` says whether anything was left out. Nil when no frame survives.
    static func stack(_ frames: [StackFrame], queryValues: QueryValues, full: Bool = false) -> (text: String, truncated: Bool)? {
        let maxFrames = full ? maxFullStackFrames : maxStackFrames
        let maxBytes = full ? maxFullStackBytes : maxStackBytes
        var lines: [String] = []
        var used = 0
        var truncated = frames.count > maxFrames
        for frame in frames.prefix(maxFrames) {
            let function = clip(frame.function, bytes: maxFunctionBytes)
            let name = String(String.UnicodeScalarView(function.text.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : $0 }))
            var location = frame.url.flatMap { boundedURL($0, queryValues).text } ?? ""
            if !location.isEmpty, let line = frame.line {
                location += ":\(line)" + (frame.column.map { ":\($0)" } ?? "")
            }
            let text = name.isEmpty ? location : location.isEmpty ? name : "\(name) (\(location))"
            guard !text.isEmpty else { continue }
            let size = text.utf8.count + (lines.isEmpty ? 0 : 1)
            guard used + size <= maxBytes else {
                truncated = true
                if lines.isEmpty { lines.append(clip(text, bytes: maxBytes).text) }  // one frame alone over the bound is cut, not dropped
                break
            }
            used += size
            lines.append(text)
            truncated = truncated || function.truncated
        }
        return lines.isEmpty ? nil : (lines.joined(separator: "\n"), truncated)
    }

    /// Frames from a WebKit `Error.stack`, whose lines read `function@url:line:column` (`@url:…` without a name). The page
    /// supplied the string, so only the first `maxStackFrames + 1` lines are looked at and a line that does not end in a
    /// location keeps just its function name.
    static func webKitFrames(_ stack: String, limit: Int = maxStackFrames) -> [StackFrame] {
        stack.split(separator: "\n", omittingEmptySubsequences: true).prefix(limit + 1).map { (line: Substring) -> StackFrame in
            let at = line.firstIndex(of: "@")
            var frame = StackFrame(function: at.map { String(line[..<$0]) } ?? "")
            var location: Substring = at.map { line[line.index(after: $0)...] } ?? line
            func number() -> Int? {
                guard let colon = location.lastIndex(of: ":"), let value = Int(location[location.index(after: colon)...]) else { return nil }
                location = location[..<colon]
                return value
            }
            let last = number()
            if let middle = number() {
                (frame.line, frame.column) = (middle, last)
            } else {
                frame.line = last
            }
            frame.url = location.contains(":") ? String(location) : nil
            return frame
        }
    }
}

/// Parses untrusted messages posted by the WebKit page hook. Anything that is not exactly the expected shape is dropped;
/// unknown keys (cookies, headers) are never copied.
nonisolated enum PageDiagnosticsHook {
    private static let levels: Set<String> = ["log", "info", "warn", "error", "debug"]
    private static let outcomes: Set<String> = ["completed", "failed", "aborted"]
    private static let transports: Set<String> = ["fetch", "xhr", "resource"]

    static func entry(from body: Any, queryValues: PageDiagnostics.QueryValues, detail: PageDiagnostics.DetailPolicy = .off) -> PageDiagnostics.Entry? {
        guard let body = body as? [String: Any] else { return nil }
        switch body["k"] as? String {
        case "console":
            return console(body, queryValues, detail)
        case "net":
            return network(body, queryValues, detail)
        default:
            return nil
        }
    }

    /// How many events the page's start-up buffer had to drop before the relay attached; nil for any other message.
    static func lostEarly(from body: Any) -> Int? {
        guard let body = body as? [String: Any], body["k"] as? String == "lost", let count = body["n"] as? Int, (1...1_000_000).contains(count) else { return nil }
        return count
    }

    private static func console(_ body: [String: Any], _ queryValues: PageDiagnostics.QueryValues, _ detail: PageDiagnostics.DetailPolicy) -> PageDiagnostics.Entry? {
        guard let level = body["level"] as? String, levels.contains(level), let text = body["text"] as? String else { return nil }
        let message = PageDiagnostics.clip(text)
        var fields: [String: PageDiagnostics.Field] = ["level": .text(level), "text": .text(message.text), "source": "webkit-hook"]
        var truncated = message.truncated
        if let raw = body["url"] as? String {
            let url = PageDiagnostics.boundedURL(raw, queryValues)
            fields["url"] = url.text.map { .text($0) }
            truncated = truncated || url.truncated
        }
        if let line = body["line"] as? Int, line >= 0 { fields["line"] = .number(line) }
        if let column = body["col"] as? Int, column > 0 { fields["column"] = .number(column) }
        if let raw = body["stack"] as? String {
            let full = detail.consoleDetail
            let source = PageDiagnostics.clip(raw, bytes: full ? PageDiagnostics.maxFullStackSourceBytes : PageDiagnostics.maxStackSourceBytes)
            let frames = PageDiagnostics.webKitFrames(source.text, limit: full ? PageDiagnostics.maxFullStackFrames : PageDiagnostics.maxStackFrames)
            if let stack = PageDiagnostics.stack(frames, queryValues: queryValues, full: full) {
                fields["stack"] = .text(stack.text)
                truncated = truncated || stack.truncated || source.truncated
            }
        }
        if detail.consoleDetail, let raw = body["pv"] as? String {
            let preview = PageDiagnostics.Redaction.preview(json: raw)
            fields["preview"] = .text(preview.text)
            truncated = truncated || preview.truncated
        }
        return .init(stream: .console, fields: fields, truncated: truncated)
    }

    /// `method` and `url` are absent when the hook could not know them without running page code (a Request, URL or
    /// RequestInit argument): unknown is never reported as a guess. `urlClipped` is the hook's own cut of a long URL.
    /// `type` is the call kind for fetch and XMLHttpRequest and the mapped initiator for a resource-timing entry.
    private static func network(_ body: [String: Any], _ queryValues: PageDiagnostics.QueryValues, _ detail: PageDiagnostics.DetailPolicy) -> PageDiagnostics.Entry? {
        guard let via = body["via"] as? String, transports.contains(via) else { return nil }
        let outcome = (body["outcome"] as? String).flatMap { outcomes.contains($0) ? $0 : nil } ?? "unknown"
        var fields: [String: PageDiagnostics.Field] = ["outcome": .text(outcome), "source": .text("webkit-\(via)")]
        fields["method"] = PageDiagnostics.method(body["method"]).map { .text($0) }
        let raw = body["url"] as? String
        let url = raw.map { PageDiagnostics.boundedURL($0, detail.queryValues(for: $0, tagged: queryValues)) }
        fields["url"] = url?.text.map { .text($0) }
        fields["status"] = PageDiagnostics.status(body["status"]).map { .number($0) }
        fields["durationMs"] = PageDiagnostics.duration(milliseconds: body["ms"] as? Double).map { .number($0) }
        fields["mimeType"] = PageDiagnostics.mediaType(body["mime"]).map { .text($0) }
        fields["transferBytes"] = PageDiagnostics.byteCount(body["bytes"]).map { .number($0) }
        switch via {
        case "resource":
            let initiator = (body["rtype"] as? String).flatMap { $0.utf8.count <= 32 ? $0.lowercased() : nil } ?? ""
            fields["type"] = .text(PageDiagnostics.resourceType(initiator: initiator, url: url?.text))
        default:
            fields["type"] = .text(via)
        }
        let truncated = (url?.truncated ?? false) || body["urlClipped"] as? Bool == true
        var entry = PageDiagnostics.Entry(stream: .network, fields: fields, truncated: truncated)
        if let raw, via != "resource", detail.network(raw), let rd = body["rd"] as? [String: Any] {
            entry.detail = detailInput(rd, url: raw, detail, queryValues)
        }
        return entry
    }

    /// The raw detail the page hook read for a request to `url`. Nil when the page reports that the request left the developer
    /// sites (a redirect) or when the final address is not one: nothing is kept then, not even the request's own side.
    static func detailInput(
        _ rd: [String: Any], url: String, _ policy: PageDiagnostics.DetailPolicy, _ queryValues: PageDiagnostics.QueryValues
    ) -> PageDiagnostics.DetailInput? {
        if rd["off"] as? Bool == true { return nil }
        if let final = rd["fin"] as? String, !policy.covers(final) { return nil }
        let mode: (String) -> PageDiagnostics.QueryValues = { policy.queryValues(for: $0, tagged: queryValues) }
        func headers(_ key: String) -> [PageDiagnostics.Header]? {
            guard policy.options.headers, let list = rd[key] as? [[Any]] else { return nil }
            let pairs = list.prefix(PageDiagnostics.Redaction.maxHeaders).compactMap { entry -> (name: String, value: String)? in
                guard entry.count == 2, let name = entry[0] as? String, let value = entry[1] as? String else { return nil }
                return (name, PageDiagnostics.clip(value, bytes: 1_024).text)
            }
            return PageDiagnostics.Redaction.headers(pairs, requestURL: url, mode: mode)
        }
        func body(_ key: String) -> PageDiagnostics.RawBody? {
            guard policy.options.bodies, let raw = rd[key] as? [String: Any] else { return nil }
            return PageDiagnostics.RawBody(
                text: raw["t"] as? String, contentType: (raw["ct"] as? String).map { PageDiagnostics.clip($0, bytes: 512).text },
                size: PageDiagnostics.byteCount(raw["size"]), binary: raw["bin"] as? Bool == true, partial: raw["more"] as? Bool == true,
                note: (raw["note"] as? String).map { PageDiagnostics.clip($0, bytes: 200).text })
        }
        return PageDiagnostics.DetailInput(
            url: url, requestHeaders: headers("reqH"), responseHeaders: headers("resH"), requestBody: body("reqB"), responseBody: body("resB"))
    }

    // MARK: Page-side scripts

    /// Runs in the page world, either as a document-start user script (so it sees the document from its first script) or
    /// evaluated into a document that is already running. Reports through a DOM event (an isolated-world relay forwards it to
    /// native), preserves every wrapped call's `this`, arguments, result and exceptions, and on the `-off` event stops
    /// reporting and restores only the wrappers it still owns (a page that wrapped over them keeps its own wrapper; ours is
    /// inert).
    ///
    /// Events are held in a closure-private ring of at most 128 until the relay announces itself with the `-ready` event, then
    /// delivered in order; `lost` events that did not fit are reported once as `{k: 'lost', n}`. An install that finds a live
    /// hook of the same event (the user script ran first, or the document came back from the back/forward cache) does
    /// nothing: it answers the `-probe` event and returns, so nothing is ever wrapped twice.
    ///
    /// The hook never runs page code to describe a value: console arguments are rendered from primitives only (every object
    /// and Proxy is `[object]`; no `instanceof`, prototype walk, getter, `toString` or property read), and fetch /
    /// XMLHttpRequest metadata comes only from primitive string arguments. A `Request`, `URL` or `RequestInit` argument is
    /// never read, so that method or URL is reported as null (unknown), and `fetch(url)` with no init is the only way the
    /// method is known without a read. Status, headers and abort reasons come from brand-checked native getters, which throw
    /// on a foreign object instead of running its code. A genuine Error (`Error.isError`, a brand check that a Proxy fails)
    /// is described from its own data properties `message`, `name` and `stack` only; an accessor is never called. Resource
    /// timing entries are read through getters captured at install. Ceiling: builtins the page patched before the hook was
    /// installed cannot be told apart from the platform's, which the document-start install narrows to nothing.
    static func pageHook(event: String, detail: PageDiagnostics.DetailPolicy = .off) -> String {
        [hookCore(event: event, detail: detail), hookDetail, hookConsole, hookNetwork, hookResources, hookClose].joined(separator: "\n")
    }

    /// What the page-side hook may read, as the JSON the script starts with: nothing unless the Developer tier holds. The hook
    /// reads a request's detail only for a host on `hosts`; native code checks every address again.
    private static func detailConfiguration(_ detail: PageDiagnostics.DetailPolicy) -> String {
        let active = detail.tier
        let object: [String: Any] = [
            "headers": active && detail.options.headers, "bodies": active && detail.options.bodies, "console": active && detail.options.console,
            "n": active && detail.options.network, "hosts": active ? detail.anyPortHosts : [],
            "sites": active ? detail.sites.map { site -> [String: Any] in ["h": site.host, "p": site.port.map { $0 as Any } ?? NSNull()] } : [],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func hookCore(event: String, detail: PageDiagnostics.DetailPolicy) -> String {
        """
        (() => {
          const EV = "\(event)";
          const DET = \(detailConfiguration(detail));
          const apply = Reflect.apply, dispatch = document.dispatchEvent.bind(document), CE = CustomEvent, stringify = JSON.stringify;
          const now = performance.now.bind(performance), URLCtor = URL, slice = String.prototype.slice;
          const thenOf = Promise.prototype.then, addListener = EventTarget.prototype.addEventListener, removeListener = EventTarget.prototype.removeEventListener;
          const wmGet = WeakMap.prototype.get, wmSet = WeakMap.prototype.set, push = Array.prototype.push, shift = Array.prototype.shift;
          const gopd = Object.getOwnPropertyDescriptor, gpo = Object.getPrototypeOf, isError = Error.isError;
          try {
            const probe = new CE(EV + '-probe', { detail: { alive: false } });
            dispatch(probe);
            if (probe.detail.alive === true) return true;
          } catch (e) {}
          const getter = (ctor, key) => {
            try { return gopd(ctor.prototype, key).get; } catch (e) { return undefined; }
          };
          const responseStatus = getter(globalThis.Response, 'status'), xhrStatus = getter(globalThis.XMLHttpRequest, 'status');
          const responseHeaders = getter(globalThis.Response, 'headers'), errorName = getter(globalThis.DOMException, 'name');
          const headersGet = globalThis.Headers && Headers.prototype.get, xhrHeader = XMLHttpRequest.prototype.getResponseHeader;
          const read = (get, object) => { try { return apply(get, object, []); } catch (e) { return null; } };
          const clip = (s, n) => s.length > n ? apply(slice, s, [0, n]) : s;
          let live = true, ready = false, lost = 0;
          const ring = [];
          const send = s => { try { dispatch(new CE(EV, { detail: s })); } catch (e) {} };
          const emit = o => {
            if (!live) return;
            try {
              const s = stringify(o);
              if (ready) { send(s); return; }
              if (ring.length >= 128) { apply(shift, ring, []); lost++; }
              apply(push, ring, [s]);
            } catch (e) {}
          };
          const onReady = () => {
            if (ready || !live) return;
            ready = true;
            if (lost) send(stringify({ k: 'lost', n: lost }));
            for (let i = 0; i < ring.length; i++) send(ring[i]);
            ring.length = 0;
          };
          const onProbe = e => { try { e.detail.alive = true; } catch (x) {} };
          apply(addListener, document, [EV + '-ready', onReady]);
          apply(addListener, document, [EV + '-probe', onProbe]);
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
          const own = (object, key) => {
            const d = gopd(object, key);
            return d && 'value' in d ? d.value : undefined;
          };
          const errorKinds = [];
          for (const name of ['Error', 'TypeError', 'RangeError', 'SyntaxError', 'ReferenceError', 'EvalError', 'URIError']) {
            try { apply(push, errorKinds, [[globalThis[name].prototype, name]]); } catch (e) {}
          }
          // A genuine Error described without running page code: `message`, `name` and `stack` only when they are own data
          // properties, the name of a built-in kind from its prototype's identity. Null for anything else.
          const errorInfo = v => {
            try {
              if (typeof v !== 'object' || v === null || typeof isError !== 'function' || apply(isError, Error, [v]) !== true) return null;
              let name = own(v, 'name');
              if (typeof name !== 'string') {
                const proto = gpo(v);
                name = 'Error';
                for (let i = 0; i < errorKinds.length; i++) if (errorKinds[i][0] === proto) name = errorKinds[i][1];
              }
              const message = own(v, 'message'), stack = own(v, 'stack');
              return { text: clip(name, 64) + (typeof message === 'string' && message ? ': ' + clip(message, 1024) : ''), stack: typeof stack === 'string' ? clip(stack, 4096) : '' };
            } catch (e) { return null; }
          };
        """
    }

    private static let hookConsole = """
          for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
            wrap(console, level, orig => function (...args) {
              try {
                let out = '', stack = '', pre = DET.console ? [] : null, objects = false;
                for (let i = 0; i < 16 && i < args.length && out.length < 4096; i++) {
                  const info = errorInfo(args[i]);
                  if (info && !stack) stack = info.stack;
                  out += (i ? ' ' : '') + clip(info ? info.text : text(args[i]), 4096);
                  if (pre) {
                    objects = objects || (!info && typeof args[i] === 'object' && args[i] !== null);
                    apply(push, pre, [info ? info.text : pv(args[i], 0, [])]);
                  }
                }
                emit({ k: 'console', level, text: clip(out, 4096), stack: stack || (pre ? stackHere() : ''), pv: pre && objects ? clip(stringify(pre), 2048) : undefined });
              } catch (e) {}
              return apply(orig, this, args);
            });
          }
          // An uncaught error counts only when the engine dispatched it: a page-made event is untrusted, and `isTrusted` cannot be
          // overridden on it.
          const errorOf = getter(globalThis.ErrorEvent, 'error'), reasonOf = getter(globalThis.PromiseRejectionEvent, 'reason');
          const onError = e => {
            try {
              if (e.isTrusted !== true || typeof e.message !== 'string') return;
              const info = errorInfo(read(errorOf, e));
              emit({ k: 'console', level: 'error', text: clip(e.message, 4096), line: e.lineno | 0, col: e.colno | 0, stack: info ? info.stack : '',
                url: typeof e.filename === 'string' ? clip(e.filename, 2048) : '' });
            } catch (x) {}
          };
          // WebKit dispatches `unhandledrejection` as an untrusted event, so `isTrusted` cannot tell the engine's from a page-made one.
          // The brand-checked getter can tell a PromiseRejectionEvent from anything else, and a page-made one only reports what the
          // page itself chose to say.
          const onRejection = e => {
            try {
              let reason;
              try { reason = apply(reasonOf, e, []); } catch (x) { return; }
              const info = errorInfo(reason);
              emit({ k: 'console', level: 'error', text: clip('Unhandled rejection: ' + (info ? info.text : text(reason)), 4096), stack: info ? info.stack : '' });
            } catch (x) {}
          };
          window.addEventListener('error', onError, true);
          window.addEventListener('unhandledrejection', onRejection, true);
        """

    private static let hookNetwork = """
          // A primitive string URL resolved against the document base, cut before and after resolution (null: unknown).
          const known = x => {
            if (typeof x !== 'string') return null;
            let clipped = x.length > 2048, href = null;
            try { href = new URLCtor(clip(x, 2048), document.baseURI).href; } catch (e) {}
            if (href !== null && href.length > 2048) { href = clip(href, 2048); clipped = true; }
            return { href, clipped };
          };
          const verb = m => typeof m === 'string' && m.length <= 16 ? m : null;
          const net = (via, method, target, start, status, outcome, mime, rd, ms) =>
            emit({ k: 'net', via, method, url: target ? target.href : null, urlClipped: target ? target.clipped : false, status,
              ms: ms === undefined ? now() - start : ms, outcome, mime, rd });
          const mimeOfResponse = r => {
            try { const v = apply(headersGet, apply(responseHeaders, r, []), ['content-type']); return typeof v === 'string' ? clip(v, 256) : null; } catch (e) { return null; }
          };
          const mimeOfRequest = x => {
            try { const v = apply(xhrHeader, x, ['content-type']); return typeof v === 'string' ? clip(v, 256) : null; } catch (e) { return null; }
          };
          wrap(window, 'fetch', orig => function (...args) {
            const start = now();
            let method = null, target = null, req = null;
            try {
              if (typeof args[0] === 'string') { target = known(args[0]); if (args[1] == null) method = 'GET'; }
              if (DET.n) {
                req = fetchRequest(args);
                if (req) { method = req.method || method; target = req.target || target; }
              }
            } catch (e) {}
            const result = apply(orig, this, args);
            // Same fulfillment and rejection reach the page; only a foreign (non-Promise) result is returned untouched.
            try {
              return apply(thenOf, result, [
                r => {
                  try {
                    if (req) fetchDetail(r, req, method, target, start);
                    else net('fetch', method, target, start, read(responseStatus, r), 'completed', mimeOfResponse(r));
                  } catch (e) {}
                  return r;
                },
                err => {
                  net('fetch', method, target, start, null, read(errorName, err) === 'AbortError' ? 'aborted' : 'failed', null,
                    req ? { reqH: req.rh, reqB: req.rb } : undefined);
                  throw err;
                },
              ]);
            } catch (e) { return result; }
          });
          const states = new WeakMap(), proto = XMLHttpRequest.prototype;
          wrap(proto, 'open', orig => function (...args) {
            try { apply(wmSet, states, [this, { method: verb(args[0]), target: known(args[1]), rh: [] }]); } catch (e) {}
            return apply(orig, this, args);
          });
          if (DET.n) {
            wrap(proto, 'setRequestHeader', orig => function (...args) {
              try {
                const state = apply(wmGet, states, [this]);
                if (state && state.target && covered(state.target.href) && typeof args[0] === 'string' && typeof args[1] === 'string' && state.rh.length < 64) {
                  apply(push, state.rh, [[clip(args[0], 100), clip(args[1], 1024)]]);
                }
              } catch (e) {}
              return apply(orig, this, args);
            });
          }
          wrap(proto, 'send', orig => function (...args) {
            try {
              const state = apply(wmGet, states, [this]);
              if (state && !state.watched) {
                state.watched = true;
                const start = now(), self = this;
                state.det = DET.n && !!state.target && covered(state.target.href);
                if (state.det && DET.bodies) state.rb = bodyOf(args[0], contentTypeOf(state.rh));
                apply(addListener, this, ['abort', () => { state.aborted = true; }]);
                apply(addListener, this, ['loadend', () => {
                  const status = read(xhrStatus, self);
                  if (state.det) { try { xhrDetail(self, state, start, status); } catch (e) {} return; }
                  net('xhr', state.method, state.target, start, status || null, status ? 'completed' : state.aborted ? 'aborted' : 'failed', status ? mimeOfRequest(self) : null);
                }]);
              }
            } catch (e) {}
            return apply(orig, this, args);
          });
        """

    private static let hookResources = """
          // Resource loads (images, scripts, stylesheets, fonts, frames…) that no wrapped call covers. Only entries created from
          // now on: nothing earlier than the capture is reported. fetch and XMLHttpRequest entries are skipped, the wrappers
          // above already record those calls.
          try {
            const entriesOf = PerformanceObserverEntryList.prototype.getEntries, observe = PerformanceObserver.prototype.observe, disconnect = PerformanceObserver.prototype.disconnect;
            const entryName = getter(globalThis.PerformanceEntry, 'name'), entryDuration = getter(globalThis.PerformanceEntry, 'duration');
            const initiator = getter(globalThis.PerformanceResourceTiming, 'initiatorType'), transfer = getter(globalThis.PerformanceResourceTiming, 'transferSize');
            const responseCode = getter(globalThis.PerformanceResourceTiming, 'responseStatus');
            const observer = new PerformanceObserver(list => {
              try {
                const entries = apply(entriesOf, list, []);
                for (let i = 0; i < entries.length && i < 64; i++) {
                  const entry = entries[i], kind = read(initiator, entry), name = read(entryName, entry);
                  if (kind === 'fetch' || kind === 'xmlhttprequest' || typeof kind !== 'string') continue;
                  emit({ k: 'net', via: 'resource', rtype: clip(kind, 32), url: typeof name === 'string' ? clip(name, 2048) : null, urlClipped: typeof name === 'string' && name.length > 2048,
                    bytes: read(transfer, entry) || null, status: read(responseCode, entry) || null, ms: read(entryDuration, entry), outcome: 'completed' });
                }
              } catch (e) {}
            });
            apply(observe, observer, [{ type: 'resource' }]);
            restore.push(() => apply(disconnect, observer, []));
          } catch (e) {}
        """

    private static let hookClose = """
          const off = () => {
            live = false;
            apply(removeListener, document, [EV + '-off', off]);
            apply(removeListener, document, [EV + '-ready', onReady]);
            apply(removeListener, document, [EV + '-probe', onProbe]);
            window.removeEventListener('error', onError, true);
            window.removeEventListener('unhandledrejection', onRejection, true);
            for (let i = 0; i < restore.length; i++) restore[i]();
          };
          apply(addListener, document, [EV + '-off', off]);
          return true;
        })();
        """

    /// Runs in the isolated world: forwards the page hook's events to the native handler until the same `-off` event, then
    /// tells the hook it may deliver what it buffered (`-ready`). Attaching twice (the document returned from the back/forward
    /// cache, or a repeated install) forwards once. Returns whether the native channel exists, so a failed attach is never
    /// mistaken for a live hook.
    static func relay(event: String, token: String, handler: String) -> String {
        """
        (() => {
          const channel = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers["\(handler)"];
          if (!channel) return false;
          const attached = globalThis.__wsurfDiagRelays || (globalThis.__wsurfDiagRelays = {});
          if (!attached["\(event)"]) {
            attached["\(event)"] = true;
            const forward = e => { try { const body = JSON.parse(e.detail); body.t = "\(token)"; channel.postMessage(body); } catch (err) {} };
            const off = () => {
              delete attached["\(event)"];
              document.removeEventListener("\(event)", forward, true);
              document.removeEventListener("\(event)-off", off, true);
            };
            document.addEventListener("\(event)", forward, true);
            document.addEventListener("\(event)-off", off, true);
          }
          document.dispatchEvent(new CustomEvent("\(event)-ready"));
          return true;
        })();
        """
    }

    /// Tears down both scripts of one install through the DOM, so it works in either world and before the relay exists.
    static func off(event: String) -> String {
        "(() => { document.dispatchEvent(new CustomEvent(\"\(event)-off\")); return true; })();"
    }
}
