// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

nonisolated extension PageRuntime {
    /// Selector targeting, spliced into the runtime next to the other closure-private state it needs (`refIDs`,
    /// `foundOnly`, `refSignatures`). Every selector first passes `selectorProblem`, the same safe-subset check
    /// `findElements` and `readPage` use, so a selector cannot read an attribute value the runtime does not expose.
    static let targetScript = #"""
      // MARK: Targets named by selector
      const LISTED_CAP = 25;
      const listedControl = (el, kind) => !!kind && visible(el) && (!!labelOf(el, kind) || ['field', 'select', 'scrollarea'].includes(kind));

      // The one control a selector names. It is registered like a control readPage listed, so every later check that
      // applies to a ref (matchesRef, sensitive fields, disabled, covered) applies to it unchanged.
      const resolveTarget = (selector, kinds) => {
        const problem = selectorProblem(selector);
        if (problem) return { error: SELECTOR_ERRORS[problem] };
        let matched = 0;
        const controls = [];
        for (const el of deep(document)) {
          if (!el.matches(selector)) continue;
          matched++;
          const kind = kindOf(el);
          if (listedControl(el, kind) && controls.push({ el, kind }) > LISTED_CAP) break;
        }
        if (!matched) return { error: 'No element matches that selector.' };
        if (!controls.length) {
          return { error: 'The selector matches ' + matched + ' element(s), but none is a visible control that readPage lists. Use a selector for the control itself.' };
        }
        if (controls.length > 1) {
          return { error: 'The selector matches ' + (controls.length > LISTED_CAP ? 'more than ' + LISTED_CAP : controls.length)
            + ' controls. Narrow it to exactly one, for example with a data-testid.' };
        }
        const { el, kind } = controls[0];
        if (kinds && !kinds.includes(kind)) return { error: 'The selector matches a ' + kind + ', which this tool cannot use.' };
        if (isSensitiveField(el)) return { error: 'The user must interact with sensitive fields.' };
        let ref = refIDs.get(el);
        if (!ref) { ref = window.__wsurfRefs.push(el); refIDs.set(el, ref); }
        foundOnly.delete(el);
        el.__wsurfRef = ref;
        refSignatures.set(ref, signature(el));
        // The page's current observation id stays as it is, so an observation the client holds is not invalidated.
        window.__wsurfSnapshot = window.__wsurfSnapshot || (Date.now().toString(36) + Math.random().toString(36));
        return { ref, snapshot: window.__wsurfSnapshot, document: documentID, url: location.href };
      };

      // MARK: Drag
      // One end of a drag: a control ref readPage listed, or the single visible element a selector names. A drop zone is
      // rarely a control, so a selector end is not held to what readPage lists.
      const dragEndpoint = (spec, role) => {
        if (spec.ref) {
          if (!matchesRef(spec.ref)) return { stale: true };
          return { el: window.__wsurfRefs[spec.ref - 1] };
        }
        const problem = selectorProblem(spec.selector);
        if (problem) return { error: SELECTOR_ERRORS[problem] };
        let matched = 0;
        const shown = [];
        for (const candidate of deep(document)) {
          if (!candidate.matches(spec.selector)) continue;
          matched++;
          if (visible(candidate) && shown.push(candidate) > 1) break;
        }
        if (!matched) return { error: 'No element matches the ' + role + ' selector.' };
        if (!shown.length) return { error: 'The ' + role + ' selector matches only hidden elements.' };
        if (shown.length > 1) return { error: 'The ' + role + ' selector matches more than one visible element. Narrow it to exactly one.' };
        return { el: shown[0] };
      };

      const dragRefusal = (el, role) => {
        if (!el?.isConnected || !visible(el)) return 'The ' + role + ' is hidden or gone.';
        if (el.ownerDocument !== document) return 'Drag is not available inside a frame.';
        if (['IFRAME', 'FRAME'].includes(el.tagName)) return 'A frame cannot be dragged or dropped on.';
        if (isSensitiveField(el)) return 'The user must interact with sensitive fields.';
        if (disabled(el)) return 'The ' + role + ' is disabled.';
        if (el.tagName === 'INPUT' && el.type === 'file') return 'File inputs take part in no drag.';
        return '';
      };

      const topmost = ([x, y]) => {
        let el = document.elementFromPoint(x, y);
        for (let i = 0; i < 30 && el?.shadowRoot; i++) {
          const child = el.shadowRoot.elementFromPoint(x, y);
          if (!child || child === el) break;
          el = child;
        }
        return el;
      };
      const within = (hit, el) => { for (let n = hit; n; n = n.parentNode || n.host) if (n === el) return true; return false; };

      const describeEnd = el => {
        const kind = kindOf(el) || 'button';
        const form = el.form || (el.closest && el.closest('form'));
        return { label: labelOf(el, kind), context: norm([
          el.getAttribute && el.getAttribute('aria-label'), el.title, el.name, el.getAttribute && el.getAttribute('data-action'),
          form && form.getAttribute('action'), form && form.getAttribute('aria-label'), form && form.innerText
        ].filter(Boolean).join(' ')).slice(0, 800) };
      };

      // Where a drag starts and ends, in viewport CSS pixels, and who is there. The elements are kept so the dispatch can
      // confirm that the same ones are still under those points.
      const dragPlan = (from, to, dx, dy) => {
        const source = dragEndpoint(from, 'source');
        if (!source.el) return source;
        let problem = dragRefusal(source.el, 'drag source');
        if (problem) return { error: problem };
        source.el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
        const centre = el => { const r = el.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; };
        const inside = ([x, y]) => x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight;
        const start = centre(source.el);
        if (!inside(start) || !within(topmost(start), source.el)) return { error: 'The drag source is offscreen or covered by another element.' };
        let target = null, end;
        if (to) {
          target = dragEndpoint(to, 'target');
          if (!target.el) return target;
          problem = dragRefusal(target.el, 'drop target');
          if (problem) return { error: problem };
          end = centre(target.el);
          if (!inside(end)) return { error: 'The drop target is outside the viewport. Scroll so both ends are visible, or use dx and dy.' };
          if (!within(topmost(end), target.el)) return { error: 'The drop target is covered by another element.' };
        } else {
          end = [start[0] + dx, start[1] + dy];
          if (!inside(end)) return { error: 'The drop point is outside the viewport.' };
          const landing = topmost(end);
          if (!landing) return { error: 'Nothing is at the drop point.' };
          problem = dragRefusal(landing, 'drop point');
          if (problem) return { error: problem };
          target = { el: landing };
        }
        window.__wsurfDragTargets = { from: source.el, to: target.el };
        const selection = window.getSelection();
        const nativeDrag = !!source.el.closest('[draggable=true], img, a[href]')
          || (!!selection && !selection.isCollapsed && selection.containsNode(source.el, true));
        return { from: { x: start[0], y: start[1], ...describeEnd(source.el) }, to: { x: end[0], y: end[1], ...describeEnd(target.el) }, nativeDrag };
      };
      // The elements a drag was planned against are still the ones under its first and last points.
      const dragHolds = (first, last) => {
        const kept = window.__wsurfDragTargets;
        window.__wsurfDragTargets = null;
        return !!kept && within(topmost(first), kept.from) && within(topmost(last), kept.to);
      };
    """#
}

extension PageDriver {
    /// The page's single control that a selector names, registered as a ref the usual checks accept.
    struct ControlTarget: Equatable {
        let ref: Int
        let observationID: String
        let documentID: String
        let url: String
    }

    struct TargetFailure: Error, Equatable {
        let message: String
    }

    /// `kinds` are the control kinds the calling tool can act on (all when nil). Only the live document is searched.
    static func resolveControl(selector: String, kinds: [String]?, in view: BrowserPage) async -> Result<ControlTarget, TargetFailure> {
        switch PageRuntime.validate(selector: selector) {
        case .success:
            break
        case .failure(.invalid):
            return .failure(.init(message: "Invalid selector."))
        case .failure(.empty), .failure(.tooLong):
            return .failure(.init(message: "The selector must be 1 to \(PageRuntime.maxSelectorBytes) UTF-8 bytes."))
        }
        let kindList = (kinds.flatMap { try? JSONEncoder().encode($0) }).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        guard let encoded = jsonString(selector),
            let object = await evaluateJSON(scripted("return JSON.stringify(R.resolveTarget(\(encoded), \(kindList)));"), in: view)
        else { return .failure(.init(message: "The page did not respond. Try again after it finishes loading.")) }
        if let error = object["error"] as? String { return .failure(.init(message: error)) }
        guard object["stale"] == nil, let ref = object["ref"] as? Int, let snapshot = object["snapshot"] as? String,
            let documentID = object["document"] as? String, let url = object["url"] as? String
        else { return .failure(.init(message: staleMessage)) }
        // The control joins the observation the client already holds, so refs it was given stay usable beside it.
        let prior = observation(in: view)
        let kept = prior.flatMap { $0.id == snapshot && $0.documentID == documentID ? $0.refs : nil } ?? []
        observations.setObject(
            PageObservation(id: snapshot, documentID: documentID, url: url, refs: kept.union([ref])), forKey: view)
        return .success(ControlTarget(ref: ref, observationID: snapshot, documentID: documentID, url: url))
    }
}
