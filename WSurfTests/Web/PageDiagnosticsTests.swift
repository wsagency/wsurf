// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct PageDiagnosticsTests {
    private let connection = UUID()

    private func buffer(maxRecords: Int = 1_024, maxBytes: Int = 2 * 1_048_576, maxRecordBytes: Int = 8 * 1_024) -> PageDiagnostics.Buffer {
        PageDiagnostics.Buffer(connection: connection, tab: "tab-1", documentID: "doc-1", maxRecords: maxRecords, maxBytes: maxBytes, maxRecordBytes: maxRecordBytes)
    }

    @discardableResult
    private func add(_ buffer: PageDiagnostics.Buffer, _ stream: PageDiagnostics.Stream = .console, _ text: String = "x", document: String = "doc-1") -> Bool {
        buffer.append(stream: stream, timestamp: Date(timeIntervalSince1970: 0), documentID: document, fields: ["text": .text(text)])
    }

    // MARK: Reading and cursors

    @Test func emptyBufferReadsNothingWithAUsableCursor() throws {
        let buffer = buffer()
        let page = try buffer.read(stream: .console, cursor: nil, limit: 50)
        #expect(page.records.isEmpty)
        #expect(page.gap == 0)
        add(buffer, .console, "later")
        let next = try buffer.read(stream: .console, cursor: page.nextCursor, limit: 50)
        #expect(next.records.map { $0.fields["text"] } == ["later"])
    }

    @Test func readsAreOrderedPagedAndResumeFromTheCursor() throws {
        let buffer = buffer()
        for index in 0..<5 { add(buffer, .console, "m\(index)") }
        let first = try buffer.read(stream: .console, cursor: nil, limit: 2)
        #expect(first.records.map { $0.fields["text"] } == ["m0", "m1"])
        #expect(first.records.map(\.seq) == [0, 1])
        let second = try buffer.read(stream: .console, cursor: first.nextCursor, limit: 10)
        #expect(second.records.map { $0.fields["text"] } == ["m2", "m3", "m4"])
        let third = try buffer.read(stream: .console, cursor: second.nextCursor, limit: 10)
        #expect(third.records.isEmpty)
    }

    @Test func streamsHaveIndependentSequencesAndCursors() throws {
        let buffer = buffer()
        add(buffer, .console, "c0")
        add(buffer, .network, "n0")
        add(buffer, .console, "c1")
        let console = try buffer.read(stream: .console, cursor: nil, limit: 10)
        let network = try buffer.read(stream: .network, cursor: nil, limit: 10)
        #expect(console.records.map(\.seq) == [0, 1])
        #expect(network.records.map(\.seq) == [0])
        #expect(throws: PageDiagnostics.ReadError.self) {
            try buffer.read(stream: .network, cursor: console.nextCursor, limit: 10)
        }
    }

    @Test func aLimitOutsideOneToOneHundredIsAnErrorNotClamped() throws {
        let buffer = buffer()
        for _ in 0..<150 {
            add(buffer)
        }
        #expect(try buffer.read(stream: .console, cursor: nil, limit: 100).records.count == 100)
        for limit in [0, -1, 101, 1_000] {
            #expect(throws: PageDiagnostics.ReadError.invalidLimit) { try buffer.read(stream: .console, cursor: nil, limit: limit) }
        }
    }

    @Test func foreignMalformedAndExpiredCursorsAreRejected() throws {
        let buffer = buffer()
        add(buffer)
        let valid = try buffer.read(stream: .console, cursor: nil, limit: 10).nextCursor

        let otherConnection = PageDiagnostics.Buffer(connection: UUID(), tab: "tab-1", documentID: "doc-1")
        add(otherConnection)
        let otherTab = PageDiagnostics.Buffer(connection: connection, tab: "tab-2", documentID: "doc-1")
        add(otherTab)
        for foreign in [otherConnection, otherTab] {
            #expect(throws: PageDiagnostics.ReadError.self) { try foreign.read(stream: .console, cursor: valid, limit: 10) }
        }
        for malformed in ["", "not base64!", Data("a|b".utf8).base64EncodedString(), Data("\(connection)|tab-1|console|0|abc".utf8).base64EncodedString()] {
            #expect(throws: PageDiagnostics.ReadError.self) { try buffer.read(stream: .console, cursor: malformed, limit: 10) }
        }
        // A cursor pointing past anything ever produced cannot be genuine.
        let future = Data("\(connection)|tab-1|console|\(buffer.epoch)|999".utf8).base64EncodedString()
        #expect(throws: PageDiagnostics.ReadError.self) { try buffer.read(stream: .console, cursor: future, limit: 10) }

        buffer.reset()
        #expect(throws: PageDiagnostics.ReadError.self) { try buffer.read(stream: .console, cursor: valid, limit: 10) }
    }

    @Test func aCursorFromBeforeResetAndStartIsRejectedByTheNewBufferToo() throws {
        let first = buffer()
        for index in 0..<5 { add(first, .console, "old\(index)") }
        let old = try first.read(stream: .console, cursor: nil, limit: 3).nextCursor
        // `resetDevelopment` then `startDiagnostics` for the same connection and tab builds a fresh buffer.
        let second = buffer()
        for index in 0..<5 { add(second, .console, "new\(index)") }
        #expect(throws: PageDiagnostics.ReadError.self) { try second.read(stream: .console, cursor: old, limit: 10) }
        #expect(second.epoch != first.epoch)
    }

    // MARK: Eviction and loss counters

    @Test func recordCapEvictsOldestAndReportsTheGap() throws {
        let buffer = buffer(maxRecords: 3)
        for index in 0..<5 { add(buffer, .console, "m\(index)") }
        #expect(buffer.recordCount == 3)
        #expect(buffer.evicted(.console) == 2)
        let page = try buffer.read(stream: .console, cursor: nil, limit: 10)
        #expect(page.records.map { $0.fields["text"] } == ["m2", "m3", "m4"])
        #expect(page.gap == 0)  // reading from the oldest retained record is not a gap
        #expect(page.evicted == 2)
    }

    @Test func staleCursorBehindEvictionYieldsDataPlusDropCount() throws {
        let buffer = buffer(maxRecords: 3)
        add(buffer, .console, "m0")
        let cursor = try buffer.read(stream: .console, cursor: nil, limit: 1).nextCursor  // next = seq 1
        for index in 1..<8 { add(buffer, .console, "m\(index)") }  // retains m5, m6, m7
        let page = try buffer.read(stream: .console, cursor: cursor, limit: 10)
        #expect(page.records.map { $0.fields["text"] } == ["m5", "m6", "m7"])
        #expect(page.gap == 4)  // m1…m4 were lost between the cursor and the oldest retained record
    }

    @Test func retentionIsSharedAcrossStreamsAndEvictsTheGloballyOldest() throws {
        let buffer = buffer(maxRecords: 2)
        add(buffer, .console, "c0")
        add(buffer, .network, "n0")
        add(buffer, .console, "c1")
        #expect(buffer.evicted(.console) == 1)
        #expect(buffer.evicted(.network) == 0)
        #expect(try buffer.read(stream: .network, cursor: nil, limit: 10).records.count == 1)
        #expect(try buffer.read(stream: .console, cursor: nil, limit: 10).records.map { $0.fields["text"] } == ["c1"])
    }

    @Test func byteCapEvictsOldestUntilTheNewRecordFits() {
        let buffer = buffer(maxBytes: 1_000, maxRecordBytes: 600)
        for _ in 0..<10 { add(buffer, .console, String(repeating: "a", count: 300)) }
        #expect(buffer.byteCount <= 1_000)
        #expect(buffer.recordCount >= 1)
        #expect(buffer.evicted(.console) == 10 - buffer.recordCount)
    }

    @Test func burstOfLargeEventsStaysWithinTheRealSerializedByteCap() throws {
        let buffer = buffer()
        // Control characters serialize to 6 bytes each: 1,200 of them are far more than 1,200 raw bytes.
        let payload = String(repeating: "\u{1}", count: 1_200)
        for index in 0..<10_000 { add(buffer, .console, "event \(index) " + payload) }
        let page = try buffer.read(stream: .console, cursor: nil, limit: 100)
        let serialized = try JSONSerialization.data(withJSONObject: page.records.map { record in
            ["seq": Int(record.seq), "stream": record.stream.rawValue, "documentID": record.documentID, "truncated": record.truncated,
             "timestamp": "2026-10-14T00:00:00.000Z", "fields": record.fields.mapValues { field -> Any in
                switch field {
                case .text(let text):
                    text
                case .number(let number):
                    number
                }
            },
            ] as [String: Any]
        })
        // What the buffer counts for a record is never less than what that record serializes to.
        #expect(buffer.byteCount <= 2 * 1_048_576)
        #expect(buffer.byteCount >= serialized.count / page.records.count * buffer.recordCount)
        #expect(buffer.evicted(.console) == 10_000 - buffer.recordCount)
        #expect(page.records.first?.seq == UInt64(buffer.evicted(.console)))
    }

    // MARK: Record bounds

    @Test func oversizedRecordsAreTruncatedWithAFlag() throws {
        let buffer = buffer(maxRecordBytes: 256)
        add(buffer, .console, String(repeating: "é", count: 1_000))  // 2 bytes per character
        let page = try buffer.read(stream: .console, cursor: nil, limit: 1)
        let record = try #require(page.records.first)
        #expect(record.truncated)
        #expect(record.byteCount <= 256)
        guard case .text(let text)? = record.fields["text"] else { Issue.record("text missing"); return }
        #expect(text.allSatisfy { $0 == "é" })  // cut on a character boundary, never mid-scalar
        #expect(page.truncated == 1)
        #expect(buffer.byteCount == record.byteCount)
    }

    @Test func controlCharactersCountAtTheirEscapedSize() throws {
        let buffer = buffer(maxRecordBytes: 400)
        add(buffer, .console, String(repeating: "\u{1}", count: 500))  // 3,000 bytes once escaped
        let record = try #require(try buffer.read(stream: .console, cursor: nil, limit: 1).records.first)
        #expect(record.truncated)
        #expect(record.byteCount <= 400)
        guard case .text(let text)? = record.fields["text"] else { Issue.record("text missing"); return }
        #expect(!text.isEmpty)
        let json = try JSONSerialization.data(withJSONObject: ["text": text])
        #expect(json.count <= 400)
    }

    @Test func aHugeGraphemeClusterIsCutByScalarsNotEmptied() throws {
        let buffer = buffer(maxRecordBytes: 1_024)
        // One grapheme cluster of 5,001 scalars: character-based cutting would drop it whole and leave nothing.
        add(buffer, .console, "e" + String(repeating: "\u{301}", count: 5_000))
        let record = try #require(try buffer.read(stream: .console, cursor: nil, limit: 1).records.first)
        guard case .text(let text)? = record.fields["text"] else { Issue.record("text missing"); return }
        #expect(record.truncated)
        #expect(record.byteCount <= 1_024)
        #expect(text.unicodeScalars.count > 100)
    }

    @Test func numericFieldsSurviveTruncationUntouched() throws {
        let buffer = buffer(maxRecordBytes: 256)
        buffer.append(stream: .network, timestamp: Date(timeIntervalSince1970: 0), documentID: "doc-1", fields: ["url": .text(String(repeating: "u", count: 1_000)), "status": 404])
        let record = try #require(try buffer.read(stream: .network, cursor: nil, limit: 1).records.first)
        #expect(record.fields["status"] == 404)
        #expect(record.truncated)
    }

    @Test func withinLimitRecordsAreNotMarkedTruncated() throws {
        let buffer = buffer()
        add(buffer, .network, "small")
        let page = try buffer.read(stream: .network, cursor: nil, limit: 1)
        #expect(page.records.first?.truncated == false)
        #expect(page.truncated == 0)
    }

    @Test func truncationShrinksTheLargestFieldFirst() throws {
        let buffer = buffer(maxRecordBytes: 400)
        _ = buffer.append(stream: .console, timestamp: Date(), documentID: "doc-1", fields: ["level": "error", "text": .text(String(repeating: "t", count: 500)), "url": "https://a.example/x"])
        let record = try #require(try buffer.read(stream: .console, cursor: nil, limit: 1).records.first)
        #expect(record.fields["level"] == "error")
        #expect(record.fields["url"] == "https://a.example/x")
        #expect(record.byteCount <= 400)
    }

    // MARK: Epochs and documents

    @Test func resetClearsRecordsBumpsTheEpochAndKeepsCountersHonest() throws {
        let buffer = buffer()
        add(buffer)
        let epoch = buffer.epoch
        buffer.reset()
        #expect(buffer.epoch == epoch + 1)
        #expect(buffer.recordCount == 0)
        #expect(buffer.byteCount == 0)
        #expect(buffer.evicted(.console) == 0)
        add(buffer, .console, "fresh")
        #expect(try buffer.read(stream: .console, cursor: nil, limit: 10).records.map(\.seq) == [0])
    }

    @Test func recordsFromAnotherDocumentAreRejectedNotMerged() throws {
        let buffer = buffer()
        buffer.reset(documentID: "doc-2")
        #expect(!add(buffer, .console, "old", document: "doc-1"))
        #expect(add(buffer, .console, "new", document: "doc-2"))
        let page = try buffer.read(stream: .console, cursor: nil, limit: 10)
        #expect(page.records.map { $0.fields["text"] } == ["new"])
        #expect(page.records.allSatisfy { $0.documentID == "doc-2" })
        #expect(page.documentID == "doc-2")
    }

    @Test func recordsForAnyOtherDocumentThanTheOwnersAreDropped() {
        let buffer = buffer()
        #expect(!add(buffer, .console, "x", document: "other"))
        #expect(buffer.recordCount == 0)
    }
}

struct PageDiagnosticsSanitizeTests {
    @Test(arguments: [
        ("https://user:pw@example.com/a/b?token=secret#frag", "https://example.com/a/b"),
        ("http://example.com:8080/p?x=1", "http://example.com:8080/p"),
        ("https://example.com", "https://example.com"),
        ("https://example.com/?a=b", "https://example.com/"),
        ("https://example.com/a%20b?q", "https://example.com/a%20b"),
        ("wss://h.example/socket?key=1#x", "wss://h.example/socket"),
        ("https://[::1]:3000/x?y", "https://[::1]:3000/x"),
        ("https://u%40x:p%3A@example.com/", "https://example.com/"),
        ("file:///Users/me/page.html?x#y", "file:///Users/me/page.html"),
    ])
    func stripsUserinfoQueryAndFragment(input: String, expected: String) {
        #expect(PageDiagnostics.sanitize(url: input) == expected)
    }

    @Test(arguments: [
        "data:text/plain;base64,c2VjcmV0",
        "blob:https://example.com/3f6e",
        "javascript:alert(document.cookie)",
        "about:blank?x",
    ])
    func opaqueSchemesRevealOnlyTheScheme(input: String) {
        let scheme = String(input.prefix { $0 != ":" })
        #expect(PageDiagnostics.sanitize(url: input) == "\(scheme):")
    }

    @Test(arguments: ["", "   ", "not a url", "https:///nohost", "/relative?token=1", "://x"])
    func unparsableOrHostlessInputIsNil(input: String) {
        #expect(PageDiagnostics.sanitize(url: input) == nil)
    }

    @Test(arguments: [
        "https://user:pw@example.com/a/b?token=secret#frag", "https://example.com", "data:text/plain,secret", "https://[::1]:3000/x?y",
    ])
    func isIdempotentSoOutputValidationCanReapplyIt(input: String) throws {
        let once = try #require(PageDiagnostics.sanitize(url: input))
        #expect(PageDiagnostics.sanitize(url: once) == once)
    }

    @Test func neverEmitsASecretFromAnyPartOfTheURL() throws {
        let hostile = [
            "https://admin:hunter2@example.com/path?password=hunter2#hunter2",
            "https://example.com/a?next=https://evil.example/?hunter2",
            "https://hunter2@example.com/",
            "https://example.com/#hunter2",
        ]
        for url in hostile {
            let sanitized = PageDiagnostics.sanitize(url: url) ?? ""
            #expect(!sanitized.contains("hunter2"), "\(sanitized)")
        }
    }
}
