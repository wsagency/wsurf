// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import XCTest

@testable import WSurf

// A pass over twenty watches that are all due, each page changed since the last pass, with the reading and the model injected.
// The bound is far above what a healthy build takes and far below what a pass costs when it writes or reads pages itself.
nonisolated final class PageWatchPerformanceTests: XCTestCase, @unchecked Sendable {
    @MainActor
    private final class Pass {
        var date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var number = 0
        var fetched = 0
        var judged = 0
        var notified = 0
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
                judge: { _, _ in
                    pass.judged += 1
                    return PageWatchVerdict(met: false, state: "ok", message: "")
                },
                classify: { _, _ in nil },
                notify: { _, _ in pass.notified += 1 }
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

        // What a pass does, counted instead of timed (its time, 2 ms, is noise): one read and one judgement per due watch, no
        // notification, and at most three writes to the list of watches per watch (a pass makes exactly three today).
        let changes = MainActor.assumeIsolated { ChangeCounter { _ = center.watches } }
        let options = XCTMeasureOptions.budgeted
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            let before = MainActor.assumeIsolated {
                pass.number += 1
                pass.date += 3_600
                return (fetched: pass.fetched, judged: pass.judged, notified: pass.notified, changes: changes.count)
            }
            finish { await center.checkDue() }
            MainActor.assumeIsolated {
                XCTAssertEqual(pass.fetched - before.fetched, PageWatch.limit, "one read per due watch")
                XCTAssertEqual(pass.judged - before.judged, PageWatch.limit, "one judgement per due watch")
                XCTAssertEqual(pass.notified - before.notified, 0, "nothing met, so nothing to say")
                XCTAssertLessThanOrEqual(
                    changes.count - before.changes, 3 * PageWatch.limit, "a few writes to the list of watches per watch, as before")
            }
        }
    }
}
