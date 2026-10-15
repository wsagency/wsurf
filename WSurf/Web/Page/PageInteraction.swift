// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import WebKit

extension PageDriver {
    static func verifyControl(ref: Int, value: String?, checked: Bool?, in view: BrowserPage) async -> Bool {
        guard await validateObservation(in: view, ref: ref), let encoded = jsonString(value ?? "") else { return false }
        let result = await evaluateJSON(scripted("""
            const el = window.__wsurfRefs[\(ref) - 1];
            if (!R.matchesRef(\(ref)) || !R.visible(el) || R.isSensitiveField(el)) return JSON.stringify({ matched: false });
            const valueMatches = \(value == nil) || ('value' in el && el.value === \(encoded));
            const checkedMatches = \(checked == nil) || (['checkbox','radio'].includes(el.type) && el.checked === \(checked ?? false));
            return JSON.stringify({ matched: valueMatches && checkedMatches });
            """), in: view)
        return result?["matched"] as? Bool == true
    }

    static func inspectControl(ref: Int, offset: Int = 0, in view: BrowserPage) async -> String {
        guard await validateObservation(in: view, ref: ref) else { return staleMessage }
        let start = max(0, offset)
        let script = scripted(
            """
            const el = window.__wsurfRefs[\(ref) - 1];
            const rect = el.getBoundingClientRect();
            const result = { ref: \(ref), kind: R.kindOf(el), label: R.labelOf(el, R.kindOf(el)),
              disabled: R.disabled(el), readOnly: !!el.readOnly || el.getAttribute('aria-readonly') === 'true',
              role: el.getAttribute('role'), expanded: el.getAttribute('aria-expanded'),
              checked: el.checked ?? el.getAttribute('aria-checked'),
              bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
            if (R.isSensitiveField(el)) result.value = '(hidden)';
            else if (el.tagName === 'INPUT') {
              result.type = el.type;
              if (['range','color','date','datetime-local','time','month','week','number'].includes(el.type)) result.value = el.value;
              result.min = el.min.slice(0, 100); result.max = el.max.slice(0, 100);
              result.step = el.step.slice(0, 100); result.placeholder = el.placeholder.slice(0, 200);
            } else if (el.options) {
              result.options = Array.from(el.options).slice(\(start), \(start + 12)).map(o => ({
                label: R.norm(o.text).slice(0, 100), value: o.value.slice(0, 100),
                disabled: o.disabled || !!o.closest('optgroup[disabled]'), selected: o.selected }));
              result.totalOptions = el.options.length;
              const cost = value => new TextEncoder().encode(JSON.stringify(value).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')).length;
              while (result.options.length > 1 && cost(result) > \(max(500, outputBudget.totalCharacters - 400))) result.options.pop();
              if (\(start) + result.options.length < el.options.length) result.nextOffset = \(start) + result.options.length;
            }
            return JSON.stringify(result);
            """)
        guard let result = await evaluateJSON(script, in: view),
            let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        else { return staleMessage }
        return "CONTROL:\n" + String(decoding: data, as: UTF8.self)
            + "\nobservationID: " + (observation(in: view)?.id ?? "")
    }

    static func setChecked(
        ref: Int, checked: Bool, in view: BrowserPage, announced: Bool = false, refreshControls: Bool = true
    ) async -> String {
        guard await validateObservation(in: view, ref: ref) else { return staleMessage }
        let state = await evaluateJSON(scripted("""
            const el = window.__wsurfRefs[\(ref) - 1];
            if (R.isSensitiveField(el)) return JSON.stringify({ refused: true });
            R.expectValue(el, \(checked));
            return JSON.stringify({ kind: R.kindOf(el), checked: el.checked ?? (el.getAttribute('aria-checked') === 'true') });
            """), in: view)
        if state?["refused"] as? Bool == true { return "The user must fill this sensitive field. Do not retry with another tool." }
        guard let kind = state?["kind"] as? String, ["checkbox", "radio"].contains(kind) else {
            return "Use a checkbox, switch, or radio ref."
        }
        let documentID = observation(in: view)?.documentID
        let status: String
        if state?["checked"] as? Bool == checked {
            status = "Checked state already matches."
        } else {
            if kind == "radio", !checked { return "Choose another radio option to change the selection." }
            let output = await click(ref: ref, label: "", in: view, announced: announced, refreshControls: false)
            guard output.hasPrefix("Clicked") else { return output }
            status = "Set checked state to \(checked)."
        }
        return await finishValueAction(
            status: status, ref: ref, documentID: documentID, refreshControls: refreshControls, in: view)
    }

    private static let elementConditions: Set<String> = ["elementVisible", "elementHidden", "elementEnabled"]

    static func waitForPage(condition: String, value: String, timeout: Int = 5, in view: BrowserPage) async -> String {
        let isElement = elementConditions.contains(condition)
        guard isElement || ["text", "textAbsent", "url", "ready"].contains(condition),
            condition == "ready" || !value.isEmpty,
            let encoded = jsonString(value)
        else {
            return "Use text, textAbsent, url, elementVisible, elementHidden, elementEnabled, or ready with a nonempty value where required."
        }
        if isElement {
            switch PageRuntime.validate(selector: value) {
            case .success: break
            case .failure(.invalid): return "Invalid selector."
            case .failure(.empty), .failure(.tooLong):
                return "The selector must be 1 to \(PageRuntime.maxSelectorBytes) UTF-8 bytes."
            }
        }
        let expression: String
        switch condition {
        case "ready":
            expression = "document.readyState === 'complete'"
        case "url":
            expression = "location.href.includes(value)"
        case "textAbsent":
            expression = "!R.pageText().includes(value)"
        case "elementVisible":
            expression = "state.count === 1 && state.visible"
        case "elementHidden":
            expression = "state.count === 0 || !state.visible"
        case "elementEnabled":
            expression = "state.count === 1 && state.enabled"
        default:
            expression = "R.pageText().includes(value)"
        }
        let elementState = isElement
            ? """
            const state = R.elementState(value);
            if (state.error) return JSON.stringify({ error: state.error });
            if (state.count > 1) return JSON.stringify({ error: 'The selector matches more than one element.' });
            """
            : ""
        // An element wait belongs to the document it started on: a navigation ends it instead of answering for the new page.
        var startDocument: String?
        let deadline = ContinuousClock.now + .seconds(min(15, max(1, timeout)))
        repeat {
            guard PageAutomationGuard.allowsExecution else { return staleMessage }
            let output = await PageAutomationGuard.withCurrentDocument(in: view) {
                let script = scripted(
                    """
                    const value = \(encoded);
                    \(elementState)
                    const matches = \(expression);
                    return JSON.stringify({ matches, document: R.documentID });
                    """)
                guard let result = await evaluateJSON(script, in: view), result["stale"] == nil else { return staleMessage }
                if let error = result["error"] as? String { return error }
                if isElement {
                    guard let document = result["document"] as? String, document == (startDocument ?? document) else { return staleMessage }
                    startDocument = document
                }
                return result["matches"] as? Bool == true ? "matched" : "pending"
            }
            if output == "matched" {
                return "Condition met.\n" + (await PageAutomationGuard.withCurrentDocument(in: view) { await snapshot(view, lookingFor: isElement ? "" : value) })
            }
            if output != "pending" { return output }
            try? await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        return "Timed out waiting for \(condition).\n" + (await PageAutomationGuard.withCurrentDocument(in: view) { await snapshot(view, lookingFor: isElement ? "" : value) })
    }

    /// One capture path for the viewport, an element or a CSS-pixel region. Sensitive filled fields anywhere on the page
    /// refuse the capture, checked before and after, even for a crop. Never scrolls, stitches or changes the viewport.
    /// `developmentAllowed` is asked before any work, after each await and just before pixels are returned: an element
    /// registered only by `findElements` is captured while it answers true, never otherwise. Ordinary control refs, the
    /// viewport and regions never ask for it.
    static func screenshot(
        _ target: ScreenshotTarget = .viewport, developmentAllowed: () -> Bool = { false }, in view: BrowserPage
    ) async -> Result<ScreenshotCapture, ScreenshotFailure> {
        guard PageAutomationGuard.allowsExecution else { return .failure(.stale) }
        var ref = 0
        switch target {
        case .viewport:
            break
        case .element(let requested):
            // A selected frame measures in its own viewport, which the page's geometry cannot be mapped back from.
            guard selectedFrame == nil else { return .failure(.unmappableFrame) }
            guard await validateObservation(in: view, ref: requested, inspectable: true) else { return .failure(.stale) }
            ref = requested
        case .region:
            guard selectedFrame == nil else { return .failure(.unmappableFrame) }
        }
        let document = view.url
        let probe = scripted(
            """
            const out = { document: R.documentID, vw: window.innerWidth, vh: window.innerHeight,
              safe: !Array.from(R.walk(document.body)).some(el => R.isSensitiveField(el) && (el.value || el.isContentEditable && el.textContent)) };
            const ref = \(ref);
            if (ref) {
              const geometry = R.screenshotGeometry(ref);
              if (geometry.stale) return JSON.stringify({ stale: true });
              Object.assign(out, geometry);
            }
            return JSON.stringify(out);
            """)
        guard let before = await evaluateJSON(probe, in: view), before["stale"] == nil else { return .failure(.stale) }
        // An element only `findElements` registered is capturable under development access alone; that is decided first.
        let foundOnly = before["foundOnly"] as? Bool == true
        guard !(foundOnly && !developmentAllowed()) else { return .failure(.needsDevelopment) }
        guard before["safe"] as? Bool == true else { return .failure(.privacy) }
        func number(_ object: [String: Any]?, _ key: String) -> CGFloat? { (object?[key] as? NSNumber).map { CGFloat($0.doubleValue) } }
        let mapped = ScreenshotGeometry.topViewportRect(measured:)
        var placed: CGRect?
        guard let width = number(before, "vw"), let height = number(before, "vh") else { return .failure(.stale) }
        let viewport = CGSize(width: width, height: height)
        let css: CGRect
        switch target {
        case .viewport:
            guard width > 0, height > 0 else { return .failure(.invalidGeometry) }
            css = CGRect(origin: .zero, size: viewport)
        case .region(let requested):
            switch ScreenshotGeometry.region(requested, inViewportCSS: viewport) {
            case .success(let clipped): css = clipped
            case .failure(let failure): return .failure(failure)
            }
        case .element:
            switch mapped(before) {
            case .failure(let failure): return .failure(failure)
            case .success(let box):
                placed = box
                switch ScreenshotGeometry.visibleBounds(ofElement: box, inViewportCSS: viewport) {
                case .success(let clipped): css = clipped
                case .failure(let failure): return .failure(failure)
                }
            }
        }
        let zoom = view.pageZoom
        guard css.width * zoom >= 1, css.height * zoom >= 1 else { return .failure(.invalidGeometry) }
        let crop: CGRect? = target == .viewport ? nil : CGRect(x: css.minX * zoom, y: css.minY * zoom, width: css.width * zoom, height: css.height * zoom)
        let pointWidth = crop?.width ?? view.bounds.width
        guard let image = try? await view.capture(rect: crop, width: min(1280, max(1, pointWidth))),
            PageAutomationGuard.allowsExecution, view.url == document,
            let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), bitmap.pixelsWide > 0
        else { return .failure(.captureFailed) }
        guard !(foundOnly && !developmentAllowed()) else { return .failure(.needsDevelopment) }
        guard let after = await evaluateJSON(probe, in: view), after["stale"] == nil, after["document"] as? String == before["document"] as? String else {
            return .failure(.stale)
        }
        // Development access is checked again right before pixels leave, after the last await.
        guard !((foundOnly || after["foundOnly"] as? Bool == true) && !developmentAllowed()) else { return .failure(.needsDevelopment) }
        guard after["safe"] as? Bool == true else { return .failure(.privacy) }
        if let placed {
            guard case .success(let now) = mapped(after),
                [now.minX - placed.minX, now.minY - placed.minY, now.width - placed.width, now.height - placed.height].allSatisfy({ abs($0) <= 0.5 })
            else { return .failure(.stale) }
        }
        guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return .failure(.captureFailed) }
        return .success(
            ScreenshotCapture(
                jpeg: jpeg, bounds: css, scale: CGFloat(bitmap.pixelsWide) / css.width,
                requiresDevelopment: foundOnly || after["foundOnly"] as? Bool == true))
    }
}
