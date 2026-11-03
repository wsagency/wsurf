// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

nonisolated enum PasswordAutofillScript {
    static let source = AutofillFormScript.source + AutofillSuggestionScript.source + clientSource
    static let clientSource = #"""
    (() => {
      if (globalThis.__wsurfPasswords) return;
      const channel = globalThis.__wsurfSend
        ? { postMessage: value => globalThis.__wsurfSend('wsurfPasswords', value) } : null;
      const state = {target:null, token:null, url:null};
      const forms = globalThis.__wsurfAutofillForms;
      let enabled = false;
      const visible = forms.visible;
      const tokens = forms.tokens;
      const fields = target => {
        if (!visible(target)) return null;
        const group = forms.group(target);
        if (!group?.safe || group.passwords.length > 3 || group.usernames.length > 1 ||
            forms.field(target)?.category !== 'password') return null;
        const current = group.passwords.filter(field => field.kind === 'current-password');
        if (current.length > 1 || (!current.length && group.passwords.length)) return null;
        if (group.passwords.length > 1 && !current[0]?.tokens.includes('current-password')) return null;
        if (forms.field(target)?.kind === 'new-password') return null;
        return {form:group.root,passwords:current.map(field => field.element),username:group.usernames[0]?.element};
      };
      // A lone, visible verification-code input in a safe form with no password: the one field a code may fill.
      const otp = target => {
        if (!(target instanceof HTMLInputElement) || !visible(target)) return null;
        const group = forms.group(target);
        if (!group?.safe || group.passwords.length || forms.field(target)?.kind !== 'one-time-code') return null;
        if (group.fields.filter(field => field.kind === 'one-time-code').length !== 1) return null;
        return {form:group.root,element:target};
      };
      // `kind` is what the dropdown may do with typing: only a username field lets typed characters start its search.
      // `webauthn`: the field takes passkeys, so native may add "Use a Passkey…" while the page has a pending conditional request.
      const extra = target => {
        const kind = forms.field(target)?.kind || '';
        if (otp(target)) return {field:'totp',kind};
        const username = fields(target)?.username?.value;
        return {field:'password',kind,webauthn:tokens(target).includes('webauthn'),
          username:typeof username === 'string' && username.length <= 500 ? username : ''};
      };
      const suggestions = globalThis.__wsurfAutofillSuggestions;
      const tracker = suggestions.track(channel, state, target => {
        return enabled && (!!fields(target) || !!otp(target));
      }, extra);
      const eligible = (token,url) => enabled && suggestions.valid(state,token,url) && (!!fields(state.target) || !!otp(state.target));
      // Pick Credential…: the field the person right-clicked in this frame, taken only from a trusted contextmenu event. Native keeps
      // the latest one per page, and fills only that field (and its partner), only in this frame, once the person has picked.
      const pick = {target:null, token:null, url:null};
      const pickable = el => el instanceof HTMLInputElement &&
        ['text','email','tel','number','password','search','url'].includes(el.type) && forms.rendered(el);
      const secret = el => el.type === 'password' || ['current-password','new-password'].includes(forms.field(el)?.kind);
      const current = el => secret(el) && forms.field(el)?.kind !== 'new-password';
      // What the field looks like to the picker, which lists codes first for a code field: only an ordering hint.
      const pickKind = el => forms.field(el)?.kind === 'one-time-code' || el.maxLength === 1 ||
        el.inputMode === 'numeric' && el.maxLength > 0 && el.maxLength <= 8 ? 'code' : secret(el) ? 'password' : 'text';
      document.addEventListener('contextmenu', event => {
        if (!event.isTrusted || !enabled) return;
        const target = event.composedPath()[0];
        const fits = pickable(target);
        pick.target = fits ? target : null;
        pick.token = fits ? crypto.randomUUID() : null;
        pick.url = location.href;
        channel?.postMessage({action:'context',token:pick.token,url:pick.url,documentID:forms.documentID,field:fits ? pickKind(target) : ''});
      }, true);
      const picked = (token,url) => enabled && !!token && pick.token === token && pick.url === url && location.href === url &&
        !!pick.target?.isConnected && pickable(pick.target);
      // A code split over boxes of a character or a few goes into exactly those boxes, from the first, whichever one was
      // right-clicked: the nearest container whose boxes of that size in the same form are exactly as many as the code needs.
      // More boxes than that, or too few, is no split code: null.
      const boxes = (target,length) => {
        const size = target.maxLength;
        if (!(size > 0 && size < length)) return [target];
        const count = Math.ceil(length / size), scope = forms.scope(target);
        for (let node = forms.parent(target), depth = 0; node && depth < 5; node = forms.parent(node), depth++) {
          const all = forms.elements(node).filter(el => el instanceof HTMLInputElement && el.maxLength === size && pickable(el) &&
            forms.scope(el) === scope);
          if (all.length === count && all.includes(target)) return all;
          if (all.length > count) return null;
        }
        return null;
      };
      // One field takes its value the way typing it reaches the page's own listeners, React's and Angular's and AribaWeb-style
      // handlers that copy a field on a key or on blur included: focus, keydown, beforeinput, the value through the native setter,
      // input, keyup, change, blur. Every event made here is the script's own, so untrusted, and none carries the value: only the
      // field holds it. Blink sends no focus or blur while its page is unfocused, as Chromium's is while, and for a moment after,
      // a native sheet such as the picker has the window; a focus or blur the engine did not send is then sent here, so the page
      // sees the same sequence in both engines.
      const put = (el,value) => {
        el.setAttribute('data-wsurf-password','');
        const seen = new Set(), note = event => { if (event.target === el) seen.add(event.type); };
        const focus = (type,bubbles) => el.dispatchEvent(new FocusEvent(type,{bubbles,composed:true}));
        const key = type => el.dispatchEvent(new KeyboardEvent(type,{bubbles:true,cancelable:true,composed:true,key:'Unidentified'}));
        const edit = type => el.dispatchEvent(new InputEvent(type,{bubbles:true,composed:true,inputType:'insertReplacementText'}));
        el.addEventListener('focus',note,true);
        el.addEventListener('blur',note,true);
        try {
          const before = suggestions.active() === el;
          el.focus({preventScroll:true});
          const focused = suggestions.active() === el;
          if (focused && !before && !seen.has('focus')) { focus('focus',false); focus('focusin',true); }
          key('keydown');
          edit('beforeinput');
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,value);
          edit('input');
          key('keyup');
          el.dispatchEvent(new Event('change',{bubbles:true}));
          if (suggestions.active() === el) el.blur();
          if (focused && !seen.has('blur')) { focus('blur',false); focus('focusout',true); }
        } finally {
          el.removeEventListener('focus',note,true);
          el.removeEventListener('blur',note,true);
        }
        return 1;
      };
      // The fields of one fill, in order, with nothing selected for suggestions on the way; focus then goes back to the field the
      // person chose, so Return still submits. `fill` returns how many fields took a value.
      const fillAll = (home,fill) => suggestions.quietly(() => {
        const count = fill();
        if (count && home?.isConnected) home.focus({preventScroll:true});
        return count;
      });
      // How many fields took a value; -1 when a password or a code would go to a form that sends it to another site, so nothing was
      // filled.
      const pickFill = (token,url,login) => {
        if (!picked(token,url)) return 0;
        const target = pick.target;
        if (typeof login?.code === 'string') {
          if (!forms.safe(forms.group(target)?.root)) return -1;
          const list = boxes(target, login.code.length);
          if (!list) return 0;
          pick.token = null;
          const size = list.length > 1 ? target.maxLength : login.code.length;
          return fillAll(target, () => {
            list.forEach((el,index) => put(el, login.code.slice(index * size, (index + 1) * size)));
            return list.length;
          });
        }
        const group = forms.group(target);
        const fields = (group?.fields || []).map(field => field.element).filter(pickable);
        const at = fields.indexOf(target);
        let username = null, password = null;
        if (secret(target)) {
          password = target;
          username = group?.usernames.map(field => field.element).find(el => pickable(el) && !secret(el)) ||
            fields.slice(0, Math.max(at, 0)).filter(el => !secret(el)).pop() || null;
        } else {
          username = target;
          password = fields.slice(at + 1).find(current) || fields.find(current) || null;
        }
        const hasPassword = typeof login?.password === 'string';
        if (hasPassword && password && !forms.safe(group?.root)) return -1;
        pick.token = null;
        return fillAll(target, () => {
          let count = 0;
          if (username && typeof login?.username === 'string' && login.username) count += put(username, login.username);
          // The username's own listeners ran in between: the password goes only where it still may.
          if (password && hasPassword && location.href === url && password.isConnected && forms.safe(forms.group(target)?.root)) {
            count += put(password, login.password);
          }
          return count;
        });
      };
      globalThis.__wsurfPasswords = {
        setEnabled(value) {
          const changed = enabled !== (value === true);
          enabled = value === true;
          if (!enabled) tracker.clear();
          else if (changed) tracker.refresh();
        },
        // A vault was unlocked: the field that is still focused is selected again, and its select carries the same token.
        refresh() { if (enabled) tracker.refresh(); },
        eligible,
        pickTarget(token,url) { return picked(token,url) ? pickKind(pick.target) : null; },
        pickFill,
        bounds(token,url) { return eligible(token,url) ? suggestions.geometry(state.target) : null; },
        fill(token,url,login) {
          if (!eligible(token,url)) return 0;
          const target = state.target;
          if (typeof login?.code === 'string') {
            const code = otp(target);
            if (!code || !forms.rendered(target) || location.href !== url || !target.isConnected) return 0;
            state.token = null;
            return fillAll(target, () => put(target,login.code));
          }
          const found = fields(target);
          if (!found) return 0;
          if (found.username && !forms.rendered(found.username) && found.username.value && found.username.value !== login.username) return 0;
          if (found.passwords.length > 1 || found.passwords.some(el => tokens(el).includes('new-password'))) return 0;
          state.token = null;
          const set = (el,value) => {
            if (!el || !forms.rendered(el) || location.href !== url || !target.isConnected) return 0;
            return put(el,value);
          };
          return fillAll(target, () => {
            let count = 0;
            if (found.username) count += set(found.username,login.username);
            if (!found.passwords.length || !forms.safe(found.form) || forms.scope(found.passwords[0]) !== found.form) return count;
            if (typeof login.password !== 'string') return count;
            count += set(found.passwords[0],login.password);
            return count;
          });
        }
      };
      const ready = () => channel?.postMessage({action:'ready',documentID:forms.documentID});
      ready();
      window.addEventListener('pageshow',ready);
    })();
    """#
}
