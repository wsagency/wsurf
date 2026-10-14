// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// Bounded, in-memory console/network records for one development-owned tab, plus URL sanitization.
/// Nothing here touches disk, logs record content, or retains native payloads.
nonisolated enum PageDiagnostics {
    enum Stream: String { case console, network }

    enum CursorError: Error, Equatable { case invalid }

    struct Record: Equatable {
        let seq: UInt64
        let timestamp: Date
        let documentID: String
        let stream: Stream
        let fields: [String: String]
        let truncated: Bool

        /// Approximate serialized size: field keys and values plus the document identity.
        var byteCount: Int { Record.size(fields) + documentID.utf8.count }

        fileprivate static func size(_ fields: [String: String]) -> Int {
            fields.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        }
    }

    struct Page: Equatable {
        let records: [Record]
        let nextCursor: String
        /// Records lost between the supplied cursor and the oldest retained record.
        let gap: Int
        /// Records evicted from this stream since the current epoch began.
        let evicted: Int
        /// Records in this page that were cut down to the per-record limit.
        let truncated: Int
        let epoch: Int
        let documentID: String
    }

    /// One buffer per owned tab. Retention (records and bytes) is shared by both streams and evicts the globally oldest
    /// record first. Main-actor only; native callbacks hop to the main actor before appending.
    @MainActor
    final class Buffer {
        static let maxReadLimit = 100

        let connection: UUID
        let tab: String
        private(set) var documentID: String
        private(set) var epoch = 0
        private let maxRecords: Int
        private let maxBytes: Int
        private let maxRecordBytes: Int
        private var records: [Record] = []
        private var nextSeq: [Stream: UInt64] = [:]
        private var evictedCount: [Stream: Int] = [:]
        private(set) var byteCount = 0

        /// `tab` must not contain `|` (it is part of the cursor encoding); MCP tab identifiers never do.
        init(connection: UUID, tab: String, documentID: String, maxRecords: Int = 1_024, maxBytes: Int = 2 * 1_048_576, maxRecordBytes: Int = 8 * 1_024) {
            self.connection = connection
            self.tab = tab
            self.documentID = documentID
            self.maxRecords = maxRecords
            self.maxBytes = maxBytes
            self.maxRecordBytes = maxRecordBytes
        }

        var recordCount: Int { records.count }

        func evicted(_ stream: Stream) -> Int { evictedCount[stream, default: 0] }

        /// Stores a record for the owner's current document. Returns false (and stores nothing) for any other document,
        /// so late events from a previous document can never be merged under the new identity.
        @discardableResult
        func append(stream: Stream, timestamp: Date, documentID: String, fields: [String: String]) -> Bool {
            guard documentID == self.documentID else { return false }
            let (bounded, truncated) = bound(fields, documentID: documentID)
            let seq = nextSeq[stream, default: 0]
            nextSeq[stream] = seq + 1
            let record = Record(seq: seq, timestamp: timestamp, documentID: documentID, stream: stream, fields: bounded, truncated: truncated)
            records.append(record)
            byteCount += record.byteCount
            while records.count > maxRecords || byteCount > maxBytes, records.count > 1 {
                let oldest = records.removeFirst()
                byteCount -= oldest.byteCount
                evictedCount[oldest.stream, default: 0] += 1
            }
            return true
        }

        /// Clears every record, starts a new epoch (invalidating all earlier cursors) and optionally rebinds the document.
        func reset(documentID: String? = nil) {
            records.removeAll()
            nextSeq.removeAll()
            evictedCount.removeAll()
            byteCount = 0
            epoch += 1
            if let documentID { self.documentID = documentID }
        }

        func read(stream: Stream, cursor: String?, limit: Int) throws(CursorError) -> Page {
            let next = nextSeq[stream, default: 0]
            let retained = records.filter { $0.stream == stream }
            let oldest = retained.first?.seq ?? next
            var start = oldest
            var gap = 0
            if let cursor {
                let position = try decode(cursor, stream: stream)
                guard position <= next else { throw .invalid }
                if position < oldest { gap = Int(oldest - position) } else { start = position }
            }
            let page = retained.filter { $0.seq >= start }.prefix(min(max(limit, 1), Buffer.maxReadLimit))
            let after = page.last.map { $0.seq + 1 } ?? start
            return Page(
                records: Array(page), nextCursor: encode(stream: stream, seq: after), gap: gap,
                evicted: evicted(stream), truncated: page.filter(\.truncated).count, epoch: epoch, documentID: documentID)
        }

        // MARK: Cursor

        private func encode(stream: Stream, seq: UInt64) -> String {
            Data("\(connection.uuidString)|\(tab)|\(stream.rawValue)|\(epoch)|\(seq)".utf8).base64EncodedString()
        }

        private func decode(_ cursor: String, stream: Stream) throws(CursorError) -> UInt64 {
            guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8) else { throw .invalid }
            let parts = text.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 5,
                parts[0] == connection.uuidString, parts[1] == tab, parts[2] == stream.rawValue,
                Int(parts[3]) == epoch, let seq = UInt64(parts[4])
            else { throw .invalid }
            return seq
        }

        // MARK: Record bounds

        /// Cuts the largest field value, on character boundaries, until the record fits `maxRecordBytes`.
        private func bound(_ fields: [String: String], documentID: String) -> ([String: String], Bool) {
            var fields = fields
            var truncated = false
            while Record.size(fields) + documentID.utf8.count > maxRecordBytes,
                let largest = fields.max(by: { $0.value.utf8.count < $1.value.utf8.count }), !largest.value.isEmpty
            {
                var excess = Record.size(fields) + documentID.utf8.count - maxRecordBytes
                var value = largest.value
                while excess > 0, let last = value.popLast() { excess -= String(last).utf8.count }
                fields[largest.key] = value
                truncated = true
            }
            return (fields, truncated)
        }
    }

    // MARK: URL sanitization

    private static let hierarchicalSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp", "file"]

    /// Keeps scheme, host, port and path only. Userinfo, query and fragment are removed; opaque schemes (data, blob,
    /// javascript, about, …) reveal just their scheme. Idempotent, so it can be applied again at output.
    static func sanitize(url: String) -> String? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon].lowercased()
        guard let first = scheme.unicodeScalars.first, (first.value >= 0x61 && first.value <= 0x7A),
            scheme.unicodeScalars.allSatisfy({ ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || "+-.".unicodeScalars.contains($0) })
        else { return nil }
        guard hierarchicalSchemes.contains(scheme) else { return "\(scheme):" }
        guard let components = URLComponents(string: url) else { return nil }
        var host = components.percentEncodedHost ?? ""
        if host.isEmpty, scheme != "file" { return nil }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(components.percentEncodedPath)"
    }
}
