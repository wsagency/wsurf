// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The list that opens over the Downloads button: which downloads it holds, what each one's two buttons can do, and that the
/// view draws. The hover itself needs a pointer, so it is not here.
@MainActor
struct RecentDownloadsTests {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wsurf-recent-downloads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A download in `state` whose file is really on disk, unless `exists` is false.
    private func item(
        _ name: String, _ state: DownloadManager.Item.State, in folder: URL, exists: Bool = true
    ) throws -> DownloadManager.Item {
        let file = folder.appendingPathComponent(name)
        if exists {
            try Data("x".utf8).write(to: file)
        }
        var item = DownloadManager.Item(id: UUID(), filename: name, source: "example.com", sourceTabID: nil)
        item.destination = file
        item.bytesReceived = 2_000_000
        item.bytesExpected = 5_000_000
        item.state = state
        return item
    }

    // MARK: - Which downloads

    @Test func theFiveNewestAreListedNewestFirst() {
        let downloads = DownloadManager(persists: false)
        for number in 1...7 {
            downloads.beginItem(source: URL(string: "https://example.com/file\(number).pdf"))
        }

        let listed = RecentDownloads.newest(downloads.items)
        #expect(listed.map(\.filename) == ["file7.pdf", "file6.pdf", "file5.pdf", "file4.pdf", "file3.pdf"])
        #expect(RecentDownloads.limit == 5)
    }

    @Test func aShortListIsListedWholeAndAnEmptyOneIsEmpty() {
        let downloads = DownloadManager(persists: false)
        #expect(RecentDownloads.newest(downloads.items).isEmpty)

        downloads.beginItem(source: URL(string: "https://example.com/a.pdf"))
        downloads.beginItem(source: URL(string: "https://example.com/b.pdf"))
        #expect(RecentDownloads.newest(downloads.items).map(\.filename) == ["b.pdf", "a.pdf"])
    }

    // MARK: - What the buttons can do

    @Test func aFinishedFileOnDiskCanBeOpenedAndShown() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let finished = try item("Report.pdf", .finished, in: folder)

        #expect(finished.canOpen)
        #expect(finished.canReveal)
        #expect(!finished.isMissing)
    }

    @Test func aDownloadThatIsNotFinishedCannotBeOpened() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let states: [DownloadManager.Item.State] = [
            .running, .cancelled, .failed("Network error"), .interrupted("Download paused"),
        ]
        for state in states {
            let unfinished = try item("Report.pdf", state, in: folder)
            #expect(!unfinished.canOpen, "\(state)")
            #expect(!unfinished.isMissing, "\(state): it never finished, so nothing went missing")
        }
    }

    @Test func aFileLeftBehindCanStillBeShownWhateverBecameOfTheDownload() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let states: [DownloadManager.Item.State] = [
            .running, .cancelled, .failed("Network error"), .interrupted("Download paused"),
        ]
        for state in states {
            #expect(try item("Report.pdf", state, in: folder).canReveal, "\(state)")
        }
    }

    @Test func aFileMovedOrDeletedAfterwardsCanNeitherBeOpenedNorShown() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gone = try item("Report.pdf", .finished, in: folder, exists: false)

        #expect(!gone.canOpen)
        #expect(!gone.canReveal)
        #expect(gone.isMissing)

        var unplaced = try item("Other.pdf", .finished, in: folder)
        unplaced.destination = nil
        #expect(!unplaced.canOpen)
        #expect(!unplaced.canReveal)
    }

    @Test func theButtonsFollowTheFileWhenItIsMovedAwayWhileTheListIsOpen() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let finished = try item("Report.pdf", .finished, in: folder)
        #expect(finished.canOpen && finished.canReveal)

        try FileManager.default.moveItem(at: folder.appendingPathComponent("Report.pdf"), to: folder.appendingPathComponent("Elsewhere.pdf"))
        #expect(!finished.canOpen && !finished.canReveal && finished.isMissing)
    }

    // MARK: - The line under the name

    @Test func theStatusSaysSizeProgressOrWhatWentWrong() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let done = try item("Report.pdf", .finished, in: folder)
        #expect(done.shortStatus == done.sizeSummary)
        #expect(done.shortStatus.contains("5"))

        let running = try item("Report.pdf", .running, in: folder)
        #expect(running.shortStatus == running.sizeSummary)
        #expect(running.shortStatus.contains("2") && running.shortStatus.contains("5"))

        let failed = try item("Report.pdf", .failed("The network connection was lost."), in: folder)
        #expect(failed.shortStatus == String(localized: "Failed"))

        let cancelled = try item("Report.pdf", .cancelled, in: folder)
        #expect(cancelled.shortStatus == String(localized: "Canceled"))

        let missing = try item("Gone.pdf", .finished, in: folder, exists: false)
        #expect(missing.shortStatus == String(localized: "File moved or deleted"))
    }

    // MARK: - The view

    /// The list drawn by AppKit in a window of the given look, `scale` pixels to the point.
    private func picture(of downloads: DownloadManager, dark: Bool, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let list = RecentDownloadsList(downloads: downloads, showAll: {}, dismiss: {})
            .environment(\.windowColorScheme, dark ? .dark : .light)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: list)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.colorSpace = .pixelTests
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int((size.width * scale).rounded()), pixelsHigh: Int((size.height * scale).rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// A list of fake downloads, newest first: one running, a finished PDF, a finished archive, one whose file was deleted,
    /// a failed one, a cancelled one and an older one the list leaves out. The files are in `folder`.
    private func fakeDownloads(in folder: URL) throws -> DownloadManager {
        func record(
            _ name: String, _ outcome: String, bytes: Int64, on disk: Bool, reason: String? = nil, age: TimeInterval
        ) throws -> [String: Any] {
            let file = folder.appendingPathComponent(name)
            if disk {
                try Data(repeating: 1, count: 16).write(to: file)
            }
            var entry: [String: Any] = [
                "id": UUID().uuidString, "filename": name, "source": "example.com",
                "destination": file.absoluteString, "bytesReceived": bytes, "bytesExpected": bytes,
                "outcome": outcome, "started": Date(timeIntervalSinceNow: -age).timeIntervalSinceReferenceDate,
            ]
            entry["reason"] = reason
            return entry
        }
        let list = [
            try record("annual-report-2026.pdf", "finished", bytes: 3_884_106, on: true, age: 60),
            try record("swift-6.2-osx.pkg", "finished", bytes: 24_117_248, on: true, age: 300),
            try record("holiday-photos.zip", "finished", bytes: 812_000_000, on: false, age: 900),
            try record("installer.dmg", "failed", bytes: 0, on: false, reason: "The network connection was lost.", age: 1_200),
            try record("draft.docx", "cancelled", bytes: 0, on: false, age: 1_500),
            try record("older.txt", "finished", bytes: 100, on: true, age: 3_000),
        ]
        let file = folder.appendingPathComponent("list.json")
        try JSONSerialization.data(withJSONObject: list).write(to: file)
        let downloads = DownloadManager(file: file)
        let id = downloads.beginItem(source: URL(string: "https://example.com/video-lesson.mp4"))
        downloads.noteDestination(folder.appendingPathComponent("video-lesson.mp4"), expectedLength: 250_000_000, for: id)
        downloads.noteProgress(received: 96_000_000, expected: 250_000_000, for: id)
        // Writes the list now, so no write is left waiting to land in the folder after the test has removed it.
        downloads.writeNow()
        return downloads
    }

    @Test func theListDrawsWithItsRowsAndWithNoneAtAll() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = try fakeDownloads(in: folder)
        #expect(downloads.items.count == 7)
        #expect(RecentDownloads.newest(downloads.items).count == 5)

        let full = try picture(of: downloads, dark: false, scale: 1)
        let empty = try picture(of: DownloadManager(persists: false), dark: false, scale: 1)
        #expect(full.pixelsWide == 300)
        #expect(empty.pixelsWide == 300)
        #expect(full.pixelsHigh > empty.pixelsHigh + 4 * 30, "five rows are taller than the one line of the empty list")
    }

    /// Writes the list in both looks as PNGs when `WSURF_DOWNLOADS_HOVER_EVIDENCE` names a folder, for a person to look at.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WSURF_DOWNLOADS_HOVER_EVIDENCE"] != nil))
    func evidence() throws {
        let output = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WSURF_DOWNLOADS_HOVER_EVIDENCE"]), isDirectory: true
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = try fakeDownloads(in: folder)
        for (name, dark) in [("light", false), ("dark", true)] {
            let list = try picture(of: downloads, dark: dark)
            let png = try #require(list.representation(using: .png, properties: [:]))
            try png.write(to: output.appendingPathComponent("recent-downloads-\(name).png"))
        }
        let empty = try picture(of: DownloadManager(persists: false), dark: false)
        let png = try #require(empty.representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("recent-downloads-empty-light.png"))
    }
}
