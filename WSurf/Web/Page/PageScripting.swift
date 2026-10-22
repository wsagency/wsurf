// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// Running a script in a page, and editing its DOM, for the MCP Developer tier.
///
/// Both exist only for a paired app on a developer site in the Developer profile (`MCPBrowserSession` decides that, and asks
/// again after every suspension through `authorized`). Everything here is bounded: the script text, the time it may take, and
/// the result it may return.
///
/// **What a script may read, and the rule for sensitive values.** A script runs in the page's own world (`page`), so it sees
/// what the page's scripts see, or in a world of its own (`isolated`) that shares the DOM but none of the page's variables. In
/// both it can read anything the page holds. What comes *back to the agent* is checked first. WSurf's own page runtime, which
/// runs in a world the page cannot reach, reads the values that sensitive fields hold, before the script runs and again after it
/// (in the document, its open shadow roots and its same-origin frames). A field is sensitive when `R.isSensitiveField` says so,
/// the test `readPage` already applies: a password field, a field autofill marked as password, card or contact, or one whose
/// autocomplete, name, id or label says password, code, card number, CVC, IBAN, account number and the like.
///
/// Every string in the result, every key, the text of a thrown error and whatever the engine says when the script cannot run is
/// then compared with those values. A string equal to
/// one of them (ignoring ASCII case and surrounding space) becomes `‹hidden›`; a value of at least 4 characters is also hidden
/// inside longer text, as it is, whitespace-collapsed, percent-encoded, JSON-escaped and HTML-escaped. The reply states how many
/// places were hidden. Values the connection typed itself as test secrets are hidden by `MCPSecretScrubber` on top of this.
///
/// Cookie values the page can read, when they look like a session id or a token (16 characters or more), are hidden the same way.
///
/// This keeps a value from coming back by accident. It is not a sandbox: a script that splits, encodes or derives a value in
/// another way, or sends it over the network, can still carry it out. That is why the tool exists only in the Developer tier, and
/// why every call is audited.
enum PageScripting {
    /// The most source text a script may have.
    nonisolated static let maximumSourceBytes = 16 * 1_024
    /// The serialized value a script may return; anything beyond it is cut and flagged.
    nonisolated static let maximumValueBytes = 16 * 1_024
    /// How far hiding sensitive values may lengthen a result past `maximumValueBytes` (a hidden value becomes `‹hidden›`).
    nonisolated static let hidingSlack = 4 * 1_024
    /// What the page may hand back for one call (value, error and envelope), checked before WSurf reads any of it.
    nonisolated static let maximumReplyBytes = 48 * 1_024
    nonisolated static let timeoutMilliseconds = 50...5_000
    nonisolated static let defaultTimeoutMilliseconds = 2_000
    /// How long WSurf waits past the page's own deadline for a script that never yields.
    static let grace: Duration = .seconds(1)

    /// The isolated world is kept for the life of the app: WebKit drops a world, with everything a script set in it, as soon as
    /// the last reference to it goes.
    private static let isolatedWorld = WKContentWorld.world(name: "wsurf.script")

    /// Where a script runs.
    enum World: String, Sendable {
        case page, isolated

        @MainActor var contentWorld: WKContentWorld {
            self == .page ? .page : PageScripting.isolatedWorld
        }
    }

    enum Outcome {
        /// The page's reply as JSON, with sensitive values hidden: `{ok, type, value, truncated}` or `{ok: false, error}`, and
        /// `redacted`, the number of places hidden.
        case completed(String)
        /// The script did not finish in time. `interrupted` says whether the engine could stop it.
        case timedOut(interrupted: Bool)
        /// The script could not be compiled or started.
        case failed(String)
        /// The page or the connection's access changed while the script ran; nothing is returned.
        case stale
    }

    private enum Run: Sendable {
        case reply(String)
        case failed(String)
    }

    // MARK: Evaluation

    /// Runs `source` and returns what it produced, bounded and with sensitive values hidden. `authorized` is asked before the
    /// script starts, in the same turn that starts it, and after every suspension; once it says no, nothing is returned.
    static func evaluate(
        _ source: String, world: World, timeout: Int, in view: BrowserPage,
        authorized: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        guard PageAutomationGuard.allowsExecution, PageDriver.selectedFrame == nil, authorized() else { return .stale }
        // Before the script: what the page holds now. A script may clear a field or leave the document after reading it.
        guard let armed = await trusted(armScript, in: view), let object = json(armed), let document = object["document"] as? String else {
            return authorized() && !Task.isCancelled ? .failed("The page did not answer, so the script was not run") : .stale
        }
        guard authorized(), let wrapper = wrapper(address: PageAutomationGuard.current?.documentURL ?? "", timeout: timeout) else {
            return .stale
        }
        let ceiling = Duration.milliseconds(timeout) + grace
        let run = await run(wrapper, source: source, in: world.contentWorld, ceiling: ceiling, on: view, authorized: authorized)
        // No answer means the time is up or the request was cancelled (Stop): either way the script is stopped where it can be.
        let interrupted = run == nil ? await interrupt(view) : false
        guard authorized(), !Task.isCancelled else { return .stale }
        guard let run else { return .timedOut(interrupted: interrupted) }
        let reply: String
        switch run {
        case .failed(let message):
            // What the engine says about a failure can carry page text (a page that replaced `setTimeout` with a function that
            // throws a field's value, say), so it is a reply like any other and is checked like one.
            reply = failureReply(message)
        case .reply(let text):
            reply = text
            guard reply.utf8.count <= maximumReplyBytes, let answer = json(reply) else {
                return .failed("The script returned more than the \(maximumReplyBytes / 1_024) KiB WSurf accepts for one call.")
            }
            if answer["stale"] as? Bool == true { return .stale }
            if answer["timedOut"] as? Bool == true { return .timedOut(interrupted: false) }
        }
        // After the script: the page's own world checks the reply against the sensitive values, the ones armed before and the
        // ones there are now. A reply that cannot be checked is not returned.
        let checked = await PageAutomationGuard.rescoped(in: view) { () -> String? in
            guard let script = redactScript(reply: reply, document: document) else { return nil }
            return await trusted(script, in: view)
        }
        guard authorized(), !Task.isCancelled else { return .stale }
        guard let checked, checked.utf8.count <= maximumReplyBytes, let verdict = json(checked), verdict["stale"] == nil else { return .stale }
        return .completed(checked)
    }

    /// Stops a script that never yields, where the engine can. WebKit has no public way to interrupt running script, so its page
    /// stays busy until the script ends or the tab is reloaded or closed.
    private static func interrupt(_ view: BrowserPage) async -> Bool {
        guard let chromium = view.chromium else { return false }
        // A new task, so a cancelled request still stops the script.
        return await Task { @MainActor in (try? await chromium.command("Runtime.terminateExecution")) != nil }.value
    }

    /// `message` as the reply of a script that could not run, in the shape a script's own error has.
    private static func failureReply(_ message: String) -> String {
        let error: [String: Any] = ["name": "ScriptNotRun", "message": message, "stack": ""]
        let reply: [String: Any] = ["ok": false, "error": error]
        return (try? JSONSerialization.data(withJSONObject: reply)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func run(
        _ body: String, source: String, in world: WKContentWorld, ceiling: Duration, on view: BrowserPage,
        authorized: @escaping @MainActor @Sendable () -> Bool
    ) async -> Run? {
        await PageReply<Run>.awaiting(within: ceiling) { gate in
            Task { @MainActor in
                do {
                    // The script travels as an argument, never inside the body, so nothing in it can change the body's structure.
                    let value = try await view.callAsyncJavaScript(
                        body, in: nil, contentWorld: world, prepareArguments: { ["source": source] },
                        dispatchCheck: {
                            if !authorized() {
                                throw ChromiumError.staleFrame
                            }
                        })
                    gate.finish(.reply(value as? String ?? ""))
                } catch {
                    gate.finish(.failed(describe(error)))
                }
            }
        }
    }

    /// What the engine says about a script it could not run. WebKit puts the page's message in the error's user info.
    private static func describe(_ error: Error) -> String {
        let native = error as NSError
        let detail = native.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
        let line = (native.userInfo["WKJavaScriptExceptionLineNumber"] as? Int).map { " (line \($0))" } ?? ""
        let text = detail + line
        return text.count > 500 ? String(text.prefix(500)) + "…" : text
    }

    /// Runs `script` in WSurf's own world and returns its text.
    private static func trusted(_ script: String, in view: BrowserPage) async -> String? {
        guard PageAutomationGuard.allowsExecution, await PageDriver.selectedFrameIsLive(in: view),
            let raw = (try? await view.evaluateJavaScript(script, in: nil, contentWorld: PageAutomationGuard.world)) as? String,
            PageAutomationGuard.allowsExecution
        else { return nil }
        return raw
    }

    private static func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    // MARK: DOM edits and full inspection

    /// Applies one edit in WSurf's own world, so a page that replaced `setAttribute` or `remove` cannot change what happens.
    /// Nil when the page does not answer.
    static func edit(_ request: [String: Any], in view: BrowserPage) async -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: request), let literal = String(data: data, encoding: .utf8) else { return nil }
        return await PageDriver.evaluateJSON(PageDriver.scripted(helpers + "return JSON.stringify(edit(\(literal)));"), in: view)
    }

    /// `inspectElement` with everything: all attributes, computed properties and an outerHTML excerpt, checked like a script
    /// result. `properties` names the computed properties wanted; empty means all.
    static func inspectFully(ref: Int, properties: [String], in view: BrowserPage) async -> [String: Any]? {
        guard let data = try? JSONSerialization.data(withJSONObject: properties), let wanted = String(data: data, encoding: .utf8) else { return nil }
        return await PageDriver.evaluateJSON(PageDriver.scripted(helpers + "return fullInspection(\(ref), \(wanted));"), in: view)
    }

    // MARK: Page-side scripts

    private static var armScript: String {
        PageDriver.scripted(
            helpers + #"""
                window.__wsurfRedact = Array.from(sensitive());
                return JSON.stringify({ document: R.documentID, armed: window.__wsurfRedact.length });
                """#)
    }

    private static func redactScript(reply: String, document: String) -> String? {
        guard let text = PageDriver.jsonString(reply), let id = PageDriver.jsonString(document) else { return nil }
        return PageDriver.scripted(
            helpers + #"""
                if (R.documentID !== \#(id)) return JSON.stringify({ stale: true });
                const armed = window.__wsurfRedact || [];
                window.__wsurfRedact = [];
                return redactJSON(\#(text), armed);
                """#)
    }

    /// The function body that runs in the page; the script itself comes in as the argument `source`. The harness compiles it as
    /// the body of its own function, `return ( source )`, so it can only be one expression: text that tries to close the
    /// parenthesis and carry on ends in a `return` and never runs, and the function has the page's global scope only, so it
    /// reaches none of the harness. A function the expression yields is called, a promise is awaited, anything else is the value.
    /// Its own error, or running past `timeout`, ends the wait with an answer, so a script that fails or never settles still gets
    /// a reply. Anything the page's timers cannot interrupt (a loop that never yields) is stopped by the ceiling in `evaluate`.
    /// A page whose Content-Security-Policy forbids eval cannot compile it in the page world (`EvalError`); the isolated world
    /// is not bound by it.
    nonisolated static func wrapper(address: String, timeout: Int) -> String? {
        guard let address = try? String(data: JSONEncoder().encode(address), encoding: .utf8) else { return nil }
        return #"""
            if (location.href !== \#(address)) return JSON.stringify({ stale: true });
            const later = globalThis.setTimeout, cancel = globalThis.clearTimeout, encoder = new TextEncoder();
            const keep = (text, limit) => text.length > limit ? text.slice(0, limit) + '…' : text;
            // Addresses in a message or a stack lose their query and fragment.
            const tidy = text => String(text).replace(/(\bhttps?:\/\/[^\s)'"?#]+)[?#][^\s)'"]*/g, '$1');
            const failure = error => {
              let name = 'Error', message = '', stack = '';
              try {
                if (error && typeof error === 'object') {
                  name = String(error.name || 'Error'); message = String(error.message ?? ''); stack = String(error.stack || '');
                } else { name = 'Thrown'; message = String(error); }
              } catch (e) { message = '[unreadable]'; }
              return { name: keep(name, 80), message: keep(tidy(message), 1000), stack: keep(tidy(stack).split('\n').slice(0, 12).join('\n'), 2000) };
            };
            const nodeLabel = node => {
              if (node.nodeType !== 1) return '[' + (node.nodeName || 'Node') + ']';
              let text = '<' + node.localName;
              if (node.id) text += '#' + node.id;
              if (typeof node.className === 'string' && node.className.trim()) text += '.' + node.className.trim().split(/\s+/).slice(0, 4).join('.');
              return keep(text + '>', 120);
            };
            // One pass of the bounds: depth, items per level, text per string and nodes in all. A circular reference is marked.
            const snapshot = (root, p) => {
              let truncated = false, nodes = 0;
              const ancestors = new Set();
              const cut = text => { if (text.length <= p.text) return text; truncated = true; return text.slice(0, p.text) + '…'; };
              const expand = (value, depth) => {
                if (Array.isArray(value)) {
                  const out = [], count = Math.min(value.length, p.items);
                  for (let i = 0; i < count; i++) out.push(visit(value[i], depth + 1));
                  if (value.length > count) { truncated = true; out.push('[… ' + (value.length - count) + ' more]'); }
                  return out;
                }
                if (value instanceof Error) return failure(value);
                if (value instanceof Date) return Number.isNaN(value.getTime()) ? '[Invalid Date]' : value.toISOString();
                if (value instanceof RegExp) return cut(String(value));
                if (value instanceof Promise) return '[Promise]';
                if (ArrayBuffer.isView(value) || value instanceof ArrayBuffer) return '[' + (value.constructor ? value.constructor.name : 'Buffer') + ' ' + value.byteLength + ' bytes]';
                if (value instanceof Map) return { '[Map]': Array.from(value).slice(0, p.items).map(([k, v]) => [visit(k, depth + 1), visit(v, depth + 1)]), size: value.size };
                if (value instanceof Set) return { '[Set]': Array.from(value).slice(0, p.items).map(v => visit(v, depth + 1)), size: value.size };
                if ((typeof NodeList === 'function' && value instanceof NodeList) || (typeof HTMLCollection === 'function' && value instanceof HTMLCollection)) {
                  return expand(Array.from(value), depth);
                }
                if (typeof value.toJSON === 'function') {
                  const json = value.toJSON();
                  if (json !== value) return visit(json, depth);
                }
                const keys = Object.keys(value), out = {}, count = Math.min(keys.length, p.items);
                for (let i = 0; i < count; i++) {
                  let item;
                  try { item = visit(value[keys[i]], depth + 1); } catch (e) { item = '[Getter threw]'; }
                  out[cut(keys[i])] = item;
                }
                if (keys.length > count) { truncated = true; out['[…]'] = (keys.length - count) + ' more'; }
                return out;
              };
              const visit = (value, depth) => {
                try {
                  switch (typeof value) {
                    case 'string': return cut(value);
                    case 'number': return Number.isFinite(value) ? value : '[' + value + ']';
                    case 'boolean': return value;
                    case 'undefined': return '[undefined]';
                    case 'bigint': return '[BigInt ' + value + ']';
                    case 'symbol': return '[' + String(value) + ']';
                    case 'function': return '[Function ' + (value.name || 'anonymous') + ']';
                  }
                  if (value === null) return null;
                  if (value === globalThis) return '[Window]';
                  if (typeof Node === 'function' && value instanceof Node) return nodeLabel(value);
                  if (ancestors.has(value)) return '[Circular]';
                  if (++nodes > p.nodes) { truncated = true; return '[…]'; }
                  if (depth >= p.depth) { truncated = true; return Array.isArray(value) ? '[Array(' + value.length + ')]' : '[Object]'; }
                  ancestors.add(value);
                  try { return expand(value, depth); } finally { ancestors.delete(value); }
                } catch (e) { return '[Unreadable]'; }
              };
              return { tree: visit(root, 0), truncated };
            };
            const profiles = [{ depth: 6, items: 100, text: 4096, nodes: 2000 }, { depth: 4, items: 40, text: 1024, nodes: 600 }, { depth: 3, items: 16, text: 256, nodes: 200 }];
            const describe = value => {
              if (value === undefined) return { type: 'undefined', value: null, truncated: false };
              const type = value === null ? 'null' : Array.isArray(value) ? 'array'
                : (typeof Node === 'function' && value instanceof Node) ? 'node' : typeof value;
              for (const p of profiles) {
                const { tree, truncated } = snapshot(value, p);
                if (encoder.encode(JSON.stringify(tree)).length <= \#(maximumValueBytes)) return { type, value: tree, truncated };
              }
              return { type, value: keep(JSON.stringify(snapshot(value, profiles[2]).tree), 4000), truncated: true };
            };
            const outcome = await new Promise(resolve => {
              const timer = later(() => resolve({ timedOut: true }), \#(timeout));
              const finish = result => { cancel(timer); resolve(result); };
              (async () => {
                let make;
                try {
                  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
                  make = new AsyncFunction('return (\n' + source + '\n)');
                } catch (error) {
                  finish({ ok: false, error: { ...failure(error), compile: true } });
                  return;
                }
                try {
                  const candidate = await make();
                  const value = typeof candidate === 'function' ? await candidate() : candidate;
                  finish({ ok: true, ...describe(value) });
                } catch (error) {
                  finish({ ok: false, error: failure(error) });
                }
              })();
            });
            return JSON.stringify(outcome);
            """#
    }

    /// Helpers for WSurf's own world, spliced after the runtime so they can use it (`R`). `sensitive` reads the values sensitive
    /// fields hold; `redactJSON` hides them in a JSON text; `edit` and `fullInspection` serve `editDOM` and `inspectElement`.
    static let helpers = #"""
        const HIDDEN = '‹hidden›';
        const isHolder = el => /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName);
        // The values sensitive fields hold now (the live value, the value attribute and the default), and the cookie values the
        // page can read that look like a session id or a token. Shorter cookie values are settings and flags, and stay.
        const sensitive = () => {
          const found = new Set();
          try {
            for (const part of document.cookie.split(';')) {
              const value = part.slice(part.indexOf('=') + 1).trim();
              let decoded = value;
              try { decoded = decodeURIComponent(value); } catch (e) {}
              for (const form of [value, decoded]) if (part.includes('=') && form.length >= 16) found.add(form);
            }
          } catch (e) {}
          const root = document.body || document.documentElement;
          if (!root) return found;
          for (const el of R.walk(root)) {
            const editable = el.isContentEditable === true && !isHolder(el);
            if (!isHolder(el) && !editable) continue;
            if (!R.isSensitiveField(el)) continue;
            for (const value of [isHolder(el) ? el.value : el.textContent, el.getAttribute('value'), el.defaultValue]) {
              if (typeof value === 'string' && value !== '') found.add(value);
            }
          }
          return found;
        };
        // A value as a script or a page writes it out.
        const forms = value => {
          const out = new Set([value, value.replace(/\s+/g, ' ').trim()]);
          try {
            const percent = encodeURIComponent(value);
            out.add(percent); out.add(percent.replace(/%20/g, '+'));
          } catch (e) {}
          const json = JSON.stringify(value).slice(1, -1);
          out.add(json); out.add(json.replace(/\//g, '\\/'));
          const html = value.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
          out.add(html); out.add(html.replace(/"/g, '&quot;').replace(/'/g, '&#39;'));
          return Array.from(out).filter(form => form.length >= 4);
        };
        const redactor = extra => {
          const values = new Set(extra);
          for (const value of sensitive()) values.add(value);
          const list = Array.from(values).sort((a, b) => b.length - a.length).slice(0, 64);
          const whole = new Set(list.map(value => value.toLowerCase()));
          const parts = [];
          for (const value of list) if (value.length >= 4) parts.push(...forms(value));
          parts.sort((a, b) => b.length - a.length);
          const needles = parts.map(part => part.toLowerCase());
          let hidden = 0;
          const mask = text => {
            if (!needles.length || text.length < 4) return text;
            const lower = text.toLowerCase();
            // Case folding changes the length of a few characters; then the text is matched as it is.
            const same = lower.length === text.length, haystack = same ? lower : text;
            const covered = new Uint8Array(text.length);
            let any = false;
            for (const found of parts) {
              const needle = same ? found.toLowerCase() : found;
              for (let at = haystack.indexOf(needle); at !== -1; at = haystack.indexOf(needle, at + 1)) {
                covered.fill(1, at, at + needle.length); any = true;
              }
            }
            if (!any) return text;
            let out = '', inside = false;
            for (let i = 0; i < text.length; i++) {
              if (covered[i]) { if (!inside) { out += HIDDEN; hidden++; } inside = true; } else { out += text[i]; inside = false; }
            }
            return out;
          };
          const clean = text => {
            const folded = text.toLowerCase();
            if (whole.has(folded) || whole.has(folded.trim())) { hidden++; return HIDDEN; }
            return mask(text);
          };
          return { clean, count: () => hidden };
        };
        // `text` is JSON: every string and key is checked, and the number of places hidden is added as `redacted`.
        const redactJSON = (text, extra) => {
          const r = redactor(extra);
          // Two keys that are hidden to the same text keep both, the later one numbered.
          const entries = value => {
            const out = {};
            for (const [key, item] of Object.entries(value)) {
              let name = r.clean(key), n = 1;
              while (Object.prototype.hasOwnProperty.call(out, name)) name = r.clean(key) + ' (' + (++n) + ')';
              out[name] = visit(item);
            }
            return out;
          };
          const visit = value => Array.isArray(value) ? value.map(visit)
            : value && typeof value === 'object' ? entries(value)
            : typeof value === 'string' ? r.clean(value) : value;
          const result = visit(JSON.parse(text));
          if (result && typeof result === 'object' && !Array.isArray(result)) result.redacted = r.count();
          return JSON.stringify(result);
        };

        const cut = (text, limit) => text.length > limit ? text.slice(0, limit) + '…' : text;
        const summary = el => {
          let text = el.localName;
          if (el.id) text += '#' + el.id;
          if (typeof el.className === 'string' && el.className.trim()) text += '.' + el.className.trim().split(/\s+/).slice(0, 3).join('.');
          return cut(text, 120);
        };
        // WSurf's own page elements and marks. An element is WSurf's when it, or an ancestor, carries a reserved id or class, or
        // when it carries a reserved attribute itself (the marks autofill puts on a field, the extension relay's flag).
        const RESERVED = /^(__wsurf|wsurf-)/i;
        const isOwn = el => {
          for (let node = el; node && node.nodeType === 1; node = node.parentElement) {
            if (node.id && RESERVED.test(node.id)) return true;
            for (const name of node.classList) if (RESERVED.test(name)) return true;
          }
          return Array.from(el.attributes).some(attribute => /^data-wsurf/i.test(attribute.name));
        };
        function* topLevel(root) {
          for (const el of root.querySelectorAll('*')) {
            yield el;
            if (el.shadowRoot) yield* topLevel(el.shadowRoot);
          }
        }
        const SELECTOR_REFUSALS = {
          invalid: 'Invalid selector.',
          secret: 'That selector reads the value attribute, which can reveal what a password or payment field holds. Select by another attribute.',
        };
        const SCRIPTABLE = new Set(['href', 'src', 'action', 'formaction', 'xlink:href', 'data', 'poster', 'background', 'srcset']);
        // Where a form posts and how: changing it on a form that takes a password would send the password somewhere else.
        const ROUTING = new Set(['action', 'formaction', 'method', 'target', 'enctype', 'formmethod', 'formtarget', 'formenctype', 'form']);
        // What an element that loads or runs code may not be pointed at.
        const LOADING = new Set([...SCRIPTABLE, 'content', 'http-equiv', 'rel']);
        // Why this attribute may not be set, or null. Event handlers and script URLs run code, and a script is `evaluateScript`'s
        // to run, with its time limit and its audit entry.
        const attributeProblem = (name, value) => {
          if (!/^[A-Za-z_][-A-Za-z0-9_:.]{0,63}$/.test(name)) return 'That is not a valid attribute name.';
          const lower = name.toLowerCase();
          if (lower.startsWith('on')) return 'Event handler attributes run script. Use evaluateScript.';
          if (lower.startsWith('data-wsurf') || lower.startsWith('__wsurf')) return "WSurf's own attributes cannot be changed.";
          if (lower === 'srcdoc') return 'srcdoc runs a document. Use evaluateScript.';
          if (value != null && SCRIPTABLE.has(lower) && /^[\s\u0000-\u001f]*(javascript|vbscript|data:text\/html)/i.test(String(value).replace(/[\t\n\r]/g, ''))) {
            return 'A script URL runs code. Use evaluateScript.';
          }
          return null;
        };
        const STYLE_NAME = /^(--[A-Za-z0-9_-]+|-?[A-Za-z][-A-Za-z0-9]*)$/;
        const FORBIDDEN_TAGS = new Set(['script', 'iframe', 'frame', 'frameset', 'object', 'embed', 'applet', 'base', 'link', 'meta', 'portal']);
        const POSITIONS = new Set(['beforebegin', 'afterbegin', 'beforeend', 'afterend']);

        const target = request => {
          if (request.ref) {
            if (!R.inspectableRef(request.ref)) return { error: 'That element is gone or changed. Use findElements or readPage again.', kind: 'stale' };
            return { el: window.__wsurfRefs[request.ref - 1] };
          }
          // Any attribute may be tested except `value` (see selectorProblem); the refusal is the same whether or not it would match.
          const problem = R.selectorProblem(request.selector, true);
          if (problem === 'secret') return { error: SELECTOR_REFUSALS.secret, kind: 'denied' };
          if (problem) return { error: SELECTOR_REFUSALS.invalid, kind: 'invalid' };
          const matches = [];
          for (const el of topLevel(document)) {
            if (el.matches(request.selector) && matches.push(el) > 1) break;
          }
          if (!matches.length) return { error: 'No element matches that selector.', kind: 'invalid' };
          if (matches.length > 1) return { error: 'The selector matches more than one element. Make it match exactly one.', kind: 'invalid' };
          return { el: matches[0] };
        };

        // Whether `el` is, or holds, a password, code or payment field (in its subtree, shadow roots and same-origin frames).
        const holdsSensitive = el => {
          if (isHolder(el) && R.isSensitiveField(el)) return true;
          for (const node of R.walk(el)) if (isHolder(node) && R.isSensitiveField(node)) return true;
          return false;
        };
        // Whether `form` takes a sensitive field, counting the controls that join it by their `form` attribute. The list comes from
        // the prototype, because a control named `elements` would stand in for it on the form itself.
        const formControls = Object.getOwnPropertyDescriptor(HTMLFormElement.prototype, 'elements').get;
        const takesSensitive = form => form instanceof HTMLFormElement && Array.from(formControls.call(form)).some(control => isHolder(control) && R.isSensitiveField(control));
        // The form an element submits, or belongs to: itself when it is one, else its form owner.
        const formOf = el => el.localName === 'form' ? el : (el.form || null);
        // Where a form posts is not changed on one that takes a sensitive field, nor are its buttons pointed elsewhere, nor a button
        // joined to it. `value` is what the attribute is being set to; null for a removal.
        const routingProblem = (el, name, value) => {
          const lower = name.toLowerCase();
          if (!ROUTING.has(lower)) return null;
          if (takesSensitive(formOf(el))) return 'This form takes a password, code or payment field, so where it posts cannot be changed.';
          if (lower === 'form' && value != null && takesSensitive(document.getElementById(String(value)))) {
            return 'That form takes a password, code or payment field, so nothing can be attached to it.';
          }
          return null;
        };

        const edit = request => {
          const found = target(request);
          if (found.error) return found;
          const el = found.el;
          if (!el.isConnected) return { error: 'That element is no longer in the page.', kind: 'stale' };
          if (el.ownerDocument !== document) return { error: 'That element is inside a frame. Only the page itself can be edited.', kind: 'denied' };
          if (isOwn(el)) return { error: "That element belongs to WSurf's own page tools and cannot be edited.", kind: 'denied' };
          if (R.isSensitiveField(el)) return { error: 'A password, code or payment field cannot be edited by an app. The user fills it.', kind: 'denied' };
          const tag = el.localName;
          const refuse = (error, kind = 'invalid') => ({ error, kind });
          // An element that holds such a field keeps its content: its text, its children and what is inserted in it stay as they are.
          if (['setText', 'remove', 'insert'].includes(request.op) && holdsSensitive(el)) {
            return refuse('This element holds a password, code or payment field, so its content cannot be changed by an app.', 'denied');
          }
          // The attributes of an element that loads code do not change where it loads from.
          const loadingProblem = name => FORBIDDEN_TAGS.has(tag) && LOADING.has(name.toLowerCase())
            ? 'A ' + tag + ' element loads code or a document, so its address and settings are not changed. Use evaluateScript.' : null;
          switch (request.op) {
            case 'setAttribute': {
              const problem = attributeProblem(request.name, request.value) || loadingProblem(request.name) || routingProblem(el, request.name, request.value);
              if (problem) return refuse(problem, 'denied');
              el.setAttribute(request.name, request.value);
              return { ok: true, target: summary(el) };
            }
            case 'removeAttribute': {
              const problem = attributeProblem(request.name, null) || loadingProblem(request.name) || routingProblem(el, request.name, null);
              if (problem) return refuse(problem, 'denied');
              const had = el.hasAttribute(request.name);
              el.removeAttribute(request.name);
              return { ok: true, target: summary(el), changed: had };
            }
            case 'setText': {
              if (['input', 'textarea', 'select', 'script', 'iframe'].includes(tag)) return refuse('The text of this element is not set this way.', 'denied');
              el.textContent = request.value;
              return { ok: true, target: summary(el) };
            }
            case 'setStyle': {
              if (!STYLE_NAME.test(request.name) || request.name.length > 64) return refuse('That is not a valid CSS property name.');
              if (!el.style) return refuse('This element has no inline style.');
              // An empty value removes the property; anything else must be a value the browser accepts for it.
              if (request.value !== '' && !CSS.supports(request.name, request.value)) {
                return refuse('The browser does not accept that value for ' + request.name + '.');
              }
              el.style.setProperty(request.name, request.value, request.important ? 'important' : '');
              return { ok: true, target: summary(el), value: cut(el.style.getPropertyValue(request.name), 200) };
            }
            case 'remove': {
              if (['html', 'head', 'body'].includes(tag)) return refuse('The page cannot work without ' + tag + '.', 'denied');
              el.remove();
              return { ok: true, target: summary(el) };
            }
            case 'insert': {
              const name = String(request.tag || '').toLowerCase();
              if (!/^[a-z][a-z0-9-]{0,31}$/.test(name)) return refuse('That is not a valid tag name.');
              if (FORBIDDEN_TAGS.has(name)) return refuse('A ' + name + ' element can run or load code. Use evaluateScript.', 'denied');
              const position = request.position || 'beforeend';
              if (!POSITIONS.has(position)) return refuse('position must be beforebegin, afterbegin, beforeend or afterend.');
              if ((position === 'beforebegin' || position === 'afterend') && (el === document.documentElement || !el.parentElement)) {
                return refuse('Nothing can be inserted before or after this element.');
              }
              const node = document.createElement(name);
              if (request.value) node.textContent = request.value;
              el.insertAdjacentElement(position, node);
              return { ok: true, target: summary(el), inserted: summary(node) };
            }
          }
          return refuse('Unknown operation.');
        };

        // Everything about one element: all attributes, computed properties, an outerHTML excerpt. The reply is checked like a
        // script result, and field values are blanked in the markup.
        const fullInspection = (ref, wanted) => {
          if (!R.inspectableRef(ref)) return JSON.stringify({ stale: true });
          const el = window.__wsurfRefs[ref - 1];
          if (isOwn(el)) return JSON.stringify({ denied: true });
          const base = R.inspect(ref);
          if (base.stale) return JSON.stringify({ stale: true });
          const view = el.ownerDocument.defaultView || window;
          const holder = R.isSensitiveField(el);
          const attributes = {};
          const total = el.attributes.length;
          for (let i = 0; i < Math.min(total, 128); i++) {
            const attribute = el.attributes[i];
            if (/^data-wsurf/i.test(attribute.name)) continue;
            attributes[cut(attribute.name, 64)] = holder && attribute.name.toLowerCase() === 'value' ? HIDDEN : cut(attribute.value, 512);
          }
          const style = view.getComputedStyle(el);
          const names = wanted.length ? wanted : Array.from({ length: style.length }, (_, i) => style[i]);
          const computed = {};
          let used = 2, computedTruncated = false;
          for (const name of names) {
            const value = cut(style.getPropertyValue(name), 200);
            if (!wanted.length && value === '') continue;
            const cost = name.length + value.length + 6;
            if (used + cost > 8192) { computedTruncated = true; break; }
            computed[name] = value;
            used += cost;
          }
          const clone = el.cloneNode(true);
          for (const node of [clone, ...clone.querySelectorAll('*')]) {
            for (const attribute of Array.from(node.attributes)) if (/^data-wsurf/i.test(attribute.name)) node.removeAttribute(attribute.name);
            if (node.localName === 'input' || node.localName === 'textarea') node.removeAttribute('value');
            if (node.localName === 'textarea') node.textContent = '';
          }
          if (holder && !isHolder(el)) clone.textContent = '';
          let html = clone.outerHTML, htmlTruncated = false;
          const encoder = new TextEncoder();
          while (encoder.encode(html).length > 8192) { html = html.slice(0, Math.floor(html.length * 0.9)); htmlTruncated = true; }
          base.full = { attributes, attributesTotal: total, attributesTruncated: total > 128, computed, computedTruncated, outerHTML: html, outerHTMLTruncated: htmlTruncated };
          return redactJSON(JSON.stringify(base), []);
        };
        """#
}
