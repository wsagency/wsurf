// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct DevelopmentEmulationLockTests {
    /// An old lease's cleanup queued before a new lease's apply must finish first, however long it takes.
    @Test func cleanupQueuedBeforeANewApplyRunsFirst() async {
        let lock = DevelopmentEmulationLock()
        var log: [String] = []
        await lock.acquire()  // an in-flight apply of the old lease
        let cleanup = Task {
            await lock.acquire()
            defer { lock.release() }
            try? await Task.sleep(for: .milliseconds(30))
            log.append("old cleanup")
        }
        await Task.yield()
        let apply = Task {
            await lock.acquire()
            defer { lock.release() }
            log.append("new apply")
        }
        await Task.yield()
        log.append("old apply done")
        lock.release()
        await cleanup.value
        await apply.value
        #expect(log == ["old apply done", "old cleanup", "new apply"])
    }

    @Test func releasingAnUncontendedLockFreesIt() async {
        let lock = DevelopmentEmulationLock()
        await lock.acquire()
        lock.release()
        await lock.acquire()
        lock.release()
    }
}
