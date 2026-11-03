// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CCef
import Foundation
import Testing

@testable import CefKit
@testable import WSurf

/// Timers that only fire when a test says so. It records what the pump asked for, so a test can state which timers are alive.
@MainActor
private final class FakeTimers {
    final class Entry {
        let interval: TimeInterval
        let tolerance: TimeInterval
        let repeats: Bool
        let fire: @MainActor () -> Void
        var isActive = true

        init(interval: TimeInterval, tolerance: TimeInterval, repeats: Bool, fire: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.tolerance = tolerance
            self.repeats = repeats
            self.fire = fire
        }
    }

    private(set) var entries: [Entry] = []

    var active: [Entry] {
        entries.filter(\.isActive)
    }

    var periodic: [Entry] {
        active.filter(\.repeats)
    }

    var source: CefMessagePump.TimerSource {
        { [self] interval, tolerance, repeats, fire in
            let entry = Entry(interval: interval, tolerance: tolerance, repeats: repeats, fire: fire)
            entries.append(entry)
            return { entry.isActive = false }
        }
    }

    func oneShot(_ interval: TimeInterval) -> Entry? {
        active.first { !$0.repeats && $0.interval == interval }
    }

    func repeating(_ interval: TimeInterval) -> Entry? {
        active.first { $0.repeats && $0.interval == interval }
    }

    func fire(_ entry: Entry?) {
        guard let entry, entry.isActive else { return }
        if !entry.repeats {
            entry.isActive = false
        }
        entry.fire()
    }
}

/// A pump on fake timers whose message loop only counts its passes.
@MainActor
private final class PumpRig {
    let timers = FakeTimers()
    private(set) var passes = 0
    /// Runs inside the next message loop pass, as a nested loop would.
    var duringPass: (@MainActor () -> Void)?
    /// How long each pass takes on the rig's clock.
    var passDuration: TimeInterval = 0
    private var clock: TimeInterval = 0

    lazy var pump = CefMessagePump(timers: timers.source, runLoopWork: { [unowned self] in
        passes += 1
        clock += passDuration
        let nested = duringPass
        duringPass = nil
        nested?()
    }, now: { [unowned self] in clock })

    /// A pump that has started and settled: no browser, no timer.
    static func settled() -> PumpRig {
        let rig = PumpRig()
        rig.pump.start()
        rig.timers.fire(rig.timers.oneShot(CefMessagePump.settleInterval))
        return rig
    }
}

@MainActor
@Suite(.serialized)
struct CefMessagePumpTests {
    private typealias Pump = CefMessagePump

    // MARK: Idle

    @Test
    func idlePumpWithNoBrowserStopsEveryRepeatingTimer() {
        let rig = PumpRig()
        rig.pump.start()
        #expect(rig.pump.hasFallbackTimer)
        rig.timers.fire(rig.timers.oneShot(Pump.settleInterval))
        #expect(!rig.pump.hasFallbackTimer)
        #expect(rig.timers.periodic.isEmpty)
        #expect(rig.timers.active.isEmpty)
    }

    @Test
    func aLiveBrowserKeepsTheSafetyNetRunning() {
        let rig = PumpRig()
        rig.pump.start()
        rig.pump.browserDidOpen()
        #expect(rig.timers.oneShot(Pump.settleInterval) == nil)
        #expect(rig.timers.periodic.count == 1)
        #expect(rig.timers.periodic.first?.interval == Pump.fallbackInterval)
        #expect(rig.timers.periodic.first?.tolerance == Pump.fallbackTolerance)
    }

    @Test
    func theSafetyNetStopsOnceTheLastBrowserHasClosedAndSettled() {
        let rig = PumpRig()
        rig.pump.start()
        rig.pump.browserDidOpen()
        rig.pump.browserDidOpen()
        rig.pump.browserDidClose()
        #expect(rig.timers.oneShot(Pump.settleInterval) == nil, "one browser is still alive")
        rig.pump.browserDidClose()
        #expect(rig.pump.liveBrowserCount == 0)
        #expect(rig.pump.hasFallbackTimer, "the browser's teardown still has the safety net while it settles")
        rig.timers.fire(rig.timers.oneShot(Pump.settleInterval))
        #expect(rig.timers.active.isEmpty)
    }

    @Test
    func openingABrowserDuringSettlingCancelsTheStop() {
        let rig = PumpRig()
        rig.pump.start()
        rig.pump.browserDidOpen()
        rig.pump.browserDidClose()
        let settle = rig.timers.oneShot(Pump.settleInterval)
        rig.pump.browserDidOpen()
        #expect(settle?.isActive == false)
        #expect(rig.timers.periodic.count == 1)
    }

    @Test
    func openingABrowserRestartsTheSafetyNetAfterItStopped() {
        let rig = PumpRig.settled()
        #expect(rig.timers.periodic.isEmpty)
        rig.pump.browserDidOpen()
        #expect(rig.timers.periodic.count == 1)
        rig.pump.browserDidClose()
        rig.timers.fire(rig.timers.oneShot(Pump.settleInterval))
        #expect(rig.timers.active.isEmpty)
    }

    @Test
    func anUnmatchedCloseNeverCountsBelowZero() {
        let rig = PumpRig()
        rig.pump.start()
        rig.pump.browserDidClose()
        #expect(rig.pump.liveBrowserCount == 0)
        rig.pump.browserDidOpen()
        #expect(rig.pump.liveBrowserCount == 1)
    }

    @Test
    func theSafetyNetRunsTheLoopWithoutStartingABusyWindow() {
        let rig = PumpRig()
        rig.pump.start()
        rig.timers.fire(rig.timers.periodic.first)
        #expect(rig.passes == 1)
        #expect(rig.timers.periodic.count == 1, "a repeating timer stays alive after it fires")
        #expect(!rig.pump.isPollingBusy)
    }

    // MARK: Requests

    @Test
    func anImmediateRequestRunsTheLoopAtOnceAndPollsUntilTheWindowEnds() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: 0)
        #expect(rig.passes == 1)
        #expect(rig.pump.isPollingBusy)
        #expect(rig.timers.repeating(Pump.busyInterval) != nil)
        rig.timers.fire(rig.timers.repeating(Pump.busyInterval))
        #expect(rig.passes == 2)
        rig.timers.fire(rig.timers.oneShot(Pump.busyLingerWithoutBrowser))
        #expect(!rig.pump.isPollingBusy)
        #expect(rig.timers.active.isEmpty, "nothing repeats once the window has ended")
    }

    @Test
    func theBusyWindowOutlastsTheLastRequestLongerWithABrowser() {
        let rig = PumpRig()
        rig.pump.start()
        rig.pump.browserDidOpen()
        rig.pump.requestWork(delayMilliseconds: 0)
        #expect(rig.timers.oneShot(Pump.busyLingerWithBrowser) != nil)
        #expect(rig.timers.oneShot(Pump.busyLingerWithoutBrowser) == nil)
    }

    @Test
    func aLaterRequestExtendsTheBusyWindowAndKeepsOnePoll() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: 0)
        let firstEnd = rig.timers.oneShot(Pump.busyLingerWithoutBrowser)
        let poll = rig.timers.repeating(Pump.busyInterval)
        rig.pump.requestWork(delayMilliseconds: 0)
        #expect(firstEnd?.isActive == false)
        #expect(rig.timers.oneShot(Pump.busyLingerWithoutBrowser) != nil)
        #expect(rig.timers.periodic.count == 1)
        #expect(rig.timers.repeating(Pump.busyInterval) === poll)
    }

    @Test
    func thePollRunsTheLoopWithoutExtendingTheWindow() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: 0)
        let end = rig.timers.oneShot(Pump.busyLingerWithoutBrowser)
        rig.timers.fire(rig.timers.repeating(Pump.busyInterval))
        rig.timers.fire(rig.timers.repeating(Pump.busyInterval))
        #expect(rig.timers.oneShot(Pump.busyLingerWithoutBrowser) === end)
    }

    @Test
    func aDelayedRequestIsHonouredExactlyAndPollsOnlyOnceItIsDue() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: 250)
        #expect(rig.timers.active.count == 1)
        #expect(rig.timers.active.first?.interval == 0.25)
        #expect(rig.timers.active.first?.tolerance == 0)
        #expect(rig.passes == 0)
        #expect(!rig.pump.isPollingBusy)
        rig.timers.fire(rig.timers.oneShot(0.25))
        #expect(rig.passes == 1)
        #expect(rig.pump.isPollingBusy)
    }

    @Test
    func aDelayLongerThanAFrameIsNotShortened() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: 5_000)
        #expect(rig.timers.oneShot(5) != nil)
    }

    @Test
    func aNewDelayedRequestReplacesTheEarlierOne() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: 250)
        let first = rig.timers.oneShot(0.25)
        rig.pump.requestWork(delayMilliseconds: 500)
        #expect(first?.isActive == false)
        #expect(rig.timers.oneShot(0.5) != nil)
    }

    @Test
    func aHugeDelayIsCappedAtOneMinute() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: Int64.max)
        #expect(rig.timers.oneShot(Pump.longestRequestDelay) != nil)
    }

    @Test
    func anImmediateRequestLeavesAPendingDelayedRequestAlone() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: 250)
        let delayed = rig.timers.oneShot(0.25)
        rig.pump.requestWork(delayMilliseconds: 0)
        #expect(rig.passes == 1)
        #expect(delayed?.isActive == true, "CEF does not ask again for a wake it already asked for")
        rig.timers.fire(delayed)
        #expect(rig.passes == 2)
    }

    // MARK: Nested loops

    @Test
    func aRequestInsideARunningLoopIsRunAgainAfterItReturns() {
        let rig = PumpRig.settled()
        rig.duringPass = { rig.pump.requestWork(delayMilliseconds: 0) }
        rig.pump.performWork()
        #expect(rig.passes == 1, "the nested request cannot re-enter the loop")
        let replay = rig.timers.oneShot(0)
        #expect(replay != nil)
        rig.timers.fire(replay)
        #expect(rig.passes == 2)
        #expect(rig.timers.oneShot(0) == nil)
    }

    @Test
    func theRerunOfANestedRequestLeavesAPendingDelayedRequestAlone() {
        let rig = PumpRig.settled()
        rig.pump.requestWork(delayMilliseconds: 250)
        let delayed = rig.timers.oneShot(0.25)
        rig.duringPass = { rig.pump.requestWork(delayMilliseconds: 0) }
        rig.pump.performWork()
        #expect(delayed?.isActive == true)
        #expect(rig.timers.oneShot(0) != nil)
    }

    // MARK: Passes cut short

    @Test
    func aPassThatRanLongKeepsTheBusyPollGoingWithNoBrowser() {
        let rig = PumpRig.settled()
        rig.passDuration = 0.012
        rig.pump.requestWork(delayMilliseconds: 0)
        // CEF asks for nothing more after a pass it cut short; the pump keeps polling while passes do work.
        for _ in 0 ..< 10 {
            let end = rig.timers.oneShot(Pump.busyLingerWithoutBrowser)
            rig.timers.fire(rig.timers.repeating(Pump.busyInterval))
            #expect(end?.isActive == false, "a pass that ran long moves the end of the busy window")
            #expect(rig.pump.isPollingBusy)
        }
        #expect(rig.passes == 11)
        rig.passDuration = 0
        let end = rig.timers.oneShot(Pump.busyLingerWithoutBrowser)
        rig.timers.fire(rig.timers.repeating(Pump.busyInterval))
        #expect(end?.isActive == true, "an idle pass leaves the end where it was")
        rig.timers.fire(end)
        #expect(!rig.pump.isPollingBusy)
        #expect(rig.timers.active.isEmpty)
    }

    @Test
    func aSafetyNetPassThatRanLongStartsTheBusyPoll() {
        let rig = PumpRig()
        rig.pump.start()
        rig.pump.browserDidOpen()
        rig.timers.fire(rig.timers.repeating(Pump.fallbackInterval))
        #expect(!rig.pump.isPollingBusy, "an idle pass starts nothing")
        rig.passDuration = Pump.workingPassDuration
        rig.timers.fire(rig.timers.repeating(Pump.fallbackInterval))
        #expect(rig.pump.isPollingBusy)
        #expect(rig.timers.oneShot(Pump.busyLingerWithBrowser) != nil)
    }

    // MARK: Stopping

    @Test
    func aStoppedPumpIgnoresRequestsAndLeavesNoTimer() {
        let rig = PumpRig()
        rig.pump.start()
        rig.pump.browserDidOpen()
        rig.pump.requestWork(delayMilliseconds: 100)
        rig.pump.requestWork(delayMilliseconds: 0)
        rig.pump.stop()
        #expect(rig.timers.active.isEmpty)
        let passes = rig.passes
        rig.pump.requestWork(delayMilliseconds: 0)
        rig.pump.performWork()
        #expect(rig.passes == passes)
        #expect(rig.timers.active.isEmpty)
    }

    // MARK: Real CEF

    /// Posts `count` tasks to CEF's UI thread, each busy for `busy` (more than one pass of CEF's loop can run in all), and
    /// returns how many have run by `timeout`. Starts once the pump is quiet: no browser, no timer, if it gets there.
    private func runTasksOnCEFsUIThread(count: Int, busy: useconds_t, timeout: Duration, postedFromAPass: Bool = false) async throws
        -> (ran: Int, quiet: Bool, liveBrowsers: Int) {
        try ChromiumRuntime.shared.ensureInitialized()
        let pump = try #require(CefRuntime.shared.messagePump)
        let quietBy = ContinuousClock.now + .seconds(15)
        while pump.liveBrowserCount > 0 || pump.hasFallbackTimer || pump.isPollingBusy, ContinuousClock.now < quietBy {
            try await Task.sleep(for: .milliseconds(50))
        }
        let quiet = pump.liveBrowserCount == 0 && !pump.hasFallbackTimer && !pump.isPollingBusy
        let probe = UIThreadProbe(busy: busy)
        if postedFromAPass {
            // Posted by a task while CEF's loop runs, as Chromium's own work is.
            UIThreadProbe.post { (0 ..< count).forEach { _ in probe.post() } }
        } else {
            (0 ..< count).forEach { _ in probe.post() }
        }
        let deadline = ContinuousClock.now + timeout
        while probe.ran < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return (probe.ran, quiet, pump.liveBrowserCount)
    }

    @Test
    func uiThreadWorkLongerThanOnePassFinishesWithNoBrowserAlive() async throws {
        let result = try await runTasksOnCEFsUIThread(count: 40, busy: 5000, timeout: .seconds(5))
        #expect(result.ran == 40, "ran \(result.ran) of 40; quiet \(result.quiet), live browsers \(result.liveBrowsers)")
    }

    @Test
    func uiThreadWorkPostedInsideAPassFinishesWithNoBrowserAlive() async throws {
        let result = try await runTasksOnCEFsUIThread(count: 40, busy: 5000, timeout: .seconds(5), postedFromAPass: true)
        #expect(result.ran == 40, "ran \(result.ran) of 40; quiet \(result.quiet), live browsers \(result.liveBrowsers)")
    }
}

/// Counts tasks that ran on CEF's UI thread (the main thread, with CefKit's external pump).
private final class UIThreadProbe: @unchecked Sendable {
    let busy: useconds_t
    private(set) var ran = 0

    init(busy: useconds_t) {
        self.busy = busy
    }

    func post() {
        Self.post { [self] in
            usleep(busy)
            ran += 1
        }
    }

    private final class Job {
        let body: () -> Void
        init(_ body: @escaping () -> Void) {
            self.body = body
        }
    }

    static func post(_ body: @escaping () -> Void) {
        let task = ChromiumInterop.allocate(cef_task_t.self, owner: Job(body))
        task.pointee.execute = { taskSelf in
            ChromiumInterop.owner(Job.self, of: UnsafeMutableRawPointer(taskSelf))?.body()
        }
        // cef_post_task takes the reference `allocate` made.
        _ = cef_post_task(TID_UI, task)
    }
}
