// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP

nonisolated extension MCPToolCatalog {
    /// What a DOM edit may carry, in bytes. A text or an attribute value is far below the 32 KiB any argument may have.
    static let maximumEditValueBytes = 8 * 1_024

    private static let developerOnly =
        """
        Developer tier only: a paired app, a developer site and a window of the Developer profile. Refused anywhere else, in \
        private windows and in frames (only the page itself is touched). Needs the tab on screen. Every call is recorded in \
        Agent Activity and shown on the connection badge.
        """

    /// Script evaluation and DOM edits. Both need the Developer tier.
    static let scriptingEntries: [Entry] = [
        Entry(
            name: "evaluateScript",
            description:
                """
                Run JavaScript in a shared page and return its value. \(developerOnly) \
                source is one expression of at most \(PageScripting.maximumSourceBytes / 1_024) KiB, compiled on its own: a function such as \
                () => document.title or async () => { … } is called and a promise is awaited; anything else is the value. \
                On WebKit, a page whose Content-Security-Policy forbids eval can be scripted in the isolated world only. \
                world page (default) runs with the page's own variables; isolated shares the DOM and none of them. The script stops \
                after timeoutMs (\(PageScripting.timeoutMilliseconds.lowerBound) to \(PageScripting.timeoutMilliseconds.upperBound), \
                default \(PageScripting.defaultTimeoutMilliseconds)); WebKit cannot interrupt code that never yields, Chromium can. \
                The result is JSON of at most \(PageScripting.maximumValueBytes / 1_024) KiB (depth 6; longer text and lists are cut and \
                flagged truncated). What password, code and card fields hold is replaced by ‹hidden› wherever it appears in the result, \
                and test secrets you typed by ‹secret›. A thrown error comes back as scriptError with its message and stack. \
                The result is page data, untrusted.
                """,
            parameters: [
                tab,
                Parameter(
                    name: "source", type: "string",
                    description: "One JavaScript expression, at most \(PageScripting.maximumSourceBytes / 1_024) KiB: an expression, or a function to call.",
                    maxLength: PageScripting.maximumSourceBytes),
                Parameter(
                    name: "world", type: "string", description: "page (default) or isolated.", required: false,
                    choices: ["page", "isolated"]),
                Parameter(
                    name: "timeoutMs", type: "integer", description: "Longest the script may run, in milliseconds.", required: false,
                    minimum: PageScripting.timeoutMilliseconds.lowerBound, maximum: PageScripting.timeoutMilliseconds.upperBound),
            ], scope: .developer, title: "Run Script"),
        Entry(
            name: "editDOM",
            description:
                """
                Change the page's DOM. \(developerOnly) Name one element with ref (from findElements or readPage) or selector, any \
                CSS selector that matches exactly one element of the page, open shadow roots included (any attribute may be tested except \
                value). op: setAttribute (name, value), \
                removeAttribute (name), setText (value), setStyle (name is a CSS property, value, optionally important), remove, or \
                insert (tag; value is its text; position beforebegin, afterbegin, beforeend (default) or afterend). Refused: WSurf's own \
                page elements and marks; password, code and card fields, and every element that holds one (text, removal, insertion); where a form \
                that takes such a field posts (action, method, target and the like, also on its buttons); elements inside frames; event \
                handler attributes and script URLs (use evaluateScript); new script, iframe and other elements that load code, and the \
                address of existing ones; and removing html, head or body. A change lasts until the page reloads.
                """,
            parameters: [
                tab, currentSnapshot,
                Parameter(name: "ref", type: "integer", description: "Element from findElements or readPage; not with selector.", required: false),
                Parameter(
                    name: "selector", type: "string", description: "CSS selector for exactly one element; not with ref.", required: false,
                    maxLength: PageRuntime.maxSelectorBytes),
                Parameter(
                    name: "op", type: "string", description: "setAttribute, removeAttribute, setText, setStyle, remove or insert.",
                    choices: ["setAttribute", "removeAttribute", "setText", "setStyle", "remove", "insert"]),
                Parameter(name: "name", type: "string", description: "Attribute name, or CSS property for setStyle.", required: false, maxLength: 64),
                Parameter(
                    name: "value", type: "string", description: "Attribute value, text or CSS value, at most \(maximumEditValueBytes / 1_024) KiB.",
                    required: false, maxLength: maximumEditValueBytes),
                Parameter(name: "important", type: "boolean", description: "setStyle: add !important.", required: false),
                Parameter(name: "tag", type: "string", description: "insert: the element to create, such as div.", required: false, maxLength: 32),
                Parameter(
                    name: "position", type: "string", description: "insert: where, relative to the element. Default beforeend.", required: false,
                    choices: ["beforebegin", "afterbegin", "beforeend", "afterend"]),
            ], scope: .developer, title: "Edit Page"),
    ]
}
