// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

nonisolated enum PageRuntime {
    static let script = #"""
      const R = (window.__wsurf = window.__wsurf || (() => {
      // A page can clobber `form.name` / `form.id` with a named control, so a non-string is empty text, never an exception.
      const norm = s => typeof s === 'string' ? s.replace(/\s+/g, ' ').trim() : '';
      const documentID = Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16)).join('-');
      const refIDs = new WeakMap();
      // Elements registered only by findAll. They may be inspected, but carry no action authority: matchesRef, resolve by
      // ref and resolve by label all ignore them until readPage's collect emits the same element as a control.
      const foundOnly = new WeakSet();
      const refSignatures = new Map();
      const expectedValues = new WeakMap();
      let lastControlQuery = null;
      window.__wsurfRefs = [];
      const parentOf = el => el.parentElement || el.getRootNode()?.host || el.ownerDocument?.defaultView?.frameElement;

      function* walk(root) {
        for (const el of root.querySelectorAll('*')) {
          yield el;
          if (el.shadowRoot) yield* walk(el.shadowRoot);
          if (el.tagName === 'IFRAME') {
            try {
              if (el.contentDocument && el.contentDocument.body) yield* walk(el.contentDocument.body);
            } catch (e) {}
          }
        }
      }

      const visible = el => {
        const frame = el.ownerDocument.defaultView?.frameElement;
        if (frame && !visible(frame)) return false;
        try { if (el.checkVisibility && !el.checkVisibility()) return false; } catch (e) {}
        const style = realm(el).getComputedStyle(el);
        return style.visibility !== 'hidden' && style.visibility !== 'collapse' && el.getClientRects().length > 0;
      };

      const inViewport = el => {
        const rect = el.getBoundingClientRect(), view = realm(el);
        return rect.bottom > 0 && rect.top < view.innerHeight && rect.right > 0 && rect.left < view.innerWidth
          && (!view.frameElement || inViewport(view.frameElement));
      };
      const disabled = el => {
        for (let node = el; node; node = parentOf(node)) {
          if (node.getAttribute('aria-disabled') === 'true') return true;
        }
        return !!el.disabled || el.matches(':disabled');
      };
      const accessibleName = el => {
        const ids = norm(el.getAttribute('aria-labelledby')).split(' ').filter(Boolean);
        const root = el.getRootNode();
        const named = ids.map(id => root.getElementById?.(id)?.textContent || '').join(' ');
        return norm(named) || norm(el.getAttribute('aria-label'));
      };

      const kindOf = el => {
        const tag = el.tagName;
        if (tag === 'SELECT') return 'select';
        if (tag === 'TEXTAREA') return 'field';
        if (tag === 'INPUT') {
          const t = (el.type || 'text').toLowerCase();
          if (t === 'hidden') return null;
          if (t === 'submit' || t === 'button' || t === 'image') return 'button';
          if (t === 'checkbox') return 'checkbox';
          if (t === 'radio') return 'radio';
          return 'field';
        }
        if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button';
        if (tag === 'A' && el.href) return 'link';
        const role = el.getAttribute && el.getAttribute('role');
        if (['checkbox', 'radio', 'switch'].includes(role)) return role === 'switch' ? 'checkbox' : role;
        if (['textbox', 'searchbox'].includes(role)) return 'field';
        if (role === 'combobox') return el.isContentEditable || tag === 'INPUT' ? 'field' : 'combobox';
        if (['button', 'tab', 'menuitem', 'menuitemcheckbox', 'menuitemradio', 'link', 'option'].includes(role)) return 'button';
        if (role === 'gridcell' && el.hasAttribute('tabindex')
          && !el.querySelector('button,a[href],input,select,textarea,[role=button]')) return 'button';
        if (el.hasAttribute && el.hasAttribute('onclick')) return 'button';
        if (el.isContentEditable && !(el.parentElement && el.parentElement.isContentEditable)) return 'field';
        if (role === 'region' || (el.scrollHeight > el.clientHeight + 1 && ['auto','scroll'].includes(realm(el).getComputedStyle(el).overflowY))) return 'scrollarea';
        return null;
      };

      const controlLabel = el => norm(
        accessibleName(el) || el.innerText || el.value || el.title || el.querySelector('img[alt]')?.alt || ''
      ).slice(0, 60);
      const fieldLabel = el => {
        const assoc = el.labels && el.labels.length ? el.labels[0].innerText : '';
        return norm(
          accessibleName(el) || assoc || el.placeholder || el.name || el.id || ''
        ).slice(0, 60);
      };
      const labelOf = (el, kind) => ['button', 'link', 'combobox', 'scrollarea'].includes(kind) ? controlLabel(el) : fieldLabel(el);

      const isSensitiveField = el => {
        if (el.hasAttribute('data-wsurf-payment-card') || el.hasAttribute('data-wsurf-contact') || el.hasAttribute('data-wsurf-password')) return true;
        const kind = ((el.type || '') + '').toLowerCase();
        if (kind === 'password') return true;
        const auto = norm(el.autocomplete).toLowerCase();
        const hint = (fieldLabel(el) + ' ' + auto + ' ' + norm(el.name) + ' ' + norm(el.id)).toLowerCase();
        if (/(?:^| )(?:current-password|new-password|one-time-code|cc-number|cc-exp|cc-exp-month|cc-exp-year|cc-csc|cc-name)(?: |$)/.test(auto)) return true;
        return /password|passcode|\bpin\b|cvv|cvc|cvn|card ?number|cardnumber|card verification|security code|iban|sort ?code|routing/.test(hint)
          || /account ?number|ssn|social security|national insurance|passport|tax ?id|one[- ]?time|\botp\b|2fa|verification code|seed phrase|recovery phrase|private key/.test(hint);
      };

      const signature = el => JSON.stringify([kindOf(el), labelOf(el, kindOf(el)), el.id, el.name,
        el.type, el.href, el.getAttribute('formaction'), el.form?.action, el.form?.method]);
      const inspectableRef = ref => {
        const el = window.__wsurfRefs[ref - 1];
        return !!el?.isConnected && signature(el) === refSignatures.get(ref);
      };
      const matchesRef = ref => inspectableRef(ref) && !foundOnly.has(window.__wsurfRefs[ref - 1]);
      const expectValue = (el, value) => expectedValues.set(el, { value, signature: signature(el) });
      const valueState = ref => {
        const el = window.__wsurfRefs[ref - 1];
        const expected = el && expectedValues.get(el);
        if (!el?.isConnected || !expected || signature(el) !== expected.signature || isSensitiveField(el)) return 'unverified';
        const actual = typeof expected.value === 'boolean'
          ? (el.checked ?? (el.getAttribute('aria-checked') === 'true'))
          : (el.isContentEditable ? el.textContent : el.value);
        return actual === expected.value ? 'matched' : 'mismatch';
      };

      // `commit` makes the walk an observation: it rotates the snapshot id and gives every new control a ref. A ref keeps the
      // signature its control had when a client last saw it (`acknowledge`, or `observe` for what it lists), so a control that
      // changed since is refused, whatever later walks did. Without `commit` the walk only reads.
      const collect = (commit = true) => {
        if (commit) window.__wsurfSnapshot = Date.now().toString(36) + Math.random().toString(36);
        const out = [];
        if (!document.body) return out;
        for (const el of walk(document.body)) {
          const kind = kindOf(el);
          if (!kind || !visible(el)) continue;
          const label = labelOf(el, kind);
          if (!label && !['field', 'select', 'scrollarea'].includes(kind)) continue;
          let dup = false;
          for (let a = el.parentElement, hops = 0; a && hops < 3; a = a.parentElement, hops++) {
            if (a.__wsurfRef && ['button', 'link'].includes(kindOf(a)) && ['button', 'link'].includes(kind) && labelOf(a, 'button') === label) { dup = true; break; }
          }
          if (dup) continue;

          let ref = refIDs.get(el);
          if (!ref && commit) { ref = window.__wsurfRefs.push(el); refIDs.set(el, ref); refSignatures.set(ref, signature(el)); }
          if (commit) {
            foundOnly.delete(el);
            el.__wsurfRef = ref;
          }
          const entry = { r: ref || 0, k: kind, l: label };
          if (kind === 'link' && el.href.length <= 2048) entry.h = el.href;
          if (kind === 'field') {
            if (el.readOnly || el.getAttribute('aria-readonly') === 'true') entry.ro = 1;
            entry.t = ((el.type || (el.isContentEditable ? 'editable' : 'text')) + '').toLowerCase();
            const v = norm(el.value || (el.isContentEditable ? el.textContent : '') || '');
            if (isSensitiveField(el)) {
              entry.s = 1;
              entry.f = v ? 1 : 0;
            } else if (v) {
              entry.v = v.slice(0, 30);
            }
          }
          if (kind === 'select') {
            if (isSensitiveField(el)) {
              entry.s = 1;
              entry.f = el.value ? 1 : 0;
            } else {
              entry.v = el.selectedIndex >= 0 ? norm(el.options[el.selectedIndex].text).slice(0, 30) : '';
              entry.o = Array.from(el.options).slice(0, 3).map(o => norm(o.text).slice(0, 45));
              entry.oc = el.options.length;
            }
          }
          if (kind === 'checkbox' || kind === 'radio') entry.c = el.checked || el.getAttribute('aria-checked') === 'true' ? 1 : 0;
          if (disabled(el)) entry.d = 1;
          const rect = el.getBoundingClientRect();
          entry.vp = inViewport(el);
          const frame = el.ownerDocument.defaultView?.frameElement;
          if (frame) entry.frame = frame.title || frame.name || 'embedded frame';
          if (el.tagName === 'SUMMARY' && el.parentElement?.tagName === 'DETAILS') entry.expanded = el.parentElement.open ? 'true' : 'false';
          else if (el.getAttribute('aria-expanded')) entry.expanded = el.getAttribute('aria-expanded');
          if (el.getAttribute('aria-pressed')) entry.pr = el.getAttribute('aria-pressed') === 'true' ? 1 : 0;
          if (el.getAttribute('aria-selected')) entry.se = el.getAttribute('aria-selected') === 'true' ? 1 : 0;
          out.push(entry);
        }
        return out;
      };

      const pageText = (viewportOnly = false) => {
        const parts = [];
        const visit = root => {
          if (!root) return;
          const doc = root.ownerDocument || document;
          const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = walker.nextNode())) {
            const el = node.parentElement;
            if (!el || el.closest('script,style,noscript,template') || !visible(el)) continue;
            const rect = el.getBoundingClientRect();
            if (viewportOnly && !inViewport(el)) continue;
            const field = el.closest('textarea,input,[contenteditable],[role=textbox],[role=searchbox]');
            if (field && isSensitiveField(field)) continue;
            const t = norm(node.textContent);
            if (t) parts.push(t);
          }
          for (const el of root.querySelectorAll('*')) {
            if (el.shadowRoot) visit(el.shadowRoot);
            if (el.tagName === 'IFRAME') { try { visit(el.contentDocument?.body); } catch (e) {} }
          }
        };
        visit(document.body);
        return norm(parts.join(' '));
      };

      const viewportText = limit => {
        const height = window.innerHeight;
        const parts = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          const t = norm(node.textContent);
          if (!t) continue;
          const parent = node.parentElement;
          if (!parent) continue;
          const r = parent.getBoundingClientRect();
          if (r.bottom <= 0 || r.top >= height || r.width === 0) continue;
          parts.push(t);
          if (parts.join(' ').length > limit) break;
        }
        const joined = norm(parts.join(' ')).slice(0, limit);
        return joined || pageText().slice(0, limit);
      };

      const resolve = (ref, label, kinds) => {
        if (ref > 0) {
          const el = window.__wsurfRefs[ref - 1];
          if (!el || !el.isConnected || foundOnly.has(el) || !kinds.includes(kindOf(el))) return { stale: true };
          return { el };
        }
        const t = norm(label).toLowerCase();
        const candidates = [];
        for (const el of window.__wsurfRefs) {
          if (!el.isConnected || foundOnly.has(el)) continue;
          const kind = kindOf(el);
          if (!kind || !kinds.includes(kind)) continue;
          candidates.push({ el, label: labelOf(el, kind).toLowerCase() });
        }
        let matches = candidates.filter(c => c.label === t);
        if (!matches.length) matches = candidates.filter(c => t && c.label.includes(t));
        if (matches.length > 1) return { ambiguous: true };
        if (matches.length === 1) return { el: matches[0].el };
        return { options: [...new Set(candidates.map(c => c.label).filter(l => l && l.length < 50))].slice(0, 25) };
      };

      const realm = el => (el.ownerDocument && el.ownerDocument.defaultView) || window;

      const setValue = (el, value) => {
        if (el.isContentEditable) {
          el.focus();
          el.textContent = value;
          el.dispatchEvent(new (realm(el).Event)('input', { bubbles: true }));
          return;
        }
        const view = realm(el);
        const proto = el.tagName === 'TEXTAREA' ? view.HTMLTextAreaElement.prototype : view.HTMLInputElement.prototype;
        Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, value);
        el.dispatchEvent(new (view.Event)('input', { bubbles: true }));
        el.dispatchEvent(new (view.Event)('change', { bubbles: true }));
      };

      const highlight = (el, ms) => {
        try {
          const doc = el.ownerDocument;
          const view = doc.defaultView;
          doc.__wsurfRing?.remove();
          const ring = doc.createElement('div');
          ring.className = '__wsurf-ring';
          ring.setAttribute('aria-hidden', 'true');
          doc.__wsurfRing = ring;
          const s = ring.style;
          const set = (key, value) => s.setProperty(key, value, 'important');
          set('all', 'initial');
          set('position', 'fixed');
          set('box-sizing', 'border-box');
          set('margin', '0');
          set('padding', '0');
          set('border', '2px solid #3478F6');
          set('box-shadow', '0 0 0 4px rgba(52, 120, 246, 0.25)');
          set('z-index', '2147483647');
          set('pointer-events', 'none');
          set('transition', 'opacity 0.2s');
          doc.documentElement.appendChild(ring);
          let changes, sizeChanges;
          const stop = () => {
            changes?.disconnect();
            sizeChanges?.disconnect();
            ring.remove();
          };
          const sync = () => {
            if (!el.isConnected || !ring.isConnected) { stop(); return; }
            const rect = el.getBoundingClientRect();
            set('left', (rect.left - 4) + 'px');
            set('top', (rect.top - 4) + 'px');
            set('width', (rect.width + 8) + 'px');
            set('height', (rect.height + 8) + 'px');
            const radius = parseFloat(view.getComputedStyle(el).borderTopLeftRadius) || 0;
            set('border-radius', (radius + 4) + 'px');
          };
          const track = () => {
            sync();
            if (ring.isConnected) view.requestAnimationFrame(track);
          };
          track();
          changes = new view.MutationObserver(records => {
            if (records.some(record => record.target !== ring)) sync();
          });
          changes.observe(doc.documentElement, { attributes: true, childList: true, subtree: true });
          if (view.ResizeObserver) {
            sizeChanges = new view.ResizeObserver(sync);
            sizeChanges.observe(el);
          }
          setTimeout(() => { set('opacity', '0'); setTimeout(stop, 250); }, ms);
        } catch (e) {}
      };

      const pressEnter = el => {
        const view = realm(el);
        const opts = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true, composed: true };
        let submitted = false;
        const mark = () => { submitted = true; };
        const form = el.form;
        form?.addEventListener('submit', mark, { capture: true });
        const accepted = el.dispatchEvent(new (view.KeyboardEvent)('keydown', opts));
        el.dispatchEvent(new (view.KeyboardEvent)('keyup', opts));
        form?.removeEventListener('submit', mark, { capture: true });
        if (accepted && !submitted && form?.isConnected) { try { form.requestSubmit(); } catch (e) {} }
      };

      const actionable = (el, checkEnabled = true) => {
        if (!el?.isConnected || !visible(el)) return 'The control is hidden or no longer available.';
        if (checkEnabled && disabled(el)) return 'The control is disabled.';
        el.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        const rect = el.getBoundingClientRect();
        const root = el.getRootNode();
        const view = realm(el);
        const left = Math.max(0, rect.left), right = Math.min(view.innerWidth, rect.right);
        const top = Math.max(0, rect.top), bottom = Math.min(view.innerHeight, rect.bottom);
        if (right <= left || bottom <= top) return 'The control is outside the viewport.';
        const hit = (root.elementFromPoint ? root : el.ownerDocument).elementFromPoint((left + right) / 2, (top + bottom) / 2);
        if (!hit || !(hit === el || el.contains(hit))) return 'The control is covered by another element.';
        const frame = el.ownerDocument.defaultView?.frameElement;
        return frame ? actionable(frame) : '';
      };

      const sigHash = text => {
        let hash = 2166136261;
        for (let i = 0; i < text.length; i++) hash = Math.imul(hash ^ text.charCodeAt(i), 16777619) >>> 0;
        return hash || 1;
      };
      // Records that a client has now seen the controls `pairs` ([ref, hash of the signature it was shown]) list, but only
      // where the control still has that signature: one that changed in between stays refused.
      const acknowledge = pairs => {
        for (const [ref, hash] of pairs) {
          const el = window.__wsurfRefs[ref - 1];
          if (!el?.isConnected || foundOnly.has(el)) continue;
          const current = signature(el);
          if (sigHash(current) === hash) refSignatures.set(ref, current);
        }
        return true;
      };

      // `acknowledge` false returns each listed control's signature hash instead, for the caller to acknowledge what it shows.
      const observe = (query, textLimit, controlLimit, textOffset, controlOffset, scope, viewportOnly, ack = true) => {
        // A rejected scope must not rotate the snapshot or walk the page.
        if (scope && selectorProblem(scope)) return { error: 'The scope selector is invalid or reads an attribute value that is not exposed.' };
        const all = collect();
        const text = pageText(viewportOnly);
        const terms = norm(query).toLowerCase().split(/\s+/).filter(Boolean);
        let start = Math.min(Math.max(0, textOffset), text.length);
        if (terms.length && !textOffset) {
          const lower = text.toLowerCase();
          const positions = terms.map(t => lower.indexOf(t)).filter(p => p >= 0);
          if (positions.length) start = Math.max(0, Math.min(...positions) - Math.min(60, Math.floor(textLimit / 10)));
        }
        if (start > 0 && /[\uDC00-\uDFFF]/.test(text[start] || '')) start++;
        let end = Math.min(text.length, start + textLimit);
        if (end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1] || '')) end--;
        let roots = null;
        if (scope) { try { roots = new Set(document.querySelectorAll(scope)); } catch (e) {} }
        if (scope && !roots?.size) return { error: 'No element matches that scope.' };
        const inScope = el => { for (let node = el; node; node = parentOf(node)) if (roots.has(node)) return true; return false; };
        const candidates = all.filter(c => (!roots || inScope(window.__wsurfRefs[c.r - 1])) && (!viewportOnly || c.vp));
        const availabilityOrder = (a, b) => Number(b.vp) - Number(a.vp) || Number(!!a.d) - Number(!!b.d);
        if (terms.length) candidates.sort((a, b) => {
          const score = c => terms.reduce((n, t) => n + (c.l.toLowerCase().includes(t) ? 10 : 0), 0);
          return score(b) - score(a) || availabilityOrder(a, b);
        });
        else candidates.sort(availabilityOrder);
        const controlQuery = JSON.stringify([norm(query).toLowerCase(), scope, viewportOnly]);
        let offset = Math.max(0, controlOffset), controlReset = '';
        if (offset > 0 && lastControlQuery !== null && lastControlQuery !== controlQuery) {
          offset = 0; controlReset = 'query_changed';
        } else if (offset > 0 && offset >= candidates.length) {
          offset = 0; controlReset = 'out_of_range';
        }
        lastControlQuery = controlQuery;
        const listed = candidates.slice(offset, offset + controlLimit);
        for (const c of listed) {
          const el = window.__wsurfRefs[c.r - 1];
          if (!el) continue;
          if (ack) refSignatures.set(c.r, signature(el));
          else c.sg = sigHash(signature(el));
        }
        return { text: text.slice(start, end), textTotal: text.length, textStart: start,
          controls: listed, controlTotal: candidates.length, controlStart: offset,
          controlReset,
          snapshot: window.__wsurfSnapshot, document: documentID, url: location.href };
      };

      // MARK: Development inspection: elementState (waits), findAll, inspect
      // Every result is bounded while it is built; nothing reads input values, hidden-field contents or raw HTML.

      const STYLE_PROPERTIES = \#(styleLiteral);
      const ATTRIBUTE_ALLOWLIST = new Set(['id', 'class', 'role', 'type', 'name', 'for', 'tabindex', 'alt', 'title', 'placeholder',
        'href', 'src', 'target', 'rel', 'lang', 'dir', 'disabled', 'readonly', 'required', 'checked', 'selected', 'hidden', 'multiple',
        'autocomplete', 'contenteditable', 'draggable', 'inert', 'open', 'width', 'height', 'colspan', 'rowspan', 'min', 'max', 'step']);
      const clip = (s, n) => { s = norm(s); return s.length > n ? Array.from(s).slice(0, n).join('') : s; };
      const round = n => Math.round(n * 100) / 100;
      // Size of a result as delivered: Swift re-serialises the JSON (escaping "/"), and the text is then wrapped by
      // AgentToolkit.untrusted, which escapes & < >. Measured here, on those exact bytes, so a budget cannot be missed by
      // escaping. WIRE_LIMIT sits 8 KiB under the 32 KiB cap for the "ELEMENT:"/"observationID:" lines and Foundation's
      // own formatting of numbers, which this measure cannot see.
      const WIRE_LIMIT = 24576;
      const WIRE_ESCAPES = { '/': '\\/', '&': '&amp;', '<': '&lt;', '>': '&gt;' };
      const wireBytes = value => new TextEncoder().encode(JSON.stringify(value).replace(/[\/&<>]/g, c => WIRE_ESCAPES[c])).length;
      const rectOf = el => { const r = el.getBoundingClientRect(); return { x: round(r.x), y: round(r.y), width: round(r.width), height: round(r.height) }; };
      const hiddenInput = el => el.tagName === 'INPUT' && ((el.type || '') + '').toLowerCase() === 'hidden';
      const inert = el => { for (let n = el; n; n = parentOf(n)) if (n.hasAttribute && n.hasAttribute('inert')) return true; return false; };

      function* deep(root) {
        for (const el of root.querySelectorAll('*')) {
          yield el;
          if (el.shadowRoot) yield* deep(el.shadowRoot);
          if (el.tagName === 'IFRAME') {
            try {
              const inner = el.contentDocument;
              if (inner && inner.documentElement) yield* deep(inner);
            } catch (e) {}
          }
        }
      }
      // Selector policy. A selector is evaluated against the page, so an attribute predicate is a read of that attribute:
      // `input[type=hidden][value^=s3]` (or the same under :has) would recover a hidden token a byte at a time. Attribute
      // predicates are therefore limited to attributes this runtime already exposes. The selector is canonicalised by the
      // engine's own CSS parser first, so escapes (`v\61lue`), case and namespace forms (`[*|value]`) cannot hide a name.
      const URL_ATTRIBUTES = new Set(['href', 'src']);
      const TEST_ATTRIBUTES = new Set(['data-testid', 'data-test', 'data-test-id', 'data-cy', 'data-qa', 'data-automation-id']);
      const skipString = (text, start) => {
        for (let k = start + 1; k < text.length; k++) {
          if (text[k] === '\\') k++;
          else if (text[k] === text[start]) return k;
        }
        return text.length;
      };
      const attributeSelectors = text => {
        const out = [];
        for (let i = 0; i < text.length; i++) {
          const c = text[i];
          if (c === '\\') { i++; continue; }
          if (c === '"' || c === "'") { i = skipString(text, i); continue; }
          if (c !== '[') continue;
          let body = '', j = i + 1;
          for (; j < text.length && text[j] !== ']'; j++) {
            if (text[j] === '\\') { body += text.slice(j, j + 2); j++; continue; }
            if (text[j] === '"' || text[j] === "'") { const e = skipString(text, j); body += text.slice(j, e + 1); j = e; continue; }
            body += text[j];
          }
          out.push(body);
          i = j;
        }
        return out;
      };
      const ATTRIBUTE_BODY = /^\s*(?:(?:[^\s|=~^$*\\\[\]"']*|\*)\|(?!=))?([^\s|=~^$*\\\[\]"']+)\s*(?:([~|^$*]?=)[\s\S]*)?$/;
      // null when the selector may run; otherwise 'invalid' (not a selector) or 'unsafe' (reads an unexposed attribute).
      const selectorProblem = selector => {
        try { document.createDocumentFragment().querySelector(selector); } catch (e) { return 'invalid'; }
        let canonical;
        try {
          const sheet = new CSSStyleSheet();
          sheet.insertRule(selector + '{}');
          if (sheet.cssRules.length !== 1 || !sheet.cssRules[0].selectorText) return 'invalid';
          canonical = sheet.cssRules[0].selectorText;
        } catch (e) { return 'invalid'; }
        for (const body of attributeSelectors(canonical)) {
          const m = ATTRIBUTE_BODY.exec(body);
          if (!m) return 'unsafe';
          const name = m[1].toLowerCase(), hasValue = !!m[2];
          if (name.startsWith('aria-') || TEST_ATTRIBUTES.has(name)) continue;
          if (!ATTRIBUTE_ALLOWLIST.has(name) || (hasValue && URL_ATTRIBUTES.has(name))) return 'unsafe';
        }
        return null;
      };
      const SELECTOR_ERRORS = { invalid: 'Invalid selector.',
        unsafe: 'That selector reads an attribute value that is not exposed. Use id, class, role, type, name, aria-*, or a test attribute (data-testid); href and src by presence only.' };
      const refFor = el => {
        let ref = refIDs.get(el);
        if (!ref) { ref = window.__wsurfRefs.push(el); refIDs.set(el, ref); foundOnly.add(el); }
        refSignatures.set(ref, signature(el));
        return ref;
      };

      const elementState = selector => {
        const problem = selectorProblem(selector);
        if (problem) return { problem, error: SELECTOR_ERRORS[problem] };
        const matches = [];
        for (const el of deep(document)) {
          if (el.matches(selector)) { matches.push(el); if (matches.length > 1) break; }
        }
        if (matches.length !== 1) return { count: matches.length, visible: null, enabled: null };
        const el = matches[0], rect = el.getBoundingClientRect();
        return { count: 1, visible: visible(el) && rect.width > 0 && rect.height > 0, enabled: !disabled(el) && !inert(el) };
      };

      const nameOf = el => {
        if (['SCRIPT', 'STYLE', 'TEMPLATE', 'NOSCRIPT', 'OPTION', 'OPTGROUP', 'DATALIST'].includes(el.tagName) || hiddenInput(el)) return '';
        if (['INPUT', 'TEXTAREA', 'SELECT'].includes(el.tagName)) return clip(fieldLabel(el), 80);
        const aria = accessibleName(el);
        if (aria || el.isContentEditable) return clip(aria, 80);
        const kind = kindOf(el);
        if (kind === 'button' || kind === 'link') return clip(controlLabel(el), 80);
        let text = '';
        for (const node of el.childNodes) { if (node.nodeType === 3) text += node.nodeValue + ' '; if (text.length > 400) break; }
        return clip(text || el.getAttribute('alt') || el.getAttribute('title') || '', 80);
      };

      const summaryOf = (el, ref) => {
        const tag = el.tagName.toLowerCase();
        if (hiddenInput(el)) return { r: ref, tag, type: 'hidden' };
        const out = { r: ref, tag };
        if (el.id) out.id = clip(el.id, 80);
        const cls = Array.from(el.classList || []).slice(0, 5).map(c => clip(c, 40));
        if (cls.length) out.cls = cls;
        const role = el.getAttribute('role');
        if (role) out.role = clip(role, 40);
        const name = nameOf(el);
        if (name) out.name = name;
        out.rect = rectOf(el);
        out.visible = visible(el);
        if (el.ownerDocument !== document) out.inFrame = true;
        return out;
      };

      const findAll = (selector, offset, limit) => {
        const problem = selectorProblem(selector);
        if (problem) return { problem, error: SELECTOR_ERRORS[problem] };
        if (!Number.isInteger(offset) || offset < 0 || offset > 10000 || !Number.isInteger(limit) || limit < 1 || limit > 100) {
          return { problem: 'range', error: 'offset must be 0 to 10000 and limit 1 to 100.' };
        }
        const observation = window.__wsurfSnapshot = Date.now().toString(36) + Math.random().toString(36);
        const items = [];
        const result = { observation, document: documentID, url: location.href, offset, limit, returned: 0, hasMore: true, items,
          coverage: { crossOriginFrames: 'skipped', closedShadowRoots: 'skipped' } };
        let used = wireBytes(result), index = 0;
        result.hasMore = false;
        for (const el of deep(document)) {
          if (!el.matches(selector)) continue;
          if (index++ < offset) continue;
          if (items.length === limit) { result.hasMore = true; break; }
          const item = summaryOf(el, refFor(el)), cost = wireBytes(item) + 1;
          // The first item always fits (summaries are clipped), so a page always advances.
          if (items.length && used + cost > WIRE_LIMIT) { result.hasMore = true; break; }
          items.push(item);
          used += cost;
        }
        result.returned = items.length;
        return result;
      };

      const safeURL = (value, el) => {
        try {
          const u = new URL(value, el.baseURI);
          return u.origin === 'null' ? u.protocol : u.origin + u.pathname;
        } catch (e) { return ''; }
      };

      const inspect = ref => {
        if (!inspectableRef(ref)) return { stale: true };
        const el = window.__wsurfRefs[ref - 1], view = realm(el), style = view.getComputedStyle(el);
        const px = name => round(parseFloat(style.getPropertyValue(name)) || 0);
        const sides = (a, b = '') => ({ top: px(a + '-top' + b), right: px(a + '-right' + b), bottom: px(a + '-bottom' + b), left: px(a + '-left' + b) });
        const rect = rectOf(el), padding = sides('padding'), border = sides('border', '-width');
        const total = el.attributes.length, hidden = hiddenInput(el), attributes = {};
        let kept = 0, scanned = 0;
        for (; scanned < Math.min(total, 256) && kept < 32; scanned++) {
          const attr = el.attributes[scanned], name = attr.name.toLowerCase();
          if (hidden ? name !== 'type' : !(ATTRIBUTE_ALLOWLIST.has(name) || name.startsWith('aria-'))) continue;
          attributes[name] = name === 'href' || name === 'src' ? safeURL(attr.value, el) : clip(attr.value, 120);
          kept++;
        }
        const styles = {};
        for (const property of STYLE_PROPERTIES) {
          const value = style.getPropertyValue(property);
          if (value !== '') styles[property] = clip(value, 120);
        }
        const ancestors = [];
        let ancestorsTruncated = false;
        for (let node = parentOf(el); node && node.nodeType === 1; node = parentOf(node)) {
          if (ancestors.length === 16) { ancestorsTruncated = true; break; }
          const s = realm(node).getComputedStyle(node), box = node.getBoundingClientRect();
          const entry = { tag: node.tagName.toLowerCase(), display: s.display, position: s.position,
            overflow: s.overflowX + ' ' + s.overflowY, width: round(box.width), height: round(box.height) };
          if (node.id) entry.id = clip(node.id, 80);
          const cls = Array.from(node.classList || []).slice(0, 3).map(c => clip(c, 40));
          if (cls.length) entry.cls = cls;
          ancestors.push(entry);
        }
        const out = {
          r: ref, document: documentID, tag: el.tagName.toLowerCase(), name: nameOf(el),
          attributes, attributesTotal: total, attributesTruncated: scanned < total,
          rect,
          scroll: { scrollWidth: el.scrollWidth, scrollHeight: el.scrollHeight, clientWidth: el.clientWidth, clientHeight: el.clientHeight,
            scrollTop: round(el.scrollTop), scrollLeft: round(el.scrollLeft) },
          box: { boxSizing: style.boxSizing, margin: sides('margin'), border, padding,
            // Layout pixels (untransformed): clientWidth/Height already exclude borders and scrollbars.
            content: { width: Math.max(0, round(el.clientWidth - padding.left - padding.right)),
                       height: Math.max(0, round(el.clientHeight - padding.top - padding.bottom)) } },
          style: styles, ancestors, ancestorsTruncated
        };
        if (el.ownerDocument !== document) out.inFrame = true;
        while (wireBytes(out) > WIRE_LIMIT && out.ancestors.length) { out.ancestors.pop(); out.ancestorsTruncated = true; }
        if (wireBytes(out) > WIRE_LIMIT) { out.attributes = {}; out.attributesTruncated = true; }
        if (wireBytes(out) > WIRE_LIMIT) { out.style = {}; out.truncated = true; }
        return out;
      };
      // Where a ref'd element, and everything that frames or clips it, sit in their own document's viewport, for a screenshot
      // crop. Boxes are measured, never guessed: a bounding box, the layout size and the composed 2D linear part of every
      // transform up to the document root (rotation, reflection, skew, scale); Swift derives the translation from the
      // bounding box's centre and maps the polygon (`ScreenshotGeometry`). A 3D transform or an unreachable frame sets
      // `unmappable`.
      const screenshotGeometry = ref => {
        const el = inspectableRef(ref) ? window.__wsurfRefs[ref - 1] : null;
        if (!el || !el.isConnected) return { stale: true };
        const out = { foundOnly: foundOnly.has(el), clips: [], frames: [] };
        const r = (x, y, width, height) => ({ x, y, width, height });
        const win = node => node.ownerDocument.defaultView, up = node => node.parentElement || node.getRootNode().host;
        // [a, b, c, d] is matrix(a, b, c, d); mul(p, q) applies q first.
        const mul = (p, q) => [p[0] * q[0] + p[2] * q[1], p[1] * q[0] + p[3] * q[1], p[0] * q[2] + p[2] * q[3], p[1] * q[2] + p[3] * q[3]];
        const REPLACED = new Set(['IFRAME', 'IMG', 'VIDEO', 'AUDIO', 'CANVAS', 'svg', 'INPUT', 'SELECT', 'TEXTAREA', 'BUTTON', 'OBJECT', 'EMBED']);
        const radians = token => {
          const n = parseFloat(token);
          return token.endsWith('grad') ? n * Math.PI / 200 : token.endsWith('deg') ? n * Math.PI / 180 : token.endsWith('turn') ? n * 2 * Math.PI : n;
        };
        // The 2D linear part one node applies to itself: CSS `zoom` (which scales layout, unlike a transform: bounding boxes are
        // zoomed while offset and client sizes are not), then `transform`, `scale` and `rotate` (translation is derived later).
        // Null for a 3D transform, which a 2D polygon cannot carry.
        const own = node => {
          const s = win(node).getComputedStyle(node);
          if (s.display === 'contents' || (s.display === 'inline' && !REPLACED.has(node.tagName))) return [1, 0, 0, 1];
          const zoom = parseFloat(s.zoom) || 1;
          let l = [zoom, 0, 0, zoom];
          if (s.transform && s.transform !== 'none') {
            const m = new DOMMatrix(s.transform);
            if (m.m13 || m.m23 || m.m31 || m.m32 || m.m43 || m.m14 || m.m24 || m.m33 !== 1 || m.m44 !== 1) return null;
            l = mul([m.m11, m.m12, m.m21, m.m22], l);
          }
          const scale = (s.scale || 'none').trim().split(/\s+/);
          if (scale[0] !== 'none') { const sx = parseFloat(scale[0]); l = mul([sx, 0, 0, scale.length > 1 ? parseFloat(scale[1]) : sx], l); }
          const rotate = (s.rotate || 'none').trim().split(/\s+/);
          if (rotate[0] !== 'none') {
            let t = radians(rotate[rotate.length - 1]);
            if (rotate.length > 1) {
              const word = rotate.length === 2 ? { x: [1, 0, 0], y: [0, 1, 0], z: [0, 0, 1] }[rotate[0]] : null;
              const v = word || (rotate.length === 4 ? rotate.slice(0, 3).map(parseFloat) : null);
              if (!v || v[0] || v[1]) { if (t) return null; } else t *= Math.sign(v[2]);
            }
            l = mul([Math.cos(t), Math.sin(t), -Math.sin(t), Math.cos(t)], l);
          }
          // A non-zero z in `translate` is 3D: under a perspective ancestor it scales the box, which no 2D polygon carries.
          const translate = (s.translate || 'none').trim().split(/\s+/);
          if (translate.length > 2 && parseFloat(translate[2])) return null;
          return l.every(Number.isFinite) ? l : null;
        };
        // Every transform from `node` up to its document's root, composed once.
        const linearOf = node => { let acc = [1, 0, 0, 1]; for (let n = node; n; n = up(n)) { const l = own(n); if (!l) return null; acc = mul(l, acc); } return acc; };
        // `local` is the region of interest in layout pixels from the node's border-box origin.
        const place = (node, local) => {
          // SVG nodes have no layout box (offset and client sizes): nothing to measure the placement from.
          if (typeof node.offsetWidth !== 'number') { out.unmappable = true; return null; }
          const linear = linearOf(node);
          if (!linear) { out.unmappable = true; return null; }
          const b = node.getBoundingClientRect();
          return { border: r(b.x, b.y, b.width, b.height), layout: r(0, 0, node.offsetWidth, node.offsetHeight), linear, local };
        };
        // Padding boxes (what an `overflow` container shows) of the ancestors that cut `node` off, in its own viewport.
        // An absolute or fixed node escapes the containers that are not its containing block.
        const clipsOf = node => {
          const view = win(node), clips = [];
          let position = view.getComputedStyle(node).position;
          for (let a = up(node); a; a = up(a)) {
            const s = view.getComputedStyle(a), block = s.transform !== 'none' || s.filter !== 'none';
            if (position === 'fixed' ? !block : position === 'absolute' && s.position === 'static' && !block) continue;
            position = s.position;
            const rootScroller = a === view.document.body && view.getComputedStyle(view.document.documentElement).overflow === 'visible';
            if ((s.overflowX === 'visible' && s.overflowY === 'visible') || s.display === 'inline' || s.display === 'contents' || rootScroller) continue;
            const p = place(a, r(a.clientLeft, a.clientTop, a.clientWidth, a.clientHeight));
            if (p) clips.push(p);
          }
          return clips;
        };
        const box = el.getBoundingClientRect();
        out.rect = r(box.x, box.y, box.width, box.height);
        out.clips = clipsOf(el);
        let w = win(el);
        for (; w && w !== window && w.frameElement; w = w.parent) {
          const frame = w.frameElement, style = win(frame).getComputedStyle(frame), pad = name => parseFloat(style[name]) || 0;
          const p = place(frame, r(frame.clientLeft + pad('paddingLeft'), frame.clientTop + pad('paddingTop'),
            frame.clientWidth - pad('paddingLeft') - pad('paddingRight'), frame.clientHeight - pad('paddingTop') - pad('paddingBottom')));
          if (p) out.frames.push({ ...p, clips: clipsOf(frame) });
        }
        if (w !== window) out.unmappable = true;
        return out;
      };

      \#(feedbackScript)

      return { matchesRef, inspectableRef, isFoundOnly: ref => foundOnly.has(window.__wsurfRefs[ref - 1]), expectValue, valueState, walk, documentID, norm, collect,
        pageText, viewportText, resolve, setValue, pressEnter,
        labelOf, kindOf, visible, highlight, isSensitiveField, disabled, actionable, observe, acknowledge, elementState, findAll, inspect, selectorProblem, screenshotGeometry,
        digest, waitFor };
    })());
    """#

    // MARK: Bounded inputs for development tools

    static let maxSelectorBytes = 2_048

    enum SelectorFailure: Error, Equatable { case empty, tooLong, invalid }

    /// A CSS selector is accepted only when non-blank, free of NUL, and at most 2,048 UTF-8 bytes. Syntax is checked
    /// by the page itself (`Invalid selector.`), never guessed here.
    static func validate(selector: String) -> Result<String, SelectorFailure> {
        if selector.allSatisfy(\.isWhitespace) {
            return .failure(.empty)
        }
        if selector.utf8.count > maxSelectorBytes {
            return .failure(.tooLong)
        }
        if selector.unicodeScalars.contains(where: { $0.value == 0 }) {
            return .failure(.invalid)
        }
        return .success(selector)
    }

    /// Computed style properties `inspect` may return (≤ 64); the script receives this exact list.
    static let inspectStyleProperties = [
        "display", "position", "visibility", "opacity", "overflow-x", "overflow-y", "z-index", "top", "right", "bottom", "left",
        "width", "height", "min-width", "min-height", "max-width", "max-height", "box-sizing", "float", "clear",
        "flex-direction", "flex-wrap", "flex-grow", "flex-shrink", "flex-basis", "order", "justify-content", "justify-items",
        "justify-self", "align-items", "align-content", "align-self", "row-gap", "column-gap",
        "grid-template-columns", "grid-template-rows", "grid-auto-flow", "grid-column-start", "grid-column-end",
        "grid-row-start", "grid-row-end", "font-family", "font-size", "font-weight", "line-height", "text-align", "white-space",
        "color", "background-color", "border-radius", "transform", "pointer-events",
    ]
    private static let styleLiteral = "[" + inspectStyleProperties.map { "'\($0)'" }.joined(separator: ",") + "]"

}
