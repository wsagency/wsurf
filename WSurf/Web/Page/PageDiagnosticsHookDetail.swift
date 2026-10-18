// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated extension PageDiagnosticsHook {
    /// The page-side half of the Developer tier's opt-in detail. It shares the hook's scope (`apply`, `clip`, `own`, `getter`,
    /// `read`, `known`, `net`) and is inert unless `DET` enables it, so a capture started without the options records exactly what
    /// it did before.
    ///
    /// It reads a request only when the destination host is one of `DET.hosts`, and a response only when the final address of a
    /// redirected request is too. What it reads is bounded in the page (a body is cut at 40,960 characters, a header list at 64
    /// pairs) and checked again natively, where the headers are redacted and the bodies hide their credentials.
    ///
    /// It does not run page code to read a value. Header lists, bodies and request fields are read through getters and methods
    /// the hook captured at install, which throw on a foreign object, or as the own data properties of a plain `RequestInit`
    /// object; an accessor is never called. The ceiling is a Proxy, whose traps run when its keys are read, and a console
    /// object, whose own data properties are read to depth 3 (an accessor is shown as `[getter]`, not called).
    ///
    /// A response body is read from `response.clone()` through its stream, for at most 3 seconds and 40,960 characters, then the
    /// clone is cancelled; the page's own copy is never touched. The record is sent after that wait, with the duration measured
    /// when the response arrived. WebKit gives a page no view of what it did not make itself: browser-added request headers
    /// (cookies, user agent), the headers of resource loads and navigations, and WebSocket frames are not visible here.
    static let hookDetail = #"""
          const objectProto = Object.prototype, ErrorCtor = Error, enc = encodeURIComponent, okey = Object.keys, isArr = Array.isArray;
          const indexOf = String.prototype.indexOf, lower = String.prototype.toLowerCase, joinArr = Array.prototype.join, sliceStr = String.prototype.slice;
          const trimStr = String.prototype.trim, charAt = String.prototype.charAt;
          const TextDecoderCtor = globalThis.TextDecoder, decodeChunk = TextDecoderCtor && TextDecoderCtor.prototype.decode;
          const setTimer = globalThis.setTimeout, clearTimer = globalThis.clearTimeout;
          const headersEach = globalThis.Headers && Headers.prototype.forEach;
          const paramsText = globalThis.URLSearchParams && URLSearchParams.prototype.toString;
          const formEach = globalThis.FormData && FormData.prototype.forEach;
          const blobSize = getter(globalThis.Blob, 'size'), blobType = getter(globalThis.Blob, 'type'), fileName = getter(globalThis.File, 'name');
          const bufferLength = getter(globalThis.ArrayBuffer, 'byteLength');
          const viewLength = getter(Object.getPrototypeOf(Uint8Array), 'byteLength');
          const requestUrl = getter(globalThis.Request, 'url'), requestMethod = getter(globalThis.Request, 'method');
          const requestHeaders = getter(globalThis.Request, 'headers');
          const responseUrl = getter(globalThis.Response, 'url'), responseRedirected = getter(globalThis.Response, 'redirected');
          const responseStream = getter(globalThis.Response, 'body');
          const cloneResponse = globalThis.Response && Response.prototype.clone;
          const streamReader = globalThis.ReadableStream && ReadableStream.prototype.getReader;
          const readerRead = globalThis.ReadableStreamDefaultReader && ReadableStreamDefaultReader.prototype.read;
          const readerCancel = globalThis.ReadableStreamDefaultReader && ReadableStreamDefaultReader.prototype.cancel;
          const xhrResponseText = getter(globalThis.XMLHttpRequest, 'responseText'), xhrResponse = getter(globalThis.XMLHttpRequest, 'response');
          const xhrType = getter(globalThis.XMLHttpRequest, 'responseType'), xhrUrl = getter(globalThis.XMLHttpRequest, 'responseURL');
          const xhrAllHeaders = XMLHttpRequest.prototype.getAllResponseHeaders;
          const BODY_LIMIT = 40960, READ_MS = 3000;

          // An address the Developer tier covers: a host that counts on any port, or a listed site on its port. Native code decides
          // again; this keeps requests to anywhere else from being read at all.
          const covered = href => {
            if (typeof href !== 'string') return false;
            try {
              const u = new URLCtor(href);
              if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
              const raw = u.hostname, h = apply(charAt, raw, [0]) === '[' ? apply(sliceStr, raw, [1, -1]) : raw;
              for (let i = 0; i < DET.hosts.length; i++) if (DET.hosts[i] === h) return true;
              const port = u.port === '' ? (u.protocol === 'https:' ? 443 : 80) : +u.port;
              for (let i = 0; i < DET.sites.length; i++) {
                const site = DET.sites[i];
                if (site.h === h && (site.p === null ? (u.protocol === 'https:' ? 443 : 80) : site.p) === port) return true;
              }
            } catch (e) {}
            return false;
          };
          const isText = m => {
            if (typeof m !== 'string') return false;
            const t = apply(lower, m, []);
            return apply(indexOf, t, ['text/']) === 0 || apply(indexOf, t, ['json']) >= 0 || apply(indexOf, t, ['xml']) >= 0
              || apply(indexOf, t, ['x-www-form-urlencoded']) >= 0 || apply(indexOf, t, ['graphql']) >= 0;
          };

          // [[name, value], ...] from a Headers object, a plain object's own data properties or an array of pairs (at most 64).
          const pairsOf = h => {
            const out = [];
            const add = (n, v) => {
              if (out.length < 64 && typeof n === 'string' && typeof v === 'string') apply(push, out, [[clip(n, 100), clip(v, 1024)]]);
            };
            try {
              if (h === null || typeof h !== 'object') return out;
              if (headersEach) {
                let branded = true;
                try { apply(headersEach, h, [(v, n) => { add(n, v); }]); } catch (e) { branded = false; }
                if (branded) return out;
              }
              if (isArr(h)) {
                const count = own(h, 'length') | 0;
                for (let i = 0; i < count && i < 64; i++) {
                  const p = own(h, i);
                  if (isArr(p)) add(own(p, 0), own(p, 1));
                }
              } else {
                const keys = okey(h);
                for (let i = 0; i < keys.length && i < 64; i++) add(keys[i], own(h, keys[i]));
              }
            } catch (e) {}
            return out;
          };
          const contentTypeOf = pairs => {
            for (let i = 0; i < pairs.length; i++) if (apply(lower, pairs[i][0], []) === 'content-type') return pairs[i][1];
            return null;
          };
          const parseHeaderBlock = block => {
            const out = [];
            if (typeof block !== 'string') return out;
            const text = clip(block, 16384);
            let from = 0;
            while (from < text.length && out.length < 64) {
              let end = apply(indexOf, text, ['\n', from]);
              if (end < 0) end = text.length;
              const line = apply(sliceStr, text, [from, end]);
              from = end + 1;
              const colon = apply(indexOf, line, [':']);
              if (colon > 0) apply(push, out, [[clip(apply(sliceStr, line, [0, colon]), 100), clip(apply(trimStr, apply(sliceStr, line, [colon + 1]), []), 1024)]]);
            }
            return out;
          };

          // A request body as { t } text, or a summary { bin, size, ct }; null when there is none.
          const bodyOf = (b, type) => {
            try {
              if (b === undefined || b === null) return null;
              if (typeof b === 'string') return { t: clip(b, BODY_LIMIT), size: b.length, ct: type || 'text/plain', more: b.length > BODY_LIMIT };
              if (typeof b === 'object') {
                if (paramsText) {
                  try {
                    const s = apply(paramsText, b, []);
                    return { t: clip(s, BODY_LIMIT), size: s.length, ct: 'application/x-www-form-urlencoded', more: s.length > BODY_LIMIT };
                  } catch (e) {}
                }
                if (formEach) {
                  try {
                    const parts = [];
                    apply(formEach, b, [(v, n) => {
                      if (parts.length >= 256) return;
                      const value = typeof v === 'string' ? v : '[file ' + clip('' + read(fileName, v), 100) + ', ' + read(blobSize, v) + ' bytes]';
                      apply(push, parts, [enc(n) + '=' + enc(value)]);
                    }]);
                    return { t: clip(apply(joinArr, parts, ['&']), BODY_LIMIT), ct: 'application/x-www-form-urlencoded' };
                  } catch (e) {}
                }
                const blob = read(blobSize, b);
                if (blob !== null) return { bin: true, size: blob, ct: read(blobType, b) || type || null };
                const buffer = read(bufferLength, b);
                if (buffer !== null) return { bin: true, size: buffer, ct: type || null };
                const view = read(viewLength, b);
                if (view !== null) return { bin: true, size: view, ct: type || null };
              }
              return { bin: true, size: null, ct: type || null };
            } catch (e) { return null; }
          };

          // The body of a clone of `response`, read through its stream for at most READ_MS and BODY_LIMIT characters.
          const readText = async response => {
            let reader = null, timer = null;
            try {
              const stream = read(responseStream, apply(cloneResponse, response, []));
              if (!stream) return { t: '', size: 0 };
              reader = apply(streamReader, stream, []);
              let stopped = false;
              timer = apply(setTimer, globalThis, [() => { stopped = true; try { apply(readerCancel, reader, []); } catch (e) {} }, READ_MS]);
              const decoder = new TextDecoderCtor('utf-8');
              let text = '', more = false;
              for (;;) {
                const step = await apply(readerRead, reader, []);
                if (step.done) { more = stopped; break; }
                text += apply(decodeChunk, decoder, [step.value, { stream: true }]);
                if (text.length > BODY_LIMIT) { more = true; break; }
              }
              try { apply(clearTimer, globalThis, [timer]); } catch (e) {}
              try { apply(readerCancel, reader, []); } catch (e) {}
              return { t: clip(text, BODY_LIMIT), size: more ? null : text.length, more };
            } catch (e) {
              try { if (timer !== null) apply(clearTimer, globalThis, [timer]); } catch (x) {}
              return { note: 'not captured: the body could not be read' };
            }
          };

          // What a fetch call asks for, read only when the destination is a covered host. Null otherwise.
          const fetchRequest = args => {
            const first = args[0];
            let target = null, method = null, headerSource = null, bodySource;
            if (typeof first === 'string') {
              target = known(first);
            } else {
              const address = read(requestUrl, first);
              if (typeof address === 'string') {
                target = known(address);
                method = read(requestMethod, first);
                headerSource = read(requestHeaders, first);
              }
            }
            if (!target || !target.href || !covered(target.href)) return null;
            const init = args[1];
            if (init === undefined || init === null) {
              if (method === null) method = 'GET';
            } else if (typeof init === 'object' && (gpo(init) === objectProto || gpo(init) === null)) {
              const m = own(init, 'method');
              if (typeof m === 'string' && m.length <= 16) method = m;
              const h = own(init, 'headers');
              if (h !== undefined) headerSource = h;
              bodySource = own(init, 'body');
            }
            const pairs = pairsOf(headerSource);
            let rb = null;
            if (DET.bodies) {
              rb = typeof first === 'string' || init !== undefined ? bodyOf(bodySource, contentTypeOf(pairs)) : { note: 'not captured: the body of a Request object is not read' };
            }
            return { method, target, rh: DET.headers ? pairs : null, rb };
          };
          const fetchDetail = (r, req, method, target, start) => {
            const ms = now() - start;
            const status = read(responseStatus, r), mime = mimeOfResponse(r);
            const final = read(responseUrl, r);
            if (read(responseRedirected, r) === true && !covered(final)) {
              net('fetch', method, target, start, status, 'completed', mime, { off: true }, ms);
              return;
            }
            const rd = { reqH: req.rh, reqB: req.rb, fin: typeof final === 'string' ? clip(final, 2048) : null };
            if (DET.headers) rd.resH = pairsOf(read(responseHeaders, r));
            if (DET.bodies && isText(mime)) {
              apply(thenOf, readText(r), [body => { body.ct = mime; rd.resB = body; net('fetch', method, target, start, status, 'completed', mime, rd, ms); }]);
              return;
            }
            if (DET.bodies) rd.resB = mime ? { bin: true, size: null, ct: mime } : { note: 'not captured: the response has no content type' };
            net('fetch', method, target, start, status, 'completed', mime, rd, ms);
          };
          const xhrBody = (x, mime) => {
            if (!isText(mime)) return mime ? { bin: true, size: null, ct: mime } : { note: 'not captured: the response has no content type' };
            const kind = read(xhrType, x);
            if (kind === '' || kind === 'text') {
              const t = read(xhrResponseText, x);
              return typeof t === 'string' ? { t: clip(t, BODY_LIMIT), size: t.length, ct: mime, more: t.length > BODY_LIMIT } : { note: 'not captured: the body could not be read' };
            }
            if (kind === 'json') {
              try { const j = stringify(read(xhrResponse, x)); return { t: clip(j, BODY_LIMIT), ct: mime, more: j.length > BODY_LIMIT }; } catch (e) {}
            }
            return { note: 'not captured: this response type is not text' };
          };
          const xhrDetail = (x, state, start, status) => {
            const ms = now() - start;
            const outcome = status ? 'completed' : state.aborted ? 'aborted' : 'failed';
            const mime = status ? mimeOfRequest(x) : null;
            const final = read(xhrUrl, x);
            if (status && typeof final === 'string' && final !== '' && !covered(final)) {
              net('xhr', state.method, state.target, start, status || null, outcome, mime, { off: true }, ms);
              return;
            }
            const rd = { reqH: DET.headers ? state.rh : null, reqB: state.rb || null, fin: typeof final === 'string' && final !== '' ? clip(final, 2048) : null };
            if (status && DET.headers) rd.resH = parseHeaderBlock(read(xhrAllHeaders, x));
            if (status && DET.bodies) rd.resB = xhrBody(x, mime);
            net('xhr', state.method, state.target, start, status || null, outcome, mime, rd, ms);
          };

          // A console argument as bounded data: own data properties only (an accessor is `[getter]`), depth 3, 20 entries.
          const pv = (v, depth, seen) => {
            switch (typeof v) {
              case 'string': return clip(v, 200);
              case 'number': return v === v && v !== Infinity && v !== -Infinity ? v : '' + v;
              case 'boolean': return v;
              case 'undefined': return '[undefined]';
              case 'bigint': return v + 'n';
              case 'function': return '[function]';
              case 'symbol': return '[symbol]';
            }
            if (v === null) return null;
            for (let i = 0; i < seen.length; i++) if (seen[i] === v) return '[circular]';
            if (depth >= 3) return isArr(v) ? '[array]' : '[object]';
            apply(push, seen, [v]);
            const describe = (object, key) => {
              const d = gopd(object, key);
              return d === undefined ? '[empty]' : 'value' in d ? pv(d.value, depth + 1, seen) : '[getter]';
            };
            let out;
            if (isArr(v)) {
              out = [];
              const count = own(v, 'length') | 0;
              for (let i = 0; i < count && i < 20; i++) apply(push, out, [describe(v, i)]);
              if (count > 20) apply(push, out, ['…' + (count - 20) + ' more']);
            } else {
              out = Object.create(null);
              const keys = okey(v);
              for (let i = 0; i < keys.length && i < 20; i++) out[keys[i]] = describe(v, keys[i]);
              if (keys.length > 20) out['…'] = keys.length - 20 + ' more';
            }
            seen.length = seen.length - 1;
            return out;
          };
          // Where this console call came from: the stack of a fresh Error without the two frames of the hook itself.
          const stackHere = () => {
            try {
              const s = own(new ErrorCtor(), 'stack');
              if (typeof s !== 'string') return '';
              const first = apply(indexOf, s, ['\n']);
              const second = first < 0 ? -1 : apply(indexOf, s, ['\n', first + 1]);
              return second < 0 ? '' : clip(apply(sliceStr, s, [second + 1]), 8192);
            } catch (e) { return ''; }
          };
        """#
}
