// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The notices WSurf could not show, and the watch that stops because its site was set to No Access: kept with the watches
/// until the person dismisses them.
@MainActor
@Suite(.serialized)
struct PageWatchNoticeTests {
    private let page = URL(string: "https://shop.example/kettle")!
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// One center on `file`, a clock the test moves, and a page that always reads the same. `allowed` is the site's setting.
    @MainActor
    private final class Rig {
        var date: Date
        var allowed = true
        var notices: [PageWatchCenter.Notice] = []
        var center: PageWatchCenter!

        init(date: Date, file: URL?) {
            self.date = date
            center = PageWatchCenter(
                file: file,
                schedules: false,
                now: { [unowned self] in self.date },
                fetch: { _ in PageWatchReading(title: "Kettle", text: "Kettle $54.99 In stock", url: nil) },
                judge: { _, _ in PageWatchVerdict(met: false, state: "$54.99", message: "") },
                classify: { _, _ in PageWatchVerdict(met: false, state: "", message: "") },
                notify: { [unowned self] _, notice in notices.append(notice) },
                allows: { [unowned self] _ in allowed }
            )
        }
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "PageWatchNoticeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "PageWatches.json")
    }

    private func watching(_ rig: Rig, condition: String = "price below $50") async throws -> PageWatch {
        guard case .watching(let watch) = await rig.center.start(
            url: page, title: "", condition: condition, everyMinutes: 60
        ) else {
            throw Unwatched()
        }
        return watch
    }

    private struct Unwatched: Error {}

    // MARK: - Persistence

    @Test func missedNoticesSurviveARelaunch() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        let watch = try await watching(rig)
        rig.center.noteMissed(watch, .met)
        rig.date += 60
        rig.center.noteMissed(watch, .unreachable)
        await rig.center.flush()

        let reopened: PageWatchCenter = Rig(date: start, file: file).center
        #expect(reopened.missed == rig.center.missed)
        #expect(reopened.missed.map(\.notice) == [.met, .unreachable])
        #expect(reopened.missed.map(\.date) == [start, start + 60])
        #expect(reopened.missed.allSatisfy { $0.url == page && $0.condition == "price below $50" && $0.place == "shop.example" })
        #expect(PageWatchRow.badge(for: reopened) == 2)
    }

    @Test func aStoredNoticeHoldsTheSiteAndConditionButNoPageText() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        let watch = try await watching(rig)
        let fingerprint = try #require(watch.fingerprint)
        #expect(watch.title == "Kettle" && watch.state == "$54.99" && watch.snapshot != nil)
        rig.center.noteMissed(watch, .met)
        await rig.center.flush()

        let stored = try String(contentsOf: PageWatchCenter.missedFile(beside: file), encoding: .utf8)
        #expect(stored.contains("shop.example") && stored.contains("price below $50"))
        for pageText in ["Kettle", "54.99", "In stock", fingerprint] {
            #expect(!stored.contains(pageText), "\(pageText)")
        }
    }

    @Test func missedNoticesKeepTheLastTwentyAcrossARelaunch() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        let watch = try await watching(rig)
        for index in 0..<(PageWatchCenter.missedLimit + 5) {
            rig.date += 1
            rig.center.noteMissed(watch, index.isMultiple(of: 2) ? .met : .unreachable)
        }
        await rig.center.flush()

        let kept = rig.center.missed
        #expect(kept.count == PageWatchCenter.missedLimit)
        #expect(kept.first?.date == start + 6, "the five oldest went first")
        #expect(kept.last?.date == start + TimeInterval(PageWatchCenter.missedLimit + 5))
        #expect(Rig(date: start, file: file).center.missed == kept)
    }

    @Test func aStoredNoticeListPastTheLimitIsCutToTheNewest() {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stored = (0..<(PageWatchCenter.missedLimit + 5)).map { index in
            PageWatchCenter.Missed(url: page, condition: "condition \(index)", notice: .met, date: start + TimeInterval(index))
        }
        JSONFileStore.encodeAndWrite(stored, to: PageWatchCenter.missedFile(beside: file))

        #expect(Rig(date: start, file: file).center.missed == Array(stored.suffix(PageWatchCenter.missedLimit)))
    }

    @Test func aStoredNoticeForAnAddressNoWatchCouldHaveIsNotKept() {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stored = [
            PageWatchCenter.Missed(url: URL(filePath: "/etc/hosts"), condition: "", notice: .met, date: start),
            PageWatchCenter.Missed(url: URL(string: "javascript:alert(1)")!, condition: "", notice: .met, date: start),
            PageWatchCenter.Missed(url: page, condition: "", notice: .met, date: start),
        ]
        JSONFileStore.encodeAndWrite(stored, to: PageWatchCenter.missedFile(beside: file))

        #expect(Rig(date: start, file: file).center.missed == [stored[2]])
    }

    @Test func aDismissedNoticeStaysGoneAfterARelaunch() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        let watch = try await watching(rig)
        for notice in [PageWatchCenter.Notice.met, .unreachable, .expired] {
            rig.center.noteMissed(watch, notice)
        }
        let second = try #require(rig.center.missed.dropFirst().first)
        rig.center.dismissMissed(second.id)
        rig.center.dismissMissed(UUID())
        await rig.center.flush()

        #expect(rig.center.missed.map(\.notice) == [.met, .expired])
        #expect(Rig(date: start, file: file).center.missed.map(\.notice) == [.met, .expired])

        rig.center.dismissMissed()
        await rig.center.flush()

        #expect(rig.center.missed.isEmpty)
        #expect(PageWatchRow.badge(for: rig.center) == 0)
        #expect(Rig(date: start, file: file).center.missed.isEmpty)
    }

    @Test func closingACenterKeepsTheStoredNotices() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        let watch = try await watching(rig)
        rig.center.noteMissed(watch, .expired)
        await rig.center.close()
        rig.center.noteMissed(watch, .met)
        await rig.center.flush()

        #expect(Rig(date: start, file: file).center.missed.map(\.notice) == [.expired])
    }

    @Test func aCenterWithoutAFileKeepsNoticesOnlyInMemory() async throws {
        let rig = Rig(date: start, file: nil)
        let watch = try await watching(rig)
        rig.center.noteMissed(watch, .met)
        await rig.center.flush()

        #expect(rig.center.missed.count == 1)
        #expect(Rig(date: start, file: nil).center.missed.isEmpty)
    }
}
