// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import MCP

/// Limits for one call, from its `budget` argument.
nonisolated struct FeedbackBudget: Equatable, Sendable {
    static let bytes = 1_000...60_000
    static let settle = 200...5_000
    static let defaultBytes = 4_000
    static let defaultSettle = 1_500

    var maxBytes = FeedbackBudget.defaultBytes
    var settleMs = FeedbackBudget.defaultSettle

    /// Exactly the keys `maxBytes` and `settleMs`, each an integer in its range. The catalog has shape-checked the value.
    init(_ value: Value? = nil) {
        guard case .object(let box)? = value else { return }
        maxBytes = box["maxBytes"]?.intValue ?? Self.defaultBytes
        settleMs = box["settleMs"]?.intValue ?? Self.defaultSettle
    }

    static func isValid(_ box: [String: Value]) -> Bool {
        guard Set(box.keys).isSubset(of: ["maxBytes", "settleMs"]) else { return false }
        return (box["maxBytes"].map { value in value.intValue.map { bytes.contains($0) } ?? false } ?? true)
            && (box["settleMs"].map { value in value.intValue.map { settle.contains($0) } ?? false } ?? true)
    }
}

/// What a connection keeps between its screenshots.
@MainActor
final class MCPActionFeedbackState {
    var lastCapture: ContinuousClock.Instant?
    /// At most two captures a second: an image is the costliest thing a call returns.
    var captureInterval: Duration = .milliseconds(500)
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
}

/// New console errors and failed requests of a tab whose diagnostics capture this connection runs. Marks the end of both
/// streams when it is created, so only what the action caused is reported.
@MainActor
struct MCPDiagnosticsWatch {
    private let diagnostics: DevelopmentDiagnostics?
    private let consoleMark: String?
    private let networkMark: String?

    var isRunning: Bool {
        diagnostics != nil
    }

    init(tab: BrowserTab, connection: UUID) {
        guard tab.developmentRelation(of: connection) == .own, let running = tab.developmentOwner?.diagnostics else {
            diagnostics = nil
            consoleMark = nil
            networkMark = nil
            return
        }
        diagnostics = running
        consoleMark = running.buffer.head(of: .console)
        networkMark = running.buffer.head(of: .network)
    }

    func changes() async -> (console: ActionEffect.Console?, failed: [ActionEffect.FailedRequest]) {
        guard let diagnostics, await diagnostics.sync() else { return (nil, []) }
        func text(_ record: PageDiagnostics.Record, _ key: String) -> String? {
            guard case .text(let value)? = record.fields[key] else { return nil }
            return value
        }
        let errors = diagnostics.buffer.records(of: .console, after: consoleMark).filter { text($0, "level") == "error" }
        let failed = diagnostics.buffer.records(of: .network, after: networkMark).compactMap { record -> ActionEffect.FailedRequest? in
            var status: Int?
            if case .number(let value)? = record.fields["status"] { status = value }
            guard text(record, "outcome") == "failed" || (status ?? 0) >= 400 else { return nil }
            return .init(method: text(record, "method") ?? "GET", url: text(record, "url") ?? "", status: status)
        }
        return (errors.isEmpty ? nil : .init(errors: errors.count, first: errors.prefix(3).compactMap { text($0, "text") }), failed)
    }
}

extension PageDiagnostics.Buffer {
    /// The cursor after the newest record of `stream`: what is written later is new.
    func head(of stream: PageDiagnostics.Stream) -> String? {
        var cursor: String?
        for _ in 0..<(Self.maxReadLimit + 1) {
            guard let page = try? read(stream: stream, cursor: cursor, limit: Self.maxReadLimit) else { return cursor }
            cursor = page.nextCursor
            if page.records.count < Self.maxReadLimit {
                break
            }
        }
        return cursor
    }

    /// The records of `stream` written after `cursor`. A cursor from before a navigation names an epoch that no longer
    /// exists; everything the new document wrote so far is then new.
    func records(of stream: PageDiagnostics.Stream, after cursor: String?) -> [PageDiagnostics.Record] {
        var cursor = cursor
        var found: [PageDiagnostics.Record] = []
        for _ in 0..<12 {
            let page: PageDiagnostics.Page
            do {
                page = try read(stream: stream, cursor: cursor, limit: Self.maxReadLimit)
            } catch {
                guard cursor != nil else { break }
                cursor = nil
                continue
            }
            found += page.records
            guard page.records.count == Self.maxReadLimit else { break }
            cursor = page.nextCursor
        }
        return found
    }
}

/// Actions that report what they changed instead of the whole page.
@MainActor
extension MCPBrowserSession {
    static let feedbackActions: Set<String> = [
        "clickOnPage", "typeOnPage", "selectOption", "setChecked", "fillFields", "scrollPage", "pressKey", "hoverOnPage",
    ]

    /// Whether a page tool's text is the success of its action, not a refusal or an error message.
    static func succeeded(_ name: String, _ output: String) -> Bool {
        let prefixes = [
            "PAGE TEXT:", "Clicked", "Typed", "Selected", "Scrolled", "Already at", "Went back.",
            "CONTROL:", "Condition met.", "Set checked", "Checked state", "Screenshot captured.", "Hovered.", "Sent ", "ELEMENTS:", "ELEMENT:",
        ]
        return prefixes.contains { output.hasPrefix($0) } || (name == "fillFields" && output.hasPrefix("Filled "))
    }

    /// Runs `name` and returns what it changed. Nil when the page cannot be digested beforehand: the caller then answers with
    /// the whole page, as `result: full` does.
    func deltaAction(
        name: String, arguments: [String: Value], tab: BrowserTab, view: BrowserPage, scope: PageAutomationGuard,
        reading: PageAutomationGuard, observation: PageObservation?
    ) async -> CallTool.Result? {
        let budget = FeedbackBudget(arguments["budget"])
        let viewportOnly = name == "scrollPage" && arguments["ref"] == nil
        guard let before = await PageDriver.digest(in: view, commit: false, viewportOnly: viewportOnly) else { return nil }
        let watch = MCPDiagnosticsWatch(tab: tab, connection: id)
        let tabsBefore = Set(browser.tabs.map(\.id))
        let clock = ContinuousClock()
        let started = clock.now
        let meter = PageSettle.Meter()
        let output = await PageSettle.$meter.withValue(meter) {
            await PageSettle.$limits.withValue(.init(grace: .zero, quietCeiling: .milliseconds(budget.settleMs))) {
                await PageDriver.$feedbackMode.withValue(.delta) {
                    await pageAction(name: name, arguments: arguments, view: view)
                }
            }
        }
        guard reading.validate(), !Task.isCancelled else {
            observations[tab.id] = nil
            return failure("Page access changed before the operation finished. Its contents were not returned.")
        }
        let status = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = arguments["ref"]?.intValue ?? arguments["fields"]?.arrayValue?.first?.objectValue?["ref"]?.intValue
        guard Self.succeeded(name, output) else {
            keepObservation(observation, for: tab, in: view)
            var effect = ActionEffect(action: name, status: status)
            effect.statusOnly = true
            let image = await failureImage(arguments["screenshotOnFailure"]?.stringValue, ref: target, tab: tab, view: view, scope: scope)
            if image != nil { effect.status += "\nscreenshot: " + (arguments["screenshotOnFailure"]?.stringValue ?? "viewport") }
            return feedbackReply(
                name: name, tab: tab, effect: effect, budget: budget, settle: meter.elapsed, started: started, ok: false, image: image).result
        }
        guard let after = await PageDriver.digestAfterAction(in: view, viewportOnly: viewportOnly, validate: reading.validate) else {
            observations[tab.id] = nil
            var effect = ActionEffect(action: name, status: status)
            effect.statusOnly = true
            effect.status += "\nThe page did not answer afterwards. Use readPage."
            return feedbackReply(name: name, tab: tab, effect: effect, budget: budget, settle: meter.elapsed, started: started, ok: true, image: nil).result
        }
        guard reading.validate(), !Task.isCancelled else {
            observations[tab.id] = nil
            return failure("Page access changed before the operation finished. Its contents were not returned.")
        }
        var effect = ActionEffect.make(action: name, status: status, before: before, after: after, viewportOnly: viewportOnly)
        let changes = await watch.changes()
        effect.diagnosticsRunning = watch.isRunning
        effect.console = changes.console
        effect.failedRequests = changes.failed
        effect.popups = openedTabs(since: tabsBefore, by: tab)
        // The client now holds the refs this reply lists, besides those of earlier replies for the same document.
        let reply = feedbackReply(name: name, tab: tab, effect: effect, budget: budget, settle: meter.elapsed, started: started, ok: true, image: nil)
        guard reading.validate(), !Task.isCancelled else {
            observations[tab.id] = nil
            return failure("Page access changed before the operation finished. Its contents were not returned.")
        }
        PageDriver.adopt(after, listed: reply.refs, in: view)
        observations[tab.id] = PageObservation(id: after.snapshot, snapshot: after.snapshot, documentURL: after.url)
        hasReadContent = true
        destinations.formUnion(PageDriver.listedLinks(in: reply.text).map { destinationKey($0.url) })
        for popup in effect.popups {
            if let url = URL(string: popup.url) {
                destinations.insert(destinationKey(url))
            }
        }
        return reply.result
    }

    /// A failed action changes nothing the client holds, so the observation it has stays usable while the page still has it.
    private func keepObservation(_ observation: PageObservation?, for tab: BrowserTab, in view: BrowserPage) {
        if let observation, PageDriver.observation(in: view)?.id == observation.id {
            observations[tab.id] = observation
        } else {
            observations[tab.id] = nil
        }
    }

    /// The tabs that appeared during the action and were opened by `opener`'s own page. A tab a person, another window or
    /// another page opened meanwhile is neither reported nor made a destination the connection may navigate to.
    private func openedTabs(since known: Set<UUID>, by opener: BrowserTab) -> [ActionEffect.Popup] {
        browser.tabs.compactMap { tab in
            guard !known.contains(tab.id), browser.openerByTab[tab.id] == opener.id, !tab.isPrivate, let url = URL(string: tab.urlString),
                ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else { return nil }
            return .init(title: tab.title, url: url.absoluteString)
        }
    }

    // MARK: Reply

    private func compact(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The reply for `effect` within `budget.maxBytes` of text: the rendering gives up detail, step by step, until the whole
    /// text block fits. `refs` are the controls the client was told about.
    func feedbackReply(
        name: String, tab: BrowserTab, effect: ActionEffect, budget: FeedbackBudget, settle: Duration, started: ContinuousClock.Instant,
        ok: Bool, image: Data?
    ) -> (result: CallTool.Result, text: String, refs: Set<Int>) {
        let clock = ContinuousClock()
        func milliseconds(_ duration: Duration) -> Int {
            Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
        }
        var limits = ActionEffect.Limits()
        var rendered = effect.render(limits)
        var truncated = rendered.truncated
        var bytes = 0
        func value(_ text: String) -> Value {
            var cost: [String: Value] = [
                "bytes": .int(bytes), "settleMs": .int(milliseconds(settle)), "totalMs": .int(milliseconds(started.duration(to: clock.now))),
            ]
            if truncated { cost["truncated"] = true }
            var fields: [String: Value] = [
                "tabID": .string(tab.id.uuidString), "status": .string(ok ? "ok" : "failed"), "action": .string(name),
                "content": .string(AgentToolkit.untrusted(text)), "cost": .object(cost),
            ]
            fields["navigation"] = .string(effect.navigation.rawValue)
            if effect.navigation != .none, let url = effect.url, PageOutputBudget.cost(url) <= 512 { fields["url"] = .string(url) }
            if let id = effect.observationID, ok { fields["observationID"] = .string(id) }
            if !effect.diagnosticsRunning { fields["diagnostics"] = "off" }
            return .object(fields)
        }
        /// The size field is part of what it measures, so it is settled by repeating until it stops changing.
        func measure(_ text: String) -> Int {
            for _ in 0..<4 {
                let size = compact(value(text)).utf8.count
                if size == bytes {
                    break
                }
                bytes = size
            }
            return bytes
        }
        while measure(rendered.text) > budget.maxBytes, limits.shrink() {
            rendered = effect.render(limits)
            truncated = true
        }
        var text = rendered.text
        var refs = rendered.refs
        if bytes > budget.maxBytes {
            // Nothing is left to give up: cut the text itself.
            truncated = true
            var keep = text.utf8.count
            while bytes > budget.maxBytes, keep > 0 {
                keep = keep * 9 / 10 - 1
                text = PageOutputBudget.prefix(rendered.text, fitting: max(0, keep))
                _ = measure(text)
            }
            let shown = Set(text.split(separator: "\n").compactMap { line -> Int? in
                guard line.hasPrefix("["), let end = line.firstIndex(of: "]") else { return nil }
                return Int(line[line.index(after: line.startIndex)..<end])
            })
            refs.formIntersection(shown)
        }
        let json: Value = value(text)
        var blocks: [MCP.Tool.Content] = [.text(text: compact(json), annotations: nil, _meta: nil)]
        if let image { blocks.append(.image(data: image.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil)) }
        var result = CallTool.Result(content: blocks, structuredContent: Optional.some(json), isError: !ok)
        if image != nil, Self.replyBytes(result) > MCPMessageFramer.maximumBytes {
            result = CallTool.Result(content: [blocks[0]], structuredContent: Optional.some(json), isError: !ok)
        }
        return (result, text, refs)
    }

    // MARK: Screenshots

    /// At most two captures a second per connection.
    func throttleCapture() async {
        if let last = feedback.lastCapture {
            let wait = feedback.captureInterval - last.duration(to: .now)
            if wait > .zero {
                await feedback.sleep(wait)
            }
        }
        feedback.lastCapture = .now
    }

    /// The image of a failed action, when the client asked for one: the element first, then the viewport. Small enough to
    /// look at, and refused wherever a screenshot is.
    func failureImage(_ mode: String?, ref: Int?, tab: BrowserTab, view: BrowserPage, scope: PageAutomationGuard) async -> Data? {
        guard let mode, scope.validate() else { return nil }
        await throttleCapture()
        var targets: [ScreenshotTarget] = []
        if mode == "element", let ref, ref > 0 { targets.append(.element(ref: ref)) }
        targets.append(.viewport)
        for target in targets {
            let outcome = await PageDriver.screenshot(
                target, developmentAllowed: { false }, maximumBytes: Self.failureImageBytes, maxWidth: Self.failureImageWidth, in: view)
            if case .success(let capture) = outcome, !capture.requiresDevelopment, scope.validate() {
                return capture.jpeg
            }
        }
        return nil
    }

    nonisolated static let failureImageBytes = 60_000
    nonisolated static let failureImageWidth = 640
}
