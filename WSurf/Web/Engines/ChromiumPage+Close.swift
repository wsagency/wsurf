// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CCef
import Foundation
import os

extension ChromiumPage {
    /// How long `close()` waits for CEF's `on_before_close` before it asks once more and lets the page go without the answer.
    static let closeTimeout: Duration = .seconds(5)

    private static let closeLog = Logger(subsystem: "io.wsagency.wsurf", category: "chromium")

    /// `timingOut`: the first request, which `closeTimeout` bounds.
    func requestBrowserClose(timingOut: Bool = false) {
        if timingOut {
            closeUnanswered(after: Self.closeTimeout)
        }
        withHost { $0.pointee.close_browser?($0, 1) }
    }

    /// CEF's `on_before_close`.
    func browserDidClose() {
        guard !dropsCloseAnswerForTesting else { return }
        didClose()
    }

    /// A close CEF has not answered in `timeout` would hold the tab's retirement, and with it the page, forever. Asks CEF once
    /// more, then ends the page on this side: the browser reference is released and every waiter resumes. A late
    /// `on_before_close` finds the page closed and its client gone, and changes nothing.
    private func closeUnanswered(after timeout: Duration) {
        let clock = closeClock
        Task { [weak self] in
            try? await clock.sleep(for: timeout)
            guard let self, !isClosed else { return }
            Self.closeLog.error("CEF did not confirm a browser close in time; releasing the page without it")
            requestBrowserClose()
            didClose()
        }
    }
}
