// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import XCTest

extension XCTMeasureOptions {
    /// Six iterations for every case that `Tools/check-performance.sh` holds to a budget. The gate drops the first sample of the
    /// memory metric as the warm-up (lazy setup and caches are paid there) and compares the median of the other five with the
    /// budget; the time metric stays on the mean of all six. Change the count only together with that rule.
    static var budgeted: XCTMeasureOptions {
        let options = XCTMeasureOptions()
        options.iterationCount = 6
        return options
    }
}
