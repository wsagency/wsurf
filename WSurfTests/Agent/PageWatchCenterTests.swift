// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import XCTest

@testable import WSurf

@MainActor
private final class Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    var waiters: Int {
        waiting.count
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func releaseFirst() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }

    func open() {
        isOpen = true
        let all = waiting
        waiting = []
        for continuation in all {
            continuation.resume()
        }
    }
}

@MainActor
private final class Sleeper {
    private(set) var requested: [TimeInterval] = []
    private var sleeping: [UUID: CheckedContinuation<Void, Never>] = [:]

    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleeping[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.wake(id) }
        }
    }

    func wakeAll() {
        for id in Array(sleeping.keys) {
            wake(id)
        }
    }

    private func wake(_ id: UUID) {
        sleeping.removeValue(forKey: id)?.resume()
    }
}

@MainActor
private final class Harness {
    var date: Date
    var text = "Kettle $54.99 In stock"
    var reads = true
    var allowed = true
    var verdict = PageWatchVerdict(met: false, state: "$54.99", message: "")
    var judged = 0
    var fetches: [PageWatch] = []
    var answers = true
    var classified: [PageWatchChange.Pair] = []
    var classification: (PageWatchChange.Pair) -> PageWatchVerdict = { _ in
        PageWatchVerdict(met: false, state: "", message: "")
    }
    var landed: URL?
    var hasModel = true
    var notices: [PageWatchCenter.Notice] = []
    var duringJudge: (() -> Void)?
    var fetchGate: Gate?
    var inFlight = 0
    var mostInFlight = 0
    let sleeper = Sleeper()
    var center: PageWatchCenter!

    var fetched: Int {
        fetches.count
    }

    init(
        date: Date,
        file: URL? = nil,
        schedules: Bool = false,
        launchHold: TimeInterval = 60,
        queue: PageWatchQueue = PageWatchQueue()
    ) {
        self.date = date
        center = PageWatchCenter(
            file: file,
            schedules: schedules,
            launchHold: launchHold,
            queue: queue,
            now: { [unowned self] in self.date },
            sleep: { [unowned self] in await sleeper.sleep($0) },
            fetch: { [unowned self] watch in
                fetches.append(watch)
                inFlight += 1
                mostInFlight = max(mostInFlight, inFlight)
                defer { inFlight -= 1 }
                await fetchGate?.wait()
                return reads ? PageWatchReading(title: "Kettle", text: text, url: landed) : nil
            },
            judge: { [unowned self] _, _ in
                judged += 1
                duringJudge?()
                return answers ? verdict : nil
            },
            classify: { [unowned self] _, pair in
                classified.append(pair)
                return answers ? classification(pair) : nil
            },
            canJudge: { [unowned self] in hasModel },
            notify: { [unowned self] _, notice in notices.append(notice) },
            allows: { [unowned self] _ in allowed }
        )
    }

    func advance(_ seconds: TimeInterval) {
        date += seconds
    }
}

@MainActor
@Suite(.serialized)
struct PageWatchCenterTests {
    private let page = URL(string: "https://shop.example/kettle")!
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func watching(
        _ harness: Harness,
        minutes: Int = 60,
        condition: String = "price below $50",
        access: PageWatch.Access = .anonymous
    ) async -> PageWatch? {
        let result = await harness.center.start(
            url: page, title: "", condition: condition, everyMinutes: minutes, access: access
        )
        guard case .watching(let watch) = result else { return nil }
        return watch
    }

    private func watchingAnyChange(_ harness: Harness) async -> PageWatch? {
        await watching(harness, condition: "")
    }

    private func isWatching(_ result: PageWatchCenter.Start) -> Bool {
        if case .watching = result {
            return true
        }
        return false
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "PageWatchCenterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "PageWatches.json")
    }

    // MARK: - Starting

    @Test func aWatchStartsFromAReadingOfThePage() async throws {
        let harness = Harness(date: start)
        let watch = try #require(await watching(harness))

        #expect(watch.title == "Kettle")
        #expect(watch.state == "$54.99")
        #expect(watch.nextCheck == start + 3600)
        #expect(harness.center.watches == [watch])
    }

    @Test func aPageThatCannotBeReadIsNeverWatched() async {
        let harness = Harness(date: start)
        harness.reads = false
        let result = await harness.center.start(url: page, title: "", condition: "", everyMinutes: 60)

        #expect(result == .unreadable)
        #expect(harness.center.watches.isEmpty)
    }

    @Test func aConditionThatAlreadyHoldsSetsNoWatch() async {
        let harness = Harness(date: start)
        harness.verdict = PageWatchVerdict(met: true, state: "$42", message: "It is $42 already.")
        let result = await harness.center.start(url: page, title: "", condition: "price below $50", everyMinutes: 60)

        #expect(result == .alreadyMet(harness.verdict))
        #expect(harness.center.watches.isEmpty)
        #expect(harness.notices.isEmpty)
    }

    @Test func aPageThatRedirectsAtTheStartIsNotWatched() async {
        let harness = Harness(date: start)
        harness.landed = URL(string: "https://shop.example/login")
        let result = await harness.center.start(url: page, title: "", condition: "", everyMinutes: 60)

        #expect(result == .unreadable)
    }

    @Test func noWatchStartsWithoutAModel() async {
        let harness = Harness(date: start)
        harness.hasModel = false
        let result = await harness.center.start(url: page, title: "", condition: "", everyMinutes: 60)

        #expect(result == .noModel)
        #expect(harness.center.watches.isEmpty)
    }

    @Test func aModelErrorAtTheStartIsNotAMissingModel() async {
        let harness = Harness(date: start)
        harness.answers = false
        let result = await harness.center.start(url: page, title: "", condition: "price below $50", everyMinutes: 60)

        #expect(result == .undecided)
        #expect(harness.center.watches.isEmpty)
    }

    @Test func aSiteBlockedForTheAssistantIsNeverRead() async {
        let harness = Harness(date: start)
        harness.allowed = false
        let result = await harness.center.start(url: page, title: "", condition: "", everyMinutes: 60)

        #expect(result == .denied)
        #expect(harness.fetched == 0)
        #expect(harness.center.watches.isEmpty)
    }

    @Test func watchesAreAnonymousUnlessThePersonChoseTheirSignIns() async throws {
        let harness = Harness(date: start)
        let plain = try #require(await watching(harness, condition: "plain"))
        let signedIn = try #require(await watching(harness, condition: "signed in", access: .signedIn))
        harness.text = "Kettle $49.99 In stock"
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(plain.access == .anonymous)
        #expect(signedIn.access == .signedIn)
        #expect(harness.fetches.prefix(2).map(\.access) == [.anonymous, .signedIn])
        let later = harness.fetches.dropFirst(2)
        #expect(Dictionary(grouping: later, by: \.id).values.allSatisfy { $0.count == 1 })
        #expect(later.first { $0.id == plain.id }?.access == .anonymous)
        #expect(later.first { $0.id == signedIn.id }?.access == .signedIn)
    }

    @Test func aReadingKeepsOnlyWhatTheCenterAllows() async throws {
        let harness = Harness(date: start)
        harness.text = String(repeating: "x", count: PageWatch.snapshotLimit * 2)
        let watch = try #require(await watching(harness))

        #expect(watch.snapshot?.count == PageWatch.snapshotLimit)
        #expect(watch.fingerprint == PageWatchReading(title: "", text: String(harness.text.prefix(PageWatch.snapshotLimit))).fingerprint)
    }

    // MARK: - Limits

    @Test func intervalsStayBetweenFiveMinutesAndADay() {
        #expect(PageWatch.interval(minutes: 1) == 300)
        #expect(PageWatch.interval(minutes: 90) == 5400)
        #expect(PageWatch.interval(minutes: 100_000) == 86_400)
        #expect(PageWatch.interval(minutes: -5) == 300)
    }

    @Test func theSameWatchIsRefusedBeforeReading() async throws {
        let harness = Harness(date: start)
        let watch = try #require(await watching(harness))
        let fetched = harness.fetched
        let result = await harness.center.start(
            url: page, title: "", condition: "price below $50", everyMinutes: 30, access: .signedIn
        )

        #expect(result == .duplicate(watch))
        #expect(harness.fetched == fetched)
        #expect(harness.center.watches == [watch])
    }

    @Test func twoStartsOfTheSameWatchKeepOnlyOne() async {
        let harness = Harness(date: start)
        let gate = Gate()
        harness.fetchGate = gate
        let first = Task { await harness.center.start(url: page, title: "", condition: "price below $50", everyMinutes: 60) }
        let second = Task { await harness.center.start(url: page, title: "", condition: "price below $50", everyMinutes: 60) }
        #expect(await waitUntil { gate.waiters == 2 })
        gate.open()
        let results = [await first.value, await second.value]

        #expect(results.filter(isWatching).count == 1)
        #expect(results.contains { if case .duplicate = $0 { true } else { false } })
        #expect(harness.center.watches.count == 1)
    }

    @Test func noWatchStartsPastTheLimit() async throws {
        let harness = Harness(date: start)
        for index in 0..<PageWatch.limit {
            _ = try #require(await watching(harness, condition: "condition \(index)"))
        }
        let fetched = harness.fetched
        let result = await harness.center.start(url: page, title: "", condition: "one more", everyMinutes: 60)

        #expect(result == .full)
        #expect(harness.fetched == fetched)
        #expect(harness.center.watches.count == PageWatch.limit)
    }

    @Test func twoStartsForTheLastPlaceKeepOnlyOne() async throws {
        let harness = Harness(date: start)
        for index in 0..<(PageWatch.limit - 1) {
            _ = try #require(await watching(harness, condition: "condition \(index)"))
        }
        let gate = Gate()
        harness.fetchGate = gate
        let first = Task { await harness.center.start(url: page, title: "", condition: "left", everyMinutes: 60) }
        let second = Task { await harness.center.start(url: page, title: "", condition: "right", everyMinutes: 60) }
        #expect(await waitUntil { gate.waiters == 2 })
        gate.open()
        let results = [await first.value, await second.value]

        #expect(results.filter(isWatching).count == 1)
        #expect(results.contains(.full))
        #expect(harness.center.watches.count == PageWatch.limit)
    }

    // MARK: - Checking

    @Test func anUnchangedPageSkipsTheModel() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.judged == 1)
        #expect(harness.center.watches.first?.nextCheck == start + 7200)
        #expect(harness.notices.isEmpty)
    }

    @Test func onlyDueWatchesAreChecked() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.text = "Kettle $49.99 In stock"
        harness.advance(1800)
        await harness.center.checkDue()

        #expect(harness.judged == 1)
    }

    @Test func aMetConditionNotifiesOnceAndEndsTheWatch() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.text = "Kettle $42.99 In stock"
        harness.verdict = PageWatchVerdict(met: true, state: "$42.99", message: "The price dropped to $42.99.")
        harness.advance(3600)
        await harness.center.checkDue()
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.notices == [.met])
        #expect(harness.center.watches.isEmpty)
    }

    @Test func aChangeThatIsNotTheConditionUpdatesTheState() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.text = "Kettle $52.99 In stock"
        harness.verdict = PageWatchVerdict(met: false, state: "$52.99", message: "")
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.center.watches.first?.state == "$52.99")
        #expect(harness.notices.isEmpty)
    }

    @Test func aWatchEndsAfterItsLifetime() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.advance(PageWatch.lifetime)
        await harness.center.checkDue()

        #expect(harness.notices == [.expired])
        #expect(harness.center.watches.isEmpty)
    }

    @Test func aSiteBlockedLaterIsDroppedWithoutReading() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.allowed = false
        harness.text = "Kettle $42.99 In stock"
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.center.watches.isEmpty)
        #expect(harness.fetched == 1)
        #expect(harness.judged == 1)
        #expect(harness.notices.isEmpty)
    }

    @Test func stoppingAWatchMidCheckSendsNothing() async throws {
        let harness = Harness(date: start)
        let watch = try #require(await watching(harness))
        harness.text = "Kettle $42.99 In stock"
        harness.verdict = PageWatchVerdict(met: true, state: "$42.99", message: "Dropped.")
        harness.duringJudge = { harness.center.stop(watch.id) }
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.notices.isEmpty)
        #expect(harness.center.watches.isEmpty)
    }

    @Test func aWatchStoppedByShutDownMidCheckDoesNothingMore() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.text = "Kettle $42.99 In stock"
        harness.verdict = PageWatchVerdict(met: true, state: "$42.99", message: "Dropped.")
        harness.duringJudge = { harness.center.shutDown() }
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.notices.isEmpty)
        #expect(harness.center.watches.isEmpty)
    }

    @Test func watchesAreFoundByIDTitleOrCondition() async throws {
        let harness = Harness(date: start)
        let watch = try #require(await watching(harness))

        #expect(harness.center.matching(watch.id.uuidString) == [watch])
        #expect(harness.center.matching("kettle") == [watch])
        #expect(harness.center.matching("below $50") == [watch])
        #expect(harness.center.matching("teapot").isEmpty)
        #expect(harness.center.matching("") == [watch])
    }

    // MARK: - Failures

    @Test func threeFailedReadsInARowPauseTheWatch() async throws {
        let harness = Harness(date: start)
        let watch = try #require(await watching(harness))
        harness.reads = false
        for _ in 1..<PageWatch.failureLimit {
            harness.advance(3600)
            await harness.center.checkDue()
        }
        #expect(harness.notices.isEmpty)
        #expect(harness.center.watches.first?.failures == PageWatch.failureLimit - 1)

        harness.advance(3600)
        await harness.center.checkDue()
        let paused = try #require(harness.center.watches.first)

        #expect(harness.notices == [.unreachable])
        #expect(paused.isPaused)
        #expect(harness.center.refusal(url: page, condition: watch.condition) == .duplicate(paused))

        let fetched = harness.fetched
        harness.advance(86_400)
        await harness.center.checkDue()
        #expect(harness.fetched == fetched)
    }

    @Test func aSuccessfulCheckResumesAPausedWatch() async throws {
        let harness = Harness(date: start)
        let watch = try #require(await watching(harness))
        harness.reads = false
        for _ in 0..<PageWatch.failureLimit {
            harness.advance(3600)
            await harness.center.checkDue()
        }
        await harness.center.check(watch.id)
        #expect(harness.notices == [.unreachable])

        harness.reads = true
        await harness.center.check(watch.id)

        #expect(harness.center.watches.first?.failures == 0)
        #expect(harness.center.watches.first?.isPaused == false)
        #expect(harness.notices == [.unreachable])
    }

    @Test func aPausedWatchStillExpires() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.reads = false
        for _ in 0..<PageWatch.failureLimit {
            harness.advance(3600)
            await harness.center.checkDue()
        }
        harness.advance(PageWatch.lifetime)
        await harness.center.checkDue()

        #expect(harness.notices == [.unreachable, .expired])
        #expect(harness.center.watches.isEmpty)
    }

    @Test func aGoodReadClearsEarlierFailures() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.reads = false
        harness.advance(3600)
        await harness.center.checkDue()
        harness.reads = true
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.center.watches.first?.failures == 0)
    }

    @Test func aMissingModelPostponesTheCheckWithoutEndingTheWatch() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness))
        harness.text = "Kettle $49.99 In stock"
        harness.hasModel = false
        for _ in 0..<PageWatch.failureLimit {
            harness.advance(3600)
            await harness.center.checkDue()
        }
        harness.hasModel = true
        harness.answers = false
        for _ in 0..<PageWatch.failureLimit {
            harness.advance(3600)
            await harness.center.checkDue()
        }

        let watch = try #require(harness.center.watches.first)
        #expect(harness.notices.isEmpty)
        #expect(watch.failures == 0)
        #expect(watch.nextCheck == harness.date + 3600)
        #expect(watch.snapshot == "Kettle $54.99 In stock")
    }

    @Test func aRedirectAwayFromThePageIsAFailedRead() async throws {
        let harness = Harness(date: start)
        harness.landed = page
        _ = try #require(await watchingAnyChange(harness))
        harness.landed = URL(string: "https://shop.example/login?return_to=%2Fkettle")
        harness.text = "Sign in to continue"
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.classified.isEmpty)
        #expect(harness.center.watches.first?.failures == 1)
        #expect(harness.notices.isEmpty)
    }

    // MARK: - Any change

    @Test func anyChangeNeverAsksTheModelAboutTheFirstReading() async throws {
        let harness = Harness(date: start)
        harness.verdict = PageWatchVerdict(met: true, state: "200 hp", message: "Now 200 hp, up from 150 hp.")
        let watch = try #require(await watchingAnyChange(harness))

        #expect(harness.judged == 0)
        #expect(harness.classified.isEmpty)
        #expect(watch.snapshot == harness.text)
        #expect(harness.notices.isEmpty)
    }

    @Test func anyChangeShowsTheModelOnlyWhatChanged() async throws {
        let harness = Harness(date: start)
        harness.text = "Kettle. Price $54.99. In stock."
        _ = try #require(await watchingAnyChange(harness))
        harness.text = "Kettle. Price $49.99. In stock."
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.classified == [PageWatchChange.Pair(removed: "Price $54.99.", added: "Price $49.99.")])
        #expect(harness.judged == 0)
    }

    @Test func anyChangeIgnoresNoiseButKeepsTheNewText() async throws {
        let harness = Harness(date: start)
        harness.text = "Kettle. Views: 10."
        _ = try #require(await watchingAnyChange(harness))
        harness.text = "Kettle. Views: 11."
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.notices.isEmpty)
        #expect(harness.center.watches.first?.snapshot == "Kettle. Views: 11.")
    }

    @Test func anyChangeNotifiesWhenTheChangeMatters() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watchingAnyChange(harness))
        harness.text = "Kettle $49.99 In stock"
        harness.classification = { _ in PageWatchVerdict(met: true, state: "", message: "The price is now $49.99.") }
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.notices == [.met])
        #expect(harness.center.watches.isEmpty)
    }

    @Test func aLongUnpunctuatedPageStillReportsItsChange() async throws {
        let harness = Harness(date: start)
        let filler = Array(repeating: "Add to cart Free shipping Reviews", count: 80).joined(separator: " ")
        harness.text = "Kettle\n$54.99\nIn stock\n" + filler
        _ = try #require(await watchingAnyChange(harness))
        harness.text = "Kettle\n$49.99\nIn stock\n" + filler
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.classified == [PageWatchChange.Pair(removed: "$54.99", added: "$49.99")])
    }

    @Test func aRealChangeIsNotHiddenByNoiseBesideIt() async throws {
        let harness = Harness(date: start)
        harness.text = "Views: 10\nPrice $54.99"
        _ = try #require(await watchingAnyChange(harness))
        harness.text = "Views: 11\nPrice $49.99"
        harness.classification = { pair in
            pair.added == "Price $49.99"
                ? PageWatchVerdict(met: true, state: "", message: "Price dropped.")
                : PageWatchVerdict(met: false, state: "", message: "")
        }
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.classified.count == 2)
        #expect(harness.notices == [.met])
    }

    @Test func tooManyChangesOfNoiseDoNotNotify() async throws {
        let harness = Harness(date: start)
        harness.text = (1...40).map { "Line \($0)" }.joined(separator: "\n")
        _ = try #require(await watchingAnyChange(harness))
        harness.text = (1...40).map { "Row \($0)" }.joined(separator: "\n")
        harness.advance(3600)
        await harness.center.checkDue()

        #expect(harness.classified.count == PageWatchCenter.classifyLimit)
        #expect(harness.notices.isEmpty)
        #expect(harness.center.watches.first?.snapshot == harness.text)
    }

    @Test func aChangeListsOnlyTheSentencesThatDiffer() {
        let change = PageWatchChange(
            from: "Intro. Engine: 200 hp. Price from 1.3M. Outro!",
            to: "Intro. Engine: 210 hp. Price from 1.3M. Outro! New section."
        )

        #expect(change.removed == ["Engine: 200 hp."])
        #expect(change.added == ["Engine: 210 hp.", "New section."])
        #expect(PageWatchChange(from: "Same. Text.", to: "Same.  Text.").isEmpty)
    }

    @Test func aChangePairsTextFromTheSamePlace() {
        let change = PageWatchChange(
            from: "Updated May 1.\nIntro.\nBody.\nPrice $54.99.",
            to: "Intro.\nBody.\nPrice $49.99."
        )

        #expect(change.pairs == [
            .init(removed: "Updated May 1.", added: nil),
            .init(removed: "Price $54.99.", added: "Price $49.99."),
        ])
    }

    @Test func samePageIgnoresTrailingSlashQueryAndHostCase() {
        let watched = URL(string: "https://Shop.example/kettle")!
        #expect(PageWatch.isSamePage(URL(string: "https://shop.example/kettle/?ref=1")!, watched))
        #expect(!PageWatch.isSamePage(URL(string: "https://shop.example/login")!, watched))
        #expect(!PageWatch.isSamePage(URL(string: "https://login.example/kettle")!, watched))
    }

    @Test func samePageKeepsTheWatchedQuery() {
        let watched = URL(string: "https://shop.example/item?id=123")!
        #expect(PageWatch.isSamePage(URL(string: "https://shop.example/item?id=123&ref=1")!, watched))
        #expect(!PageWatch.isSamePage(URL(string: "https://shop.example/item?id=999")!, watched))
        #expect(!PageWatch.isSamePage(URL(string: "https://shop.example/item")!, watched))
    }

    // MARK: - Storage

    @Test func watchesSurviveARelaunch() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let harness = Harness(date: start, file: file)
        let watch = try #require(await watching(harness))
        await harness.center.flush()

        #expect(Harness(date: start, file: file).center.watches == [watch])
    }

    @Test func aStoppedWatchIsGoneAfterARelaunch() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let harness = Harness(date: start, file: file)
        let watch = try #require(await watching(harness))
        harness.center.stop(watch.id)
        await harness.center.flush()

        #expect(Harness(date: start, file: file).center.watches.isEmpty)
    }

    @Test func closingACenterKeepsTheStoredWatches() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let harness = Harness(date: start, file: file)
        let watch = try #require(await watching(harness))
        await harness.center.close()

        #expect(harness.center.watches.isEmpty)
        #expect(Harness(date: start, file: file).center.watches == [watch])
    }

    @Test func aStoredListPastTheLimitIsCutToTwenty() throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stored = (0..<(PageWatch.limit + 5)).map { index in
            PageWatch(
                id: UUID(), url: page, title: "", condition: "condition \(index)", interval: 3600, created: start, nextCheck: start
            )
        }
        JSONFileStore.encodeAndWrite(stored, to: file)

        #expect(Harness(date: start, file: file).center.watches == Array(stored.prefix(PageWatch.limit)))
    }

    @Test func aStoredIntervalBelowTheMinimumCannotMakeAWatchRunHot() async throws {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let stored = PageWatch(
            id: UUID(), url: page, title: "", condition: "price below $50", interval: 1, created: start, nextCheck: start
        )
        JSONFileStore.encodeAndWrite([stored], to: file)
        let harness = Harness(date: start, file: file)
        await harness.center.checkDue()

        #expect(harness.center.watches.first?.nextCheck == start + PageWatch.intervals.lowerBound)
    }

    // MARK: - Schedule

    @Test func theScheduleWaitsOutTheLaunchHold() async throws {
        let harness = Harness(date: start, schedules: true)
        _ = try #require(await watching(harness))
        #expect(await waitUntil { harness.sleeper.requested == [900] })
        harness.text = "Kettle $49.99 In stock"
        harness.advance(3600)
        harness.center.resume()
        #expect(await waitUntil { harness.sleeper.requested == [900, 60] })
        #expect(harness.judged == 1)

        harness.advance(60)
        harness.sleeper.wakeAll()

        #expect(await waitUntil { harness.judged == 2 })
        await harness.center.close()
    }

    @Test(arguments: [(minutes: 1440, slept: 900), (minutes: 5, slept: 300)])
    func theScheduleSleepsUntilTheNextCheckButNeverLongerThanFifteenMinutes(minutes: Int, slept: TimeInterval) async throws {
        let harness = Harness(date: start, schedules: true)
        _ = try #require(await watching(harness, minutes: minutes))
        #expect(await waitUntil { !harness.sleeper.requested.isEmpty })

        #expect(harness.sleeper.requested == [slept])
        await harness.center.close()
    }

    @Test func theScheduleChecksADueWatchAfterTheLaunchHold() async throws {
        let harness = Harness(date: start, schedules: true, launchHold: 0)
        _ = try #require(await watching(harness))
        harness.text = "Kettle $49.99 In stock"
        harness.advance(3600)
        harness.center.resume()

        #expect(await waitUntil { harness.judged == 2 })
        await harness.center.close()
    }

    @Test func closingStopsTheScheduleWithoutNotifying() async throws {
        let harness = Harness(date: start, schedules: true, launchHold: 0)
        _ = try #require(await watching(harness))
        harness.text = "Kettle $42.99 In stock"
        harness.verdict = PageWatchVerdict(met: true, state: "$42.99", message: "Dropped.")
        harness.advance(3600)
        harness.center.resume()
        await harness.center.close()

        #expect(harness.notices.isEmpty)
        #expect(harness.center.watches.isEmpty)
        #expect(!harness.center.isScheduling)
    }

    @Test func aSleepingScheduleDoesNotKeepTheCenterAlive() async throws {
        weak var released: PageWatchCenter?
        do {
            let center = PageWatchCenter(
                file: nil,
                fetch: { _ in PageWatchReading(title: "Kettle", text: "Kettle $54.99 In stock") },
                judge: { _, _ in PageWatchVerdict(met: false, state: "$54.99", message: "") },
                classify: { _, _ in nil },
                notify: { _, _ in }
            )
            released = center
            let result = await center.start(url: page, title: "", condition: "price below $50", everyMinutes: 60)
            guard case .watching = result else {
                Issue.record("Expected a watch")
                return
            }
        }
        #expect(await waitUntil { released == nil })
    }

    // MARK: - Serial checks

    @Test func checksRunOneAtATime() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness, condition: "one"))
        _ = try #require(await watching(harness, condition: "two"))
        _ = try #require(await watching(harness, condition: "three"))
        _ = try #require(await watching(harness, condition: "four"))
        let notDue = try #require(await watching(harness, minutes: 120, condition: "five"))
        harness.text = "Kettle $49.99 In stock"
        harness.advance(3600)
        let gate = Gate()
        harness.fetchGate = gate
        let before = harness.fetched

        let pass = Task { await harness.center.checkDue() }
        #expect(await waitUntil { gate.waiters == 1 })
        let single = Task { await harness.center.check(notDue.id) }
        for _ in 0..<5 {
            #expect(await waitUntil { gate.waiters == 1 })
            gate.releaseFirst()
        }
        await pass.value
        await single.value

        #expect(harness.fetched - before == 5)
        #expect(harness.mostInFlight == 1)
    }

    @Test func aCheckAlreadyRunningIsNotStartedTwice() async throws {
        let harness = Harness(date: start)
        let watch = try #require(await watching(harness))
        harness.advance(3600)
        let gate = Gate()
        harness.fetchGate = gate
        let before = harness.fetched
        let running = Task { await harness.center.check(watch.id) }
        #expect(await waitUntil { gate.waiters == 1 })
        await harness.center.check(watch.id)
        gate.open()
        await running.value

        #expect(harness.fetched - before == 1)
    }

    @Test func aCheckCancelledWhileWaitingLeavesTheQueue() async throws {
        let queue = PageWatchQueue()
        let harness = Harness(date: start, queue: queue)
        let first = try #require(await watching(harness, condition: "one"))
        let second = try #require(await watching(harness, condition: "two"))
        let third = try #require(await watching(harness, condition: "three"))
        harness.text = "Kettle $49.99 In stock"
        harness.advance(3600)
        let gate = Gate()
        harness.fetchGate = gate
        let before = harness.fetched

        let running = Task { await harness.center.check(first.id) }
        #expect(await waitUntil { gate.waiters == 1 })
        let leaving = Task { await harness.center.check(second.id) }
        #expect(await waitUntil { queue.pending == 1 })
        let staying = Task { await harness.center.check(third.id) }
        #expect(await waitUntil { queue.pending == 2 })
        leaving.cancel()
        #expect(await waitUntil { queue.pending == 1 })
        gate.open()
        await running.value
        await leaving.value
        await staying.value

        #expect(harness.fetches.dropFirst(before).map(\.id) == [first.id, third.id])
        let left = try #require(harness.center.watches.first { $0.id == second.id })
        #expect(left.failures == 0)
        #expect(left.nextCheck == start + 3600)
        #expect(harness.mostInFlight == 1)
    }

    @Test func aCheckCancelledWhileReadingIsNotAFailure() async throws {
        let harness = Harness(date: start)
        let watch = try #require(await watching(harness))
        harness.advance(3600)
        let gate = Gate()
        harness.fetchGate = gate
        harness.reads = false
        let running = Task { await harness.center.check(watch.id) }
        #expect(await waitUntil { gate.waiters == 1 })
        running.cancel()
        gate.open()
        await running.value

        let kept = try #require(harness.center.watches.first)
        #expect(kept.failures == 0)
        #expect(kept.nextCheck == start + 3600)
        #expect(harness.notices.isEmpty)
    }

    @Test func aPassCancelledBetweenWatchesLeavesTheRestDue() async throws {
        let harness = Harness(date: start)
        _ = try #require(await watching(harness, condition: "one"))
        _ = try #require(await watching(harness, condition: "two"))
        harness.advance(3600)
        let gate = Gate()
        harness.fetchGate = gate
        let before = harness.fetched
        let pass = Task { await harness.center.checkDue() }
        #expect(await waitUntil { gate.waiters == 1 })
        pass.cancel()
        gate.open()
        await pass.value

        #expect(harness.fetched - before == 1)
        #expect(harness.center.watches.map(\.nextCheck) == [start + 3600, start + 3600])
        #expect(harness.center.watches.map(\.failures) == [0, 0])
    }
}

// MARK: - Performance

// A pass over twenty watches that are all due, each page changed since the last pass, with the reading and the model injected.
// The bound is far above what a healthy build takes and far below what a pass costs when it writes or reads pages itself.
nonisolated final class PageWatchPerformanceTests: XCTestCase, @unchecked Sendable {
    @MainActor
    private final class Pass {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var number = 0
        var fetched = 0
    }

    /// Runs `work` on the main actor and returns when it is done. The test methods are plain main-thread code, not a main-actor job,
    /// so the wait lets the run loop start the task. An `async` test method would hold the main actor and the task would never start.
    private func finish(_ work: @escaping @MainActor () async -> Void) {
        let finished = XCTestExpectation(description: "work finished")
        Task { @MainActor in
            await work()
            finished.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 60), .completed)
    }

    func testSchedulingTwentyDueWatches() {
        let (pass, center) = MainActor.assumeIsolated {
            let pass = Pass()
            let center = PageWatchCenter(
                file: nil,
                schedules: false,
                now: { pass.date },
                fetch: { watch in
                    pass.fetched += 1
                    let text = (0..<40).map { "\(watch.condition) line \($0) pass \(pass.number)." }.joined(separator: "\n")
                    return PageWatchReading(title: "Page", text: text, url: watch.url)
                },
                judge: { _, _ in PageWatchVerdict(met: false, state: "ok", message: "") },
                classify: { _, _ in nil },
                notify: { _, _ in }
            )
            return (pass, center)
        }
        finish {
            for index in 0..<PageWatch.limit {
                let result = await center.start(
                    url: URL(string: "https://watch.example/\(index)")!, title: "", condition: "condition \(index)", everyMinutes: 60
                )
                guard case .watching = result else {
                    XCTFail("Expected watch \(index) to start")
                    return
                }
            }
        }

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let before = MainActor.assumeIsolated {
                pass.number += 1
                pass.date += 3_600
                return pass.fetched
            }
            finish { await center.checkDue() }
            XCTAssertEqual(MainActor.assumeIsolated { pass.fetched } - before, PageWatch.limit)
        }
    }
}
