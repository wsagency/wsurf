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
      let enabled = false, managerMode = false;
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
        if (!managerMode || !(target instanceof HTMLInputElement) || !visible(target)) return null;
        const group = forms.group(target);
        if (!group?.safe || group.passwords.length || forms.field(target)?.kind !== 'one-time-code') return null;
        if (group.fields.filter(field => field.kind === 'one-time-code').length !== 1) return null;
        return {form:group.root,element:target};
      };
      const extra = target => {
        if (!managerMode) return {};
        if (otp(target)) return {field:'totp'};
        const username = fields(target)?.username?.value;
        return {field:'password',username:typeof username === 'string' && username.length <= 500 ? username : ''};
      };
      const suggestions = globalThis.__wsurfAutofillSuggestions;
      const tracker = suggestions.track(channel, state, target => {
        return enabled && (!!fields(target) || !!otp(target));
      }, extra);
      const eligible = (token,url) => enabled && suggestions.valid(state,token,url) && (!!fields(state.target) || !!otp(state.target));
      globalThis.__wsurfPasswords = {
        setEnabled(value) {
          const changed = enabled !== (value === true);
          enabled = value === true;
          if (!enabled) tracker.clear();
          else if (changed) tracker.refresh();
        },
        setCredentialManager(value) {
          const changed = managerMode !== (value === true);
          managerMode = value === true;
          if (changed) tracker.clear();
        },
        eligible,
        bounds(token,url) { return eligible(token,url) ? suggestions.geometry(state.target) : null; },
        fill(token,url,login) {
          if (!eligible(token,url)) return 0;
          const target = state.target;
          if (typeof login?.code === 'string') {
            const code = otp(target);
            if (!code || !forms.rendered(target) || location.href !== url || !target.isConnected) return 0;
            state.token = null;
            target.setAttribute('data-wsurf-password','');
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(target,login.code);
            target.dispatchEvent(new Event('input',{bubbles:true,composed:true}));
            target.dispatchEvent(new Event('change',{bubbles:true}));
            return 1;
          }
          const found = fields(target);
          if (!found) return 0;
          if (found.username && !forms.rendered(found.username) && found.username.value && found.username.value !== login.username) return 0;
          if (found.passwords.length > 1 || found.passwords.some(el => tokens(el).includes('new-password'))) return 0;
          state.token = null;
          const set = (el,value) => {
            if (!el || !forms.rendered(el) || location.href !== url || !target.isConnected) return 0;
            el.setAttribute('data-wsurf-password','');
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(el,value);
            el.dispatchEvent(new Event('input',{bubbles:true,composed:true}));
            el.dispatchEvent(new Event('change',{bubbles:true}));
            return 1;
          };
          let count = 0;
          if (found.username) count += set(found.username,login.username);
          if (!found.passwords.length || !forms.safe(found.form) || forms.scope(found.passwords[0]) !== found.form) return count;
          if (typeof login.password !== 'string') return count;
          count += set(found.passwords[0],login.password);
          return count;
        }
      };
      const ready = () => channel?.postMessage({action:'ready',documentID:forms.documentID});
      ready();
      window.addEventListener('pageshow',ready);
    })();
    """#
}
