// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// The compact state of a page around an action: its controls, the text in the viewport, the focused element and the scroll
/// position. Two digests are diffed into an `ActionEffect`; neither is sent to a client.
nonisolated struct PageDigest: Equatable, Sendable {
    struct Control: Equatable, Sendable {
        var ref: Int
        var kind: String
        var label: String
        /// `text`, `value`, `filled`, `checked`, `expanded`, `pressed`, `selected` and `disabled`, for the ones the control has.
        /// A sensitive field has `filled` and never `value`.
        var state: [String: String]
        var inViewport: Bool
        /// The control as `readPage` prints it, so a client reads one format and the observed-link rule sees the same lines.
        var line: String
        /// Hash of the control's signature when the digest was taken (0 when it was not asked for): what a reply that lists the
        /// control acknowledges the client has seen.
        var signature = 0
    }

    var documentID: String
    var url: String
    var title: String
    var snapshot: String
    var controls: [Control]
    var controlTotal: Int
    var texts: [String]
    /// The focused element as `[ref] kind "label"`, or nil when nothing but the page itself has focus.
    var focus: String?
    var scrollY = 0
    var scrollHeight = 0
    var viewportHeight = 0
}

/// What one action changed, in the order a client wants to read it. Strings from the page (labels, text, console messages,
/// URLs) are untrusted: the reply wraps the rendering as it wraps every page text.
nonisolated struct ActionEffect: Codable, Equatable, Sendable {
    enum Navigation: String, Codable, Sendable {
        case none, sameDocument, load
    }

    struct Line: Codable, Equatable, Sendable {
        var ref: Int
        var text: String
    }

    struct Change: Codable, Equatable, Sendable {
        var ref: Int
        var field: String
        var from: String
        var to: String
    }

    struct FailedRequest: Codable, Equatable, Sendable {
        var method: String
        var url: String
        var status: Int?
    }

    struct Popup: Codable, Equatable, Sendable {
        var title: String
        var url: String
    }

    struct Console: Codable, Equatable, Sendable {
        var errors: Int
        var first: [String]
    }

    var action: String
    /// The driver's own line, for example `Clicked “Add to cart”.`
    var status: String
    var navigation = Navigation.none
    var url: String?
    var title: String?
    var added: [Line] = []
    var removed: [Int] = []
    var changed: [Change] = []
    var textAdded: [String] = []
    var textRemoved: [String] = []
    var focus: String?
    var scroll: String?
    var console: Console?
    var failedRequests: [FailedRequest] = []
    var popups: [Popup] = []
    var diagnosticsRunning = false
    /// The effect holds only the driver's status line: the action failed, or the page could not be read afterwards.
    var statusOnly = false
    /// After a navigation there is nothing to diff against: the new page's viewport text and controls instead.
    var pageText: String?
    var pageControls: [Line] = []
    var observationID: String?

    /// What a rendering keeps. `shrink()` narrows it until the reply fits the caller's byte budget.
    struct Limits: Equatable, Sendable {
        var added = 10
        var removed = 20
        var changed = 20
        var text = 3
        var textCharacters = 200
        var console = 3
        var failed = 3
        var pageText = 600
        var pageControls = 15

        /// Halves the first limit that is still above its floor. False when nothing is left to give up.
        mutating func shrink() -> Bool {
            let steps: [(WritableKeyPath<Limits, Int>, Int)] = [
                (\.pageControls, 3), (\.pageText, 100), (\.textCharacters, 40), (\.text, 1), (\.changed, 3), (\.added, 3),
                (\.removed, 3), (\.console, 1), (\.failed, 1), (\.pageControls, 0), (\.pageText, 0), (\.changed, 1), (\.added, 1),
                (\.removed, 0), (\.textCharacters, 20),
            ]
            for (path, floor) in steps where self[keyPath: path] > floor {
                self[keyPath: path] = max(floor, self[keyPath: path] / 2)
                return true
            }
            return false
        }
    }

    struct Rendered: Equatable, Sendable {
        /// The text a client reads; page-derived strings are not yet wrapped as untrusted.
        var text: String
        /// Refs this rendering gives the client: the only new ones it may use.
        var refs: Set<Int>
        /// A limit cut something the effect holds.
        var truncated: Bool
    }

    var isEmpty: Bool {
        navigation == .none && added.isEmpty && removed.isEmpty && changed.isEmpty && textAdded.isEmpty && textRemoved.isEmpty
            && focus == nil && scroll == nil && console == nil && failedRequests.isEmpty && popups.isEmpty
    }

    /// The lines of a rendering and what the limits cut from it.
    private struct Writer {
        let limits: Limits
        var lines: [String] = []
        var refs = Set<Int>()
        var truncated = false

        mutating func clipped(_ text: String, _ count: Int) -> String {
            guard text.count > count else { return text }
            truncated = true
            return String(text.prefix(max(0, count - 1))) + "…"
        }

        mutating func quoted(_ list: [String]) -> String {
            list.map { "\"" + clipped($0, limits.textCharacters) + "\"" }.joined(separator: " | ")
        }
    }

    func render(_ limits: Limits = Limits()) -> Rendered {
        var writer = Writer(limits: limits, lines: [status.trimmingCharacters(in: .whitespacesAndNewlines)])
        if navigation != .none {
            writer.lines.append("navigation: \(navigation.rawValue)" + (url.map { " → " + $0 } ?? ""))
        }
        if navigation == .load {
            renderPage(into: &writer)
        } else {
            renderControls(into: &writer)
            renderText(into: &writer)
        }
        renderState(into: &writer)
        renderDiagnostics(into: &writer)
        if isEmpty, !statusOnly {
            writer.lines.append("No visible change.")
        }
        return Rendered(text: writer.lines.joined(separator: "\n"), refs: writer.refs, truncated: writer.truncated)
    }

    /// A navigation has nothing to diff against: the new page's title, text and controls.
    private func renderPage(into writer: inout Writer) {
        if let title, !title.isEmpty {
            writer.lines.append("title: \"\(writer.clipped(title, 120))\"")
        }
        if let pageText, writer.limits.pageText > 0, !pageText.isEmpty {
            let cut = String(pageText.prefix(writer.limits.pageText))
            writer.truncated = writer.truncated || cut.count < pageText.count
            writer.lines.append("page text: " + cut)
        }
        let shown = pageControls.prefix(writer.limits.pageControls)
        writer.truncated = writer.truncated || shown.count < pageControls.count
        for control in shown {
            writer.lines.append(control.text)
            writer.refs.insert(control.ref)
        }
    }

    private func renderControls(into writer: inout Writer) {
        let limits = writer.limits
        if !added.isEmpty, limits.added > 0 {
            let shown = added.prefix(limits.added)
            writer.lines.append("added (\(added.count)):")
            for control in shown {
                writer.lines.append(control.text)
                writer.refs.insert(control.ref)
            }
            if shown.count < added.count {
                writer.truncated = true
                writer.lines.append("… \(added.count - shown.count) more; readPage lists them.")
            }
        } else if !added.isEmpty {
            writer.truncated = true
            writer.lines.append("added: \(added.count) controls; readPage lists them.")
        }
        if !removed.isEmpty {
            let shown = removed.prefix(limits.removed)
            writer.truncated = writer.truncated || shown.count < removed.count
            writer.lines.append(
                "removed: " + shown.map { "[\($0)]" }.joined(separator: ", ")
                    + (shown.count < removed.count ? " and \(removed.count - shown.count) more" : ""))
        }
        if !changed.isEmpty, limits.changed > 0 {
            let shown = changed.prefix(limits.changed)
            writer.lines.append("changed:")
            for change in shown {
                let quotes = change.field == "text" || change.field == "value"
                let from = quotes ? "\"" + writer.clipped(change.from, 60) + "\"" : change.from
                let to = quotes ? "\"" + writer.clipped(change.to, 60) + "\"" : change.to
                writer.lines.append("[\(change.ref)] \(change.field) \(from) → \(to)")
                writer.refs.insert(change.ref)
            }
            if shown.count < changed.count {
                writer.truncated = true
                writer.lines.append("… \(changed.count - shown.count) more changes.")
            }
        } else if !changed.isEmpty {
            writer.truncated = true
            writer.lines.append("changed: \(changed.count) controls; readPage lists them.")
        }
    }

    private func renderText(into writer: inout Writer) {
        let limit = writer.limits.text
        guard limit > 0 else { return }
        if !textAdded.isEmpty {
            writer.lines.append("text added: " + writer.quoted(Array(textAdded.prefix(limit))))
            writer.truncated = writer.truncated || textAdded.count > limit
        }
        if !textRemoved.isEmpty {
            writer.lines.append("text removed: " + writer.quoted(Array(textRemoved.prefix(limit))))
            writer.truncated = writer.truncated || textRemoved.count > limit
        }
    }

    private func renderState(into writer: inout Writer) {
        if let focus {
            writer.lines.append("focus: " + focus)
        }
        if let scroll {
            writer.lines.append("scroll: " + scroll)
        }
    }

    private func renderDiagnostics(into writer: inout Writer) {
        if let console {
            let first = console.first.prefix(writer.limits.console).map { "\"" + writer.clipped($0, writer.limits.textCharacters) + "\"" }
            writer.lines.append(
                "console: \(console.errors) new error\(console.errors == 1 ? "" : "s")"
                    + (first.isEmpty ? "" : ": " + first.joined(separator: " | ")))
        }
        if !failedRequests.isEmpty {
            let shown = failedRequests.prefix(writer.limits.failed)
            writer.truncated = writer.truncated || shown.count < failedRequests.count
            let listed = shown.map { request in
                "\(request.method) \(writer.clipped(request.url, 120)) " + (request.status.map(String.init) ?? "failed")
            }
            writer.lines.append("failed requests: " + listed.joined(separator: " | "))
        }
        for popup in popups.prefix(2) {
            writer.lines.append("opened: \"\(writer.clipped(popup.title, 60))\" → \(writer.clipped(popup.url, 200))")
        }
    }
}

extension ActionEffect {
    /// Diffs the page before and after an action. `viewportOnly` is a scroll: controls and text leaving the viewport are not
    /// removals, and the scroll position is always reported.
    static func make(action: String, status: String, before: PageDigest, after: PageDigest, viewportOnly: Bool = false) -> ActionEffect {
        var effect = ActionEffect(action: action, status: status)
        effect.observationID = after.snapshot
        if after.documentID != before.documentID {
            effect.navigation = .load
            effect.url = after.url
            effect.title = after.title
            // Viewport controls first: they are the ones a client can act on without scrolling.
            let ordered = after.controls.filter(\.inViewport) + after.controls.filter { !$0.inViewport }
            effect.pageControls = ordered.filter { $0.ref > 0 }.map { Line(ref: $0.ref, text: $0.line) }
            effect.pageText = after.texts.joined(separator: " ")
            effect.focus = after.focus.map { "none → " + $0 }
            return effect
        }
        if after.url != before.url {
            effect.navigation = .sameDocument
            effect.url = after.url
        }
        let known = Dictionary(before.controls.filter { $0.ref > 0 }.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let present = Dictionary(after.controls.filter { $0.ref > 0 }.map { ($0.ref, $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = after.controls.filter { $0.ref > 0 && known[$0.ref] == nil }
        effect.added = (fresh.filter(\.inViewport) + fresh.filter { !$0.inViewport }).map { Line(ref: $0.ref, text: $0.line) }
        if !viewportOnly {
            effect.removed = before.controls.filter { $0.ref > 0 && present[$0.ref] == nil }.map(\.ref)
        }
        for control in after.controls where control.ref > 0 {
            guard let old = known[control.ref] else { continue }
            for field in fields {
                let from = old.state[field], to = control.state[field]
                if from != to, let to {
                    effect.changed.append(Change(ref: control.ref, field: field, from: from ?? "", to: to))
                }
            }
        }
        let labels = Set((before.controls + after.controls).map(\.label))
        func isControlText(_ text: String) -> Bool {
            labels.contains(text) || (text.count > 60 && labels.contains(String(text.prefix(60))))
        }
        effect.textAdded = difference(after.texts, minus: before.texts).filter { !isControlText($0) }
        if !viewportOnly {
            effect.textRemoved = difference(before.texts, minus: after.texts).filter { !isControlText($0) }
        }
        if before.focus != after.focus {
            effect.focus = (before.focus ?? "none") + " → " + (after.focus ?? "none")
        }
        // Only a scroll reports it: acting on a control scrolls it into view, which says nothing about the page.
        if action == "scrollPage" {
            effect.scroll = "\(after.scrollY) of \(max(0, after.scrollHeight - after.viewportHeight)) px"
        }
        return effect
    }

    /// The order a control's changed fields are listed in.
    private static let fields = ["text", "value", "filled", "checked", "expanded", "pressed", "selected", "disabled"]

    /// The members of `list` left after taking one occurrence out for each member of `taken`, in order.
    static func difference(_ list: [String], minus taken: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for text in taken {
            counts[text, default: 0] += 1
        }
        return list.filter { text in
            if let count = counts[text], count > 0 {
                counts[text] = count - 1
                return false
            }
            return true
        }
    }
}
