// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import MCP

/// MCP v2 Phase 2: background pointer input, fewer turns, and the catalog profiles of the stdio relay.
nonisolated extension MCPToolCatalog {
    // MARK: Profiles

    /// Which tools a client sees, from `--tools=` on `WSurf --mcp`. `all` (the default) keeps the full catalog.
    enum Profile: String, CaseIterable, Sendable {
        /// WSurf's own tools only, without the Playwright aliases.
        case core
        /// The Playwright MCP aliases only.
        case playwright
        case all

        /// `--tools=core`, or `--tools core`. Nil when the option is absent; a value that names no profile is an error.
        static func parse(_ arguments: [String]) -> Result<Profile?, MCPError> {
            var value: String?
            for (index, argument) in arguments.enumerated() {
                if argument.hasPrefix("--tools=") {
                    value = String(argument.dropFirst("--tools=".count))
                } else if argument == "--tools" {
                    value = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
                }
            }
            guard let value else { return .success(nil) }
            guard let profile = Profile(rawValue: value.lowercased()) else {
                return .failure(.invalidParams("--tools must be core, playwright, or all."))
            }
            return .success(profile)
        }
    }

    static func listed(for profile: Profile) -> [Entry] {
        switch profile {
        case .core:
            entries
        case .playwright:
            playwrightEntries
        case .all:
            listed
        }
    }

    // MARK: Shared parameters

    static let settle = Parameter(
        name: "settle", type: "string",
        description:
            "How long to wait for the page after the action. auto (default): until quiet, up to budget.settleMs, ignoring animation "
            + "and off-screen noise. fast: 60 ms of quiet, at most 350 ms. none: return at once.",
        required: false, choices: ["none", "fast", "auto"])

    static let waitAndRead = Parameter(
        name: "waitAndRead", type: "boolean",
        description:
            "Wait for the page to load and return its first observation (text, controls, observationID, vaultHint) in this reply. "
            + "Default true; false returns as soon as navigation starts.",
        required: false)

    private static let pointerX = Parameter(
        name: "x", type: "number", description: "Viewport CSS pixels from the left, with y: act at this point instead of a ref.",
        required: false, minimum: 0, maximum: 100_000)
    private static let pointerY = Parameter(
        name: "y", type: "number", description: "Viewport CSS pixels from the top, with x.", required: false, minimum: 0, maximum: 100_000)

    /// `entry` with the pointer options of Phase 2: a point instead of a ref for click, hover and scroll, and for click the
    /// button, click count, modifiers and trusted pointer input.
    static func pointerTargeted(_ entry: Entry) -> Entry {
        let added: [Parameter]
        var note: String
        switch entry.name {
        case "clickOnPage":
            added = [
                pointerX, pointerY,
                Parameter(name: "button", type: "string", description: "left (default), right, or middle.", required: false, choices: ["left", "right", "middle"]),
                Parameter(name: "clickCount", type: "integer", description: "1 (default) or 2 for a double click.", required: false, minimum: 1, maximum: 2),
                Parameter(
                    name: "modifiers", type: "string", description: "Plus-separated shift, option, command held during the click. Control is refused.",
                    required: false, maxLength: 64),
                Parameter(
                    name: "pointer", type: "boolean",
                    description: "Send trusted pointer input (isTrusted) instead of a DOM click. Default false for a ref, true with x and y.",
                    required: false),
            ]
            note =
                " With x and y, or pointer true, WSurf hit-tests the point and sends trusted pointer input: through DevTools on Chromium, "
                + "also in a background tab without moving the user's cursor or focus; a background WebKit tab refuses. File inputs, "
                + "password reveal toggles on a protected form, and consequential buttons keep their protections."
        case "hoverOnPage":
            added = [pointerX, pointerY]
            note = " Or give x and y. On Chromium the pointer is a DevTools pointer, so it works in a background tab and WSurf need not be active."
        case "scrollPage":
            added = [pointerX, pointerY]
            note = " With x and y the wheel scrolls whatever is under that point (DevTools wheel input on Chromium)."
        default:
            return entry
        }
        if entry.name == "hoverOnPage" {
            note += " A background WebKit tab answers unsupported; use switchTab or a Chromium tab."
        }
        let parameters = entry.parameters + added
        return Entry(
            name: entry.name, description: entry.description + note, parameters: parameters, scope: entry.scope,
            readOnly: entry.readOnly, usesRef: entry.usesRef, title: entry.title)
    }

    /// Phase 2 options of tools defined elsewhere: `waitAndRead` on navigation, `includeSnapshot` on screenshots, a submit on
    /// `fillFields`, and `settle` on every action that reports what it changed.
    static func speedTargeted(_ entry: Entry) -> Entry {
        var parameters = entry.parameters
        var description = entry.description
        switch entry.name {
        case "newTab", "navigate":
            parameters.append(waitAndRead)
            description += " By default the reply waits for the page and includes its first observation, so no readPage is needed."
        case "screenshotPage":
            parameters.append(
                Parameter(
                    name: "includeSnapshot", type: "boolean",
                    description:
                        "Also return the viewport's text and controls. Default false when this connection holds a current observation "
                        + "of the page, true otherwise.",
                    required: false))
        case "fillFields":
            parameters += [
                Parameter(name: "submitRef", type: "integer", description: "Click this control (a submit button) after every field is filled and verified.", required: false),
                Parameter(name: "submit", type: "boolean", description: "Submit the form of the last text field after filling (Enter).", required: false),
            ]
            description += " All fields are checked, filled and verified in one pass; submitRef or submit finishes the form in the same call."
        default:
            break
        }
        if parameters.contains(where: { $0.name == "budget" }) {
            parameters.append(settle)
        }
        return Entry(
            name: entry.name, description: description, parameters: parameters, scope: entry.scope, readOnly: entry.readOnly,
            usesRef: entry.usesRef, title: entry.title)
    }

    // MARK: runSteps

    nonisolated static let maximumSteps = 10

    /// The step names `runSteps` takes, and the tool each one runs.
    static let stepTools: [String: String] = [
        "fillFields": "fillFields", "click": "clickOnPage", "clickOnPage": "clickOnPage", "type": "typeOnPage", "typeOnPage": "typeOnPage",
        "pressKey": "pressKey", "waitForPage": "waitForPage", "scroll": "scrollPage", "scrollPage": "scrollPage",
        "hover": "hoverOnPage", "hoverOnPage": "hoverOnPage",
    ]

    /// Shape only: 1 to `maximumSteps` objects with a known `tool` and an optional `arguments` object. Each step's arguments are
    /// checked by its own tool's entry when it runs.
    static func isSteps(_ items: [Value]) -> Bool {
        (1...maximumSteps).contains(items.count)
            && items.allSatisfy { item in
                guard case .object(let step) = item, Set(step.keys).isSubset(of: ["tool", "arguments"]),
                    let tool = step["tool"]?.stringValue, stepTools[tool] != nil
                else { return false }
                return step["arguments"].map { $0.objectValue != nil } ?? true
            }
    }

    static func stepsSchema(_ description: String) -> Value {
        .object([
            "type": "array", "minItems": 1, "maxItems": .int(maximumSteps), "description": .string(description),
            "items": .object([
                "type": "object", "additionalProperties": false, "required": ["tool"],
                "properties": .object([
                    "tool": .object(["type": "string", "enum": .array(stepTools.keys.sorted().map { .string($0) })]),
                    "arguments": .object([
                        "type": "object",
                        "description": "The tool's own arguments without tabID; refs, observationID and every other rule are the tool's.",
                    ]),
                ]),
            ]),
        ])
    }

    static let speedEntries: [Entry] = [
        Entry(
            name: "runSteps",
            description: """
                Run up to 10 page actions on one shared tab in a single call: fillFields, click, type, pressKey, waitForPage, scroll \
                and hover, each with its own arguments (no tabID) and every rule that tool has. Stops at the first step that fails, \
                opens a dialog, navigates to another website, loses access or is taken over by the user, is declined, or would expose \
                a protected secret. Returns completedSteps, failedStepIndex and error when one failed, a short summary per step, and \
                the last step's result (delta, observationID).
                """,
            parameters: [
                tab,
                Parameter(name: "steps", type: "steps", description: "One to 10 steps, each {tool, arguments}."),
            ], scope: .control, title: "Run Steps"),
    ]
}
