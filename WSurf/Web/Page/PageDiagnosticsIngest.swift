// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

nonisolated extension PageDiagnostics {
    /// One record before the buffer assigns identity: the stream and its already-sanitized fields. `truncated` reports that
    /// ingest cut a message or URL to its byte bound. The native identity (`frameID`, `loaderID`, `contextID`) is the one
    /// observed when the event began, so the owner can reject an event whose document is no longer the current one.
    struct Entry: Equatable {
        let stream: Stream
        let fields: [String: PageDiagnostics.Field]
        var truncated = false
        var frameID: String?
        var loaderID: String?
        var contextID: Int?
    }

    fileprivate static let maxTextBytes = 4_096
    fileprivate static let maxURLBytes = 2_048
    fileprivate static let maxConsoleArguments = 16
    fileprivate static let methodCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Cuts `text` to at most `bytes` UTF-8 bytes on a unicode scalar boundary, touching only the kept prefix. Scalars, not
    /// characters: a single grapheme cluster can be arbitrarily many bytes.
    fileprivate static func clip(_ text: String, bytes: Int = maxTextBytes) -> (text: String, truncated: Bool) {
        var used = 0
        var end = text.unicodeScalars.startIndex
        while end < text.unicodeScalars.endIndex {
            let size = String(text.unicodeScalars[end]).utf8.count
            if used + size > bytes { return (String(text.unicodeScalars[..<end]), true) }
            used += size
            end = text.unicodeScalars.index(after: end)
        }
        return (text, false)
    }

    fileprivate static func method(_ value: Any?) -> String? {
        guard let value = value as? String, (1...16).contains(value.count),
            value.unicodeScalars.allSatisfy(methodCharacters.contains)
        else { return nil }
        return value.uppercased()
    }

    fileprivate static func status(_ value: Any?) -> Int? {
        guard let value = value as? Int, (100...599).contains(value) else { return nil }
        return value
    }

    fileprivate static func duration(milliseconds: Double?) -> Int? {
        guard let ms = milliseconds, ms.isFinite, ms >= 0, ms < 1e9 else { return nil }
        return Int(ms.rounded())
    }

    fileprivate static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }
}

/// Parses untrusted messages posted by the WebKit page hook. Anything that is not exactly the expected shape is dropped;
/// unknown keys (cookies, stacks, headers) are never copied.
nonisolated enum PageDiagnosticsHook {
    private static let levels: Set<String> = ["log", "info", "warn", "error", "debug"]
    private static let outcomes: Set<String> = ["completed", "failed", "aborted"]

    static func entry(from body: Any) -> PageDiagnostics.Entry? {
        guard let body = body as? [String: Any] else { return nil }
        switch body["k"] as? String {
        case "console": return console(body)
        case "net": return network(body)
        default: return nil
        }
    }

    private static func console(_ body: [String: Any]) -> PageDiagnostics.Entry? {
        guard let level = body["level"] as? String, levels.contains(level), let text = body["text"] as? String else { return nil }
        let message = PageDiagnostics.clip(text)
        var fields: [String: PageDiagnostics.Field] = ["level": .text(level), "text": .text(message.text), "source": "webkit-hook"]
        var truncated = message.truncated
        if let url = (body["url"] as? String).flatMap(PageDiagnostics.sanitize(url:)) {
            let clipped = PageDiagnostics.clip(url, bytes: PageDiagnostics.maxURLBytes)
            fields["url"] = .text(clipped.text)
            truncated = truncated || clipped.truncated
        }
        if let line = body["line"] as? Int, line >= 0 { fields["line"] = .number(line) }
        return .init(stream: .console, fields: fields, truncated: truncated)
    }

    private static func network(_ body: [String: Any]) -> PageDiagnostics.Entry? {
        guard let via = body["via"] as? String, via == "fetch" || via == "xhr" else { return nil }
        let outcome = (body["outcome"] as? String).flatMap { outcomes.contains($0) ? $0 : nil } ?? "unknown"
        var fields: [String: PageDiagnostics.Field] = ["outcome": .text(outcome), "source": .text("webkit-\(via)")]
        fields["method"] = PageDiagnostics.method(body["method"]).map { .text($0) }
        let url = (body["url"] as? String).flatMap(PageDiagnostics.sanitize(url:)).map { PageDiagnostics.clip($0, bytes: PageDiagnostics.maxURLBytes) }
        fields["url"] = url.map { .text($0.text) }
        fields["status"] = PageDiagnostics.status(body["status"]).map { .number($0) }
        fields["durationMs"] = PageDiagnostics.duration(milliseconds: body["ms"] as? Double).map { .number($0) }
        return .init(stream: .network, fields: fields, truncated: url?.truncated ?? false)
    }
}

/// Turns Chromium DevTools events into bounded records. Correlates one request across its events but only keeps
/// method, sanitized URL, status and timing: headers, bodies and cookies in the events are never read.
nonisolated final class ChromiumDiagnosticsMapper {
    private struct Pending {
        var method: String?
        var url: String?
        var urlTruncated = false
        var start: Double?
        var status: Int?
        var frameID: String?
        var loaderID: String?
    }

    private static let maxInFlight = 256
    private static let consoleLevels = ["log": "log", "debug": "debug", "info": "info", "error": "error", "assert": "error", "warning": "warn"]

    private var pending: [String: Pending] = [:]
    private var order: [String] = []
    /// In-flight requests dropped because more than `maxInFlight` were open at once. Their outcome is unknown; the owner
    /// surfaces this count in its read response instead of losing them silently.
    private(set) var lostInFlight = 0

    /// Forgets every in-flight request and the loss count. Call on each document or lease change: a finish event for a
    /// request from before it then maps to nothing.
    func reset() {
        pending.removeAll()
        order.removeAll()
        lostInFlight = 0
    }

    func entry(method: String, params: [String: Any]) -> PageDiagnostics.Entry? {
        switch method {
        case "Runtime.consoleAPICalled": return Self.console(params)
        case "Runtime.exceptionThrown": return Self.exception(params)
        case "Network.requestWillBeSent": return requestWillBeSent(params)
        case "Network.responseReceived":
            if let id = params["requestId"] as? String, pending[id] != nil {
                pending[id]?.status = PageDiagnostics.status((params["response"] as? [String: Any])?["status"])
            }
            return nil
        case "Network.loadingFinished": return finish(params, outcome: "completed")
        case "Network.loadingFailed": return finish(params, outcome: (params["canceled"] as? Bool) == true ? "aborted" : "failed")
        default: return nil
        }
    }

    // MARK: Console

    private static func console(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let type = params["type"] as? String, let level = consoleLevels[type], let args = params["args"] as? [[String: Any]] else { return nil }
        var text = ""
        var truncated = args.count > PageDiagnostics.maxConsoleArguments
        for arg in args.prefix(PageDiagnostics.maxConsoleArguments) {
            let separator = text.isEmpty ? "" : " "
            let room = PageDiagnostics.maxTextBytes - text.utf8.count - separator.utf8.count
            let piece = PageDiagnostics.clip(describe(arg), bytes: max(room, 0))
            text += separator + piece.text
            if piece.truncated { truncated = true; break }
        }
        return .init(
            stream: .console, fields: ["level": .text(level), "text": .text(text), "source": "cdp"], truncated: truncated,
            contextID: params["executionContextId"] as? Int)
    }

    /// Primitives only. Objects and functions are never rendered: their descriptions can embed arbitrary page data.
    private static func describe(_ arg: [String: Any]) -> String {
        switch arg["type"] as? String {
        case "string": return arg["value"] as? String ?? ""
        case "number":
            if let int = arg["value"] as? Int { return String(int) }
            if let double = arg["value"] as? Double { return String(double) }
            return arg["unserializableValue"] as? String ?? "[number]"
        case "boolean": return (arg["value"] as? Bool) == true ? "true" : "false"
        case "undefined": return "undefined"
        case "function": return "[function]"
        case "object":
            switch arg["subtype"] as? String {
            case "null": return "null"
            case "error": return PageDiagnostics.firstLine(arg["description"] as? String ?? "Error")
            default: return "[object omitted]"
            }
        default: return "[value omitted]"
        }
    }

    private static func exception(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let details = params["exceptionDetails"] as? [String: Any] else { return nil }
        let described = (details["exception"] as? [String: Any])?["description"] as? String
        let message = PageDiagnostics.clip(PageDiagnostics.firstLine(described ?? details["text"] as? String ?? "Uncaught"))
        var fields: [String: PageDiagnostics.Field] = ["level": "error", "text": .text(message.text), "source": "cdp"]
        var truncated = message.truncated
        if let url = (details["url"] as? String).flatMap(PageDiagnostics.sanitize(url:)) {
            let clipped = PageDiagnostics.clip(url, bytes: PageDiagnostics.maxURLBytes)
            fields["url"] = .text(clipped.text)
            truncated = truncated || clipped.truncated
        }
        if let line = details["lineNumber"] as? Int, line >= 0 { fields["line"] = .number(line + 1) }  // CDP lines are 0-based
        return .init(stream: .console, fields: fields, truncated: truncated, contextID: details["executionContextId"] as? Int)
    }

    // MARK: Network

    private func requestWillBeSent(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let id = params["requestId"] as? String, let request = params["request"] as? [String: Any] else { return nil }
        let timestamp = params["timestamp"] as? Double
        var hop: PageDiagnostics.Entry?
        if let redirect = params["redirectResponse"] as? [String: Any], var previous = pending[id] {
            previous.status = PageDiagnostics.status(redirect["status"])
            hop = Self.network(previous, end: timestamp, outcome: "completed")
        }
        let url = (request["url"] as? String).flatMap(PageDiagnostics.sanitize(url:)).map { PageDiagnostics.clip($0, bytes: PageDiagnostics.maxURLBytes) }
        let next = Pending(
            method: PageDiagnostics.method(request["method"]), url: url?.text, urlTruncated: url?.truncated ?? false, start: timestamp,
            frameID: params["frameId"] as? String, loaderID: params["loaderId"] as? String
        )
        if pending.updateValue(next, forKey: id) == nil {
            order.append(id)
            if order.count > Self.maxInFlight {
                pending[order.removeFirst()] = nil
                lostInFlight += 1
            }
        }
        return hop
    }

    private func finish(_ params: [String: Any], outcome: String) -> PageDiagnostics.Entry? {
        guard let id = params["requestId"] as? String, let request = pending.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        return Self.network(request, end: params["timestamp"] as? Double, outcome: outcome)
    }

    private static func network(_ request: Pending, end: Double?, outcome: String) -> PageDiagnostics.Entry {
        var fields: [String: PageDiagnostics.Field] = ["outcome": .text(outcome), "source": "cdp"]
        fields["method"] = request.method.map { .text($0) }
        fields["url"] = request.url.map { .text($0) }
        fields["status"] = request.status.map { .number($0) }
        if let start = request.start, let end {
            fields["durationMs"] = PageDiagnostics.duration(milliseconds: ((end - start) * 1000).rounded()).map { .number($0) }
        }
        return .init(stream: .network, fields: fields, truncated: request.urlTruncated, frameID: request.frameID, loaderID: request.loaderID)
    }
}
