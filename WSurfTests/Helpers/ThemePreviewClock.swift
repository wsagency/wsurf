// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

@testable import WSurf

extension BrowserSettings {
    /// Makes every preview step reach the window, as if each came a second after the last. A theme preview otherwise
    /// applies to the window at most every `themePreviewInterval`, which a tight loop of steps would not wait for.
    /// Returns a closure that undoes it.
    @MainActor
    @discardableResult
    func previewsEveryStep() -> () -> Void {
        let saved = globalSettings.themeApplyClock
        var now = ContinuousClock.now
        globalSettings.themeApplyClock = {
            now = now.advanced(by: .seconds(1))
            return now
        }
        return { [weak self] in self?.globalSettings.themeApplyClock = saved }
    }
}
