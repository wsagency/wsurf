// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// What a download's byte count does to the list while chunks arrive faster than anyone can read them: it reaches `items` once per
/// window, the first at once, and a row that stops or finishes shows the newest count with its new state. The windows run on a
/// `TestClock`, so no case waits for time to pass.
@MainActor
struct DownloadProgressTests {
    private let clock = TestClock()
    private let source = URL(string: "https://example.com/big.zip")

    private func makeDownloads(file: URL? = nil) -> DownloadManager {
        let downloads = DownloadManager(file: file)
        downloads.clock = clock
        return downloads
    }

    private func row(_ downloads: DownloadManager, _ id: UUID) throws -> DownloadManager.Item {
        try #require(downloads.items.first { $0.id == id })
    }

    /// A window opens with the count that was published, and its timer is waiting on the clock a moment later.
    private func timersAreWaiting(_ count: Int = 1) async -> Bool {
        await waitUntil { clock.pendingCount == count }
    }

    @Test func fourHundredChunksInASecondReachTheListElevenTimes() async throws {
        let downloads = makeDownloads()
        let id = downloads.beginItem(source: source)
        let changes = ChangeCounter { _ = downloads.items }
        var received: Int64 = 10_000
        downloads.noteProgress(received: received, expected: 5_000_000, for: id)
        #expect(changes.count == 1)

        for window in 1...10 {
            #expect(await timersAreWaiting())
            for _ in 0..<40 {
                received += 10_000
                downloads.noteProgress(received: received, expected: 5_000_000, for: id)
            }
            #expect(changes.count == window, "the chunks of a window wait for it to close")
            clock.advance(by: .milliseconds(100))
            #expect(await waitUntil { changes.count == window + 1 })
        }

        #expect(received == 4_010_000)
        #expect(changes.count == 11)
        #expect(try row(downloads, id).bytesReceived == received)
        #expect(try row(downloads, id).bytesExpected == 5_000_000)
    }

    @Test func aWindowWithNothingWaitingPublishesNothingAndTheNextCountStillArrives() async throws {
        let downloads = makeDownloads()
        let id = downloads.beginItem(source: source)
        let changes = ChangeCounter { _ = downloads.items }
        downloads.noteProgress(received: 1_000, expected: 10_000, for: id)
        #expect(await timersAreWaiting())

        clock.advance(by: .milliseconds(100))
        #expect(changes.count == 1, "nothing was waiting, so nothing is published")

        // Through at once if the window has closed, or published as it closes: either way once.
        downloads.noteProgress(received: 2_000, expected: 10_000, for: id)
        #expect(await waitUntil { (try? row(downloads, id).bytesReceived) == 2_000 })
        #expect(changes.count == 2)
    }

    @Test func eachDownloadHasItsOwnWindow() async throws {
        let downloads = makeDownloads()
        let first = downloads.beginItem(source: source)
        let second = downloads.beginItem(source: source)
        downloads.noteProgress(received: 1_000, expected: 10_000, for: first)
        downloads.noteProgress(received: 5_000, expected: 10_000, for: first)
        downloads.noteProgress(received: 2_000, expected: 20_000, for: second)

        #expect(try row(downloads, first).bytesReceived == 1_000)
        #expect(try row(downloads, second).bytesReceived == 2_000, "the other download's window does not hold it back")
        #expect(await timersAreWaiting(2))

        clock.advance(by: .milliseconds(100))
        #expect(await waitUntil { (try? row(downloads, first).bytesReceived) == 5_000 })
        #expect(try row(downloads, second).bytesReceived == 2_000)
    }

    @Test func aFailureShowsTheNewestCountWithTheNewState() async throws {
        let downloads = makeDownloads()
        let id = downloads.beginItem(source: source)
        let changes = ChangeCounter { _ = downloads.items }
        downloads.noteProgress(received: 1_000, expected: 10_000, for: id)
        #expect(await timersAreWaiting())
        for received in stride(from: Int64(2_000), through: 9_000, by: 1_000) {
            downloads.noteProgress(received: received, expected: 10_000, for: id)
        }
        #expect(try row(downloads, id).bytesReceived == 1_000)

        downloads.noteFailure(id, reason: "The network connection was lost.", resumeData: nil)

        let stopped = try row(downloads, id)
        #expect(stopped.state == .failed("The network connection was lost."))
        #expect(stopped.bytesReceived == 9_000)
        #expect(changes.count == 2, "the first count, then the failure with the newest count in the same change")
        #expect(await waitUntil { clock.pendingCount == 0 }, "the window closed with the download")
    }

    @Test func aCancellationShowsTheNewestCountAtOnce() async throws {
        let downloads = makeDownloads()
        let id = downloads.beginItem(source: source)
        downloads.noteProgress(received: 1_000, expected: 10_000, for: id)
        #expect(await timersAreWaiting())
        downloads.noteProgress(received: 7_000, expected: 10_000, for: id)

        downloads.noteCancelRequested(id)

        #expect(try row(downloads, id).state == .cancelled)
        #expect(try row(downloads, id).bytesReceived == 7_000)
    }

    @Test func aFinishedSaveEndsOnItsExactSizeWhileACountIsWaiting() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = DownloadManager(destinationFolder: folder, asksWhereToSave: false)
        downloads.clock = clock
        let bytes = Data("PDF document with edits".utf8)
        // The write reports a first count and then keeps the window open, so the save's own count and its finish both arrive in it.
        downloads.writeDocument = { data, destination, options in
            if let id = downloads.items.first?.id {
                downloads.noteProgress(received: 1, expected: Int64(data.count), for: id)
            }
            try data.write(to: destination, options: options)
        }

        _ = await downloads.save(bytes, suggestedFilename: "Report.pdf", source: source)

        let saved = try #require(downloads.items.first)
        #expect(saved.state == .finished)
        #expect(saved.bytesReceived == Int64(bytes.count))
        #expect(saved.fraction == 1)
    }

    @Test func aDownloadOfUnknownSizeEndsOnItsLastCount() async throws {
        let downloads = makeDownloads()
        let id = downloads.beginItem(source: source)
        downloads.noteProgress(received: 1_000, expected: 0, for: id)
        #expect(await timersAreWaiting())
        downloads.noteProgress(received: 8_000, expected: 0, for: id)

        downloads.noteFailure(id, reason: "Stopped", resumeData: Data("resume".utf8))

        #expect(try row(downloads, id).bytesReceived == 8_000)
        #expect(try row(downloads, id).bytesExpected == 0)
    }

    @Test func aZeroIntervalPassesEveryCountThrough() throws {
        let downloads = makeDownloads()
        downloads.progressInterval = .zero
        let id = downloads.beginItem(source: source)
        let changes = ChangeCounter { _ = downloads.items }

        for received in stride(from: Int64(1_000), through: 5_000, by: 1_000) {
            downloads.noteProgress(received: received, expected: 10_000, for: id)
        }

        #expect(changes.count == 5)
        #expect(try row(downloads, id).bytesReceived == 5_000)
        #expect(clock.pendingCount == 0)
    }

    // MARK: - The list on disk

    @Test func byteCountsAloneDoNotScheduleAWriteButAStateChangeDoes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wsurf-downloads-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let downloads = makeDownloads(file: file)
        let id = downloads.beginItem(source: source)
        #expect(await timersAreWaiting(), "beginning the row schedules the first write")
        downloads.writeNow()
        #expect(clock.pendingCount == 0)

        downloads.noteProgress(received: 1_000, expected: 10_000, for: id)
        #expect(await waitUntil { clock.pendingCount >= 1 })
        #expect(clock.pendingCount == 1, "only the progress window is waiting, no write")
        downloads.noteProgress(received: 3_000, expected: 10_000, for: id)
        #expect(DownloadManager(file: file).items.first?.bytesReceived == 0)

        downloads.noteFailure(id, reason: "Stopped", resumeData: nil)
        #expect(await timersAreWaiting(), "the window closed with the download and the failure scheduled the write")
        clock.advance(by: .milliseconds(400))

        #expect(await waitUntil { DownloadManager(file: file).items.first?.state == .failed("Stopped") })
        #expect(DownloadManager(file: file).items.first?.bytesReceived == 3_000)
    }
}
