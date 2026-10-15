// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

@MainActor
struct TabSleepTimerTests {
    /// Lets every main-actor continuation that is already queued run first.
    private func drain() async {
        await Task {}.value
    }

    @Test func aNewTimerHasNoTaskUntilStarted() {
        let timer = TabSleepTimer()
        #expect(!timer.isRunning)
        timer.stop()
        #expect(!timer.isRunning)
    }

    @Test func tickingRepeatsUntilStopped() async {
        let clock = TestClock()
        let timer = TabSleepTimer(clock: clock)
        var ticks = 0
        timer.start(every: .seconds(60)) { ticks += 1 }
        #expect(timer.isRunning)

        for expected in 1...3 {
            #expect(await waitUntil { clock.pendingCount == 1 })
            clock.advance(by: .seconds(60))
            #expect(await waitUntil { ticks == expected })
        }

        timer.stop()
        #expect(!timer.isRunning)
        await drain()
        #expect(clock.pendingCount == 0)
        #expect(ticks == 3)
    }

    @Test func aSleepThatFinishedBeforeStopDoesNotTick() async {
        let clock = TestClock()
        let timer = TabSleepTimer(clock: clock)
        var ticks = 0
        timer.start(every: .seconds(60)) { ticks += 1 }
        #expect(await waitUntil { clock.pendingCount == 1 })

        // The sleep is released, then stopped before the task gets to run again.
        clock.advance(by: .seconds(60))
        timer.stop()
        await drain()
        #expect(ticks == 0)
        #expect(clock.pendingCount == 0)
    }

    @Test func aSleepThatFinishedBeforeARestartDoesNotTickTheOldPolicy() async {
        let clock = TestClock()
        let timer = TabSleepTimer(clock: clock)
        var old = 0
        var new = 0
        timer.start(every: .seconds(60)) { old += 1 }
        #expect(await waitUntil { clock.pendingCount == 1 })

        clock.advance(by: .seconds(60))
        timer.start(every: .seconds(60)) { new += 1 }
        await drain()
        #expect(old == 0)

        #expect(await waitUntil { clock.pendingCount == 1 })
        clock.advance(by: .seconds(60))
        #expect(await waitUntil { new == 1 })
        #expect(old == 0)
        timer.stop()
    }
}
