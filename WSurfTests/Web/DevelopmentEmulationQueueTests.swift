// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct DevelopmentEmulationQueueTests {
    /// The old lease's cleanup is requested and the new lease's apply follows with no suspension between them (a release
    /// then an acquire on the main actor): the cleanup must still run first, however long it takes.
    @Test func cleanupRequestedJustBeforeANewApplyRunsFirstWithoutAnyYield() async {
        let queue = DevelopmentEmulationQueue()
        var log: [String] = []
        queue.enqueue { log.append("old apply start"); try? await Task.sleep(for: .milliseconds(20)); log.append("old apply end") }
        let cleanup = queue.enqueue { try? await Task.sleep(for: .milliseconds(30)); log.append("old cleanup") }
        let apply = queue.enqueue { log.append("new apply") }
        await cleanup.value
        await apply.value
        #expect(log == ["old apply start", "old apply end", "old cleanup", "new apply"])
    }

    @Test func aCancelledCallerDoesNotAbandonQueuedWork() async {
        let queue = DevelopmentEmulationQueue()
        var log: [String] = []
        let caller = Task { await queue.enqueue { try? await Task.sleep(for: .milliseconds(20)); log.append("applied") }.value }
        await Task.yield()
        caller.cancel()
        await caller.value
        await queue.enqueue { log.append("next") }.value
        #expect(log == ["applied", "next"])
    }

    @Test func anIdleQueueRunsImmediatelyAndReturnsTheResult() async {
        let queue = DevelopmentEmulationQueue()
        #expect(await queue.enqueue { 7 }.value == 7)
        #expect(await queue.enqueue { 8 }.value == 8)
    }
}
