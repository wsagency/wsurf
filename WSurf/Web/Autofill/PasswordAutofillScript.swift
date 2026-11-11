// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

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
      const note = target => {
        const fits = pickable(target);
        pick.target = fits ? target : null;
        pick.token = fits ? crypto.randomUUID() : null;
        pick.url = location.href;
        return {action:'context',token:pick.token,url:pick.url,documentID:forms.documentID,field:fits ? pickKind(target) : ''};
      };
      document.addEventListener('contextmenu', event => {
        if (!event.isTrusted || !enabled) return;
        channel?.postMessage(note(event.composedPath()[0]));
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
      // The page's own listeners run while each field is filled, and may move, hide or swap the next one: a later field takes its
      // value only while it is still a field of the form it was chosen in, on this address, and that form still submits to this
      // site. The caches are dropped first, since the page's changes are not yet observed.
      const still = (el,root,url) => {
        forms.invalidate();
        return location.href === url && el.isConnected && pickable(el) && forms.scope(el) === root &&
          forms.safe(forms.group(el)?.root);
      };
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
          const size = list.length > 1 ? target.maxLength : login.code.length, root = forms.scope(target);
          return fillAll(target, () => {
            let count = 0;
            for (const [index, el] of list.entries()) {
              if (!still(el, root, url)) break;
              count += put(el, login.code.slice(index * size, (index + 1) * size));
            }
            return count;
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
          if (password && hasPassword && still(password, group?.root, url)) count += put(password, login.password);
          return count;
        });
      };
      // Generate Password…: the fields of the right-clicked field's form a new password goes into. Its password fields, in order,
      // without the current one: a field that declares current-password, one labelled current, old or existing, and, of three
      // fields none of which says what it is, the first, as the save script reads a new password at submit. The right-clicked field
      // is a current one of a change form when the form has a new one and this is not it. Exactly two new fields, next to each
      // other, one of them the right-clicked field, are the field and its confirmation; any other form fills the right-clicked
      // field alone.
      const oldPassword = /\b(current|old|existing)\b/;
      const generation = target => {
        const group = forms.group(target), passwords = group?.passwords || [];
        let fresh = passwords.filter(field => !field.tokens.includes('current-password') && !oldPassword.test(forms.hint(field.element)));
        if (passwords.length === 3 && fresh.length === 3 && !passwords.some(field => field.kind === 'new-password')) {
          fresh = passwords.slice(1);
        }
        const isFresh = fresh.some(field => field.element === target);
        if (!isFresh && fresh.length && passwords.some(field => field.element === target)) return {group,current:true,partner:null};
        let partner = null;
        if (isFresh && fresh.length === 2 && passwords.indexOf(fresh[1]) === passwords.indexOf(fresh[0]) + 1) {
          partner = fresh.find(field => field.element !== target)?.element || null;
        }
        return {group,current:false,partner};
      };
      // The username the form shows for the new password, by the save script's rule: the account field before the first password,
      // a hidden autocomplete="username" field included.
      const shownUsername = group => {
        const fields = group?.fields || [], passwords = group?.passwords || [], users = group?.usernames || [];
        const first = fields.indexOf(passwords[0]);
        const value = (users.filter(field => fields.indexOf(field) < first).pop() || users[0])?.element.value;
        return typeof value === 'string' && value.length <= 500 ? value : '';
      };
      const limits = el => ({minLength:el.minLength,maxLength:el.maxLength});
      // What native needs before it makes a password, and nothing it sends in: whether the right-clicked field takes a new one, the
      // form's safety, the field's passwordrules (dropped above 1,000 characters, as native ignores longer rules), its length limits
      // and its confirmation's, and the username the form shows.
      const generateTarget = (token,url) => {
        if (!picked(token,url)) return null;
        const target = pick.target;
        if (!secret(target)) return {password:false};
        const found = generation(target);
        if (found.current) return {password:true,current:true};
        const rules = Element.prototype.getAttribute.call(target,'passwordrules') || '';
        return {password:true,current:false,safe:forms.safe(found.group?.root),rules:rules.length <= 1000 ? rules : '',
          field:limits(target),partner:found.partner ? limits(found.partner) : null,username:shownUsername(found.group)};
      };
      // The generated password into the right-clicked field and its confirmation, once per right-click: how many fields took it (-1
      // when the form sends what it gets to another site, so nothing was filled) and the username the form shows.
      const generateFill = (token,url,password) => {
        if (!picked(token,url) || typeof password !== 'string' || !password || password.length > 4096) return {count:0};
        const target = pick.target;
        if (!secret(target)) return {count:0};
        const found = generation(target);
        if (found.current) return {count:0};
        if (!forms.safe(found.group?.root)) return {count:-1};
        const username = shownUsername(found.group), root = forms.scope(target);
        pick.token = null;
        const count = fillAll(target, () => {
          let count = put(target, password);
          if (found.partner && still(found.partner, root, url)) count += put(found.partner, password);
          return count;
        });
        return {count,username};
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
        // Edit ▸ Pick Credential…, asked by native only: the focused field of the frame that has focus, as a right-click on it would
        // be reported, or null. A frame without focus is silent, the top one too: with focus in the address bar or the sidebar a
        // document keeps its last field as its active element. A focus in no pickable field is silent, and so is one that is scrolled
        // out of view or off the page: a page can focus such a field ahead of time, and the person never saw it. Nothing the page does
        // reaches it.
        focusedContext() {
          const field = suggestions.active();
          return enabled && document.hasFocus() && pickable(field) && forms.visible(field) ? note(field) : null;
        },
        pickFill,
        generateTarget,
        generateFill,
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
