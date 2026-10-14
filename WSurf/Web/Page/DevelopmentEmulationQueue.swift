// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// Runs a page's development emulation work (applying a viewport, cleaning one up) strictly one at a time in the order it was
/// requested. `enqueue` reserves its turn synchronously, before it returns, so a release followed straight away by a new lease's
/// apply (no suspension between them) still runs the cleanup first. The work runs in its own task: a cancelled caller does not
/// abandon half-applied emulation.
@MainActor
final class DevelopmentEmulationQueue {
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue<Result: Sendable>(_ work: @escaping @MainActor () async -> Result) -> Task<Result, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        tail = Task { @MainActor in _ = await task.value }
        return task
    }
}
