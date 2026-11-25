// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import WebKit

extension PageDriver {
    nonisolated struct FieldValue: Codable, Equatable, Sendable {
        let ref: Int
        let value: String
        let select: Bool
    }

    private static let batchChanged = "The page changed or access ended. Read fresh controls before continuing."

    /// Fills up to 32 fields in few rounds to the page: one inspects every field (and `submitRef`), one per field checks the page
    /// and writes it, one verifies every value, and the page settles once. Between two writes nothing else runs on the page, and
    /// the batch stops as soon as the call is cancelled, its access ends, the page navigates, or the page's text or controls
    /// change (a validation message appeared): the remaining fields are left as they were.
    ///
    /// - Parameters:
    ///   - secretRefs: The refs whose values are test secrets, typed even into a sensitive text field (see `type`'s
    ///     `allowSensitive`). Every other field keeps the sensitive-field refusal.
    ///   - secretWritten: See `type`.
    ///   - submitRef: A control to click once every field was filled and verified, with the approval a click on it needs.
    ///   - submit: Submit the form of the last text field (Enter), with the approval typing with `submit` needs.
    static func fillFields(
        _ fields: [FieldValue], secretRefs: Set<Int> = [], secretWritten: ((SecretWrite) -> Void)? = nil, submitRef: Int? = nil,
        submit: Bool = false, in webView: BrowserPage, announced: Bool = false
    ) async -> String {
        guard (1...32).contains(fields.count), fields.allSatisfy({ $0.ref > 0 }),
            Set(fields.map(\.ref)).count == fields.count
        else {
            return "Use one to 32 distinct positive field refs from the latest page observation."
        }
        guard secretRefs.isEmpty || selectedFrame == nil else { return secretInFrameMessage }
        guard await canContinueBatch(fields[0].ref, in: webView), let observed = observation(in: webView) else {
            return await referenceFailureMessage(ref: fields[0].ref, in: webView)
        }
        guard let inspected = await inspectBatch(fields.map(\.ref) + (submitRef.map { [$0] } ?? []), in: webView) else {
            return await referenceFailureMessage(ref: fields[0].ref, in: webView)
        }
        if announced {
            await announce(ref: fields[0].ref, in: webView, pause: true)
        }
        var written: [FieldValue] = []
        var details: [String] = []
        for field in fields {
            guard batchMayContinue(in: webView) else {
                details.append(batchChanged)
                break
            }
            guard observation(in: webView)?.refs.contains(field.ref) == true, let control = inspected[field.ref], control["stale"] == nil else {
                details.append(await referenceFailureMessage(ref: field.ref, in: webView, otherwise: batchChanged))
                break
            }
            let secret = secretRefs.contains(field.ref)
            if let reason = fillRejection(for: control, secret: secret) {
                details.append("[\(field.ref)] skipped: \(reason)")
                continue
            }
            let outcome = await fillOne(field, control: control, secret: secret, observed: observed, secretWritten: secretWritten, in: webView)
            switch outcome {
            case .written:
                written.append(field)
            case .notFilled(let reason):
                details.append("[\(field.ref)] not filled: \(reason)")
            case .changed:
                details.append(batchChanged)
            }
            if case .changed = outcome {
                break
            }
        }
        if await canContinueBatch(fields[0].ref, in: webView) {
            await PageSettle.afterInteraction(webView)
        }
        let verified = await verifyBatch(written, secretRefs: secretRefs, documentID: observed.documentID, details: &details, in: webView)
        if !verified.isEmpty {
            details.insert("Verified refs: " + verified.map { "[\($0)]" }.joined(separator: ", ") + ".", at: 0)
        }
        if submitRef != nil || submit {
            let complete = verified.count == fields.count
            details.append(
                await submitBatch(
                    submitRef: submitRef, lastField: written.last { inspected[$0.ref]?["kind"] as? String == "field" }, inspected: inspected,
                    complete: complete, in: webView))
        }
        let snapshot = await batchSnapshot(firstRef: fields[0].ref, in: webView)
        return "Filled \(verified.count) of \(fields.count) fields. " + details.joined(separator: "\n") + "\n" + snapshot
    }

    private enum FillOutcome {
        case written, notFilled(String), changed
    }

    /// Cancellation, access and loading, checked without asking the page.
    private static func batchMayContinue(in webView: BrowserPage) -> Bool {
        !Task.isCancelled && PageAutomationGuard.allowsExecution && !webView.isLoading && !webView.isClosed
    }

    /// One field: the approval a checkbox's label needs, then a round that checks the page is as it was and writes.
    private static func fillOne(
        _ field: FieldValue, control: [String: Any], secret: Bool, observed: PageObservation,
        secretWritten: ((SecretWrite) -> Void)?, in webView: BrowserPage
    ) async -> FillOutcome {
        let kind = control["kind"] as? String
        var checked: Bool?
        if kind == "checkbox" || kind == "radio" {
            guard let wanted = Bool(field.value.lowercased()) else { return .notFilled("use true or false for a checked state.") }
            checked = wanted
            let label = control["label"] as? String ?? ""
            if control["checked"] as? Bool != wanted, let category = SensitiveAction.category(of: label, context: control["context"] as? String ?? "") {
                let permitted = await AgentActionConsent.permit(
                    label: label, category: category, host: (selectedFrame?.url ?? webView.url)?.host(),
                    authoredByAI: AgentAuthoredText.isPresent(in: webView), policy: webView.context.actionPolicy)
                guard permitted else { return .notFilled(SensitiveAction.declined(label, category: category)) }
                guard batchMayContinue(in: webView) else { return .changed }
            }
        } else if kind != "select", field.select {
            return .notFilled("select is only valid for a dropdown.")
        }
        guard let result = await writeField(field, kind: kind, checked: checked, secret: secret, observed: observed, in: webView) else {
            return batchMayContinue(in: webView) ? .notFilled(staleMessage) : .changed
        }
        if result["changed"] as? Bool == true {
            return .changed
        }
        if secret, let stored = result["stored"] as? String {
            secretWritten?(
                SecretWrite(typed: field.value, stored: stored, isSensitiveField: result["sensitive"] as? Bool == true, retained: result["retained"] as? Bool == true))
        }
        if let error = result["error"] as? String {
            return .notFilled(error)
        }
        if result["unavailable"] as? Bool == true {
            return .notFilled("The field is disabled or read-only. Read the page for available controls.")
        }
        if result["refused"] as? Bool == true {
            return .notFilled("sensitive field; the user must fill it. Do not retry with another tool.")
        }
        if let options = result["options"] as? [String] {
            return .notFilled(
                PageOutputBudget.prefix(
                    "No option matches “\(field.value)”. Options: \(options.joined(separator: " | "))", fitting: outputBudget.totalCharacters - 100))
        }
        guard result["ok"] as? Bool == true else { return .notFilled(staleMessage) }
        if kind != "select", kind != "checkbox", kind != "radio" {
            AgentAuthoredText.record(in: webView)
        }
        if secret, result["retained"] as? Bool != true {
            return .notFilled("The page did not retain the requested value. Inspect validation messages before retrying.")
        }
        return .written
    }

    // MARK: Rounds

    /// The page's text outside fields and the markup of its registered controls without their values: what a validation
    /// message or a re-rendered form changes, and typing into a field does not.
    private static let batchStateFunction = """
        const batchState = () => {
          const textOutsideFields = doc => {
            if (!doc.body) return '';
            const parts = [];
            const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
            let node;
            while ((node = walker.nextNode())) {
              const parent = node.parentElement;
              if (!parent || parent.isContentEditable || parent.closest('textarea,script,style,noscript')) continue;
              if (!parent.getClientRects().length || (parent.checkVisibility && !parent.checkVisibility())) continue;
              parts.push(node.textContent);
            }
            return R.norm(parts.join(' '));
          };
          const markupWithoutValues = el => {
            const copy = el.cloneNode(true);
            if (el.isContentEditable || el.tagName === 'TEXTAREA') copy.replaceChildren();
            for (const field of copy.querySelectorAll('textarea,[contenteditable]:not([contenteditable="false"])')) field.replaceChildren();
            const omitCheckedValue = field => {
              const kind = R.kindOf(field);
              if (kind !== 'checkbox' && kind !== 'radio') return;
              field.removeAttribute('checked');
              field.removeAttribute('aria-checked');
            };
            omitCheckedValue(copy);
            copy.querySelectorAll('[checked],[aria-checked]').forEach(omitCheckedValue);
            const omitAutofillMarkers = field => {
              field.removeAttribute('data-wsurf-contact');
              field.removeAttribute('data-wsurf-autofilled');
              field.removeAttribute('data-wsurf-password');
            };
            omitAutofillMarkers(copy);
            copy.querySelectorAll('[data-wsurf-contact],[data-wsurf-autofilled],[data-wsurf-password]').forEach(omitAutofillMarkers);
            return copy.outerHTML.replace(/value="[^"]*"/g, '');
          };
          let text = textOutsideFields(document);
          for (const frame of document.querySelectorAll('iframe')) {
            try { if (frame.contentDocument) text += ' ' + textOutsideFields(frame.contentDocument); } catch (e) {}
          }
          return JSON.stringify({ snapshot: window.__wsurfSnapshot, url: location.href, document: R.documentID,
            text, refs: (window.__wsurfRefs || []).map(el => [el.isConnected, el.disabled, R.kindOf(el), el.name, el.id, markupWithoutValues(el)]) });
        };
        """

    /// Every ref's kind, state, label and context, and the page's state for the writes to compare with. Nil when the page did
    /// not answer.
    private static func inspectBatch(_ refs: [Int], in webView: BrowserPage) async -> [Int: [String: Any]]? {
        let list = refs.map(String.init).joined(separator: ",")
        guard let object = await evaluateJSON(scripted("""
            \(batchStateFunction)
            const out = {};
            for (const ref of [\(list)]) {
              const el = window.__wsurfRefs[ref - 1];
              if (!el?.isConnected || !R.matchesRef(ref)) { out[ref] = { stale: true }; continue; }
              const kind = R.kindOf(el);
              const form = el.form || el.closest?.('form');
              out[ref] = { kind, type: (el.type || '').toLowerCase(), sensitive: R.isSensitiveSecret(el),
                unavailable: R.disabled(el) || !!el.readOnly || el.getAttribute('aria-readonly') === 'true',
                checked: el.checked ?? (el.getAttribute('aria-checked') === 'true'), label: R.labelOf(el, kind || 'button'),
                context: R.norm([el.getAttribute('aria-label'), el.title, el.name, el.getAttribute('data-action'), el.getAttribute('formaction'),
                  el.getAttribute('onclick'), form?.getAttribute('action'), form?.getAttribute('aria-label'), form?.innerText]
                  .filter(Boolean).join(' ')).slice(0, 800) };
            }
            window.__wsurfBatch = batchState();
            return JSON.stringify({ fields: out });
            """), in: webView), let found = object["fields"] as? [String: [String: Any]]
        else { return nil }
        return Dictionary(uniqueKeysWithValues: found.compactMap { key, value in Int(key).map { ($0, value) } })
    }

    /// The round that writes one field, after checking that the document, the observation and the page's state are the ones the
    /// batch started on. The checks and the write are those of `type`, `selectOption` and `setChecked`.
    private static func writeField(
        _ field: FieldValue, kind: String?, checked: Bool?, secret: Bool, observed: PageObservation, in webView: BrowserPage
    ) async -> [String: Any]? {
        guard let value = jsonString(field.value), let document = jsonString(observed.documentID), let snapshot = jsonString(observed.id),
            let url = jsonString(observed.url)
        else { return ["error": "Could not encode the input."] }
        let write: String
        switch kind {
        case "checkbox", "radio":
            write = """
                if (R.isSensitiveSecret(el)) return JSON.stringify({ error: 'The user must fill this sensitive field. Do not retry with another tool.' });
                const want = \(checked ?? false);
                R.expectValue(el, want);
                if ((el.checked ?? (el.getAttribute('aria-checked') === 'true')) === want) return JSON.stringify({ ok: true });
                if (kind === 'radio' && !want) return JSON.stringify({ error: 'Choose another radio option to change the selection.' });
                const error = R.actionable(el);
                if (error) return JSON.stringify({ error });
                if (el.readOnly || el.getAttribute('aria-readonly') === 'true') return JSON.stringify({ error: 'This control is read-only.' });
                el.click();
                return JSON.stringify({ ok: true });
                """
        case "select":
            write = """
                if (el.tagName !== 'SELECT') return JSON.stringify({ changed: true });
                if (R.isSensitiveSecret(el)) return JSON.stringify({ refused: true });
                const error = R.actionable(el);
                if (error) return JSON.stringify({ error });
                if (el.readOnly || el.getAttribute('aria-readonly') === 'true') return JSON.stringify({ error: 'This control is read-only.' });
                const want = R.norm(value).toLowerCase();
                const options = Array.from(el.options);
                let matches = options.filter(o => R.norm(o.value).toLowerCase() === want);
                if (!matches.length) matches = options.filter(o => R.norm(o.text).toLowerCase() === want);
                if (!matches.length) matches = options.filter(o => R.norm(o.text).toLowerCase().includes(want));
                if (matches.length > 1) return JSON.stringify({ error: 'Several options match. Inspect the control and use an exact value or label.' });
                const match = matches[0];
                if (!match) return JSON.stringify({ options: options.slice(0, 8).map(o => R.norm(o.text).slice(0, 60)) });
                if (match.disabled || match.closest('optgroup[disabled]')) return JSON.stringify({ error: 'That option is disabled.' });
                R.expectValue(el, match.value);
                for (const o of options) { o.selected = false; }
                match.selected = true;
                el.value = match.value;
                el.removeAttribute('data-wsurf-contact');
                el.removeAttribute('data-wsurf-autofilled');
                const view = (el.ownerDocument && el.ownerDocument.defaultView) || window;
                el.dispatchEvent(new (view.Event)('input', { bubbles: true }));
                el.dispatchEvent(new (view.Event)('change', { bubbles: true }));
                return JSON.stringify({ ok: true });
                """
        default:
            write = """
                const secret = \(secret);
                if (secret && el.ownerDocument !== document) return JSON.stringify({ error: \(jsonString(secretInFrameMessage) ?? "''") });
                const sensitive = R.isSensitiveSecret(el);
                if (!secret && sensitive) return JSON.stringify({ refused: true });
                if (R.disabled(el) || el.readOnly || el.getAttribute('aria-readonly') === 'true') return JSON.stringify({ unavailable: true });
                if (!['INPUT','TEXTAREA'].includes(el.tagName) && !el.isContentEditable) return JSON.stringify({ error: 'This control is not directly editable. Use click or keyboard controls.' });
                if (el.tagName === 'INPUT' && ['file','hidden','checkbox','radio','button','submit'].includes(el.type)) {
                  return JSON.stringify({ error: el.type === 'file' ? 'Use chooseFilesOnPage; file selection requires the user.'
                    : 'Use fillFields or setChecked for checkbox and radio controls; this input cannot accept text.' });
                }
                let text = value;
                if (el.type === 'color') {
                  if (!/^#[0-9a-f]{6}$/i.test(text)) return JSON.stringify({ error: 'Use a color in #RRGGBB format.' });
                  text = text.toLowerCase();
                }
                if (el.type === 'date' || el.type === 'range') {
                  const probe = el.cloneNode(false);
                  probe.value = text;
                  const numeric = el.type !== 'range' || (text.trim() && Number.isFinite(Number(text)) && Number(probe.value) === Number(text));
                  if ((text && !probe.value) || !probe.validity.valid || !numeric) {
                    return JSON.stringify({ error: el.type === 'date'
                      ? 'Use a valid date within the control min, max, and step constraints. Inspect the control before retrying.'
                      : 'Use a numeric value within the range min, max, and step constraints. Inspect the control before retrying.' });
                  }
                  text = probe.value;
                }
                const error = R.actionable(el);
                if (error) return JSON.stringify({ error });
                if (!secret) R.expectValue(el, text);
                R.setValue(el, text);
                if (!secret) { el.removeAttribute('data-wsurf-contact'); el.removeAttribute('data-wsurf-autofilled'); }
                if (secret) {
                  const stored = el.isContentEditable ? el.textContent : el.value;
                  return JSON.stringify({ ok: true, stored, sensitive, retained: stored === text });
                }
                return JSON.stringify({ ok: true });
                """
        }
        let script = scripted("""
            \(batchStateFunction)
            if (R.documentID !== \(document) || window.__wsurfSnapshot !== \(snapshot) || location.href !== \(url)
              || batchState() !== window.__wsurfBatch) return JSON.stringify({ changed: true });
            const el = window.__wsurfRefs[\(field.ref) - 1];
            if (!el?.isConnected || !R.matchesRef(\(field.ref))) return JSON.stringify({ changed: true });
            const kind = R.kindOf(el), value = \(value);
            \(write)
            """)
        return await evaluateJSON(script, userGesture: true, in: webView)
    }

    /// The written fields whose values the page kept, in one round; a secret was checked where it was typed, since the runtime
    /// never reads a sensitive field back.
    private static func verifyBatch(
        _ written: [FieldValue], secretRefs: Set<Int>, documentID: String, details: inout [String], in webView: BrowserPage
    ) async -> [Int] {
        guard !written.isEmpty, await canContinueBatch(written[0].ref, in: webView), let encoded = jsonString(documentID) else { return [] }
        let checked = written.filter { !secretRefs.contains($0.ref) }.map(\.ref)
        var states: [String: Any] = [:]
        if !checked.isEmpty {
            states = await evaluateJSON(scripted("""
                if (R.documentID !== \(encoded)) return JSON.stringify({});
                const out = {};
                for (const ref of [\(checked.map(String.init).joined(separator: ","))]) out[ref] = R.valueState(ref);
                return JSON.stringify(out);
                """), in: webView) ?? [:]
        }
        guard batchMayContinue(in: webView) else { return [] }
        var verified: [Int] = []
        for field in written {
            if secretRefs.contains(field.ref) || states[String(field.ref)] as? String == "matched" {
                verified.append(field.ref)
            } else {
                details.append("[\(field.ref)] not verified: the value changed or the control is no longer available.")
            }
        }
        return verified
    }

    /// Clicks `submitRef`, or presses Enter in `lastField`, once every field was verified; a consequential label needs the same
    /// approval a click or a submitting type would.
    private static func submitBatch(
        submitRef: Int?, lastField: FieldValue?, inspected: [Int: [String: Any]], complete: Bool, in webView: BrowserPage
    ) async -> String {
        guard complete else { return "Not submitted: not every field was filled and verified." }
        guard let ref = submitRef ?? lastField?.ref, let control = inspected[ref], control["stale"] == nil,
            batchMayContinue(in: webView), await validateObservation(in: webView, ref: ref)
        else { return "Not submitted: " + staleMessage }
        let label = control["label"] as? String ?? ""
        if let category = SensitiveAction.category(of: label, context: control["context"] as? String ?? "") {
            let permitted = await AgentActionConsent.permit(
                label: label, category: category, host: (selectedFrame?.url ?? webView.url)?.host(),
                authoredByAI: true, policy: webView.context.actionPolicy)
            guard permitted else { return "Not submitted: " + SensitiveAction.declined(label, category: category) }
            guard batchMayContinue(in: webView) else { return "Not submitted: " + staleMessage }
        }
        let action = submitRef != nil
            ? """
              if (R.disabled(el)) return JSON.stringify({ error: 'The control is disabled.' });
              if (el.tagName === 'INPUT' && (el.type || '').toLowerCase() === 'file') return JSON.stringify({ error: 'File selection requires the user.' });
              const error = R.actionable(el);
              if (error) return JSON.stringify({ error });
              el.click();
              """
            : "R.pressEnter(el);"
        let script = scripted("""
            const el = window.__wsurfRefs[\(ref) - 1];
            if (!el?.isConnected || !R.matchesRef(\(ref))) return JSON.stringify({ stale: true });
            \(action)
            return JSON.stringify({ ok: true });
            """)
        guard let answer = await evaluateAction(script, fallback: ["ok": true], in: webView) else { return "Not submitted: the page did not respond." }
        if let error = answer["error"] as? String {
            return "Not submitted: " + error
        }
        guard answer["ok"] as? Bool == true else { return "Not submitted: " + staleMessage }
        await PageSettle.afterInteraction(webView)
        return submitRef != nil ? "Submitted with “\(label)”." : "Submitted the form of “\(label)” (Enter)."
    }

    /// The page after a batch, unless the connection gets a change report instead or the page or access changed meanwhile.
    private static func batchSnapshot(firstRef: Int, in webView: BrowserPage) async -> String {
        if feedbackMode == .delta {
            return ""
        }
        let changed = "The page changed or access ended; read the current page before continuing."
        guard PageAutomationGuard.allowsExecution, !Task.isCancelled else { return changed }
        let observationBeforeSnapshot = observation(in: webView)?.documentID
        let refreshed = await Self.snapshot(webView)
        return observation(in: webView)?.documentID == observationBeforeSnapshot ? refreshed : changed
    }

    private static func fillRejection(for control: [String: Any], secret: Bool) -> String? {
        if secret, ["checkbox", "radio", "select"].contains(control["kind"] as? String) {
            return "a secret is typed text; this control takes a choice, not a secret."
        }
        if control["sensitive"] as? Bool == true, !secret {
            return "sensitive field; the user must fill it. Do not retry with another tool."
        }
        if control["type"] as? String == "file" {
            return "use chooseFilesOnPage; file selection requires the user."
        }
        if control["unavailable"] as? Bool == true {
            return "disabled or read-only."
        }
        return nil
    }

    private static func canContinueBatch(_ ref: Int, in webView: BrowserPage) async -> Bool {
        guard batchMayContinue(in: webView), await validateObservation(in: webView, ref: ref > 0 ? ref : nil) else { return false }
        return batchMayContinue(in: webView)
    }
}
