// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

nonisolated extension PageRuntime {
    /// Spliced into the runtime, where it shares the helpers (`collect`, `visible`, `norm`, `clip`...) it is written against.
    static let feedbackScript = #"""
      // MARK: Action feedback: digest, quiet wait, condition wait
      // A digest is the compact state of the page around an action (controls, viewport text, focus, scroll). The Swift side
      // diffs two of them; nothing here is sent to a client. Controls are read-only unless `commit` makes it an observation.

      // Every visible text node of the page, so scrolling the target into view does not change the set; a scroll asks for the
      // viewport alone. The first `limit` blocks in document order are read: a change beyond them is not seen.
      const textBlocks = (limit, viewportOnly) => {
        const out = [];
        const visit = root => {
          if (!root || out.length >= limit) return;
          const doc = root.ownerDocument || document;
          const walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
          let node;
          while (out.length < limit && (node = walker.nextNode())) {
            const el = node.parentElement;
            if (!el || el.closest('script,style,noscript,template') || !visible(el) || (viewportOnly && !inViewport(el))) continue;
            const field = el.closest('textarea,input,[contenteditable],[role=textbox],[role=searchbox]');
            if (field && isSensitiveField(field)) continue;
            const t = norm(node.textContent);
            if (t) out.push(clip(t, 160));
          }
          for (const el of root.querySelectorAll('*')) {
            if (el.shadowRoot) visit(el.shadowRoot);
            if (el.tagName === 'IFRAME') { try { visit(el.contentDocument?.body); } catch (e) {} }
          }
        };
        visit(document.body);
        return out;
      };

      const focusOf = () => {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        if (!el || el === document.body || el === document.documentElement) return null;
        const kind = kindOf(el);
        return { r: refIDs.get(el) || 0, k: kind || el.tagName.toLowerCase(), l: kind ? labelOf(el, kind) : '' };
      };

      // A committed digest also carries each control's signature hash (`sg`), for the controls a reply lists to be acknowledged.
      const digest = (viewportOnly, commit) => {
        const all = collect(commit);
        const controls = (viewportOnly ? all.filter(c => c.vp) : all).slice(0, 400);
        if (commit) {
          for (const c of controls) {
            const el = c.r ? window.__wsurfRefs[c.r - 1] : null;
            if (el) c.sg = sigHash(signature(el));
          }
        }
        const root = document.scrollingElement || document.documentElement;
        return { document: documentID, url: location.href, title: clip(document.title, 120), snapshot: window.__wsurfSnapshot,
          controls, controlTotal: all.length, texts: document.body ? textBlocks(600, viewportOnly) : [], focus: focusOf(),
          scroll: { y: Math.round(root.scrollTop), h: root.scrollHeight, vh: window.innerHeight } };
      };

      // The highlight ring animates for a second after an action; its own changes are not the page settling.
      const ringNoise = record => {
        const ring = n => n.nodeType === 1 && n.classList.contains('__wsurf-ring');
        if (ring(record.target)) return true;
        return record.type === 'childList' && [...record.addedNodes, ...record.removedNodes].every(ring);
      };

      // Resolves with a JSON string once `check()` reports a match or an error, the document is being left, or `ceiling` ms
      // pass. DOM mutations re-run the check (debounced); a 250 ms in-page timer covers a change no mutation announces
      // (a pushState, a stylesheet transition). Nothing crosses back to the host until it resolves.
      const waitFor = (check, ceiling) => new Promise(resolve => {
        const start = performance.now();
        let done = false, pending = null, observer = null, safety = null, cap = null;
        const finish = result => {
          if (done) return;
          done = true;
          observer?.disconnect();
          clearTimeout(pending); clearInterval(safety); clearTimeout(cap);
          window.removeEventListener('pagehide', onHide);
          window.removeEventListener('popstate', schedule);
          window.removeEventListener('hashchange', schedule);
          result.ms = Math.round(performance.now() - start);
          result.document = documentID;
          resolve(JSON.stringify(result));
        };
        const run = () => {
          if (done) return;
          let state;
          try { state = check(); } catch (e) { finish({ error: 'The condition could not be evaluated.' }); return; }
          if (state.error) finish({ error: state.error });
          else if (state.matches) finish({ matches: true });
        };
        const schedule = () => { clearTimeout(pending); pending = setTimeout(run, 30); };
        const onHide = () => finish({ unloading: true });
        run();
        if (done) return;
        observer = new MutationObserver(records => { if (!records.every(ringNoise)) schedule(); });
        observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
        window.addEventListener('pagehide', onHide, { once: true });
        window.addEventListener('popstate', schedule);
        window.addEventListener('hashchange', schedule);
        safety = setInterval(run, 250);
        cap = setTimeout(() => finish({ timedOut: true }), ceiling);
      });
"""#
}
