// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import WebKit

extension PageDriver {
    /// One end of a drag: a control ref from the latest observation, or a CSS selector naming one visible element.
    enum DragEnd: Equatable {
        case ref(Int)
        case selector(String)
    }

    enum DragDestination: Equatable {
        case end(DragEnd)
        /// CSS pixels from the source's centre.
        case offset(dx: Int, dy: Int)

        var named: DragEnd? {
            guard case .end(let end) = self else {
                return nil
            }
            return end
        }
    }

    /// Points a drag passes through, source centre to destination: enough for movement thresholds and sliders.
    private static let dragSteps = 5

    /// Drags between two elements of the top document. By default it dispatches the DOM events of a drag (`dragstart`,
    /// `dragover`, `drop`, or pointer and mouse events for an element that is not draggable); they are untrusted and work
    /// with the window in the background. With `pointer` it sends trusted pointer input instead: DevTools mouse events on
    /// Chromium, native mouse events through the window on WebKit. Neither needs the app to be active.
    ///
    /// Frames, file inputs, sensitive fields and disabled elements take no part in a drag, and a consequential label on either
    /// end needs the same approval a click on it would.
    static func drag(from source: DragEnd, to destination: DragDestination, pointer: Bool, in view: BrowserPage) async -> String {
        guard PageAutomationGuard.allowsExecution else {
            return staleMessage
        }
        if let refusal = await dragRefusal(source, destination, in: view) {
            return refusal
        }
        var window: NSWindow?
        if pointer {
            switch pointerWindow(of: view) {
            case .success(let found):
                window = found
            case .failure(let failed):
                return failed.message
            }
        }
        let plan: DragPlan
        switch await planDrag(source, destination, in: view) {
        case .success(let planned):
            plan = planned
        case .failure(let failed):
            return failed.message
        }
        if pointer, plan.nativeDrag {
            return "This element starts a browser drag session, which pointer input cannot complete. Use the default drag (pointer false)."
        }
        if let refusal = await approveDrag(plan, in: view) {
            return refusal
        }
        guard PageAutomationGuard.allowsExecution else {
            return staleMessage
        }
        let path = (0..<dragSteps).map { step -> CGPoint in
            let t = Double(step) / Double(dragSteps - 1)
            return CGPoint(
                x: plan.start.point.x + (plan.end.point.x - plan.start.point.x) * t,
                y: plan.start.point.y + (plan.end.point.y - plan.start.point.y) * t)
        }
        do {
            if let window {
                try await sendPointerDrag(path: path, window: window, in: view)
            } else {
                let points = path.map { CGPoint(x: $0.x * view.pageZoom, y: $0.y * view.pageZoom) }
                try await dispatchDrag(path: points, modifiers: [], pinned: true, in: view)
            }
        } catch PageComputerFailure.unverified {
            return pointer
                ? "Sent the pointer drag, but the page did not report the release. Check the resulting page."
                : "The page changed under the pointer, or the drag passes over something that takes no part in a drag "
                    + "(a disabled or sensitive control, a frame or a file input). Read the page and try again."
        } catch {
            return PageAutomationGuard.allowsExecution ? "The drag could not be delivered to the page." : staleMessage
        }
        let from = plan.start.label.isEmpty ? "the source" : "“\(plan.start.label)”"
        var to = plan.end.label.isEmpty ? "the target" : "“\(plan.end.label)”"
        if case .offset(let dx, let dy) = destination {
            to = "the point (\(dx), \(dy)) CSS pixels away"
        }
        let how = pointer ? "pointer input" : "DOM events"
        return "Sent drag from \(from) to \(to) (\(how)). Verify the returned page.\n" + (await settleAndSnippet(view))
    }

    // MARK: Steps

    private struct DragPoint {
        let point: CGPoint
        let label: String
        let context: String
    }

    private struct DragPlan {
        let start: DragPoint
        let end: DragPoint
        let nativeDrag: Bool
    }

    /// Refs must be the ones of the observation this call holds, and selectors must be within the safe subset.
    private static func dragRefusal(_ source: DragEnd, _ destination: DragDestination, in view: BrowserPage) async -> String? {
        let ends = [source, destination.named].compactMap { $0 }
        for end in ends {
            guard case .ref(let ref) = end else {
                continue
            }
            guard await validateObservation(in: view, ref: ref) else {
                return await referenceFailureMessage(ref: ref, in: view)
            }
        }
        for case .selector(let selector) in ends {
            switch PageRuntime.validate(selector: selector) {
            case .success:
                break
            case .failure(.invalid):
                return "Invalid selector."
            case .failure(.empty), .failure(.tooLong):
                return "The selector must be 1 to \(PageRuntime.maxSelectorBytes) UTF-8 bytes."
            }
        }
        return nil
    }

    /// A pointer drag acts on the window: it must be visible and free of sheets. AppKit delivers mouse events to a window of an
    /// inactive app, so unlike a hover the app need not be active.
    private static func pointerWindow(of view: BrowserPage) -> Result<NSWindow, TargetFailure> {
        guard let window = view.window, window.attachedSheet == nil, window.isVisible else {
            return .failure(.init(message: "A pointer drag needs a visible tab with no sheet open."))
        }
        return .success(window)
    }

    private static func planDrag(_ source: DragEnd, _ destination: DragDestination, in view: BrowserPage) async -> Result<DragPlan, TargetFailure> {
        func specification(_ end: DragEnd) -> String? {
            switch end {
            case .ref(let ref):
                "{\"ref\": \(ref)}"
            case .selector(let selector):
                jsonString(selector).map { "{\"selector\": \($0)}" }
            }
        }
        var to = "null", dx = 0, dy = 0
        switch destination {
        case .end(let end):
            to = specification(end) ?? "null"
        case .offset(let x, let y):
            (dx, dy) = (x, y)
        }
        guard let from = specification(source) else {
            return .failure(.init(message: "Invalid selector."))
        }
        guard let plan = await evaluateJSON(scripted("return JSON.stringify(R.dragPlan(\(from), \(to), \(dx), \(dy)));"), in: view) else {
            return .failure(.init(message: "The page did not respond. Read it again after it finishes loading."))
        }
        if let error = plan["error"] as? String {
            return .failure(.init(message: error))
        }
        guard plan["stale"] == nil, let start = point(plan["from"]), let end = point(plan["to"]) else {
            return .failure(.init(message: staleMessage))
        }
        return .success(DragPlan(start: start, end: end, nativeDrag: plan["nativeDrag"] as? Bool == true))
    }

    private static func point(_ value: Any?) -> DragPoint? {
        guard let object = value as? [String: Any], let x = (object["x"] as? NSNumber)?.doubleValue,
            let y = (object["y"] as? NSNumber)?.doubleValue, x.isFinite, y.isFinite
        else {
            return nil
        }
        return DragPoint(point: CGPoint(x: x, y: y), label: object["label"] as? String ?? "", context: object["context"] as? String ?? "")
    }

    /// The approval a click on either end's label would need. Nil when both are fine.
    private static func approveDrag(_ plan: DragPlan, in view: BrowserPage) async -> String? {
        for target in [plan.start, plan.end] {
            guard let category = SensitiveAction.category(of: target.label, context: target.context) else {
                continue
            }
            let permitted = await AgentActionConsent.permit(
                label: target.label, category: category, host: (selectedFrame?.url ?? view.url)?.host(),
                authoredByAI: AgentAuthoredText.isPresent(in: view), policy: view.context.actionPolicy)
            guard permitted else {
                return SensitiveAction.declined(target.label, category: category)
            }
        }
        return nil
    }

    /// Trusted press, move and release along `path` (CSS pixels), with a trusted `mouseup` as proof that it arrived.
    private static func sendPointerDrag(path: [CGPoint], window: NSWindow, in view: BrowserPage) async throws {
        let first = path[0], last = path[path.count - 1]
        let held = await evaluateJSON(
            scripted("return JSON.stringify({ holds: R.dragHolds([\(first.x), \(first.y)], [\(last.x), \(last.y)]) });"), in: view)
        guard held?["holds"] as? Bool == true else {
            throw PageComputerFailure.stale
        }
        let documentURL = view.url
        try await installComputerReceipt("mouseup", in: view)
        if let chromium = view.chromium {
            try await chromium.dragPointer(path: path, allowed: { PageAutomationGuard.allowsExecution })
        } else {
            guard window.makeFirstResponder(view) else {
                throw PageComputerFailure.unavailable
            }
            let points = path.map { CGPoint(x: $0.x * view.pageZoom, y: $0.y * view.pageZoom) }
            try computerMouse(point: points[0], button: "left", phase: "down", in: view, window: window)
            do {
                for point in points.dropFirst() {
                    try computerMouse(point: point, button: "left", phase: "drag", in: view, window: window)
                }
            } catch {
                try? computerMouse(point: points[points.count - 1], button: "left", phase: "up", in: view, window: window)
                throw error
            }
            try computerMouse(point: points[points.count - 1], button: "left", phase: "up", in: view, window: window)
        }
        try await awaitComputerReceipt(in: view, documentURL: documentURL)
    }
}
