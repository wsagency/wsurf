// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

nonisolated enum AutofillSaveScript {
    static let source = AutofillFormScript.source + clientSource
    /// The shipped script. Test hooks (and plain HTTP, so a loopback fixture can load it) exist only in a test process.
    static let clientSource = client(testHooks: AppDatabase.isRunningTests)

    static func client(testHooks: Bool) -> String {
        template
            .replacingOccurrences(of: "/*schemes*/", with: testHooks ? "['https:','http:']" : "['https:']")
            .replacingOccurrences(of: "/*hooks*/", with: testHooks ? hooks : "")
    }

    /// Calls the real handlers with events marked trusted, since a test cannot make the engine produce them.
    /// Reachable only from the isolated world this script lives in.
    private static let hooks = #"""
      globalThis.__wsurfAutofillSave.__test = (() => {
        const path = element => {
          const result = [];
          for (let node = element; node; node = node.assignedSlot || node.parentNode || node.host) result.push(node);
          return result;
        };
        const trusted = (element, extra) => ({isTrusted:true,composedPath:() => path(element),...extra});
        return {
          edit(element) {
            element.dispatchEvent(new Event('input',{bubbles:true,composed:true}));
            noteEdit(trusted(element));
          },
          click(element) { clicked(trusted(element)); },
          enter(element) { pressed(trusted(element,{key:'Enter',isComposing:false,repeat:false})); },
          submit(element) { submitted(trusted(element)); },
          age(milliseconds) {
            for (const record of records.values()) {
              record.editedAt -= milliseconds;
              if (record.absentAt != null) record.absentAt -= milliseconds;
            }
          }
        };
      })();
    """#

    private static let template = #"""
    (() => {
      const schemes = /*schemes*/;
      if (globalThis.__wsurfAutofillSave || !schemes.includes(location.protocol)) return;
      const channel = globalThis.__wsurfSend
        ? { postMessage: value => globalThis.__wsurfSend('wsurfAutofillSave', value) } : null;
      const forms = globalThis.__wsurfAutofillForms;
      const documentID = forms.documentID;
      let policy = {password:false,card:false,contact:false};
      const records = new Map(), observedRoots = new WeakSet(), reported = new Set();
      let timer = null, abandoned = false, submitIntent = null;
      const post = body => channel?.postMessage({...body,documentID,url:location.href});
      const diagnose = event => {
        if (reported.has(event)) return;
        reported.add(event); post({action:'diagnostic',event});
      };
      const discard = record => {
        if (record.attemptID) post({action:'discard',attemptID:record.attemptID,formID:record.id});
        record.attemptID = null; record.submitted = false; record.snapshot = null;
        records.delete(record.id);
      };
      const clear = () => {
        submitIntent = null;
        for (const record of records.values()) discard(record);
        if (timer !== null) clearInterval(timer);
        timer = null;
      };
      const collect = (fields, category) => {
        const values = {};
        for (const field of fields) {
          if (field.category !== category || !field.element.value.trim()) continue;
          const value = field.element.value.trim(), kind = field.kind;
          if (value.length > (kind === 'cc-number' ? 32 : 500)) return null;
          if (Object.hasOwn(values,kind) && values[kind] !== value) return null;
          values[kind] = value;
        }
        return values;
      };
      const confirmation = /\b(confirm|repeat|retype|re enter|again|verify)\b/;
      // `members` collects the controls the snapshot was read from; only those can veto a submit.
      const snapshot = (group, edited, members) => {
        if (!group?.safe) return null;
        const changed = group.fields.filter(field => edited.has(field.element));
        if (!changed.length) return null;
        const result = {}, fields = group.fields;
        const passwords = group.passwords, users = group.usernames;
        if (policy.password && users.length <= 3 && passwords.length <= 3) {
          if (passwords.length && changed.some(field => ['current-password','new-password'].includes(field.kind))) {
            let fresh = passwords.filter(field => field.kind === 'new-password');
            if (!fresh.length && passwords.length === 3) fresh = passwords.slice(1);
            // Two unlabelled fields that differ are the old and the new password, unless the second asks to confirm.
            if (!fresh.length && passwords.length === 2 && passwords[0].element.value !== passwords[1].element.value &&
                !confirmation.test(forms.hint(passwords[1].element))) fresh = passwords.slice(1);
            const candidates = fresh.length ? fresh : passwords;
            const value = candidates[0]?.element.value;
            if (value && value.length <= 4096 && candidates.every(field => field.element.value === value)) {
              // Several account fields: the one just before the password is the one this form asks for.
              const first = fields.indexOf(passwords[0]);
              const account = users.filter(field => fields.indexOf(field) < first).pop() || users[0];
              const username = account?.element.value || '';
              if (username.length <= 500) {
                result.password = {username,password:value};
                members.push(...passwords.map(field => field.element));
                if (account) members.push(account.element);
              }
            }
          } else if (!passwords.length && users.length === 1 && changed.includes(users[0])) {
            const value = users[0].element.value;
            if (value && value.length <= 500) { result.username = value; members.push(users[0].element); }
          }
        }
        if (policy.card) {
          const editedCard = changed.find(field => field.category === 'card');
          const number = editedCard && fields.find(field => field.kind === 'cc-number' && field.section === editedCard.section);
          if (number) {
            const sectionFields = fields.filter(field => field.section === number.section);
            const card = collect(sectionFields,'card');
            if (card) {
              const expiry = card['cc-exp'] || '';
              let match = expiry.match(/^(\d{4})-(\d{2})$/);
              if (match) { card['cc-exp-year'] = match[1]; card['cc-exp-month'] = match[2]; }
              else if ((match = expiry.match(/^(\d{1,2})\s*[\/\-]\s*(\d{2}|\d{4})$/)) ||
                       (match = expiry.match(/^(\d{2})(\d{2})$/))) {
                card['cc-exp-month'] = match[1]; card['cc-exp-year'] = match[2];
              }
              if (/^\d{2}$/.test(card['cc-exp-year'] || '')) card['cc-exp-year'] = '20' + card['cc-exp-year'];
              delete card['cc-exp'];
              if (card['cc-number'] && card['cc-exp-month'] && card['cc-exp-year']) {
                result.card = card;
                members.push(...sectionFields.filter(field => field.category === 'card').map(field => field.element));
              }
            }
          }
        }
        if (policy.contact && !passwords.length) {
          const editedContact = changed.find(field => field.category === 'contact');
          const address = editedContact && fields.find(field => ['street-address','address-line1'].includes(field.kind) &&
            field.section === editedContact.section);
          if (address) {
            const sectionFields = fields.filter(field => field.section === address.section);
            const contact = collect(sectionFields,'contact');
            if (contact) {
              result.contact = contact;
              members.push(...sectionFields.filter(field => field.category === 'contact').map(field => field.element));
            }
          }
        }
        return Object.keys(result).length ? result : null;
      };
      const update = (record, group) => {
        if (!group?.safe || group.id !== record.id) return;
        const members = [];
        record.snapshot = snapshot(group,record.edited,members);
        record.members = members;
        record.fields = group.fields;
      };
      // A verification step (SMS, e-mail, push approval) can take minutes: once one has been shown, five instead of two.
      const expired = record => {
        const age = performance.now() - record.editedAt;
        if (age <= 120000) return false;
        record.verifying ||= forms.summary().challenges > 0;
        return age > (record.verifying ? 300000 : 120000);
      };
      const stage = (record, source) => {
        if (!record.snapshot || expired(record) || abandoned) return;
        if (!record.attemptID) {
          record.attemptID = crypto.randomUUID();
          record.attemptAt = performance.now();
          record.submitted = source === 'submit';
          post({action:'stage',attemptID:record.attemptID,formID:record.id,source,...record.snapshot});
          diagnose('submitCaptured');
        } else if (source === 'submit' && !record.submitted) {
          record.submitted = true;
          post({action:'stage',attemptID:record.attemptID,formID:record.id,source,...record.snapshot});
        }
      };
      const check = () => {
        if (document.hidden || abandoned) return;
        for (const record of records.values()) {
          const now = performance.now();
          if (expired(record)) { discard(record); continue; }
          if (!record.snapshot) continue;
          const relevant = record.fields.filter(field => record.snapshot.password ?
            ['current-password','new-password'].includes(field.kind) :
            record.snapshot.card ? field.category === 'card' :
            record.snapshot.contact ? field.category === 'contact' : field.kind === 'username');
          if (relevant.some(field => forms.present(field.element))) {
            if (record.snapshot.username && !record.snapshot.password && record.attemptID && forms.summary().passwords > 0) {
              post({action:'complete',attemptID:record.attemptID,formID:record.id,source:'username-step'});
              record.attemptID = null; record.submitted = false; record.snapshot = null; records.delete(record.id);
            } else record.absentAt = null;
            continue;
          }
          const state = forms.summary();
          const replaced = record.snapshot.password ? state.passwords > 0 || state.challenges > 0 :
            record.snapshot.card ? state.cards > 0 : record.snapshot.contact ? state.addresses > 0 : state.usernames > 0;
          if (replaced) { record.absentAt = null; continue; }
          if (!record.attemptID && now - record.editedAt > 10000) continue;
          record.absentAt ??= now;
          if (now - record.absentAt < 800) continue;
          stage(record,'automatic');
          if (record.attemptID) post({action:'complete',attemptID:record.attemptID,formID:record.id,source:'disappearance'});
          record.attemptID = null; record.submitted = false; record.snapshot = null; records.delete(record.id);
        }
        if (!records.size && timer !== null) { clearInterval(timer); timer = null; }
      };
      const noteEdit = event => {
        if (!event.isTrusted) return;
        observeRoots(event);
        const element = event.composedPath()[0], field = forms.field(element), group = forms.group(element);
        if (!field?.category || !group?.safe || !policy[field.category]) return;
        abandoned = false;
        if (field.category === 'password') diagnose('editRecorded');
        element.setAttribute('data-wsurf-' + (field.category === 'card' ? 'payment-card' : field.category),'');
        let record = records.get(group.id);
        if (!record) {
          if (records.size >= 12) discard(records.values().next().value);
          record = {id:group.id,root:group.root,edited:new Set(),fields:[],members:[],snapshot:null,attemptID:null,absentAt:null};
          records.set(group.id,record);
        } else if (record.attemptID) {
          post({action:'discard',attemptID:record.attemptID,formID:record.id});
          record.attemptID = null; record.submitted = false; record.absentAt = null;
        }
        record.editedAt = performance.now();
        if (record.edited.size < 100) record.edited.add(element);
        update(record,group);
        queueMicrotask(() => {
          if (records.get(record.id) === record && forms.rendered(element)) update(record,forms.group(element));
        });
        if (timer === null) timer = setInterval(check,400);
      };
      const attempt = (target, source, known) => {
        const group = forms.group(target);
        let record = known || group && records.get(group.id);
        if (!record && forms.isAction(target)) {
          for (const root of forms.ancestors(target)) {
            if (root === document.body || root === document.documentElement) break;
            const candidates = Array.from(records.values()).filter(value => forms.contains(root,value.root));
            if (candidates.length > 1) break;
            if (candidates.length === 1) { record = candidates[0]; break; }
          }
        }
        // Values an extension or the page filled count after a trusted submit or click in the same form. Only a
        // password counts for a plain click: a pre-filled address must not turn into an offer.
        if ((source === 'submit' || source === 'interaction') && group?.safe &&
            submitIntent?.root === group.root && performance.now() - submitIntent.at < 1500) {
          const populated = group.fields.filter(field => field.category && policy[field.category] &&
            (source === 'submit' || field.category === 'password') &&
            forms.rendered(field.element) && field.element.value.trim());
          if (populated.length) {
            abandoned = false;
            if (!record) {
              if (records.size >= 12) discard(records.values().next().value);
              record = {id:group.id,root:group.root,edited:new Set(),fields:group.fields,members:[],
                snapshot:null,attemptID:null,absentAt:null};
              records.set(group.id,record);
            }
            record.editedAt = performance.now();
            record.submitted = false;
            for (const field of populated) {
              record.edited.add(field.element);
              field.element.setAttribute('data-wsurf-' +
                (field.category === 'card' ? 'payment-card' : field.category),'');
            }
            if (timer === null) timer = setInterval(check,400);
          }
        }
        if (source === 'submit') submitIntent = null;
        if (!record || !forms.safe(record.root)) return;
        const seed = record.fields.find(field => forms.rendered(field.element))?.element;
        if (seed) update(record,forms.group(seed));
        // A captcha or terms box that is still empty must not block the save; only the fields it came from can.
        if (record.members.some(element => element.willValidate && !element.validity.valid)) {
          diagnose('submitInvalid'); return;
        }
        stage(record,source);
      };
      const submitted = event => {
        if (event.isTrusted) attempt(event.composedPath()[0],'submit');
      };
      const observeRoots = event => {
        for (const root of event.composedPath()) {
          if (!(root instanceof ShadowRoot) || observedRoots.has(root)) continue;
          observedRoots.add(root);
          root.addEventListener('submit',submitted,true);
          root.addEventListener('change',noteEdit,true);
        }
      };
      document.addEventListener('focusin',observeRoots,true);
      document.addEventListener('input',noteEdit,true);
      document.addEventListener('change',noteEdit,true);
      document.addEventListener('submit',submitted,true);
      document.addEventListener('reset',event => {
        const record = records.get(forms.group(event.composedPath()[0])?.id);
        if (record) discard(record);
      },true);
      const pressed = event => {
        if (!event.isTrusted || event.key !== 'Enter' || event.isComposing || event.repeat) return;
        const element = event.composedPath()[0];
        if (element instanceof HTMLInputElement && forms.field(element)?.category) {
          submitIntent = {root:forms.scope(element),at:performance.now()};
          attempt(element,'interaction');
        }
      };
      // A link that stays on this document ("#", a fragment, "javascript:") is a button, not a way out.
      const leaves = anchor => {
        try {
          const target = new URL(anchor.href,location.href), here = new URL(location.href);
          if (target.protocol === 'javascript:') return false;
          target.hash = here.hash = '';
          return target.href !== here.href;
        } catch { return true; }
      };
      const typing = el => el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement ||
        el instanceof HTMLLabelElement || el instanceof HTMLInputElement &&
        !['button','submit','image','reset'].includes(el.type);
      const clicked = event => {
        if (!event.isTrusted) return;
        const path = event.composedPath();
        if (path.some(el => el instanceof HTMLAnchorElement && el.href && leaves(el))) {
          abandoned = true; clear(); return;
        }
        const action = path.find(forms.isAction);
        if (action) {
          submitIntent = {root:forms.scope(action),at:performance.now()};
          attempt(action,'interaction');
          return;
        }
        // Any other click inside the one form being filled in (a styled div, a same-page link) is the button.
        const inner = path.find(el => el instanceof Element);
        if (!inner || !records.size || path.some(typing)) return;
        const inside = Array.from(records.values()).filter(record => forms.contains(record.root,inner));
        if (inside.length !== 1) return;
        submitIntent = {root:inside[0].root,at:performance.now()};
        attempt(inside[0].root,'interaction',inside[0]);
      };
      document.addEventListener('keydown',pressed,true);
      document.addEventListener('click',clicked,true);
      window.addEventListener('pagehide',() => {
        if (!abandoned) for (const record of records.values()) stage(record,'pagehide');
        records.clear();
        if (timer !== null) clearInterval(timer);
        timer = null;
      });
      window.addEventListener('pageshow',event => {
        if (event.persisted) { clear(); abandoned = false; ready(); }
      });
      forms.subscribe(check);
      const ready = () => post({action:'ready'});
      globalThis.__wsurfAutofillSave = {
        check,
        setPolicy(value) {
          const next = {password:value?.password === true,card:value?.card === true,contact:value?.contact === true};
          if (Object.keys(next).some(key => next[key] !== policy[key])) clear();
          policy = next;
        }
      };
      /*hooks*/
      ready();
      document.addEventListener('DOMContentLoaded',ready,{once:true});
    })();
    """#
}
