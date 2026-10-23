// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import UserNotifications

@testable import WSurf

/// The notices WSurf could not show, kept with the watches until the person dismisses them, and the watch that ends because
/// its site was set to No Access.
@MainActor
@Suite(.serialized)
struct PageWatchNoticeTests {
    private let page = URL(string: "https://shop.example/kettle")!
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// One center on `file`, a clock the test moves, and a page whose text and readability the test sets. `allowed` is the site's setting;
    /// `notificationsOff` makes every notice a missed one, as the live center does when macOS shows nothing.
    @MainActor
    private final class Rig {
        var date: Date
        var allowed = true
        var notificationsOff = false
        var readable = true
        var met = false
        var text = "Kettle $54.99 In stock"
        var reads = 0
        var notices: [PageWatchCenter.Notice] = []
        var center: PageWatchCenter!

        init(date: Date, file: URL?) {
            self.date = date
            center = PageWatchCenter(
                file: file,
                schedules: false,
                now: { [unowned self] in self.date },
                fetch: { [unowned self] _ in
                    reads += 1
                    return readable ? PageWatchReading(title: "Kettle", text: text, url: nil) : nil
                },
                judge: { [unowned self] _, _ in PageWatchVerdict(met: met, state: "$54.99", message: "") },
                classify: { _, _ in PageWatchVerdict(met: false, state: "", message: "") },
                notify: { [unowned self] watch, notice in
                    notices.append(notice)
                    if notificationsOff {
                        center.noteMissed(watch, notice)
                    }
                },
                allows: { [unowned self] _ in allowed }
            )
        }
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "PageWatchNoticeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "PageWatches.json")
    }

    private func watching(
        _ rig: Rig, condition: String = "price below $50", at address: URL? = nil
    ) async throws -> PageWatch {
        guard case .watching(let watch) = await rig.center.start(
            url: address ?? page, title: "", condition: condition, everyMinutes: 60
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
            PageWatchCenter.Missed(
                watchID: UUID(), url: page, condition: "condition \(index)", notice: .met, date: start + TimeInterval(index)
            )
        }
        JSONFileStore.encodeAndWrite(stored, to: PageWatchCenter.missedFile(beside: file))

        #expect(Rig(date: start, file: file).center.missed == Array(stored.suffix(PageWatchCenter.missedLimit)))
    }

    @Test func aStoredNoticeForAnAddressNoWatchCouldHaveIsNotKept() {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stored = [
            PageWatchCenter.Missed(watchID: UUID(), url: URL(filePath: "/etc/hosts"), condition: "", notice: .met, date: start),
            PageWatchCenter.Missed(
                watchID: UUID(), url: URL(string: "javascript:alert(1)")!, condition: "", notice: .met, date: start
            ),
            PageWatchCenter.Missed(watchID: UUID(), url: page, condition: "", notice: .met, date: start),
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

    // MARK: - A watch whose site was set to No Access

    @Test func aSiteSetToNoAccessEndsTheWatchWithOneNoticeAndNoReading() async throws {
        let rig = Rig(date: start, file: nil)
        _ = try await watching(rig)
        rig.allowed = false
        rig.date += 3600

        await rig.center.checkDue()
        rig.date += 3600
        await rig.center.checkDue()

        #expect(rig.center.watches.isEmpty)
        #expect(rig.notices == [.denied], "once, and the watch does not come back")
        #expect(rig.reads == 1, "only the reading that started the watch")
    }

    @Test func checkingNowAWatchWhoseSiteWasSetToNoAccessEndsItWithTheSameNotice() async throws {
        let rig = Rig(date: start, file: nil)
        let watch = try await watching(rig)
        rig.allowed = false

        await rig.center.check(watch.id)
        await rig.center.check(watch.id)

        #expect(rig.center.watches.isEmpty)
        #expect(rig.notices == [.denied])
        #expect(rig.reads == 1)
    }

    @Test func aWatchStoppedForNoAccessIsKeptAsAMissedNoticeAcrossARelaunch() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        rig.notificationsOff = true
        _ = try await watching(rig)
        rig.allowed = false
        rig.date += 3600
        await rig.center.checkDue()
        await rig.center.flush()

        let reopened: PageWatchCenter = Rig(date: start, file: file).center
        #expect(reopened.watches.isEmpty)
        #expect(reopened.missed.map(\.notice) == [.denied])
        #expect(reopened.missed.first?.place == "shop.example")
        #expect(reopened.missed.first?.condition == "price below $50")
    }

    @Test func theNoAccessNoticeNamesTheSettingAndNoPageText() async throws {
        let rig = Rig(date: start, file: nil)
        let watch = try await watching(rig)
        let request = NotificationBridge.request(for: watch, .denied, profileID: UUID())

        #expect(request.content.title == "shop.example")
        #expect(request.content.body == String(localized: "WSurf stopped watching this page because this website’s Assistant Access is now No Access."))
        #expect(request.content.body.contains("No Access"))
        #expect(request.content.sound == nil, "only a met watch makes a sound")
        let shown = [request.content.title, request.content.subtitle, request.content.body].joined(separator: " ")
        #expect(!shown.contains("54.99") && !shown.contains("Kettle"))
        #expect(NotificationBridge.body(condition: "price below $50", .denied) == request.content.body)
    }

    // MARK: - Nothing outlives what it names

    private let otherPage = URL(string: "https://shop.example/toaster")!

    @Test func stoppingAWatchTakesItsNoticesAndLeavesTheOthers() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        let kettle = try await watching(rig)
        let toaster = try await watching(rig, at: otherPage)
        rig.center.noteMissed(kettle, .unreachable)
        rig.center.noteMissed(toaster, .unreachable)
        rig.center.noteMissed(kettle, .unreachable)

        rig.center.stop(kettle.id)
        await rig.center.flush()

        #expect(rig.center.missed.map(\.watchID) == [toaster.id])
        #expect(Rig(date: start, file: file).center.missed.map(\.watchID) == [toaster.id])
    }

    @Test func aWatchThatEndsOnItsOwnLeavesOnlyItsEndingNotice() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        rig.notificationsOff = true
        let watch = try await watching(rig)
        rig.center.noteMissed(watch, .unreachable)
        rig.met = true
        rig.text = "Kettle $42.99 In stock"
        rig.date += 3600

        await rig.center.checkDue()
        await rig.center.flush()

        #expect(rig.center.watches.isEmpty)
        #expect(rig.center.missed.map(\.notice) == [.met], "the ending notice stays, the older one goes with the watch")
        #expect(Rig(date: start, file: file).center.missed.map(\.notice) == [.met])
    }

    @Test func theNoAccessNoticeStaysUntilDismissedAndThenNothingIsLeft() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        rig.notificationsOff = true
        let watch = try await watching(rig)
        rig.center.noteMissed(watch, .unreachable)
        rig.allowed = false
        rig.date += 3600
        await rig.center.checkDue()
        await rig.center.flush()

        let notice = try #require(rig.center.missed.first)
        #expect(rig.center.missed.map(\.notice) == [.denied])
        #expect(Rig(date: start, file: file).center.missed == [notice])

        rig.center.dismissMissed(notice.id)
        await rig.center.flush()

        #expect(Rig(date: start, file: file).center.missed.isEmpty)
        #expect(try String(contentsOf: PageWatchCenter.missedFile(beside: file), encoding: .utf8) == "[]")
    }

    @Test func aPageThatReadsAgainDropsTheNoticeThatItCouldNotBeRead() async throws {
        let rig = Rig(date: start, file: nil)
        rig.notificationsOff = true
        let watch = try await watching(rig)
        rig.readable = false
        for _ in 0..<PageWatch.failureLimit {
            await rig.center.check(watch.id)
        }
        #expect(rig.center.missed.map(\.notice) == [.unreachable])

        rig.readable = true
        await rig.center.check(watch.id)

        #expect(rig.center.missed.isEmpty)
        #expect(rig.center.watches.first?.isUnreachable == false)
    }

    @Test func clearingHistoryOrAnyBrowsingDataRemovesTheNotices() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        let watch = try await watching(rig)
        rig.center.noteMissed(watch, .met)
        rig.center.noteMissed(watch, .denied)

        rig.center.dismissMissed()
        await rig.center.flush()

        #expect(rig.center.missed.isEmpty)
        #expect(Rig(date: start, file: file).center.missed.isEmpty)
        #expect(!exists(PageWatchCenter.missedFile(beside: file)), "nothing about the pages is left on the disk")
    }

    private func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
    }

    private func store(_ notices: [PageWatchCenter.Missed], beside file: URL) {
        JSONFileStore.encodeAndWrite(notices, to: PageWatchCenter.missedFile(beside: file))
    }

    private func sampleNotice(_ condition: String = "") -> PageWatchCenter.Missed {
        PageWatchCenter.Missed(watchID: UUID(), url: page, condition: condition, notice: .met, date: start)
    }

    @Test func clearingRemovesStoredNoticesTheListInMemoryNeverHeld() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        #expect(rig.center.missed.isEmpty)
        store([sampleNotice("price below $50")], beside: file)
        #expect(exists(PageWatchCenter.missedFile(beside: file)), "the file holds a notice the center never loaded")

        rig.center.dismissMissed()
        await rig.center.flush()

        #expect(!exists(PageWatchCenter.missedFile(beside: file)))
        #expect(Rig(date: start, file: file).center.missed.isEmpty)
    }

    @Test func clearingRemovesAFileThatCannotBeRead() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let notices = PageWatchCenter.missedFile(beside: file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json, https://shop.example/kettle".utf8).write(to: notices)
        let rig = Rig(date: start, file: file)
        #expect(rig.center.missed.isEmpty, "a file that fails to decode shows nothing")

        rig.center.dismissMissed()
        await rig.center.flush()

        #expect(!exists(notices))
    }

    @Test func clearingRightAfterANoticeIsNotUndoneByThatNoticesWrite() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        let watch = try await watching(rig)
        rig.center.noteMissed(watch, .met)
        rig.center.noteMissed(watch, .expired)

        rig.center.dismissMissed()
        await rig.center.flush()

        #expect(!exists(PageWatchCenter.missedFile(beside: file)), "the write that was still queued did not bring the file back")
        #expect(Rig(date: start, file: file).center.missed.isEmpty)
    }

    @Test func clearingAClosedCentersNoticesStillRemovesTheFile() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let rig = Rig(date: start, file: file)
        store([sampleNotice()], beside: file)
        await rig.center.close()

        rig.center.dismissMissed()
        await rig.center.flush()

        #expect(!exists(PageWatchCenter.missedFile(beside: file)))
    }

    @Test func aNoticeStoredBeforeItNamedItsWatchStillLoads() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let id = UUID()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = """
            [{"id":"\(id.uuidString)","url":"https:\\/\\/shop.example\\/kettle","condition":"price below $50","notice":"met","date":800000000}]
            """
        try Data(legacy.utf8).write(to: PageWatchCenter.missedFile(beside: file))

        let center: PageWatchCenter = Rig(date: start, file: file).center
        let notice = try #require(center.missed.first)

        #expect(center.missed.count == 1)
        #expect(notice.id == id)
        #expect(notice.watchID == id, "no watch to match, so a stop never touches it")
        #expect(notice.url == page && notice.condition == "price below $50" && notice.notice == .met)
        #expect(notice.date == Date(timeIntervalSinceReferenceDate: 800_000_000))
        center.dismissMissed(id)
        #expect(center.missed.isEmpty, "it can still be dismissed")
    }

    @Test(arguments: [
        (kinds: Set<BrowsingData.Kind>([.history]), range: BrowsingData.Range.hour),
        (kinds: Set<BrowsingData.Kind>([.history]), range: BrowsingData.Range.everything),
        (kinds: Set<BrowsingData.Kind>([.cache]), range: BrowsingData.Range.everything),
    ])
    func everyClearOfBrowsingDataTakesTheNotices(kinds: Set<BrowsingData.Kind>, range: BrowsingData.Range) async throws {
        let profile = Profile(id: UUID(), name: "Clear", symbol: "eye", color: .gray)
        defer { try? FileManager.default.removeItem(at: profile.supportDirectory) }
        let context = BrowserProfileContext(profile: profile)
        let center = try #require(context.pageWatches)
        center.noteMissed(watch(), .met)
        #expect(center.missed.count == 1)

        try await BrowsingData.clear(kinds, range: range, history: context.history, context: context)

        #expect(center.missed.isEmpty)
        #expect(PageWatchRow.badge(for: center) == 0)
    }

    @Test func clearingEverythingOnQuitTakesTheNotices() async throws {
        let profile = Profile(id: UUID(), name: "Quit", symbol: "eye", color: .gray)
        defer { try? FileManager.default.removeItem(at: profile.supportDirectory) }
        let context = BrowserProfileContext(profile: profile)
        let center = try #require(context.pageWatches)
        center.noteMissed(watch(), .expired)

        try await BrowsingData.clearEverything(history: context.history, context: context)

        #expect(center.missed.isEmpty)
    }

    @Test func clearingAnotherProfilesHistoryTakesItsNotices() throws {
        let running = Profile(id: UUID(), name: "Running", symbol: "eye", color: .gray)
        let idle = Profile(id: UUID(), name: "Idle", symbol: "eye", color: .gray)
        defer {
            BrowserProfileContext.forget(running.id)
            for profile in [running, idle] {
                try? FileManager.default.removeItem(at: profile.supportDirectory)
            }
        }
        let center = try #require(BrowserProfileContext.shared(for: running).pageWatches)
        center.noteMissed(watch(), .met)
        let stored = PageWatchCenter.missedFile(beside: idle.pageWatchesFile)
        let leftover = PageWatchCenter.Missed(watchID: UUID(), url: page, condition: "", notice: .met, date: start)
        JSONFileStore.encodeAndWrite([leftover], to: stored)
        #expect(FileManager.default.fileExists(atPath: stored.path(percentEncoded: false)))

        ProfileMaintenance.clearHistory(of: running)
        ProfileMaintenance.clearHistory(of: idle)

        #expect(center.missed.isEmpty, "a profile whose watches run clears them in memory")
        #expect(!FileManager.default.fileExists(atPath: stored.path(percentEncoded: false)), "one that is idle loses the file")
    }

    @Test func aDeletedProfilesNoticesGoWithItsFolderAndNothingIsWrittenBack() async throws {
        let file = scratchFile()
        let folder = file.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let rig = Rig(date: start, file: file)
        let watch = try await watching(rig)
        rig.center.noteMissed(watch, .met)
        await rig.center.close()
        try FileManager.default.removeItem(at: folder)

        rig.center.noteMissed(watch, .expired)
        await rig.center.flush()

        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    private func watch() -> PageWatch {
        PageWatch(id: UUID(), url: page, title: "", condition: "price below $50", interval: 3600, created: start, nextCheck: start)
    }
}
