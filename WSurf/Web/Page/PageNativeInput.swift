// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import WebKit

extension PageDriver {
    /// Moves the real pointer to the element's center, so CSS `:hover`, pointer and mouse handlers all run as they would for a
    /// person. Needs WSurf to be the active app with a key window and an on-screen tab; it never activates or raises anything.
    static func hover(ref: Int, in view: BrowserPage) async -> String {
        let unavailable = "Hover needs WSurf to be the active app."
        guard await validateObservation(in: view, ref: ref) else { return staleMessage }
        guard let window = view.window, NSApp.isActive, window.isKeyWindow, window.isVisible,
            window.occlusionState.contains(.visible), window.attachedSheet == nil
        else { return unavailable }
        await announce(ref: ref, in: view, pause: false)
        guard await validateObservation(in: view, ref: ref) else { return staleMessage }
        let result = await evaluateJSON(
            scripted(
                """
                const el = window.__wsurfRefs[\(ref) - 1];
                const error = R.actionable(el, false);
                if (error) return JSON.stringify({ error });
                if (el.ownerDocument !== document) return JSON.stringify({ error: 'Hover is not available inside a frame.' });
                const rect = el.getBoundingClientRect(), x = rect.x + rect.width / 2, y = rect.y + rect.height / 2;
                if (!(x >= 0 && y >= 0 && x < window.innerWidth && y < window.innerHeight)) return JSON.stringify({ error: 'The element is offscreen or covered.' });
                for (let node = document.elementFromPoint(x, y); node; node = node.parentNode || node.host) {
                  if (node === el) return JSON.stringify({ x, y });
                }
                return JSON.stringify({ error: 'The element is offscreen or covered.' });
                """), in: view)
        if let error = result?["error"] as? String { return error }
        guard let x = result?["x"] as? Double, let y = result?["y"] as? Double else { return staleMessage }
        guard await validateObservation(in: view, ref: ref) else { return staleMessage }
        let point = CGPoint(x: x * view.pageZoom, y: y * view.pageZoom)
        // The page's own hit test cannot see a window clip: a development-viewport pane can be smaller than the page.
        guard pageReceivesPointer(at: view.convert(point, to: nil), in: view, window: window) else {
            return "The element is not reachable by the real pointer: it is clipped by the window, covered by another view, or a sheet is open."
        }
        do {
            try movePointer(to: point, in: view, window: window)
        } catch PageComputerFailure.stale {
            return staleMessage
        } catch {
            return "Hover could not be delivered to the page."
        }
        return "Hovered. Verify the returned page.\n" + (await settleAndSnippet(view))
    }

    static func pressKey(_ key: String, ref: Int, in view: BrowserPage) async -> String {
        let keys: [String: (UInt16, String)] = [
            "Enter": (36, "\r"), "Tab": (48, "\t"), "Escape": (53, "\u{1b}"), "Space": (49, " "),
            "ArrowLeft": (123, "\u{f702}"), "ArrowRight": (124, "\u{f703}"),
            "ArrowDown": (125, "\u{f701}"), "ArrowUp": (126, "\u{f700}"),
            "Home": (115, "\u{f729}"), "End": (119, "\u{f72b}"),
            "Backspace": (51, "\u{7f}"), "Delete": (117, "\u{f728}"),
        ]
        guard let (code, characters) = keys[key] else {
            return "Use Enter, Tab, Escape, Space, ArrowLeft, ArrowRight, ArrowDown, ArrowUp, Home, End, Backspace, or Delete."
        }
        guard view.window != nil else { return "Keyboard input requires a visible tab. Switch to the page first." }
        let resolved = await resolve(ref: ref, label: "", kinds: #"["field","button","link","checkbox","radio","combobox","select","scrollarea"]"#, in: view)
        guard case .success(let found) = resolved else { return staleMessage }
        if key == "Enter" || key == "Space", let category = SensitiveAction.category(of: found.label, context: found.context) {
            guard
                await AgentActionConsent.permit(
                    label: found.label, category: category, host: (selectedFrame?.url ?? view.url)?.host(),
                    authoredByAI: AgentAuthoredText.isPresent(in: view), policy: view.context.actionPolicy)
            else {
                return SensitiveAction.declined(found.label, category: category)
            }
        }
        guard await validateObservation(in: view, ref: ref), let window = view.window else { return staleMessage }
        let ready = await evaluateJSON(
            scripted(
                """
                const el = window.__wsurfRefs[\(ref) - 1];
                if (R.isSensitiveField(el)) return JSON.stringify({ error: 'The user must interact with sensitive fields.' });
                const error = R.actionable(el);
                if (error) return JSON.stringify({ error });
                el.focus();
                return JSON.stringify({ focused: el.ownerDocument.activeElement === el || el.getRootNode().activeElement === el });
                """), in: view)
        if let error = ready?["error"] as? String { return error }
        guard ready?["focused"] as? Bool == true, window.makeFirstResponder(view),
            await validateObservation(in: view, ref: ref)
        else { return "The control could not receive keyboard focus." }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard PageAutomationGuard.allowsExecution else { return staleMessage }
            guard
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { return "Could not create keyboard input." }
            guard view.sendKeyEvent(event) else { return "The key was not delivered to the page." }
        }
        return "Sent \(key). Check the resulting page.\n" + (await settleAndSnippet(view))
    }

}
