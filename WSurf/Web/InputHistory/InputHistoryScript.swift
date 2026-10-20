// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The page side of Input History. It runs in the `WSurfAutofill` isolated world in every http(s) frame, after
/// `AutofillFormScript` has defined `__wsurfAutofillForms`.
///
/// - It listens, it never changes the page: no attribute, no style, no event is added to the document, no event is stopped, and
///   nothing is returned to page code. Page scripts cannot see this world's globals or its listeners.
/// - Only `isTrusted` input events with an `inputType` count. A value that a script, an extension or autofill put into a field is
///   never kept, and a field whose value such a source changed stays out until the person empties it themselves.
/// - A field's last typed value waits in memory for at most 1.5 s after the last keystroke, and is sent when the person leaves
///   the field, presses Enter, submits, hides or closes the page, or stops typing. Programmatic clearing cannot erase it.
/// - Card numbers, security codes, one-time codes and `contenteditable` content are never captured. Native code applies the
///   same rules again at the boundary.
nonisolated enum InputHistoryScript {
    static let clientSource = client(testHooks: AppDatabase.isRunningTests)

    /// `testHooks` adds handles that call the real handlers with trusted-looking events, since a test cannot type into a page. They
    /// exist only in the test process and only in the isolated world.
    static func client(testHooks: Bool) -> String {
        source.replacingOccurrences(of: "/*hooks*/", with: testHooks ? hooks : "")
    }

    private static let hooks = #"""
      api.__test = {
        edit(el, text) { el.value = text; onInput({isTrusted:true,isComposing:false,inputType:'insertText',composedPath:() => [el]}); },
        scripted(el, text) { el.value = text; onInput({isTrusted:false,composedPath:() => [el]}); },
        blur(el) { onFocusOut({composedPath:() => [el]}); },
        enter() { onKey({isTrusted:true,key:'Enter',isComposing:false}); },
        leave() { leave(); },
        idle(milliseconds) { idleMilliseconds = milliseconds; },
        enabled() { return enabled; },
        ping() { post({action:'ping'}); },
        pending() { return last.size; }
      };
    """#

    private static let source = #"""
    (() => {
      if (globalThis.__wsurfInputHistory || !/^https?:$/.test(location.protocol)) return;
      const forms = globalThis.__wsurfAutofillForms, send = globalThis.__wsurfSend;
      if (!forms || typeof send !== 'function') return;
      const documentID = forms.documentID, isTop = window === window.top;
      const maxTracked = 50, maxValue = 10000, maxPassword = 4096;
      const types = new Set(['text','search','email','url','tel','number','password']);
      const sensitive = /\b(otp|one time|verification code|authenticator|security code|2fa|mfa|two factor|cvv|cvc|csc|cid|card number|card no|cardnumber|cc number|cc num)\b/;
      const last = new Map(), tainted = new WeakSet(), verdicts = new WeakMap();
      let enabled = false, idleMilliseconds = 1500, deadline = 0, timer = null;
      const post = body => { try { send('wsurfInputHistory', {...body, documentID}); } catch {} };
      const where = () => location.origin + location.pathname;
      const eligible = el => el instanceof HTMLTextAreaElement || (el instanceof HTMLInputElement && types.has(el.type));
      const cardNumber = text => {
        if (text.length > 40) return false;
        const digits = text.replace(/[ -]/g, '');
        if (digits.length < 13 || digits.length > 19 || !/^\d+$/.test(digits) || /^0+$/.test(digits)) return false;
        if (digits.startsWith('62')) return true;
        let sum = 0;
        for (let i = 0; i < digits.length; i++) {
          let digit = digits.charCodeAt(digits.length - 1 - i) - 48;
          if (i % 2) { digit *= 2; if (digit > 9) digit -= 9; }
          sum += digit;
        }
        return sum % 10 === 0;
      };
      const excluded = el => {
        let verdict = verdicts.get(el);
        if (verdict === undefined) {
          const words = forms.hint(el);
          verdict = forms.tokens(el).some(token => token === 'one-time-code' || token.startsWith('cc-')) ||
            sensitive.test(words) || (el.maxLength > 0 && el.maxLength <= 8 && /\bcode\b/.test(words));
          verdicts.set(el, verdict);
        }
        return verdict;
      };
      const label = el => (el.labels?.[0]?.textContent?.slice(0, 500) || forms.metadata(el,'aria-label') ||
        forms.metadata(el,'placeholder') || forms.metadata(el,'name') || '').replace(/\s+/g, ' ').trim().slice(0, 120);
      const pairedUsername = el => {
        const other = forms.group(el)?.usernames?.[0]?.element;
        if (!other || other === el || tainted.has(other)) return '';
        const value = other.value.trim();
        return value.length <= 500 && !cardNumber(value) ? value : '';
      };
      const commit = (el, value) => {
        let field = null;
        try { field = el.isConnected ? forms.field(el) : null; } catch {}
        if (field && (forms.cardKinds.has(field.kind) || field.kind === 'one-time-code')) return;
        const named = field?.kind, cleared = value === '';
        const kind = named === 'current-password' || named === 'new-password' || el.type === 'password' ? 'password' :
          named === 'username' ? 'username' : el instanceof HTMLTextAreaElement ? 'multiline' :
          el.type === 'email' || named === 'email' ? 'email' : el.type === 'search' ? 'search' : 'text';
        if (!cleared && (value.length > (kind === 'password' ? maxPassword : maxValue) || cardNumber(value))) return;
        post({action:'commit',url:where(),title:isTop ? document.title.slice(0, 200) : '',field:String(forms.id(el)),kind,
          label:label(el),value,username:kind === 'password' && !cleared ? pairedUsername(el) : '',cleared});
      };
      const flush = only => {
        const pending = last.has(only) ? [[only, last.get(only)]] : [];
        last.delete(only);
        for (const [el, value] of pending) commit(el, value);
      };
      const flushAll = () => {
        if (timer !== null) { clearTimeout(timer); timer = null; }
        const pending = Array.from(last);
        last.clear();
        for (const [el, value] of pending) commit(el, value);
      };
      const expire = () => {
        timer = null;
        if (!last.size) return;
        const wait = deadline - performance.now();
        if (wait > 5) timer = setTimeout(expire, wait); else flushAll();
      };
      const edited = el => {
        const value = el.value;
        if (value === '') tainted.delete(el); else if (tainted.has(el)) return;
        if (value.length > maxValue) { last.delete(el); return; }
        if (last.size >= maxTracked && !last.has(el)) flushAll();
        last.set(el, value);
        deadline = performance.now() + idleMilliseconds;
        if (timer === null) timer = setTimeout(expire, idleMilliseconds);
      };
      const scripted = el => {
        if (el.value !== (last.get(el) ?? '')) { tainted.add(el); last.delete(el); }
      };
      const onInput = event => {
        if (!enabled) return;
        const el = event.composedPath()[0];
        if (!eligible(el)) return;
        if (!event.isTrusted) { scripted(el); return; }
        if (event.isComposing || typeof event.inputType !== 'string' || !event.inputType || excluded(el)) return;
        edited(el);
      };
      const onFocusOut = event => {
        if (enabled && last.size) flush(event.composedPath()[0]);
      };
      const onChange = event => {
        if (!enabled) return;
        const el = event.composedPath()[0];
        if (!eligible(el)) return;
        if (event.isTrusted) flush(el); else scripted(el);
      };
      const onKey = event => {
        if (enabled && last.size && event.isTrusted && event.key === 'Enter' && !event.isComposing) flushAll();
      };
      const onComposed = event => {
        const el = event.composedPath()[0];
        if (enabled && event.isTrusted && eligible(el) && !excluded(el)) edited(el);
      };
      const leave = () => { if (enabled && last.size) flushAll(); };
      document.addEventListener('input', onInput, true);
      document.addEventListener('compositionend', onComposed, true);
      document.addEventListener('change', onChange, true);
      document.addEventListener('focusout', onFocusOut, true);
      document.addEventListener('keydown', onKey, true);
      document.addEventListener('submit', leave, true);
      document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') leave(); });
      window.addEventListener('pagehide', leave);
      const ready = () => post({action:'ready',url:where()});
      window.addEventListener('pageshow', event => { if (event.persisted) ready(); });
      document.addEventListener('DOMContentLoaded', ready, {once:true});
      const api = {
        setPolicy(value) {
          enabled = value?.enabled === true;
          if (!enabled) {
            last.clear();
            if (timer !== null) { clearTimeout(timer); timer = null; }
          }
        }
      };
    /*hooks*/
      globalThis.__wsurfInputHistory = Object.freeze(api);
      ready();
    })();
    """#
}
