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
        guard await validateObservation(in: view, ref: ref) else { return await referenceFailureMessage(ref: ref, in: view) }
        guard let window = view.window, NSApp.isActive, window.isKeyWindow, window.isVisible,
            window.occlusionState.contains(.visible), window.attachedSheet == nil
        else { return unavailable }
        await announce(ref: ref, in: view, pause: false)
        guard await validateObservation(in: view, ref: ref) else { return await referenceFailureMessage(ref: ref, in: view) }
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

    /// Sends a key, or with `modifiers` a chord, to a control of a visible tab. It goes to the page's own responder through
    /// `BrowserPage.sendKeyEvent`, never through the application, a window or a menu, and only in the shapes `PageKeyChord`
    /// builds. A nil `modifiers` keeps the assistant's original contract of twelve named keys without modifiers.
    static func pressKey(_ key: String, ref: Int, modifiers: String? = nil, in view: BrowserPage) async -> String {
        let extended = modifiers != nil
        let chord: PageKeyChord
        switch PageKeyChord.parse(key: key, modifiers: modifiers ?? "", extended: extended) {
        case .success(let parsed):
            chord = parsed
        case .failure(let refusal):
            return refusal.message
        }
        guard view.window != nil else { return "Keyboard input requires a visible tab. Switch to the page first." }
        let resolved = await resolve(ref: ref, label: "", kinds: #"["field","button","link","checkbox","radio","combobox","select","scrollarea"]"#, in: view)
        let found: Resolved
        switch resolved {
        case .success(let value):
            found = value
        case .failure(let message):
            return message
        }
        if chord.activates, let category = SensitiveAction.category(of: found.label, context: found.context) {
            guard
                await AgentActionConsent.permit(
                    label: found.label, category: category, host: (selectedFrame?.url ?? view.url)?.host(),
                    authoredByAI: AgentAuthoredText.isPresent(in: view), policy: view.context.actionPolicy)
            else {
                return SensitiveAction.declined(found.label, category: category)
            }
        }
        guard await validateObservation(in: view, ref: ref), let window = view.window else { return await referenceFailureMessage(ref: ref, in: view) }
        let ready = await evaluateJSON(
            scripted(
                """
                const el = window.__wsurfRefs[\(ref) - 1];
                if (R.isSensitiveField(el)) return JSON.stringify({ error: 'The user must interact with sensitive fields.' });
                const error = R.actionable(el);
                if (error) return JSON.stringify({ error });
                const textField = el.isContentEditable || el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT'
                  && !['button', 'checkbox', 'color', 'file', 'hidden', 'image', 'radio', 'range', 'reset', 'submit'].includes((el.type || 'text').toLowerCase()));
                if (\(chord.needsTextField) && !textField) return JSON.stringify({ error: '\(chord.name) is sent only to a text field.' });
                el.focus();
                return JSON.stringify({ focused: el.ownerDocument.activeElement === el || el.getRootNode().activeElement === el });
                """), in: view)
        if let error = ready?["error"] as? String { return error }
        guard ready?["focused"] as? Bool == true, window.makeFirstResponder(view),
            await validateObservation(in: view, ref: ref)
        else { return "The control could not receive keyboard focus." }
        let documentURL = view.url
        do {
            // The page's own trusted keydown is the receipt: it proves what arrived, not only that a responder was called.
            if extended {
                try await installComputerReceipt("keydown", in: view)
            }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard PageAutomationGuard.allowsExecution else { return staleMessage }
                guard
                    let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: chord.eventFlags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: chord.characters, charactersIgnoringModifiers: chord.characters, isARepeat: false,
                        keyCode: chord.keyCode)
                else { return "Could not create keyboard input." }
                guard view.sendKeyEvent(event) else { return "The key was not delivered to the page." }
            }
            if chord.selectsAll {
                try await computerSelectAll(frame: nil, in: view, window: window)
            }
            if extended {
                try await awaitComputerReceipt(in: view, documentURL: documentURL)
            }
        } catch PageComputerFailure.unverified {
            return "Sent \(chord.name), but the page did not confirm receiving it. Check the resulting page.\n" + (await settleAndSnippet(view))
        } catch PageComputerFailure.sensitive {
            return "The page moved keyboard focus to a sensitive field, so Select All was not applied."
        } catch {
            _ = await evaluateJSON(scripted("window.__wsurfComputerAck?.dispose(); return JSON.stringify({ ok: true });"), in: view)
            return PageAutomationGuard.allowsExecution ? "The key could not be delivered to the page." : staleMessage
        }
        return "Sent \(chord.name). Check the resulting page.\n" + (await settleAndSnippet(view))
    }
}
