// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One repeating tick for the window's idle-tab sweep. It exists only while a duration is set: no task, and so no
/// wake-up, while Sleep inactive tabs is off or waits for memory pressure alone.
@MainActor
final class TabSleepTimer {
    private let clock: any Clock<Duration>
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        task != nil
    }

    /// The default clock is `ContinuousClock`, which keeps counting while the Mac sleeps, so the first tick after a wake
    /// sees the whole time away.
    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    func start(every interval: Duration, _ tick: @escaping @MainActor () -> Void) {
        stop()
        let clock = clock
        task = Task {
            while true {
                do {
                    try await clock.sleep(for: interval)
                } catch {
                    return
                }
                // A sleep that finished just before stop() or a restart still resumes; it must not tick an old policy.
                guard !Task.isCancelled else { return }
                tick()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    isolated deinit {
        task?.cancel()
    }
}
