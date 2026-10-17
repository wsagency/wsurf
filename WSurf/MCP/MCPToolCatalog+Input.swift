// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP

nonisolated extension MCPToolCatalog {
    /// The tools that accept a CSS selector instead of a ref, with the control kinds each can act on (empty: any).
    static let selectorTargets: [String: [String]] = [
        "clickOnPage": ["button", "link", "checkbox", "radio", "field", "select", "combobox"],
        "typeOnPage": ["field"],
        "selectOption": ["select"],
        "setChecked": ["checkbox", "radio"],
        "hoverOnPage": [],
        "pressKey": ["field", "button", "link", "checkbox", "radio", "combobox", "select", "scrollarea"],
    ]

    private static let selector = Parameter(
        name: "selector", type: "string",
        description:
            "CSS selector for exactly one visible control, instead of ref and observationID. Needs development access. "
            + "data-testid and the other test attributes work; see the safe selector subset.",
        required: false, maxLength: PageRuntime.maxSelectorBytes)

    private static let modifiers = Parameter(
        name: "modifiers", type: "string",
        description:
            "Plus-separated shift, option, command, for example shift+option. Command is sent only with A, Z, Shift+Z, the arrow keys, "
            + "Backspace, Delete and Enter. Control, clipboard and browser shortcuts are refused before anything is sent.",
        required: false, maxLength: 64)

    /// `entry` with its target named by `ref` or by `selector`, and for `pressKey` with modifiers. Applied to the existing
    /// entries here instead of in their definitions, so the targeting lives in one file.
    static func selectorTargeted(_ entry: Entry) -> Entry {
        guard selectorTargets[entry.name] != nil else { return entry }
        var parameters = entry.parameters.map { parameter -> Parameter in
            switch parameter.name {
            case "ref", "observationID":
                var relaxed = parameter
                relaxed.required = false
                return relaxed
            case "key" where entry.name == "pressKey":
                return Parameter(
                    name: "key", type: "string",
                    description:
                        "Enter, Tab, Escape, Space, ArrowLeft, ArrowRight, ArrowDown, ArrowUp, Home, End, PageUp, PageDown, Backspace, Delete, "
                        + "or one printable ASCII character.")
            default:
                return parameter
            }
        }
        parameters.insert(selector, at: (parameters.firstIndex { $0.name == "ref" } ?? parameters.count - 1) + 1)
        if entry.name == "pressKey" { parameters.append(modifiers) }
        let how = entry.name == "pressKey"
            ? " Sends the key to the page only, never to WSurf's menus or windows."
            : ""
        return Entry(
            name: entry.name,
            description: entry.description + how + " Name the control with ref (from readPage) or selector (development access), not both.",
            parameters: parameters, scope: entry.scope, readOnly: entry.readOnly, usesRef: entry.usesRef, title: entry.title)
    }

    static let inputEntries: [Entry] = [
        Entry(
            name: "dragOnPage",
            description:
                """
                Drag from one element to another, or by an offset, in the top document. By default it dispatches the DOM events of a drag \
                (dragstart, dragover, drop, or pointer and mouse events); they are untrusted and work with the tab in the background. \
                With pointer true it sends trusted pointer input instead (DevTools mouse events on Chromium, native mouse events on WebKit); \
                the tab must be visible, WSurf need not be active. The source is a readPage ref or a selector; the destination is toRef, toSelector, or dx and dy CSS \
                pixels from the source's centre. A selector end needs development access. Both ends must be visible in the viewport; \
                frames, file inputs, disabled and sensitive elements are refused. Verify the returned page.
                """,
            parameters: [
                tab,
                Parameter(
                    name: "observationID", type: "string", description: "Observation ID of the refs used; optional for selectors and offsets.",
                    required: false),
                Parameter(name: "ref", type: "integer", description: "Source: a control ref from readPage.", required: false),
                Parameter(
                    name: "selector", type: "string", description: "Source: a CSS selector for exactly one visible element. Needs development access.",
                    required: false, maxLength: PageRuntime.maxSelectorBytes),
                Parameter(name: "toRef", type: "integer", description: "Destination: a control ref from readPage.", required: false),
                Parameter(
                    name: "toSelector", type: "string",
                    description: "Destination: a CSS selector for exactly one visible element. Needs development access.", required: false,
                    maxLength: PageRuntime.maxSelectorBytes),
                Parameter(
                    name: "dx", type: "integer", description: "Destination: CSS pixels to the right of the source's centre (with dy).", required: false,
                    minimum: -dragOffsetLimit, maximum: dragOffsetLimit),
                Parameter(
                    name: "dy", type: "integer", description: "Destination: CSS pixels below the source's centre (with dx).", required: false,
                    minimum: -dragOffsetLimit, maximum: dragOffsetLimit),
                Parameter(
                    name: "pointer", type: "boolean", description: "Send trusted pointer input instead of DOM events. Default false.", required: false),
            ], scope: .control, title: "Drag on Page"),
    ]

    static let dragOffsetLimit = 5_000
}
