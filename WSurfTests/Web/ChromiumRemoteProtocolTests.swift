// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import os
import Testing
import XPC

@testable import CefKit

/// A clock the test moves by hand. `schedule` is the `CefRemoteScheduler` the code under test gets; `advance` runs the timers
/// that fall due, oldest first, and a cancelled timer never runs.
private nonisolated final class FakeClock: Sendable {
    private struct Timer {
        let id: Int
        let due: TimeInterval
        let fire: @Sendable () -> Void
    }

    private struct State {
        var now: TimeInterval = 0
        var nextID = 0
        var timers: [Timer] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var activeTimers: Int {
        state.withLock { $0.timers.count }
    }

    var schedule: CefRemoteScheduler {
        { [self] seconds, fire in
            let id = state.withLock { state -> Int in
                state.nextID += 1
                state.timers.append(Timer(id: state.nextID, due: state.now + seconds, fire: fire))
                return state.nextID
            }
            return { [self] in state.withLock { $0.timers.removeAll { $0.id == id } } }
        }
    }

    func advance(by seconds: TimeInterval) {
        let target = state.withLock { $0.now + seconds }
        while true {
            let next: Timer? = state.withLock { state in
                guard let index = state.timers.indices.filter({ state.timers[$0].due <= target })
                    .min(by: { state.timers[$0].due < state.timers[$1].due })
                else {
                    state.now = target
                    return nil
                }
                let timer = state.timers.remove(at: index)
                state.now = max(state.now, timer.due)
                return timer
            }
            guard let next else { return }
            next.fire()
        }
    }
}

private nonisolated final class Tally<Element: Sendable>: Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [Element]())

    func add(_ item: Element) {
        items.withLock { $0.append(item) }
    }

    var all: [Element] {
        items.withLock { $0 }
    }

    var count: Int {
        items.withLock { $0.count }
    }
}

/// Answers every even-numbered request from the dispatch pool's threads. Not MainActor: the suite's default isolation would
/// otherwise make the loop body MainActor code running on worker threads.
private nonisolated func answerEvenRequestsConcurrently(_ requests: CefRemoteRequests<Int>, ids: [Int64]) {
    DispatchQueue.concurrentPerform(iterations: ids.count) { @Sendable index in
        guard index.isMultiple(of: 2) else { return }
        usleep(UInt32(index % 4) * 500)
        requests.reply(ids[index], index)
    }
}

/// The D4 protocol between WSurf and the Chromium service, with no service and no connection: the message vocabulary, the
/// version check, the table of requests that WSurf waits on, and the lifecycle rules (linger, memory pressure, crash loop).
/// All of it is logic that both sides share, so a clock the test controls stands in for time.
@Suite
struct ChromiumRemoteProtocolTests {
    // MARK: - Messages

    @Test func everyKeyTypeSurvivesARoundTrip() {
        let message = CefRemoteMessage(CefRemote.Op.createBrowser, browser: 42)
        message.set("string", "héllo")
        message.set("int64", Int64.max)
        message.set("int", 7)
        message.set("negative", Int64(-5))
        message.set("double", 1.25)
        message.set("true", true)
        message.set("false", false)
        message.set("data", data: Data([0, 1, 2, 255]))
        message.set("empty", data: Data())
        message.set("doubles", doubles: [0.5, -2, 1e9])
        message.set("int64s", int64s: [3, -1, Int64.max])
        message.set("strings", strings: ["a": "1", "nil": nil])
        let inner = CefRemoteMessage("inner", browser: 9)
        inner.set("n", 11)
        message.set("messages", messages: [inner, CefRemoteMessage("second")])

        #expect(message.op == CefRemote.Op.createBrowser)
        #expect(message.browser == 42)
        #expect(message.string("string") == "héllo")
        #expect(message.int("int64") == Int64.max)
        #expect(message.int("int") == 7)
        #expect(message.int("negative") == -5)
        #expect(message.double("double") == 1.25)
        #expect(message.bool("true"))
        #expect(!message.bool("false"))
        #expect(message.data("data") == Data([0, 1, 2, 255]))
        #expect(message.has("empty"))
        #expect(message.data("empty").isEmpty)
        #expect(message.doubles("doubles") == [0.5, -2, 1e9])
        #expect(message.int64s("int64s") == [3, -1, Int64.max])
        #expect(message.strings("strings") == ["a": "1", "nil": ""])
        let nested = message.messages("messages")
        #expect(nested.map(\.op) == ["inner", "second"])
        #expect(nested[0].browser == 9)
        #expect(nested[0].int("n") == 11)
    }

    @Test func aMissingKeyReadsAsTheTypesEmptyValue() {
        let message = CefRemoteMessage("empty")
        #expect(!message.has("nothing"))
        #expect(message.string("nothing").isEmpty)
        #expect(message.int("nothing") == 0)
        #expect(message.double("nothing") == 0)
        #expect(!message.bool("nothing"))
        #expect(message.data("nothing").isEmpty)
        #expect(message.doubles("nothing").isEmpty)
        #expect(message.int64s("nothing").isEmpty)
        #expect(message.strings("nothing").isEmpty)
        #expect(message.messages("nothing").isEmpty)
        // A value of another type is not misread as an array.
        message.set("text", "not an array")
        #expect(message.int64s("text").isEmpty)
        #expect(message.messages("text").isEmpty)
    }

    @Test func aWrongTypedNumberReadsAsZero() {
        // libxpc answers NaN for a value that is not a double; the decoder's floor is 0.
        let message = CefRemoteMessage("wrong")
        message.set("text", "1.5")
        message.set("integer", Int64(3))
        message.set("flag", true)
        #expect(message.double("text") == 0)
        #expect(message.double("integer") == 0)
        #expect(message.double("flag") == 0)
    }

    @Test func aNonFiniteDoubleFromAPeerReadsAsZero() {
        let message = CefRemoteMessage("hostile")
        message.set("nan", Double.nan)
        message.set("plus", Double.infinity)
        message.set("minus", -Double.infinity)
        message.set("big", Double.greatestFiniteMagnitude)
        #expect(message.double("nan") == 0)
        #expect(message.double("plus") == 0)
        #expect(message.double("minus") == 0)
        // A finite value is the consumer's to clamp.
        #expect(message.double("big") == Double.greatestFiniteMagnitude)
    }

    @Test func nonFiniteAndWrongTypedElementsOfADoubleArrayReadAsZero() {
        let message = CefRemoteMessage("hostile")
        message.set("doubles", doubles: [1.5, .nan, .infinity, -.infinity, -2])
        #expect(message.doubles("doubles") == [1.5, 0, 0, 0, -2])

        let mixed = xpc_array_create(nil, 0)
        xpc_array_append_value(mixed, xpc_double_create(4))
        xpc_array_append_value(mixed, xpc_string_create("x"))
        xpc_array_append_value(mixed, xpc_int64_create(9))
        xpc_dictionary_set_value(message.object, "mixed", mixed)
        #expect(message.doubles("mixed") == [4, 0, 0])
    }

    @Test func aWrappedObjectMustBeADictionary() {
        let message = CefRemoteMessage("ping")
        #expect(CefRemoteMessage(wrapping: message.object)?.op == "ping")
        #expect(CefRemoteMessage(wrapping: xpc_int64_create(1)) == nil)
    }

    @Test func theHistoryAListCarriesComesBackEntryForEntry() {
        let entries = [
            CefRemote.HistoryEntry(id: 11, url: "about:blank", title: ""),
            CefRemote.HistoryEntry(id: 12, url: "https://example.test/a?q=1#x", title: "Ä page", hasPostData: true),
            CefRemote.HistoryEntry(id: Int64.max, url: "https://example.test/b", title: "B", isCurrent: true),
        ]
        let message = CefRemoteMessage.historyChanged(browser: 5, entries: entries)

        #expect(message.op == CefRemote.Event.historyChanged)
        #expect(message.browser == 5)
        #expect(message.historyEntries == entries)
        #expect(CefRemoteMessage.historyChanged(browser: 5, entries: []).historyEntries.isEmpty)
    }

    @Test func aCollapseRequestCarriesTheEntryToKeepAndTheListItExpects() {
        let message = CefRemoteMessage.collapseHistory(browser: 3, request: 77, keeping: 12, ifEntriesAre: [11, 12])

        #expect(message.op == CefRemote.Op.collapseHistory)
        #expect(message.browser == 3)
        #expect(message.int(CefRemote.Key.identifier) == 77)
        #expect(message.collapseKeep == 12)
        #expect(message.collapseExpected == [11, 12])
    }

    @Test(arguments: [CefRemote.CollapseOutcome.landed, .refused, .skipped])
    func eachCollapseOutcomeComesBackAsItself(outcome: CefRemote.CollapseOutcome) {
        let message = CefRemoteMessage.historyCollapsed(browser: 3, request: 77, outcome: outcome)

        #expect(message.op == CefRemote.Event.historyCollapsed)
        #expect(message.int(CefRemote.Key.identifier) == 77)
        #expect(message.collapseOutcome == outcome)
    }

    @Test func anOutcomeThisBuildDoesNotKnowIsNotGuessed() {
        let message = CefRemoteMessage(CefRemote.Event.historyCollapsed)
        message.set(CefRemote.Key.outcome, Int64(99))
        #expect(message.collapseOutcome == nil)
        #expect(CefRemote.CollapseOutcome.landed.rawValue == 0)
        #expect(CefRemote.CollapseOutcome.refused.rawValue == 1)
        #expect(CefRemote.CollapseOutcome.skipped.rawValue == 2)
    }

    @Test func aCollapseAnswerWithoutAnIntegerOutcomeIsNotLanded() {
        // A missing key reads 0, which is `landed`: a malformed answer must not decode as success.
        #expect(CefRemoteMessage(CefRemote.Event.historyCollapsed).collapseOutcome == nil)

        let text = CefRemoteMessage(CefRemote.Event.historyCollapsed)
        text.set(CefRemote.Key.outcome, "landed")
        #expect(text.collapseOutcome == nil)

        let real = CefRemoteMessage.historyCollapsed(browser: 1, request: 2, outcome: .landed)
        #expect(real.collapseOutcome == .landed)
    }

    // MARK: - Collapse verdict

    private func native(_ ids: [Int64], current: Int64) -> [CefRemote.HistoryEntry] {
        ids.map { CefRemote.HistoryEntry(id: $0, url: "https://example.test/\($0)", title: "", isCurrent: $0 == current) }
    }

    @Test func theServiceSendsTheResetOnlyForTheExpectedListWithTheKeptEntryCurrent() {
        #expect(CefRemote.collapseVerdict(native: native([1, 2], current: 2), keeping: 2, expected: [1, 2]) == nil)
        #expect(CefRemote.collapseVerdict(native: native([1, 2, 3], current: 3), keeping: 3, expected: [1, 2, 3]) == nil)
    }

    @Test func aListWithNothingLeftToDropHasLanded() {
        // Only the kept entry is left.
        #expect(CefRemote.collapseVerdict(native: native([2], current: 2), keeping: 2, expected: [1, 2]) == .landed)
        // The startup page is gone and the list moved on (today's `first != about:blank`).
        #expect(CefRemote.collapseVerdict(native: native([2, 3], current: 3), keeping: 2, expected: [1, 2]) == .landed)
        #expect(CefRemote.collapseVerdict(native: native([7, 8, 9], current: 9), keeping: 2, expected: [1, 2]) == .landed)
        #expect(CefRemote.collapseVerdict(native: native([2], current: 2), keeping: 2, expected: [1, 2, 3]) == .landed)
    }

    @Test func aListThatGrewPastTheExpectedOneIsSkipped() {
        #expect(CefRemote.collapseVerdict(native: native([1, 2, 3], current: 3), keeping: 2, expected: [1, 2]) == .skipped)
        #expect(CefRemote.collapseVerdict(native: native([1, 2, 3, 4], current: 2), keeping: 2, expected: [1, 2]) == .skipped)
    }

    @Test func anyOtherListIsRefusedSoTheCallerMayRetry() {
        // The startup page alone: the committed entry has not been recorded yet.
        #expect(CefRemote.collapseVerdict(native: native([1], current: 1), keeping: 2, expected: [1, 2]) == .refused)
        // Some expected entries are there, but not all and not in the expected order.
        #expect(CefRemote.collapseVerdict(native: native([1, 3], current: 3), keeping: 3, expected: [1, 2, 3]) == .refused)
        #expect(CefRemote.collapseVerdict(native: native([2, 1], current: 1), keeping: 2, expected: [1, 2]) == .refused)
        // The entry to keep is not in what the caller expected.
        #expect(CefRemote.collapseVerdict(native: native([1, 2], current: 2), keeping: 9, expected: [1, 2]) == .refused)
        // The reset keeps the current entry only, and the kept one is not current.
        #expect(CefRemote.collapseVerdict(native: native([1, 2], current: 1), keeping: 2, expected: [1, 2]) == .refused)
        // No entries at all.
        #expect(CefRemote.collapseVerdict(native: [], keeping: 2, expected: [1, 2]) == .refused)
    }

    // MARK: - Version

    @Test func aHelloOfTheSameVersionIsAccepted() {
        let hello = CefRemoteMessage.hello(linger: 12)

        #expect(hello.op == CefRemote.Op.hello)
        #expect(hello.int(CefRemote.Key.protocolVersion) == CefRemote.protocolVersion)
        #expect(hello.double(CefRemote.Key.linger) == 12)
        #expect(hello.checkProtocolVersion() == .compatible)
        #expect(!CefRemoteMessage.hello().has(CefRemote.Key.linger))
    }

    @Test func aHelloOfAnotherVersionIsRefused() {
        for theirs in [CefRemote.protocolVersion + 1, CefRemote.protocolVersion - 1, 99] {
            #expect(CefRemoteMessage.hello(protocolVersion: theirs).checkProtocolVersion() == .mismatch(theirs: theirs))
        }
    }

    @Test func aHelloWithNoVersionIsRefusedNotAssumedCurrent() {
        let hello = CefRemoteMessage(CefRemote.Op.hello)
        #expect(hello.checkProtocolVersion() == .mismatch(theirs: 0))
    }

    @Test func aRefusalReplyIsNotOkNamesBothVersionsAndCarriesOurs() {
        let reply = CefRemoteMessage("hello.reply")
        reply.setRefusal(.mismatch(theirs: 7))

        #expect(!reply.bool(CefRemote.Key.success))
        #expect(reply.int(CefRemote.Key.protocolVersion) == CefRemote.protocolVersion)
        #expect(reply.string(CefRemote.Key.error).contains("7"))
        #expect(reply.string(CefRemote.Key.error).contains("\(CefRemote.protocolVersion)"))
    }

    // MARK: - Requests

    private func table(_ clock: FakeClock, timeout: TimeInterval = 5) -> CefRemoteRequests<Int> {
        CefRemoteRequests<Int>(defaultTimeout: timeout, schedule: clock.schedule)
    }

    @Test func aRequestThatIsAnsweredResumesExactlyOnce() {
        let clock = FakeClock()
        let requests = table(clock)
        let ended = Tally<CefRemoteReply<Int>>()
        let id = requests.begin { ended.add($0) }
        #expect(requests.pendingCount == 1)

        #expect(requests.reply(id, 7))
        #expect(!requests.reply(id, 8))
        clock.advance(by: 60)

        #expect(ended.all == [.value(7)])
        #expect(requests.pendingCount == 0)
        #expect(clock.activeTimers == 0)
    }

    @Test func aRequestThatNobodyAnswersTimesOutExactlyOnceAndALateReplyIsDropped() {
        let clock = FakeClock()
        let requests = table(clock)
        let ended = Tally<CefRemoteReply<Int>>()
        let id = requests.begin { ended.add($0) }

        clock.advance(by: 4.9)
        #expect(ended.count == 0)
        #expect(requests.pendingCount == 1)
        clock.advance(by: 0.1)
        #expect(ended.all == [.timedOut])
        #expect(requests.pendingCount == 0)

        #expect(!requests.reply(id, 7))
        #expect(requests.interruptAll() == 0)
        clock.advance(by: 60)
        #expect(ended.all == [.timedOut])
    }

    @Test func aRequestNamesItsOwnTimeout() {
        let clock = FakeClock()
        let requests = table(clock)
        let ended = Tally<CefRemoteReply<Int>>()
        _ = requests.begin(timeout: 1) { ended.add($0) }

        clock.advance(by: 1)
        #expect(ended.all == [.timedOut])
        #expect(requests.pendingCount == 0)
    }

    @Test func theDefaultTimeoutIsFiveSeconds() {
        #expect(CefRemoteRequests<Int>().defaultTimeout == 5)
    }

    @Test func anInterruptionEndsEveryWaitingRequestOnceAndLeavesTheirTimersNothing() {
        let clock = FakeClock()
        let requests = table(clock)
        let ended = Tally<CefRemoteReply<Int>>()
        let ids = (0..<3).map { _ in requests.begin { ended.add($0) } }

        #expect(requests.interruptAll() == 3)
        #expect(ended.all == [.interrupted, .interrupted, .interrupted])
        #expect(clock.activeTimers == 0)
        #expect(ids.allSatisfy { !requests.reply($0, 1) })
        clock.advance(by: 60)
        #expect(ended.count == 3)
        #expect(requests.interruptAll() == 0)
    }

    @Test func aTableThatIsDroppedWithRequestsPendingEndsThemInterrupted() {
        let clock = FakeClock()
        let ended = Tally<CefRemoteReply<Int>>()
        do {
            let requests = table(clock)
            _ = requests.begin { ended.add($0) }
            _ = requests.begin { ended.add($0) }
            #expect(ended.count == 0)
        }

        #expect(ended.all == [.interrupted, .interrupted])
        #expect(clock.activeTimers == 0)
        clock.advance(by: 60)
        #expect(ended.count == 2)
    }

    @Test func aReplyGoesToTheRequestItNamesAndLeavesTheOthersWaiting() {
        let clock = FakeClock()
        let requests = table(clock)
        let first = Tally<CefRemoteReply<Int>>()
        let second = Tally<CefRemoteReply<Int>>()
        let firstID = requests.begin { first.add($0) }
        let secondID = requests.begin { second.add($0) }
        #expect(firstID != secondID)

        #expect(requests.reply(secondID, 2))
        #expect(first.count == 0)
        #expect(second.all == [.value(2)])
        #expect(requests.pendingCount == 1)
        #expect(!requests.reply(999, 1))
    }

    @Test func aTimerThatFiresBeforeBeginReturnsStillEndsTheRequestOnce() {
        let ended = Tally<CefRemoteReply<Int>>()
        let cancelled = Tally<Void>()
        let requests = CefRemoteRequests<Int>(schedule: { _, fire in
            fire()
            return { cancelled.add(()) }
        })

        let id = requests.begin { ended.add($0) }

        #expect(ended.all == [.timedOut])
        #expect(requests.pendingCount == 0)
        #expect(cancelled.count == 1)
        #expect(!requests.reply(id, 1))
    }

    @Test func anAwaitedRequestReturnsTheReply() async {
        let clock = FakeClock()
        let requests = table(clock)

        let reply = await requests.request { id in
            // The reply can come before the send returns.
            requests.reply(id, 21)
        }

        #expect(reply == .value(21))
        #expect(requests.pendingCount == 0)
    }

    @Test func anAwaitedRequestToAServiceThatNeverRepliesTimesOut() async {
        let clock = FakeClock()
        let requests = table(clock)

        let reply = await requests.request(timeout: 2) { _ in clock.advance(by: 2) }

        #expect(reply == .timedOut)
        #expect(requests.pendingCount == 0)
    }

    @Test func anAwaitedRequestSeesAnInterruption() async {
        let clock = FakeClock()
        let requests = table(clock)

        let reply = await requests.request { _ in requests.interruptAll() }

        #expect(reply == .interrupted)
    }

    @Test func repliesAndTimeoutsRacingOnManyThreadsStillEndEveryRequestOnce() async throws {
        // Even requests are answered from many threads at about the moment their 2 ms timeout runs out; odd ones are never
        // answered, so they always time out.
        let requests = CefRemoteRequests<Int>(defaultTimeout: 0.002)
        let counts = OSAllocatedUnfairLock(initialState: [Int: Int]())
        let ids = (0..<300).map { index in
            requests.begin { _ in counts.withLock { $0[index, default: 0] += 1 } }
        }

        answerEvenRequestsConcurrently(requests, ids: ids)
        // Real timers on a loaded machine: wait for the table to drain and every completion to have run (a request leaves the
        // table just before its completion runs), with a generous deadline, then assert.
        let deadline = ContinuousClock.now + .seconds(5)
        while requests.pendingCount > 0 || counts.withLock({ $0.count }) < ids.count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(requests.pendingCount == 0)
        let result = counts.withLock { $0 }
        #expect(result.count == ids.count)
        #expect(result.values.allSatisfy { $0 == 1 })
    }

    // MARK: - Linger

    private func linger(_ clock: FakeClock, seconds: TimeInterval = 10, exits: Tally<CefRemoteLinger.Reason>) -> CefRemoteLinger {
        CefRemoteLinger(seconds: seconds, schedule: clock.schedule, onExit: { exits.add($0) })
    }

    @Test func theLingerIsSixtySecondsUnlessToldOtherwiseAndNeverUnderOne() {
        let clock = FakeClock()
        let exits = Tally<CefRemoteLinger.Reason>()
        let plain = CefRemoteLinger(schedule: clock.schedule, onExit: { exits.add($0) })
        #expect(plain.seconds == 60)
        plain.setSeconds(0.1)
        #expect(plain.seconds == 1)
        plain.setSeconds(25)
        #expect(plain.seconds == 25)
    }

    @Test func aServiceWithNoBrowserLeavesWhenTheLingerEnds() {
        let clock = FakeClock()
        let exits = Tally<CefRemoteLinger.Reason>()
        let linger = linger(clock, seconds: 10, exits: exits)
        linger.start()

        clock.advance(by: 9.9)
        #expect(exits.count == 0)
        clock.advance(by: 0.1)
        #expect(exits.all == [.lingerOver])
        #expect(linger.hasExited)
        clock.advance(by: 100)
        #expect(exits.count == 1)
    }

    @Test func aNewBrowserCancelsTheLingerAndTheLastOneToCloseStartsItAgain() {
        let clock = FakeClock()
        let exits = Tally<CefRemoteLinger.Reason>()
        let linger = linger(clock, seconds: 10, exits: exits)
        linger.start()

        clock.advance(by: 5)
        linger.browserCountChanged(1)
        #expect(clock.activeTimers == 0)
        clock.advance(by: 100)
        #expect(exits.count == 0)

        linger.browserCountChanged(2)
        linger.browserCountChanged(1)
        clock.advance(by: 100)
        #expect(exits.count == 0)

        linger.browserCountChanged(0)
        clock.advance(by: 9.9)
        #expect(exits.count == 0)
        clock.advance(by: 0.1)
        #expect(exits.all == [.lingerOver])
    }

    @Test func aTimerThatAlreadyFiredWhileABrowserOpenedDoesNotTakeTheServiceDown() {
        let fires = Tally<@Sendable () -> Void>()
        let exits = Tally<CefRemoteLinger.Reason>()
        // A scheduler whose cancel does nothing: the timer's closure still runs later, as a timer already firing would.
        let linger = CefRemoteLinger(seconds: 10, schedule: { _, fire in
            fires.add(fire)
            return {}
        }, onExit: { exits.add($0) })
        linger.start()
        linger.browserCountChanged(1)

        fires.all.forEach { $0() }

        #expect(exits.count == 0)
        #expect(!linger.hasExited)
    }

    @Test func aTimerOfAnEarlierWaitDoesNotEndALaterOne() {
        let fires = Tally<@Sendable () -> Void>()
        let exits = Tally<CefRemoteLinger.Reason>()
        // A scheduler whose cancel does nothing: a cancelled timer may still fire.
        let linger = CefRemoteLinger(seconds: 10, schedule: { _, fire in
            fires.add(fire)
            return {}
        }, onExit: { exits.add($0) })
        linger.start()  // wait A
        linger.browserCountChanged(1)  // A is cancelled
        linger.browserCountChanged(0)  // wait B
        #expect(fires.count == 2)

        fires.all[0]()  // A fires late: not B's linger.
        #expect(exits.count == 0)
        #expect(!linger.hasExited)

        fires.all[1]()
        #expect(exits.all == [.lingerOver])
    }

    @Test func aTimerIsCancelledOutsideTheLock() {
        // This cancel asks the linger something. os_unfair_lock aborts on a recursive lock, so the test passes only when
        // `browserCountChanged` and the exits call cancel with the lock released.
        let linger = OSAllocatedUnfairLock<CefRemoteLinger?>(initialState: nil)
        let asked = Tally<Void>()
        let exits = Tally<CefRemoteLinger.Reason>()
        let made = CefRemoteLinger(seconds: 10, schedule: { _, _ in
            { _ = linger.withLock { $0 }?.hasExited; asked.add(()) }
        }, onExit: { exits.add($0) })
        linger.withLock { $0 = made }

        made.start()
        made.browserCountChanged(1)  // cancels the wait
        made.browserCountChanged(0)
        made.memoryPressureChanged(isUnder: true)  // exits, cancelling the second wait

        #expect(asked.count == 2)
        #expect(exits.all == [.memoryPressure])
    }

    @Test func aHelloMayShortenTheLingerBeforeItStarts() {
        let clock = FakeClock()
        let exits = Tally<CefRemoteLinger.Reason>()
        let linger = linger(clock, seconds: 60, exits: exits)
        linger.setSeconds(1)
        linger.start()

        clock.advance(by: 1)
        #expect(exits.all == [.lingerOver])
    }

    @Test func memoryPressureEndsTheWaitAtOnceWhenNoBrowserIsOpen() {
        let clock = FakeClock()
        let exits = Tally<CefRemoteLinger.Reason>()
        let linger = linger(clock, seconds: 10, exits: exits)
        linger.start()

        linger.memoryPressureChanged(isUnder: true)

        #expect(exits.all == [.memoryPressure])
        #expect(clock.activeTimers == 0)
        clock.advance(by: 100)
        linger.memoryPressureChanged(isUnder: true)
        #expect(exits.count == 1)
    }

    @Test func memoryPressureLeavesABusyServiceAloneButItLeavesAtOnceWhenTheLastBrowserCloses() {
        let clock = FakeClock()
        let exits = Tally<CefRemoteLinger.Reason>()
        let linger = linger(clock, seconds: 10, exits: exits)
        linger.start()
        linger.browserCountChanged(1)

        linger.memoryPressureChanged(isUnder: true)
        #expect(exits.count == 0)
        linger.browserCountChanged(0)

        #expect(exits.all == [.memoryPressure])
        #expect(clock.activeTimers == 0)
    }

    @Test func pressureThatPassedBeforeTheLastBrowserClosedLeavesTheNormalLinger() {
        let clock = FakeClock()
        let exits = Tally<CefRemoteLinger.Reason>()
        let linger = linger(clock, seconds: 10, exits: exits)
        linger.start()
        linger.browserCountChanged(1)
        linger.memoryPressureChanged(isUnder: true)
        linger.memoryPressureChanged(isUnder: false)

        linger.browserCountChanged(0)
        #expect(exits.count == 0)
        clock.advance(by: 10)
        #expect(exits.all == [.lingerOver])
    }

    // MARK: - Relaunch and the crash loop

    @Test func theFirstDeathsRelaunchAndTheThirdWithinThirtySecondsIsACrashLoop() {
        var policy = CefRemoteRelaunchPolicy()

        #expect(policy.recordDeath(at: 100) == .relaunch)
        #expect(policy.recordDeath(at: 110) == .relaunch)
        #expect(!policy.isCrashLooping)
        #expect(policy.recordDeath(at: 120) == .crashLooping)
        #expect(policy.isCrashLooping)
    }

    @Test func theCapIsExactlyThreeDeathsInThirtySeconds() {
        let policy = CefRemoteRelaunchPolicy()
        #expect(policy.maxDeaths == 3)
        #expect(policy.window == 30)

        var twoOnly = policy
        #expect(twoOnly.recordDeath(at: 0) == .relaunch)
        #expect(twoOnly.recordDeath(at: 29) == .relaunch)

        var three = policy
        _ = three.recordDeath(at: 0)
        _ = three.recordDeath(at: 1)
        #expect(three.recordDeath(at: 2) == .crashLooping)
    }

    @Test func aDeathAfterTheWindowRelaunchesBecauseTheOldOnesNoLongerCount() {
        var policy = CefRemoteRelaunchPolicy()
        _ = policy.recordDeath(at: 0)
        _ = policy.recordDeath(at: 10)

        #expect(policy.recordDeath(at: 35) == .relaunch)
        #expect(policy.recentDeaths == [10, 35])
        #expect(!policy.isCrashLooping)
    }

    @Test func aDeathExactlyThirtySecondsAfterTheFirstIsOutsideTheWindow() {
        var policy = CefRemoteRelaunchPolicy()
        _ = policy.recordDeath(at: 0)
        _ = policy.recordDeath(at: 10)
        #expect(policy.recordDeath(at: 30) == .relaunch)

        var inside = CefRemoteRelaunchPolicy()
        _ = inside.recordDeath(at: 0)
        _ = inside.recordDeath(at: 10)
        #expect(inside.recordDeath(at: 29.9) == .crashLooping)
    }

    @Test func aCrashLoopStaysOneEvenWhenLaterDeathsComeFarApartUntilThePersonReloads() {
        var policy = CefRemoteRelaunchPolicy()
        _ = policy.recordDeath(at: 0)
        _ = policy.recordDeath(at: 1)
        #expect(policy.recordDeath(at: 2) == .crashLooping)

        #expect(policy.recordDeath(at: 500) == .crashLooping)

        policy.userReload()
        #expect(!policy.isCrashLooping)
        #expect(policy.recentDeaths.isEmpty)
        #expect(policy.recordDeath(at: 501) == .relaunch)
    }

    @Test func aReloadStartsTheCountOver() {
        var policy = CefRemoteRelaunchPolicy()
        _ = policy.recordDeath(at: 0)
        _ = policy.recordDeath(at: 1)
        policy.userReload()

        #expect(policy.recordDeath(at: 2) == .relaunch)
        #expect(policy.recordDeath(at: 3) == .relaunch)
        #expect(policy.recordDeath(at: 4) == .crashLooping)
    }

    @Test func anEndWithNoBrowserAndNoRequestIsAnIdleExitNotADeath() {
        var policy = CefRemoteRelaunchPolicy()

        for second in 0..<10 {
            #expect(policy.recordDeath(at: TimeInterval(second), serviceWasInUse: false) == .idleExit)
        }
        #expect(policy.recentDeaths.isEmpty)
        #expect(!policy.isCrashLooping)
        // Idle exits did not count: the first real deaths still relaunch.
        #expect(policy.recordDeath(at: 11) == .relaunch)
        #expect(policy.recordDeath(at: 12) == .relaunch)
        // And one during a crash loop neither relaunches nor clears it.
        #expect(policy.recordDeath(at: 13) == .crashLooping)
        #expect(policy.recordDeath(at: 14, serviceWasInUse: false) == .idleExit)
        #expect(policy.isCrashLooping)
        #expect(policy.recentDeaths == [11, 12, 13])
    }

    @Test func theCapAndTheWindowAreParameters() {
        var strict = CefRemoteRelaunchPolicy(maxDeaths: 2, window: 5)
        #expect(strict.recordDeath(at: 0) == .relaunch)
        #expect(strict.recordDeath(at: 4) == .crashLooping)

        var slow = CefRemoteRelaunchPolicy(maxDeaths: 2, window: 5)
        _ = slow.recordDeath(at: 0)
        #expect(slow.recordDeath(at: 5) == .relaunch)
    }
}
