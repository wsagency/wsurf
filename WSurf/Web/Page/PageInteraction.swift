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
        guard await validateObservation(in: view, ref: ref) else { return await referenceFailureMessage(ref: ref, in: view) }
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
        guard await validateObservation(in: view, ref: ref) else { return await referenceFailureMessage(ref: ref, in: view) }
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
            case .success:
                break
            case .failure(.invalid):
                return "Invalid selector."
            case .failure(.empty), .failure(.tooLong):
                return "The selector must be 1 to \(PageRuntime.maxSelectorBytes) UTF-8 bytes."
            }
        }
        // An element wait belongs to the document it started on: a navigation ends it instead of answering for the new page.
        var startDocument: String?
        let startMain = view.mainDocumentID
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(min(15, max(1, timeout)))
        let started = clock.now
        defer { PageSettle.meter?.add(started.duration(to: clock.now)) }
        repeat {
            guard PageAutomationGuard.allowsExecution else { return staleMessage }
            // One call per chunk: the page watches for the condition itself and answers when it holds, the document is left or
            // the chunk ends. A chunk stays under the Chromium command timeout; a longer wait takes another call.
            let chunk = min(deadline - clock.now, .seconds(8))
            let script = waitScript(condition: condition, encoded: encoded, isElement: isElement, chunk: chunk)
            let answer = await PageAutomationGuard.rescoped(in: view) { await waitAnswer(script, chunk: chunk, in: view) }
            if let error = answer?["error"] as? String {
                return error
            }
            if isElement, let document = answer?["document"] as? String {
                guard document == (startDocument ?? document) else { return staleMessage }
                startDocument = document
            }
            if answer?["matches"] as? Bool == true {
                return "Condition met.\n" + (await PageAutomationGuard.withCurrentDocument(in: view) { await snapshot(view, lookingFor: isElement ? "" : value) })
            }
            if answer == nil || answer?["unloading"] as? Bool == true {
                // The document is going away. An element wait ends here; any other wait continues on the page that arrives.
                if isElement, startDocument != nil || view.isLoading || view.mainDocumentID != startMain {
                    return staleMessage
                }
                if view.isLoading {
                    await PageSettle.untilIdle(view, timeout: max(.zero, min(PageSettle.loadCeiling, deadline - clock.now)))
                } else {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } while clock.now < deadline && !Task.isCancelled
        return "Timed out waiting for \(condition).\n" + (await PageAutomationGuard.withCurrentDocument(in: view) { await snapshot(view, lookingFor: isElement ? "" : value) })
    }

    /// The page-side wait for `condition`: it answers `{matches}`, `{error}`, `{unloading}` or `{timedOut}` after `chunk` at most.
    private static func waitScript(condition: String, encoded: String, isElement: Bool, chunk: Duration) -> String {
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
            if (state.error) return { error: state.error };
            if (state.count > 1) return { error: 'The selector matches more than one element.' };
            """
            : ""
        return scriptedAsync(
            """
            const value = \(encoded);
            const check = () => {
              \(elementState)
              return { matches: \(expression) };
            };
            return await R.waitFor(check, \(PageSettle.milliseconds(chunk)));
            """)
    }

    /// What the page answered, or nil when the call failed, the page was left before it answered, or the guard went stale.
    private static func waitAnswer(_ script: String, chunk: Duration, in view: BrowserPage) async -> [String: Any]? {
        guard let raw = await view.callAsyncJavaScript(script, within: chunk + .seconds(1), in: selectedFrame?.frame),
            PageAutomationGuard.allowsExecution,
            let answer = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any], answer["stale"] == nil
        else { return nil }
        return answer
    }

    /// One capture path for the viewport, an element or a CSS-pixel region. Sensitive filled fields anywhere on the page
    /// refuse the capture, checked before and after, even for a crop. Never scrolls, stitches or changes the viewport.
    /// `developmentAllowed` is asked before any work, after each await and just before pixels are returned: an element
    /// registered only by `findElements` is captured while it answers true, never otherwise. Ordinary control refs, the
    /// viewport and regions never ask for it. `maximumBytes` bounds the returned JPEG and may shrink its pixels; the
    /// returned `scale` always describes the image that is returned. With `masking` (the Developer tier) filled sensitive
    /// fields are painted black in the returned image instead of refusing the capture; a field that cannot be measured
    /// still refuses it.
    static func screenshot(
        _ target: ScreenshotTarget = .viewport, developmentAllowed: () -> Bool = { false }, maximumBytes: Int? = nil,
        maxWidth: Int? = nil, masking: ScreenshotMasking? = nil, in view: BrowserPage
    ) async -> Result<ScreenshotCapture, ScreenshotFailure> {
        guard PageAutomationGuard.allowsExecution else { return .failure(.stale) }
        var masking = masking
        masking?.documentSpace = target == .fullPage
        guard target != .fullPage || view.chromium != nil else { return .failure(.fullPageUnsupported) }
        // Asked before the first await as well as after each one: a caller may have waited (for its turn to capture) since it
        // checked.
        guard target != .fullPage || developmentAllowed() else { return .failure(.needsDevelopment) }
        let ref: Int
        switch await screenshotRef(for: target, in: view) {
        case .success(let probed):
            ref = probed
        case .failure(let failure):
            return .failure(failure)
        }
        let document = view.url
        let probe = scripted(
            """
            const root = document.documentElement;
            const out = { document: R.documentID, vw: window.innerWidth, vh: window.innerHeight, dw: root.scrollWidth, dh: root.scrollHeight,
              safe: !Array.from(R.walk(document.body)).some(el => R.isSensitiveField(el) && (el.value || el.isContentEditable && el.textContent)) };
            \(masking?.probeScript ?? "")
            const ref = \(ref);
            if (ref) {
              const geometry = R.screenshotGeometry(ref);
              if (geometry.stale) return JSON.stringify({ stale: true });
              Object.assign(out, geometry);
            }
            return JSON.stringify(out);
            """)
        guard let before = await evaluateJSON(probe, in: view), before["stale"] == nil else { return .failure(.stale) }
        // An element only `findElements` registered, and the full page, are capturable under development access alone; that
        // is decided first and asked again after every await.
        let foundOnly = before["foundOnly"] as? Bool == true
        let needsDevelopment = foundOnly || target == .fullPage
        guard !(needsDevelopment && !developmentAllowed()) else { return .failure(.needsDevelopment) }
        // Without masking a filled sensitive field refuses the capture; with it, only a field that was not measured does.
        func isPrivate(_ probe: [String: Any]) -> Bool {
            masking == nil ? probe["safe"] as? Bool == true : ScreenshotMasking.isMeasured(probe)
        }
        guard isPrivate(before) else { return .failure(.privacy) }
        func number(_ object: [String: Any]?, _ key: String) -> CGFloat? {
            (object?[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        guard let width = number(before, "vw"), let height = number(before, "vh") else { return .failure(.stale) }
        let area: (css: CGRect, placed: CGRect?)
        switch screenshotArea(target, viewport: CGSize(width: width, height: height), measured: before) {
        case .success(let value):
            area = value
        case .failure(let failure):
            return .failure(failure)
        }
        let css = area.css
        let placed = area.placed
        let zoom = view.pageZoom
        guard css.width * zoom >= 1, css.height * zoom >= 1 else { return .failure(.invalidGeometry) }
        // One image pixel per CSS pixel unless the caller asks for a width: the pixels a screen adds only cost bytes.
        let requested = maxWidth ?? max(64, Int(css.width.rounded(.up)))
        let pixelLimit = target == .fullPage ? min(requested, ScreenshotTarget.fullPagePixelWidth) : requested
        let crop: CGRect? = target == .viewport ? nil : CGRect(x: css.minX * zoom, y: css.minY * zoom, width: css.width * zoom, height: css.height * zoom)
        let pointWidth = crop?.width ?? view.bounds.width
        let captured: NSImage?
        if target == .fullPage, let chromium = view.chromium {
            captured = try? await chromium.captureFullPage(css, scale: min(1, Double(pixelLimit) / Double(css.width)))
        } else {
            captured = try? await view.capture(rect: crop, width: min(1280, max(1, pointWidth)))
        }
        guard let image = captured,
            PageAutomationGuard.allowsExecution, view.url == document,
            let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), bitmap.pixelsWide > 0
        else { return .failure(.captureFailed) }
        guard !(needsDevelopment && !developmentAllowed()) else { return .failure(.needsDevelopment) }
        guard let after = await evaluateJSON(probe, in: view), after["stale"] == nil, after["document"] as? String == before["document"] as? String else {
            return .failure(.stale)
        }
        // Development access is checked again right before pixels leave, after the last await.
        let requiresDevelopment = needsDevelopment || after["foundOnly"] as? Bool == true
        guard !(requiresDevelopment && !developmentAllowed()) else { return .failure(.needsDevelopment) }
        guard isPrivate(after) else { return .failure(.privacy) }
        guard placementHeld(placed, in: after) else { return .failure(.stale) }
        // The boxes painted over the pixels are the ones measured after the capture, and they must be where they were before it.
        var picture = bitmap
        if masking != nil {
            let masks = ScreenshotMasking.masks(in: after)
            guard ScreenshotMasking.held(ScreenshotMasking.masks(in: before), masks) else { return .failure(.stale) }
            guard let painted = ScreenshotMasking.apply(masks, over: css, to: bitmap) else { return .failure(.captureFailed) }
            picture = painted
        }
        // The limit may have shrunk the pixels, so the scale comes from the image that is returned.
        guard let encoded = PageScreenshotEncoding.jpeg(picture, fitting: maximumBytes, maxPixelWidth: pixelLimit) else { return .failure(.captureFailed) }
        return .success(
            ScreenshotCapture(
                jpeg: encoded.data, bounds: css, scale: CGFloat(encoded.pixelsWide) / css.width,
                requiresDevelopment: requiresDevelopment))
    }

    /// The element ref a screenshot probes (0 for none), or the reason the target cannot be captured at all.
    private static func screenshotRef(for target: ScreenshotTarget, in view: BrowserPage) async -> Result<Int, ScreenshotFailure> {
        switch target {
        case .viewport:
            return .success(0)
        case .fullPage:
            return selectedFrame == nil ? .success(0) : .failure(.unmappableFrame)
        case .element(let requested):
            // A selected frame measures in its own viewport, which the page's geometry cannot be mapped back from.
            guard selectedFrame == nil else { return .failure(.unmappableFrame) }
            guard await validateObservation(in: view, ref: requested, inspectable: true) else { return .failure(.stale) }
            return .success(requested)
        case .region:
            guard selectedFrame == nil else { return .failure(.unmappableFrame) }
            return .success(0)
        }
    }

    /// An element capture is refused when the element moved between the probe before and the probe after the capture.
    private static func placementHeld(_ placed: CGRect?, in after: [String: Any]) -> Bool {
        guard let placed else { return true }
        guard case .success(let now) = ScreenshotGeometry.topViewportRect(measured: after),
            [now.minX - placed.minX, now.minY - placed.minY, now.width - placed.width, now.height - placed.height].allSatisfy({ abs($0) <= 0.5 })
        else { return false }
        return true
    }

    /// The CSS rect a screenshot of `target` covers and, for an element, the box it was measured at in the top viewport.
    private static func screenshotArea(
        _ target: ScreenshotTarget, viewport: CGSize, measured before: [String: Any]
    ) -> Result<(css: CGRect, placed: CGRect?), ScreenshotFailure> {
        switch target {
        case .viewport:
            guard viewport.width > 0, viewport.height > 0 else { return .failure(.invalidGeometry) }
            return .success((css: CGRect(origin: .zero, size: viewport), placed: nil))
        case .fullPage:
            let width = (before["dw"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? viewport.width
            let height = (before["dh"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? viewport.height
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return .failure(.invalidGeometry) }
            let size = CGSize(width: min(width, ScreenshotTarget.fullPageWidth), height: min(height, ScreenshotTarget.fullPageHeight))
            return .success((css: CGRect(origin: .zero, size: size), placed: nil))
        case .region(let requested):
            switch ScreenshotGeometry.region(requested, inViewportCSS: viewport) {
            case .success(let clipped):
                return .success((css: clipped, placed: nil))
            case .failure(let failure):
                return .failure(failure)
            }
        case .element:
            switch ScreenshotGeometry.topViewportRect(measured: before) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let box):
                switch ScreenshotGeometry.visibleBounds(ofElement: box, inViewportCSS: viewport) {
                case .success(let clipped):
                    return .success((css: clipped, placed: box))
                case .failure(let failure):
                    return .failure(failure)
                }
            }
        }
    }
}
