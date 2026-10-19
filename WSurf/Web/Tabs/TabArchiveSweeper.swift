// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// Runs one window's archive sweep on a timer that exists only while the person chose a delay.
@MainActor
final class TabArchiveSweeper {
    static let interval: Duration = .seconds(10 * 60)

    private let timer: TabSleepTimer
    private var delay = TabArchiveDelay.never

    var isRunning: Bool {
        timer.isRunning
    }

    init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = TabSleepTimer(clock: clock)
    }

    /// A new delay sweeps once now and then every ten minutes; Never stops the timer. The same delay changes nothing,
    /// so re-applying the idle-tab policy does not sweep again. `sweep` reads the delay itself.
    func apply(_ delay: TabArchiveDelay, sweep: @escaping @MainActor () -> Void) {
        guard delay != self.delay else { return }
        self.delay = delay
        guard delay != .never else {
            timer.stop()
            return
        }
        sweep()
        timer.start(every: Self.interval, sweep)
    }

    func stop() {
        delay = .never
        timer.stop()
    }
}
