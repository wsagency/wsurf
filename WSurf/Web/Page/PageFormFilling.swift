// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

extension PageDriver {
    nonisolated struct FieldValue: Codable, Equatable, Sendable {
        let ref: Int
        let value: String
        let select: Bool
    }

    static func fillFields(_ fields: [FieldValue], in webView: BrowserPage, announced: Bool = false) async -> String {
        guard (1...32).contains(fields.count), fields.allSatisfy({ $0.ref > 0 }),
            Set(fields.map(\.ref)).count == fields.count
        else {
            return "Use one to 32 distinct positive field refs from the latest page observation."
        }
        guard let initial = await batchState(in: webView), await canContinueBatch(fields.first?.ref ?? 0, in: webView),
            let documentID = observation(in: webView)?.documentID
        else { return staleMessage }

        var written: [FieldValue] = []
        var details: [String] = []
        for (index, field) in fields.enumerated() {
            guard await canContinueBatch(field.ref, in: webView),
                await batchState(in: webView) == initial,
                await canContinueBatch(field.ref, in: webView)
            else {
                details.append("The page changed or access ended. Read fresh controls before continuing.")
                break
            }
            guard let control = await evaluateJSON(scripted("""
                const el = window.__wsurfRefs[\(field.ref) - 1];
                return JSON.stringify({ kind: R.kindOf(el), type: (el.type || '').toLowerCase(),
                  sensitive: R.isSensitiveField(el), unavailable: R.disabled(el) || !!el.readOnly
                    || el.getAttribute('aria-readonly') === 'true' });
                """), in: webView), await canContinueBatch(field.ref, in: webView)
            else {
                details.append("[\(field.ref)] could not be inspected because the page or access changed.")
                break
            }
            if let reason = fillRejection(for: control) {
                details.append("[\(field.ref)] skipped: \(reason)")
                continue
            }

            let kind = control["kind"] as? String
            let result: String
            if kind == "checkbox" || kind == "radio" {
                guard let checked = Bool(field.value.lowercased()) else {
                    details.append("[\(field.ref)] not filled: use true or false for a checked state.")
                    continue
                }
                result = await setChecked(ref: field.ref, checked: checked, in: webView,
                                          announced: announced && index == 0, refreshControls: false)
            } else if kind == "select" {
                result = await selectOption(field.value, ref: field.ref, field: "", in: webView,
                                            announced: announced && index == 0, refreshControls: false)
            } else if field.select {
                details.append("[\(field.ref)] not filled: select is only valid for a dropdown.")
                continue
            } else {
                result = await type(text: field.value, intoField: "", ref: field.ref, submit: false,
                                    in: webView, announced: announced && index == 0, refreshControls: false)
            }
            if ["Typed", "Selected", "Set checked", "Checked state already"].contains(where: result.hasPrefix) {
                written.append(field)
            } else {
                details.append("[\(field.ref)] not filled: \(result)")
            }
            guard await canContinueBatch(field.ref, in: webView) else {
                details.append("The page changed or access ended. Read fresh controls before continuing.")
                break
            }
        }

        if await canContinueBatch(fields.first?.ref ?? 0, in: webView) {
            await PageSettle.afterInteraction(webView)
        }
        var verified: [Int] = []
        for field in written {
            guard await canContinueBatch(field.ref, in: webView) else { break }
            let state = await valueState(ref: field.ref, documentID: documentID, in: webView)
            guard await canContinueBatch(field.ref, in: webView) else { break }
            if state == "matched" {
                verified.append(field.ref)
            } else {
                details.append("[\(field.ref)] not verified: the value changed or the control is no longer available.")
            }
        }
        if !verified.isEmpty {
            details.insert("Verified refs: " + verified.map { "[\($0)]" }.joined(separator: ", ") + ".", at: 0)
        }
        let snapshot: String
        if await canContinueBatch(fields.first?.ref ?? 0, in: webView) {
            let observationBeforeSnapshot = observation(in: webView)?.documentID
            let refreshed = await Self.snapshot(webView)
            snapshot = observation(in: webView)?.documentID == observationBeforeSnapshot
                ? refreshed
                : "The page changed or access ended; read the current page before continuing."
        } else {
            snapshot = "The page changed or access ended; read the current page before continuing."
        }
        return "Filled \(verified.count) of \(fields.count) fields. " + details.joined(separator: "\n") + "\n" + snapshot
    }

    private static func fillRejection(for control: [String: Any]) -> String? {
        if control["sensitive"] as? Bool == true {
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
        guard !Task.isCancelled, PageAutomationGuard.allowsExecution, !webView.isLoading, !webView.isClosed,
            await validateObservation(in: webView, ref: ref > 0 ? ref : nil)
        else { return false }
        return !Task.isCancelled && PageAutomationGuard.allowsExecution && !webView.isLoading && !webView.isClosed
    }

    private static func batchState(in webView: BrowserPage) async -> String? {
        guard PageAutomationGuard.allowsExecution, await selectedFrameIsLive(in: webView) else { return nil }
        return (try? await webView.evaluateJavaScript(scripted("""
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
              return copy.outerHTML.replace(/value="[^"]*"/g, '');
            };
            let text = textOutsideFields(document);
            for (const frame of document.querySelectorAll('iframe')) {
              try { if (frame.contentDocument) text += ' ' + textOutsideFields(frame.contentDocument); } catch (e) {}
            }
            return JSON.stringify({ snapshot: window.__wsurfSnapshot, url: location.href, document: R.documentID,
              text, refs: (window.__wsurfRefs || []).map(el =>
                [el.isConnected, el.disabled, R.kindOf(el), el.name, el.id, markupWithoutValues(el)]) });
            """), in: selectedFrame?.frame, contentWorld: PageAutomationGuard.world)) as? String
    }
}
