// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import CryptoKit
import Foundation

/// Bounded, in-memory console/network records for one development-owned tab, plus URL sanitization.
/// Nothing here touches disk, logs record content, or retains native payloads.
nonisolated enum PageDiagnostics {
    enum Stream: String { case console, network }

    /// Bad input at the read boundary is an error, never clamped or coerced.
    enum ReadError: Error, Equatable { case invalid, invalidLimit }

    /// A record field. Numbers stay numbers (an unknown status or duration is an absent key, never `0` or a numeric string).
    enum Field: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
        case text(String)
        case number(Int)

        init(stringLiteral value: String) {
            self = .text(value)
        }

        init(integerLiteral value: Int) {
            self = .number(value)
        }

        /// Bytes this value occupies once serialized as JSON (quotes and escapes included).
        var serializedSize: Int {
            switch self {
            case .text(let text):
                PageDiagnostics.escapedSize(text) + 2
            case .number(let number):
                String(number).utf8.count
            }
        }
    }

    /// Serialized JSON string-body size of `text`: quotes and backslashes take 2 bytes, control characters 6 (`\u00XX`,
    /// the worst case), everything else its UTF-8 length.
    static func escapedSize(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + escapedSize($1) }
    }

    static func escapedSize(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0x22, 0x5C:
            2
        case ..<0x20:
            6
        default:
            String(scalar).utf8.count
        }
    }

    /// Fixed serialized cost of a record's own members (seq, timestamp, stream, truncated flag, braces, separators).
    static let recordOverhead = 160

    struct Record: Equatable {
        let seq: UInt64
        let timestamp: Date
        let documentID: String
        let stream: Stream
        let fields: [String: Field]
        let truncated: Bool

        /// Serialized JSON size: members, escaped keys and values, and the document identity.
        var byteCount: Int {
            Record.size(fields, documentID: documentID)
        }

        fileprivate static func size(_ fields: [String: Field], documentID: String) -> Int {
            fields.reduce(PageDiagnostics.recordOverhead + PageDiagnostics.escapedSize(documentID)) {
                $0 + PageDiagnostics.escapedSize($1.key) + 4 + $1.value.serializedSize
            }
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
        /// Records the read passed over because they did not match its filter (always 0 without one).
        let skipped: Int
        let epoch: Int
        let documentID: String
    }

    /// Which records of a stream a read returns. Every set member must match. Console records have a `level`; network
    /// records have `status`, `outcome` and `type`; both have a `url` (a console record's is its source file).
    struct Filter: Equatable {
        var level: String?
        var minStatus: Int?
        var urlContains: String?
        var outcome: String?
        var type: String?

        var isEmpty: Bool {
            self == Filter()
        }

        func matches(_ record: Record) -> Bool {
            if let level, record.fields["level"] != .text(level) { return false }
            if let outcome, record.fields["outcome"] != .text(outcome) { return false }
            if let type, record.fields["type"] != .text(type) { return false }
            if let minStatus {
                guard case .number(let status)? = record.fields["status"], status >= minStatus else { return false }
            }
            if let urlContains {
                guard case .text(let url)? = record.fields["url"], url.contains(urlContains) else { return false }
            }
            return true
        }
    }

    /// The answer to asking for one record by its sequence number.
    enum Lookup: Equatable {
        case found(Record)
        /// It was captured and has since been pushed out of the bounded buffer.
        case evicted
        /// The stream has not produced that many records yet.
        case notCaptured
    }

    /// One buffer per owned tab. Retention (records and bytes) is shared by both streams and evicts the globally oldest
    /// record first. Main-actor only; native callbacks hop to the main actor before appending.
    @MainActor
    final class Buffer {
        static let maxReadLimit = 100

        let connection: UUID
        let tab: String
        private(set) var documentID: String
        /// Process-unique: a new buffer for the same connection and tab never reuses an earlier buffer's epoch, so a cursor
        /// from before a reset is rejected whichever buffer instance issued it.
        private(set) var epoch = Buffer.takeEpoch()
        private static var lastEpoch = 0

        private static func takeEpoch() -> Int {
            lastEpoch += 1
            return lastEpoch
        }
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

        var recordCount: Int {
            records.count
        }

        func evicted(_ stream: Stream) -> Int {
            evictedCount[stream, default: 0]
        }

        /// Stores a record for the owner's current document. Returns false (and stores nothing) for any other document,
        /// so late events from a previous document can never be merged under the new identity.
        @discardableResult
        func append(stream: Stream, timestamp: Date, documentID: String, fields: [String: Field], truncated cut: Bool = false) -> Bool {
            guard documentID == self.documentID else { return false }
            let (bounded, boundTruncated) = bound(fields, documentID: documentID)
            let truncated = cut || boundTruncated
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
            epoch = Buffer.takeEpoch()
            if let documentID {
                self.documentID = documentID
            }
        }

        /// One record by sequence number, for as long as the buffer retains it.
        func lookup(stream: Stream, seq: UInt64) -> Lookup {
            if let record = records.first(where: { $0.stream == stream && $0.seq == seq }) {
                return .found(record)
            }
            return seq < nextSeq[stream, default: 0] ? .evicted : .notCaptured
        }

        /// A filtered read scans forward from the cursor (the buffer holds at most `maxRecords`, so the scan is bounded) and
        /// returns the first `limit` matches. The next cursor follows the last record the scan consumed: records skipped on
        /// the way are not offered again, and one the scan never reached is still ahead of the cursor.
        func read(stream: Stream, cursor: String?, limit: Int, filter: Filter = Filter()) throws(ReadError) -> Page {
            guard (1...Buffer.maxReadLimit).contains(limit) else { throw .invalidLimit }
            let next = nextSeq[stream, default: 0]
            let retained = records.filter { $0.stream == stream }
            let oldest = retained.first?.seq ?? next
            var start = oldest
            var gap = 0
            if let cursor {
                let position = try decode(cursor, stream: stream)
                guard position <= next else { throw .invalid }
                if position < oldest {
                    gap = Int(oldest - position)
                } else {
                    start = position
                }
            }
            var page: [Record] = []
            var skipped = 0
            var after = start
            for record in retained where record.seq >= start {
                if page.count == limit {
                    break
                }
                if filter.matches(record) {
                    page.append(record)
                } else {
                    skipped += 1
                }
                after = record.seq + 1
            }
            return Page(
                records: page, nextCursor: encode(stream: stream, seq: after), gap: gap, evicted: evicted(stream),
                truncated: page.filter(\.truncated).count, skipped: skipped, epoch: epoch, documentID: documentID)
        }

        // MARK: Cursor

        private func encode(stream: Stream, seq: UInt64) -> String {
            Data("\(connection.uuidString)|\(tab)|\(stream.rawValue)|\(epoch)|\(seq)".utf8).base64EncodedString()
        }

        private func decode(_ cursor: String, stream: Stream) throws(ReadError) -> UInt64 {
            guard let data = Data(base64Encoded: cursor), let text = String(data: data, encoding: .utf8) else { throw .invalid }
            let parts = text.split(separator: "|", omittingEmptySubsequences: false)
            guard parts.count == 5,
                parts[0] == connection.uuidString, parts[1] == tab, parts[2] == stream.rawValue,
                Int(parts[3]) == epoch, let seq = UInt64(parts[4])
            else { throw .invalid }
            return seq
        }

        // MARK: Record bounds

        /// Cuts the largest text value (ties by key), on unicode scalar boundaries, until the record's serialized size fits
        /// `maxRecordBytes`. Scalars, not characters: one grapheme cluster can be arbitrarily many bytes.
        private func bound(_ fields: [String: Field], documentID: String) -> ([String: Field], Bool) {
            var fields = fields
            var truncated = false
            func text(_ field: Field) -> String? {
                guard case .text(let text) = field else { return nil }
                return text
            }
            while Record.size(fields, documentID: documentID) > maxRecordBytes,
                let largest = fields.compactMap({ key, field in text(field).map { (key, $0) } })
                    .max(by: { ($0.1.utf8.count, $1.0) < ($1.1.utf8.count, $0.0) }),
                !largest.1.isEmpty {
                var excess = Record.size(fields, documentID: documentID) - maxRecordBytes
                var value = largest.1.unicodeScalars
                while excess > 0, let last = value.popLast() {
                    excess -= PageDiagnostics.escapedSize(last)
                }
                fields[largest.0] = .text(String(value))
                truncated = true
            }
            return (fields, truncated)
        }
    }

    // MARK: URL sanitization

    private static let hierarchicalSchemes: Set<String> = ["http", "https", "ws", "wss", "ftp", "file"]

    /// Keeps scheme, host, port and path. Userinfo and fragment are removed; opaque schemes (data, blob, javascript, about, …)
    /// reveal just their scheme. The query keeps plain parameter names and conceals everything else (`QueryValues`).
    static func sanitize(url: String, queryValues: QueryValues) -> String? {
        sanitized(url: url, queryValues: queryValues)?.text
    }

    /// `sanitize`, also reporting whether the query was cut: more than `maxQueryParameters` parameters (the rest become `…`).
    static func sanitized(url: String, queryValues: QueryValues) -> (text: String, cut: Bool)? {
        guard let colon = url.firstIndex(of: ":") else { return nil }
        let scheme = url[..<colon].lowercased()
        guard let first = scheme.unicodeScalars.first, first.value >= 0x61 && first.value <= 0x7A,
            scheme.unicodeScalars.allSatisfy({ ($0.value >= 0x61 && $0.value <= 0x7A) || ($0.value >= 0x30 && $0.value <= 0x39) || "+-.".unicodeScalars.contains($0) })
        else { return nil }
        guard hierarchicalSchemes.contains(scheme) else { return ("\(scheme):", false) }
        guard let components = URLComponents(string: url) else { return nil }
        var host = components.percentEncodedHost ?? ""
        if host.isEmpty, scheme != "file" { return nil }
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        let port = components.port.map { ":\($0)" } ?? ""
        var query = ""
        var cut = false
        if let raw = components.percentEncodedQuery, !raw.isEmpty {
            (query, cut) = render(query: raw, queryValues)
            query = "?" + query
        }
        return ("\(scheme)://\(host)\(port)\(components.percentEncodedPath)\(query)", cut)
    }
}
