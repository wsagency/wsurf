// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// Turns Chromium DevTools events into bounded records. Correlates one request across its events but only keeps method,
/// sanitized URL (parameter names, tagged values), status, resource type, media type, transfer size and timing.
///
/// Headers, bodies and console previews are read only while `detail` allows them (the Developer tier, opt-in per capture) and
/// only for a request whose own URL is a developer site: a redirect hop that leaves the developer sites ends what is kept, and
/// the request after it keeps nothing. Header values that must not be shown are replaced as soon as an event is read, so a cookie
/// or token is never held in a pending request. Bodies are fetched later by the owner (`Entry.bodyFetch`), which checks the
/// policy again before it makes a record.
nonisolated final class ChromiumDiagnosticsMapper {
    private struct Pending {
        var method: String?
        /// The URL as the page sent it, cut to its byte bound. It is concealed when a record is made, with the key the document
        /// that record belongs to has by then, not the key of the document that was current when the request began.
        var url: String?
        var urlTruncated = false
        var start: Double?
        var status: Int?
        var type: String?
        var mimeType: String?
        var frameID: String?
        var loaderID: String?
        /// Detail was kept for this hop: its URL was a developer site when the request began.
        var allowed = false
        var requestPairs: [(name: String, value: String)] = []
        var responsePairs: [(name: String, value: String)] = []
        var requestBody: PageDiagnostics.RawBody?
        var hasPostData = false
    }

    private static let maxInFlight = 256
    private static let consoleLevels = ["log": "log", "debug": "debug", "info": "info", "error": "error", "assert": "error", "warning": "warn"]
    /// A response body larger than this on the wire is not fetched.
    static let maxFetchedBodyBytes = 1_048_576

    /// Replaced by the owner whenever the document changes; see `PageDiagnostics.QueryValues`.
    var queryValues: PageDiagnostics.QueryValues
    /// Replaced by the owner before every event; `.off` records metadata only.
    var detail = PageDiagnostics.DetailPolicy.off
    private var pending: [String: Pending] = [:]
    private var order: [String] = []
    /// The headers the browser added on the wire (a cookie, say), by request, until the request finishes.
    private var extraRequest: [String: [(name: String, value: String)]] = [:]
    private var extraResponse: [String: [(name: String, value: String)]] = [:]
    /// In-flight requests dropped because more than `maxInFlight` were open at once. Their outcome is unknown; the owner
    /// surfaces this count in its read response instead of losing them silently.
    private(set) var lostInFlight = 0

    init(queryValues: PageDiagnostics.QueryValues) {
        self.queryValues = queryValues
    }

    /// Forgets in-flight requests and the loss count: a finish event for a request that is gone maps to nothing. Call on
    /// each document change with the new document's identity, which keeps only that document's own requests (its
    /// main-document request and early subresources start before the commit is observed); without it, everything is
    /// forgotten (a new lease). Stale entries never occupy slots, and the loss count never carries into another document.
    func reset(keeping documentID: String? = nil) {
        pending = pending.filter { documentID != nil && $0.value.loaderID == documentID }
        order.removeAll { pending[$0] == nil }
        extraRequest = extraRequest.filter { pending[$0.key] != nil }
        extraResponse = extraResponse.filter { pending[$0.key] != nil }
        lostInFlight = 0
    }

    func entry(method: String, params: [String: Any]) -> PageDiagnostics.Entry? {
        switch method {
        case "Runtime.consoleAPICalled":
            return console(params)
        case "Runtime.exceptionThrown":
            return exception(params)
        case "Network.requestWillBeSent":
            return requestWillBeSent(params)
        case "Network.requestWillBeSentExtraInfo":
            keepExtra(params, into: &extraRequest)
            return nil
        case "Network.responseReceivedExtraInfo":
            keepExtra(params, into: &extraResponse)
            return nil
        case "Network.responseReceived":
            if let id = params["requestId"] as? String, var request = pending[id] {
                let response = params["response"] as? [String: Any]
                request.status = PageDiagnostics.status(response?["status"])
                request.mimeType = PageDiagnostics.mediaType(response?["mimeType"])
                request.type = PageDiagnostics.resourceType(params["type"]) ?? request.type
                if request.allowed, detail.options.headers {
                    request.responsePairs = Self.pairs(response?["headers"])
                }
                pending[id] = request
            }
            return nil
        case "Network.loadingFinished":
            return finish(params, outcome: "completed")
        case "Network.loadingFailed":
            return finish(params, outcome: (params["canceled"] as? Bool) == true ? "aborted" : "failed")
        default:
            return nil
        }
    }

    // MARK: Console

    private func console(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let type = params["type"] as? String, let level = Self.consoleLevels[type], let args = params["args"] as? [[String: Any]] else { return nil }
        var text = ""
        var truncated = args.count > PageDiagnostics.maxConsoleArguments
        for arg in args.prefix(PageDiagnostics.maxConsoleArguments) {
            let separator = text.isEmpty ? "" : " "
            let room = PageDiagnostics.maxTextBytes - text.utf8.count - separator.utf8.count
            let piece = PageDiagnostics.clip(Self.describe(arg), bytes: max(room, 0))
            text += separator + piece.text
            if piece.truncated {
                truncated = true
                break
            }
        }
        var fields: [String: PageDiagnostics.Field] = ["level": .text(level), "text": .text(text), "source": "cdp"]
        let full = detail.consoleDetail
        // Where a warning or error was logged, and how it got there. Lower levels would only add noise, unless the full console was asked for.
        if level == "error" || level == "warn" || full {
            truncated = location(of: params["stackTrace"], into: &fields, full: full) || truncated
        }
        if full, args.contains(where: { $0["type"] as? String == "object" && $0["subtype"] as? String != "error" && $0["subtype"] as? String != "null" }),
            let preview = PageDiagnostics.Redaction.preview(args.prefix(PageDiagnostics.maxConsoleArguments).map { Self.previewValue($0, depth: 0) }) {
            fields["preview"] = .text(preview.text)
            truncated = truncated || preview.truncated
        }
        return .init(stream: .console, fields: fields, truncated: truncated, contextID: params["executionContextId"] as? Int)
    }

    /// Primitives only. Objects and functions are never rendered: their descriptions can embed arbitrary page data.
    private static func describe(_ arg: [String: Any]) -> String {
        switch arg["type"] as? String {
        case "string":
            return arg["value"] as? String ?? ""
        case "number":
            if let int = arg["value"] as? Int { return String(int) }
            if let double = arg["value"] as? Double { return String(double) }
            return arg["unserializableValue"] as? String ?? "[number]"
        case "boolean":
            return (arg["value"] as? Bool) == true ? "true" : "false"
        case "undefined":
            return "undefined"
        case "function":
            return "[function]"
        case "object":
            switch arg["subtype"] as? String {
            case "null":
                return "null"
            case "error":
                return PageDiagnostics.firstLine(arg["description"] as? String ?? "Error")
            default:
                return "[object omitted]"
            }
        default:
            return "[value omitted]"
        }
    }

    // MARK: Previews

    /// A console argument as JSON-able data for the full console: primitives as they are, an object from the preview DevTools made
    /// for it. DevTools shows an accessor as an accessor and never calls it, so no page code runs.
    private static func previewValue(_ arg: [String: Any], depth: Int) -> Any {
        switch arg["type"] as? String {
        case "string":
            return PageDiagnostics.clip(arg["value"] as? String ?? "", bytes: 200).text
        case "number":
            if let number = finite(arg["value"]) { return number }
            return arg["unserializableValue"] as? String ?? "[number]"
        case "boolean":
            return (arg["value"] as? Bool) == true
        case "undefined":
            return "[undefined]"
        case "function":
            return "[function]"
        case "bigint":
            return arg["unserializableValue"] as? String ?? "[bigint]"
        case "symbol":
            return "[symbol]"
        case "object":
            switch arg["subtype"] as? String {
            case "null":
                return NSNull()
            case "error":
                return PageDiagnostics.firstLine(arg["description"] as? String ?? "Error")
            default:
                return (arg["preview"] as? [String: Any]).map { objectPreview($0, depth: depth) } ?? "[object]"
            }
        default:
            return "[value]"
        }
    }

    private static func finite(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite else { return nil }
        return number
    }

    private static func objectPreview(_ preview: [String: Any], depth: Int) -> Any {
        let isArray = preview["subtype"] as? String == "array"
        guard depth < 3 else { return isArray ? "[array]" : "[object]" }
        let properties = (preview["properties"] as? [[String: Any]] ?? []).prefix(20)
        let overflow = preview["overflow"] as? Bool == true
        if isArray {
            var list: [Any] = properties.map { property($0, depth: depth) }
            if overflow { list.append("…") }
            return list
        }
        var object: [String: Any] = [:]
        for entry in properties {
            object[entry["name"] as? String ?? ""] = property(entry, depth: depth)
        }
        if overflow { object["…"] = "more" }
        return object
    }

    private static func property(_ entry: [String: Any], depth: Int) -> Any {
        if let nested = entry["valuePreview"] as? [String: Any] {
            return objectPreview(nested, depth: depth + 1)
        }
        let value = entry["value"] as? String ?? ""
        switch entry["type"] as? String {
        case "string":
            return PageDiagnostics.clip(value, bytes: 200).text
        case "number":
            return Double(value).flatMap { $0.isFinite ? $0 : nil } ?? value
        case "boolean":
            return value == "true"
        case "undefined":
            return "[undefined]"
        case "function":
            return "[function]"
        case "accessor":
            return "[getter]"
        case "object":
            return entry["subtype"] as? String == "null" ? NSNull() : "[object]"
        default:
            return value.isEmpty ? "[value]" : PageDiagnostics.clip(value, bytes: 200).text
        }
    }

    private func exception(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let details = params["exceptionDetails"] as? [String: Any] else { return nil }
        let described = (details["exception"] as? [String: Any])?["description"] as? String
        let message = PageDiagnostics.clip(PageDiagnostics.firstLine(described ?? details["text"] as? String ?? "Uncaught"))
        var fields: [String: PageDiagnostics.Field] = ["level": "error", "text": .text(message.text), "source": "cdp"]
        var truncated = message.truncated
        if let raw = details["url"] as? String {
            let url = PageDiagnostics.boundedURL(raw, queryValues)
            fields["url"] = url.text.map { .text($0) }
            truncated = truncated || url.truncated
        }
        if let line = details["lineNumber"] as? Int, line >= 0 { fields["line"] = .number(line + 1) }  // CDP lines are 0-based
        if let column = details["columnNumber"] as? Int, column >= 0 { fields["column"] = .number(column + 1) }
        truncated = location(of: details["stackTrace"], into: &fields, onlyStack: true, full: detail.consoleDetail) || truncated
        return .init(stream: .console, fields: fields, truncated: truncated, contextID: details["executionContextId"] as? Int)
    }

    /// Adds `stack` (and, unless `onlyStack`, the top frame as `url`, `line` and `column`) from a DevTools `StackTrace`.
    /// Returns whether anything was cut.
    private func location(of trace: Any?, into fields: inout [String: PageDiagnostics.Field], onlyStack: Bool = false, full: Bool = false) -> Bool {
        guard let frames = (trace as? [String: Any])?["callFrames"] as? [[String: Any]], !frames.isEmpty else { return false }
        let limit = full ? PageDiagnostics.maxFullStackFrames : PageDiagnostics.maxStackFrames
        let mapped = frames.prefix(limit + 1).map { frame in
            PageDiagnostics.StackFrame(
                function: frame["functionName"] as? String ?? "", url: frame["url"] as? String,
                line: (frame["lineNumber"] as? Int).map { $0 + 1 }, column: (frame["columnNumber"] as? Int).map { $0 + 1 })
        }
        var cut = frames.count > limit
        if !onlyStack, let top = mapped.first, let raw = top.url, !raw.isEmpty {
            let url = PageDiagnostics.boundedURL(raw, queryValues)
            fields["url"] = url.text.map { .text($0) }
            top.line.map { fields["line"] = .number($0) }
            top.column.map { fields["column"] = .number($0) }
            cut = cut || url.truncated
        }
        if let stack = PageDiagnostics.stack(mapped, queryValues: queryValues, full: full) {
            fields["stack"] = .text(stack.text)
            cut = cut || stack.truncated
        }
        return cut
    }

    // MARK: Network

    /// Header pairs as DevTools gives them, with every value that must not be shown already replaced.
    private static func pairs(_ value: Any?) -> [(name: String, value: String)] {
        guard let object = value as? [String: Any] else { return [] }
        return object.sorted { $0.key < $1.key }.prefix(PageDiagnostics.Redaction.maxHeaders).map { key, value in
            let text = PageDiagnostics.clip(String(describing: value), bytes: 1_024).text
            return (key, PageDiagnostics.Redaction.hidesHeader(key.lowercased(), value: text) ? PageDiagnostics.Redaction.hidden : text)
        }
    }

    private func keepExtra(_ params: [String: Any], into store: inout [String: [(name: String, value: String)]]) {
        guard detail.options.headers, detail.tier, let id = params["requestId"] as? String, store[id] != nil || store.count < Self.maxInFlight else { return }
        store[id] = Self.pairs(params["headers"])
    }

    private func requestWillBeSent(_ params: [String: Any]) -> PageDiagnostics.Entry? {
        guard let id = params["requestId"] as? String, let request = params["request"] as? [String: Any] else { return nil }
        let timestamp = params["timestamp"] as? Double
        let url = (request["url"] as? String).map { PageDiagnostics.clip($0, bytes: PageDiagnostics.maxURLBytes) }
        var hop: PageDiagnostics.Entry?
        if let redirect = params["redirectResponse"] as? [String: Any], var previous = pending[id] {
            previous.status = PageDiagnostics.status(redirect["status"])
            previous.mimeType = PageDiagnostics.mediaType(redirect["mimeType"])
            if previous.allowed, detail.options.headers {
                previous.responsePairs = Self.pairs(redirect["headers"])
            }
            hop = network(
                previous, id: id, end: timestamp, outcome: "completed", bytes: PageDiagnostics.byteCount(redirect["encodedDataLength"]),
                redirectTo: url?.text)
            extraRequest[id] = nil
            extraResponse[id] = nil
        }
        var next = Pending(
            method: PageDiagnostics.method(request["method"]), url: url?.text, urlTruncated: url?.truncated ?? false, start: timestamp,
            type: PageDiagnostics.resourceType(params["type"]), frameID: params["frameId"] as? String, loaderID: params["loaderId"] as? String
        )
        if detail.network(url?.text) {
            next.allowed = true
            if detail.options.headers {
                next.requestPairs = Self.pairs(request["headers"])
            }
            if detail.options.bodies {
                let type = Self.pairs(request["headers"]).first { $0.name.lowercased() == "content-type" }?.value
                if let post = request["postData"] as? String {
                    next.requestBody = PageDiagnostics.RawBody(
                        text: PageDiagnostics.clip(post, bytes: PageDiagnostics.Redaction.maxIntakeBytes).text, contentType: type, size: post.utf8.count)
                } else if request["hasPostData"] as? Bool == true {
                    // Too large for DevTools to send inline: the owner asks for it when the request finishes.
                    next.hasPostData = true
                    next.requestBody = PageDiagnostics.RawBody(contentType: type, note: "not captured: the body could not be read")
                }
            }
        }
        if pending.updateValue(next, forKey: id) == nil {
            order.append(id)
            if order.count > Self.maxInFlight {
                let dropped = order.removeFirst()
                pending[dropped] = nil
                extraRequest[dropped] = nil
                extraResponse[dropped] = nil
                lostInFlight += 1
            }
        }
        return hop
    }

    private func finish(_ params: [String: Any], outcome: String) -> PageDiagnostics.Entry? {
        guard let id = params["requestId"] as? String, let request = pending.removeValue(forKey: id) else { return nil }
        order.removeAll { $0 == id }
        let bytes = PageDiagnostics.byteCount(params["encodedDataLength"])
        var entry = network(request, id: id, end: params["timestamp"] as? Double, outcome: outcome, bytes: bytes, redirectTo: nil)
        extraRequest[id] = nil
        extraResponse[id] = nil
        guard var input = entry.detail, detail.options.bodies, outcome == "completed" else { return entry }
        let type = request.mimeType
        var fetch = PageDiagnostics.BodyFetch(requestID: id, response: false, requestPost: request.hasPostData, mimeType: request.mimeType)
        if PageDiagnostics.Redaction.isTextType(type), (bytes ?? 0) <= Self.maxFetchedBodyBytes {
            fetch.response = true
        } else if let type {
            let large = PageDiagnostics.Redaction.isTextType(type)
            input.responseBody = PageDiagnostics.RawBody(
                contentType: type, size: bytes, binary: !large, note: large ? "not captured: larger than \(Self.maxFetchedBodyBytes / 1_048_576) MiB" : nil)
        }
        entry.detail = input
        entry.bodyFetch = fetch.response || fetch.requestPost ? fetch : nil
        return entry
    }

    /// The record for a request, with its URLs concealed now. `redirectTo` is the raw bounded URL of the redirect target.
    private func network(_ request: Pending, id: String, end: Double?, outcome: String, bytes: Int?, redirectTo: String?) -> PageDiagnostics.Entry {
        var fields: [String: PageDiagnostics.Field] = ["outcome": .text(outcome), "source": "cdp"]
        let url = request.url.map { PageDiagnostics.boundedURL($0, detail.queryValues(for: $0, tagged: queryValues)) }
        let target = redirectTo.map { PageDiagnostics.boundedURL($0, detail.queryValues(for: $0, tagged: queryValues)) }
        fields["method"] = request.method.map { .text($0) }
        fields["url"] = url?.text.map { .text($0) }
        fields["status"] = request.status.map { .number($0) }
        fields["type"] = request.type.map { .text($0) }
        fields["mimeType"] = request.mimeType.map { .text($0) }
        fields["transferBytes"] = bytes.map { .number($0) }
        fields["redirectTo"] = target?.text.map { .text($0) }
        if let start = request.start, let end {
            fields["durationMs"] = PageDiagnostics.duration(milliseconds: ((end - start) * 1000).rounded()).map { .number($0) }
        }
        let truncated = request.urlTruncated || (url?.truncated ?? false) || (target?.truncated ?? false)
        var entry = PageDiagnostics.Entry(stream: .network, fields: fields, truncated: truncated, frameID: request.frameID, loaderID: request.loaderID)
        if request.allowed, detail.network(request.url), let address = request.url {
            entry.detail = detailInput(request, id: id, address: address)
        }
        return entry
    }

    /// The raw detail of one hop. Its headers are the ones DevTools gave plus the ones the browser added on the wire.
    private func detailInput(_ request: Pending, id: String, address: String) -> PageDiagnostics.DetailInput {
        let mode: (String) -> PageDiagnostics.QueryValues = { [policy = detail, tagged = queryValues] in policy.queryValues(for: $0, tagged: tagged) }
        func merged(_ base: [(name: String, value: String)], _ extra: [(name: String, value: String)]?) -> [PageDiagnostics.Header] {
            let known = Set(base.map { $0.name.lowercased() })
            let added = (extra ?? []).filter { !known.contains($0.name.lowercased()) }
            return PageDiagnostics.Redaction.headers(base + added, requestURL: address, mode: mode)
        }
        return PageDiagnostics.DetailInput(
            url: address,
            requestHeaders: detail.options.headers ? merged(request.requestPairs, extraRequest[id]) : nil,
            responseHeaders: detail.options.headers ? merged(request.responsePairs, extraResponse[id]) : nil,
            requestBody: request.requestBody)
    }
}
