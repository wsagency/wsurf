// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation

/// Trusted pointer input at a point or on a control, for tabs the person may not be looking at.
///
/// On Chromium every event goes through DevTools (`ChromiumPage.dispatchPointer…`): it reaches the renderer directly, so the tab
/// can stay parked, WSurf need not be active and neither the person's cursor nor the window's first responder moves. WebKit has
/// no such channel: a parked WebKit tab refuses, and a visible one gets native events through its window.
///
/// Before anything is sent the page hit-tests the point (through open shadow roots) and the same rules a ref click follows
/// apply to whatever is there: file inputs (and labels for them) are refused, a password reveal toggle is refused while the
/// document holds a protected secret, and a consequential label needs the person's approval.
extension PageDriver {
    nonisolated enum PointerButton: String, Sendable, CaseIterable {
        case left, right, middle

        /// The page event that proves a click with this button arrived as trusted input.
        func receipt(clickCount: Int) -> String {
            switch self {
            case .left:
                clickCount == 2 ? "dblclick" : "click"
            case .right:
                "contextmenu"
            case .middle:
                "auxclick"
            }
        }
    }

    /// Whether the call's document is protected (`credentialTainted` by a Vault fill). The page itself also reports a filled
    /// secret; either one refuses a password reveal toggle.
    @TaskLocal static var protectedCredentials = false

    struct PointerTarget {
        let point: CGPoint
        let label: String
        let context: String
    }

    /// `shift`, `option` and `command`, `+`-separated. Control is never sent (Control-click is a context click on a Mac).
    static func pointerModifiers(_ text: String) -> Result<PageKeyChord.Modifiers, PageKeyChord.Refusal> {
        var modifiers: PageKeyChord.Modifiers = []
        for token in text.split(whereSeparator: { "+, ".contains($0) }).map({ $0.lowercased() }) {
            switch token {
            case "shift":
                modifiers.insert(.shift)
            case "option", "alt":
                modifiers.insert(.option)
            case "command", "cmd", "meta":
                modifiers.insert(.command)
            case "control", "ctrl":
                return .failure(.control)
            default:
                return .failure(.unknownModifier(String(token.prefix(24))))
            }
        }
        return .success(modifiers)
    }

    /// The control at `ref`'s centre, or whatever is at `point` (viewport CSS pixels), with every refusal the page can decide.
    static func pointerTarget(ref: Int?, point: CGPoint?, in view: BrowserPage) async -> Result<PointerTarget, TargetFailure> {
        let x = point.map { Double($0.x) } ?? -1, y = point.map { Double($0.y) } ?? -1
        let script = scripted(
            """
            const ref = \(ref ?? 0), protectedDoc = \(protectedCredentials);
            const up = n => n.parentElement || n.getRootNode?.()?.host || null;
            let el = null, x = \(x), y = \(y);
            if (ref > 0) {
              el = window.__wsurfRefs[ref - 1];
              if (!el?.isConnected || !R.matchesRef(ref)) return JSON.stringify({ stale: true });
              if (el.ownerDocument !== document) return JSON.stringify({ error: 'Pointer input is not available inside a frame. Click by ref without x and y.' });
              const error = R.actionable(el, false);
              if (error) return JSON.stringify({ error });
              const r = el.getBoundingClientRect();
              x = r.x + r.width / 2; y = r.y + r.height / 2;
            }
            if (!(x >= 0 && y >= 0 && x < innerWidth && y < innerHeight)) return JSON.stringify({ error: 'The point is outside the viewport.' });
            let hit = document.elementFromPoint(x, y);
            while (hit?.shadowRoot) {
              const inner = hit.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === hit) break;
              hit = inner;
            }
            if (!hit) return JSON.stringify({ error: 'Nothing is at that point.' });
            if (/^(IFRAME|FRAME|OBJECT|EMBED)$/.test(hit.tagName)) return JSON.stringify({ error: 'The point is over a frame. Pointer input into frames is not available.' });
            if (el) {
              let inside = false;
              for (let n = hit; n; n = up(n)) if (n === el) { inside = true; break; }
              if (!inside) return JSON.stringify({ error: 'The control is covered by another element.' });
            }
            let target = el || hit;
            if (!el) for (let n = hit; n; n = up(n)) if (R.kindOf(n)) { target = n; break; }
            const isFile = n => n?.tagName === 'INPUT' && (n.type || '').toLowerCase() === 'file';
            const label = hit.closest?.('label');
            if ([hit, target, label?.control].some(isFile)) {
              return JSON.stringify({ error: 'File selection requires the user. Use chooseFilesOnPage.' });
            }
            const kind = R.kindOf(target);
            if ((kind === 'checkbox' || kind === 'radio') && R.isSensitiveSecret(target)) {
              return JSON.stringify({ error: 'The user must fill this sensitive field. Do not retry with another tool.' });
            }
            // A reveal toggle shows a protected password on screen, and so in every later screenshot and read.
            if (protectedDoc || R.hasFilledSensitiveSecret()) {
              const words = n => [n.getAttribute?.('aria-label'), n.title, n.id, n.getAttribute?.('class'), n.getAttribute?.('name'),
                n.getAttribute?.('data-testid'), n.getAttribute?.('data-action'), n.textContent].filter(Boolean).join(' ');
              const revealWords = [/\\b(show|reveal|unmask|hide|view)\\b.{0,24}(password|passcode|pin|secret|code)|\\beye\\b|visibility/i,
                /(password|passcode|pin)[-_ ]?.{0,24}(show|reveal|visib|toggle|unmask)/i];
              const field = n => /^(INPUT|TEXTAREA)$/.test(n.tagName) && !['button', 'submit', 'image', 'checkbox', 'reset'].includes((n.type || '').toLowerCase());
              const nearSecret = n => {
                const ids = (n.getAttribute?.('aria-controls') || '').split(/\\s+/).filter(Boolean);
                if (ids.some(id => { const c = document.getElementById(id); return c && R.isSensitiveSecret(c); })) return true;
                let scope = n;
                for (let i = 0; i < 4 && scope; i++) {
                  scope = up(scope);
                  if (scope?.querySelectorAll && Array.from(scope.querySelectorAll('input,textarea')).some(f => R.isSensitiveSecret(f))) return true;
                }
                return false;
              };
              for (const n of new Set([target, hit])) {
                if (field(n) || !nearSecret(n)) continue;
                const text = R.norm(words(n));
                const iconOnly = !R.norm(n.textContent || '') && !n.getAttribute?.('aria-label');
                if (revealWords.some(pattern => pattern.test(text)) || iconOnly || (n.tagName === 'INPUT' && (n.type || '').toLowerCase() === 'checkbox')) {
                  return JSON.stringify({ error: 'Revealing a protected password is never allowed. The user can do it themselves.' });
                }
              }
            }
            if (R.disabled(target)) return JSON.stringify({ error: 'The control is disabled.' });
            const form = target.form || target.closest?.('form');
            const context = R.norm([target.getAttribute?.('aria-label'), target.title, target.name, target.getAttribute?.('data-action'),
              target.getAttribute?.('formaction'), target.getAttribute?.('onclick'), form?.getAttribute('action'),
              form?.getAttribute('aria-label'), form?.innerText].filter(Boolean).join(' ')).slice(0, 800);
            window.__wsurfPointerTarget = target;
            return JSON.stringify({ x, y, label: kind ? R.labelOf(target, kind) : R.norm(target.textContent || '').slice(0, 120), context });
            """)
        guard let object = await evaluateJSON(script, in: view) else { return .failure(.init(message: staleMessage)) }
        if let error = object["error"] as? String {
            return .failure(.init(message: error))
        }
        guard object["stale"] == nil, let px = (object["x"] as? NSNumber)?.doubleValue, let py = (object["y"] as? NSNumber)?.doubleValue
        else { return .failure(.init(message: staleMessage)) }
        return .success(
            PointerTarget(point: CGPoint(x: px, y: py), label: object["label"] as? String ?? "", context: object["context"] as? String ?? ""))
    }

    /// Whether the element `pointerTarget` found is still the one at `point`, asked right before the press is sent.
    private static func pointerTargetHolds(_ point: CGPoint, in view: BrowserPage) async -> Bool {
        let held = await evaluateJSON(
            scripted(
                """
                const target = window.__wsurfPointerTarget;
                let hit = document.elementFromPoint(\(Double(point.x)), \(Double(point.y)));
                while (hit?.shadowRoot) {
                  const inner = hit.shadowRoot.elementFromPoint(\(Double(point.x)), \(Double(point.y)));
                  if (!inner || inner === hit) break;
                  hit = inner;
                }
                for (let n = hit; n; n = n.parentElement || n.getRootNode?.()?.host) if (n === target) return JSON.stringify({ holds: true });
                return JSON.stringify({ holds: false });
                """), in: view)
        return held?["holds"] as? Bool == true
    }

    /// The approval a click on `target` needs, as `click` asks it. Nil when it may go on.
    private static func approvePointer(_ target: PointerTarget, in view: BrowserPage) async -> String? {
        guard let category = SensitiveAction.category(of: target.label, context: target.context) else { return nil }
        let permitted = await AgentActionConsent.permit(
            label: target.label, category: category, host: view.url?.host(),
            authoredByAI: AgentAuthoredText.isPresent(in: view), policy: view.context.actionPolicy)
        guard permitted else { return SensitiveAction.declined(target.label, category: category) }
        guard PageAutomationGuard.allowsExecution else { return staleMessage }
        if category == .publication {
            AgentAuthoredText.clear(in: view)
        }
        return nil
    }

    static let backgroundWebKitPointer =
        "Pointer input is not available in a background WebKit tab. Use switchTab to show it, or setTabEngine to Chromium."

    /// A trusted click with `button`, `clickCount` and `modifiers` on `ref` or at `point`.
    static func pointerClick(
        ref: Int?, point: CGPoint?, button: PointerButton, clickCount: Int, modifiers: PageKeyChord.Modifiers, in view: BrowserPage
    ) async -> String {
        guard PageAutomationGuard.allowsExecution else { return staleMessage }
        guard selectedFrame == nil else { return "Pointer input is not available inside a selected frame." }
        if let ref {
            guard await validateObservation(in: view, ref: ref) else { return await referenceFailureMessage(ref: ref, in: view) }
            await announce(ref: ref, in: view, pause: true)
        }
        let target: PointerTarget
        switch await pointerTarget(ref: ref, point: point, in: view) {
        case .success(let found):
            target = found
        case .failure(let failed):
            return failed.message
        }
        if let refusal = await approvePointer(target, in: view) {
            return refusal
        }
        let documentURL = view.url
        do {
            if let chromium = view.chromium {
                try await installComputerReceipt(button.receipt(clickCount: clickCount), in: view)
                guard await pointerTargetHolds(target.point, in: view) else { throw PageComputerFailure.stale }
                try await chromium.dispatchPointerClick(
                    at: target.point, button: button, clickCount: clickCount, modifiers: modifiers,
                    allowed: { PageAutomationGuard.allowsExecution })
            } else {
                guard let window = view.window, !view.isParked, window.isVisible, window.attachedSheet == nil else {
                    return backgroundWebKitPointer
                }
                try await installComputerReceipt(button.receipt(clickCount: clickCount), in: view)
                guard await pointerTargetHolds(target.point, in: view) else { throw PageComputerFailure.stale }
                let native = CGPoint(x: target.point.x * view.pageZoom, y: target.point.y * view.pageZoom)
                let name = button == .middle ? "wheel" : button.rawValue
                for count in 1...clickCount {
                    try computerMouse(point: native, button: name, phase: "down", count: count, modifiers: modifiers.eventFlags, in: view, window: window)
                    try computerMouse(point: native, button: name, phase: "up", count: count, modifiers: modifiers.eventFlags, in: view, window: window)
                }
            }
            try await awaitComputerReceipt(in: view, documentURL: documentURL)
        } catch PageComputerFailure.unverified {
            return "Sent the click, but the page did not report receiving it. Check the resulting page.\n" + (await settleAndSnippet(view))
        } catch {
            _ = await evaluateJSON(scripted("window.__wsurfComputerAck?.dispose(); return JSON.stringify({ ok: true });"), in: view)
            return PageAutomationGuard.allowsExecution ? "The click could not be delivered to the page." : staleMessage
        }
        let name = target.label.isEmpty ? "(\(Int(target.point.x)), \(Int(target.point.y)))" : "“\(target.label)”"
        let how = [button == .left ? nil : "\(button.rawValue) button", clickCount == 2 ? "double" : nil].compactMap { $0 }
        return "Clicked \(name) (pointer input\(how.isEmpty ? "" : ", " + how.joined(separator: ", "))). " + (await settleAndSnippet(view))
    }

    /// Moves a DevTools pointer over `ref` or `point` on Chromium; the person's cursor does not move.
    static func pointerHover(ref: Int?, point: CGPoint?, in view: BrowserPage) async -> String {
        guard PageAutomationGuard.allowsExecution else { return staleMessage }
        guard let chromium = view.chromium else { return backgroundWebKitPointer }
        if let ref {
            guard await validateObservation(in: view, ref: ref) else { return await referenceFailureMessage(ref: ref, in: view) }
            await announce(ref: ref, in: view, pause: false)
        }
        let target: PointerTarget
        switch await pointerTarget(ref: ref, point: point, in: view) {
        case .success(let found):
            target = found
        case .failure(let failed):
            return failed.message
        }
        do {
            try await installComputerReceipt("mousemove", in: view)
            try await chromium.dispatchPointerMove(to: target.point, allowed: { PageAutomationGuard.allowsExecution })
            try await awaitComputerReceipt(in: view, documentURL: view.url)
        } catch PageComputerFailure.unverified {
            return "Sent the pointer move, but the page did not report it. Check the resulting page.\n" + (await settleAndSnippet(view))
        } catch {
            _ = await evaluateJSON(scripted("window.__wsurfComputerAck?.dispose(); return JSON.stringify({ ok: true });"), in: view)
            return PageAutomationGuard.allowsExecution ? "Hover could not be delivered to the page." : staleMessage
        }
        return "Hovered. Verify the returned page.\n" + (await settleAndSnippet(view))
    }

    /// Scrolls `direction` with the wheel at `point`: DevTools wheel input on Chromium, a scroll of the container under the
    /// point on WebKit.
    static func scroll(direction: String, at point: CGPoint, in view: BrowserPage) async -> String {
        guard ["up", "down", "left", "right"].contains(direction) else { return "Use up, down, left, or right." }
        guard PageAutomationGuard.allowsExecution else { return staleMessage }
        let horizontal = direction == "left" || direction == "right"
        let sign = direction == "up" || direction == "left" ? -1.0 : 1.0
        let probe = await evaluateJSON(
            scripted(
                """
                const x = \(Double(point.x)), y = \(Double(point.y)), horizontal = \(horizontal);
                if (!(x >= 0 && y >= 0 && x < innerWidth && y < innerHeight)) return JSON.stringify({ error: 'The point is outside the viewport.' });
                const canScroll = e => horizontal ? e.scrollWidth > e.clientWidth + 1 : e.scrollHeight > e.clientHeight + 1;
                let el = document.elementFromPoint(x, y);
                while (el && !canScroll(el)) el = el.parentElement || el.getRootNode()?.host;
                el = el || document.scrollingElement;
                const before = horizontal ? el.scrollLeft : el.scrollTop;
                const amount = (horizontal ? el.clientWidth : el.clientHeight) * 0.8 * \(sign);
                if (\(view.chromium == nil)) el.scrollBy({ left: horizontal ? amount : 0, top: horizontal ? 0 : amount, behavior: 'instant' });
                window.__wsurfWheel = { el, before };
                return JSON.stringify({ amount, before });
                """), in: view)
        if let error = probe?["error"] as? String { return error }
        guard let amount = (probe?["amount"] as? NSNumber)?.doubleValue else { return staleMessage }
        if let chromium = view.chromium {
            do {
                try await chromium.dispatchWheel(
                    at: point, deltaX: horizontal ? amount : 0, deltaY: horizontal ? 0 : amount, allowed: { PageAutomationGuard.allowsExecution })
            } catch {
                return PageAutomationGuard.allowsExecution ? "The wheel input could not be delivered to the page." : staleMessage
            }
        }
        await PageSettle.untilQuiet(view, ceiling: min(.milliseconds(900), PageSettle.limits.quietCeiling))
        let moved = await evaluateJSON(
            scripted(
                """
                const w = window.__wsurfWheel; window.__wsurfWheel = null;
                if (!w?.el) return JSON.stringify({ moved: false });
                const after = \(horizontal) ? w.el.scrollLeft : w.el.scrollTop;
                return JSON.stringify({ moved: Math.abs(after - w.before) > 0.5 });
                """), in: view)
        let at = "at (\(Int(point.x)), \(Int(point.y)))"
        let status = moved?["moved"] as? Bool == true ? "Scrolled \(direction) \(at)." : "Already at the \(direction) scroll boundary \(at)."
        if feedbackMode == .delta {
            return status
        }
        return status + "\n" + (await PageAutomationGuard.withCurrentDocument(in: view) { await snapshot(view, viewportOnly: true) })
    }
}
