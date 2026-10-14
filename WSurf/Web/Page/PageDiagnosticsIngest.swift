// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

nonisolated extension PageDiagnostics {
    /// One record before the buffer assigns identity: the stream and its already-sanitized fields.
    struct Entry: Equatable {
        let stream: Stream
        let fields: [String: String]
    }

    fileprivate static let maxText = 2_000
    fileprivate static let methodCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    fileprivate static func clip(_ text: String) -> String { String(text.prefix(maxText)) }

    fileprivate static func method(_ value: Any?) -> String? {
        guard let value = value as? String, (1...16).contains(value.count),
            value.unicodeScalars.allSatisfy(methodCharacters.contains)
        else { return nil }
        return value.uppercased()
    }

    fileprivate static func status(_ value: Any?) -> String? {
        guard let value = value as? Int, (100...599).contains(value) else { return nil }
        return String(value)
    }

    fileprivate static func duration(milliseconds: Double?) -> String? {
        guard let ms = milliseconds, ms.isFinite, ms >= 0, ms < 1e9 else { return nil }
        return String(Int(ms.rounded()))
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
        var fields = ["level": level, "text": PageDiagnostics.clip(text), "source": "webkit-hook"]
        if let url = (body["url"] as? String).flatMap(PageDiagnostics.sanitize(url:)) { fields["url"] = url }
        if let line = body["line"] as? Int, line >= 0 { fields["line"] = String(line) }
        return .init(stream: .console, fields: fields)
    }

    private static func network(_ body: [String: Any]) -> PageDiagnostics.Entry? {
        guard let via = body["via"] as? String, via == "fetch" || via == "xhr" else { return nil }
        let outcome = (body["outcome"] as? String).flatMap { outcomes.contains($0) ? $0 : nil } ?? "unknown"
        var fields = ["outcome": outcome, "source": "webkit-\(via)"]
        fields["method"] = PageDiagnostics.method(body["method"])
        fields["url"] = (body["url"] as? String).flatMap(PageDiagnostics.sanitize(url:))
        fields["status"] = PageDiagnostics.status(body["status"])
        fields["durationMs"] = PageDiagnostics.duration(milliseconds: body["ms"] as? Double)
        return .init(stream: .network, fields: fields)
    }
}

/// Turns Chromium DevTools events into bounded records. Correlates one request across its events but only keeps
/// method, sanitized URL, status and timing: headers, bodies and cookies in the events are never read.
nonisolated final class ChromiumDiagnosticsMapper {
    private struct Pending {
        var method: String?
        var url: String?
        var start: Double?
        var status: String?
    }

    private static let maxInFlight = 256
    private static let consoleLevels = ["log": "log", "debug": "debug", "info": "info", "error": "error", "assert": "error", "warning": "warn"]

    private var pending: [String: Pending] = [:]
    private var order: [String] = []

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
        let text = args.map(describe).joined(separator: " ")
        return .init(stream: .console, fields: ["level": level, "text": PageDiagnostics.clip(text), "source": "cdp"])
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
        let text = PageDiagnostics.firstLine(described ?? details["text"] as? String ?? "Uncaught")
        var fields = ["level": "error", "text": PageDiagnostics.clip(text), "source": "cdp"]
        if let url = (details["url"] as? String).flatMap(PageDiagnostics.sanitize(url:)) { fields["url"] = url }
        if let line = details["lineNumber"] as? Int, line >= 0 { fields["line"] = String(line + 1) }  // CDP lines are 0-based
        return .init(stream: .console, fields: fields)
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
        let next = Pending(
            method: PageDiagnostics.method(request["method"]),
            url: (request["url"] as? String).flatMap(PageDiagnostics.sanitize(url:)),
            start: timestamp
        )
        if pending.updateValue(next, forKey: id) == nil {
            order.append(id)
            if order.count > Self.maxInFlight { pending[order.removeFirst()] = nil }
        }
        return hop
    }

    private func finish(_ params: [String: Any], outcome: String) -> PageDiagnostics.Entry? {
        guard let id = params["requestId"] as? String, let request = pending.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        return Self.network(request, end: params["timestamp"] as? Double, outcome: outcome)
    }

    private static func network(_ request: Pending, end: Double?, outcome: String) -> PageDiagnostics.Entry {
        var fields = ["outcome": outcome, "source": "cdp"]
        fields["method"] = request.method
        fields["url"] = request.url
        fields["status"] = request.status
        if let start = request.start, let end {
            fields["durationMs"] = PageDiagnostics.duration(milliseconds: ((end - start) * 1000).rounded())
        }
        return .init(stream: .network, fields: fields)
    }
}
