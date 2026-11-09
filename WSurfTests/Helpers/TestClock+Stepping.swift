// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension TestClock {
    /// Lets every task that is ready run to its next suspension, which is where a `sleep` on this clock registers its deadline
    /// and where a woken one re-arms itself. A task started on the main actor runs before this one resumes from `yield`.
    @MainActor
    func letTasksRun() async {
        for _ in 0..<4 {
            await Task.yield()
        }
    }

    /// Moves time forward by `total` in steps of `step`, letting the tasks that wake run and re-arm between the steps, as they
    /// would as the time passed. One big `advance` would wake each sleeper once and put every deadline after the jump.
    @MainActor
    func run(for total: Duration, step: Duration = .milliseconds(10)) async {
        await letTasksRun()
        var left = total
        while left > .zero {
            let now = min(step, left)
            advance(by: now)
            left -= now
            await letTasksRun()
        }
    }

    /// Moves time forward in steps until `condition` holds, and returns whether it did within `limit` of this clock's time.
    @MainActor
    func run(
        upTo limit: Duration = .seconds(5), step: Duration = .milliseconds(10), until condition: @MainActor () -> Bool
    ) async -> Bool {
        await letTasksRun()
        var spent = Duration.zero
        while !condition() {
            guard spent < limit else { return false }
            advance(by: step)
            spent += step
            await letTasksRun()
        }
        return true
    }
}
