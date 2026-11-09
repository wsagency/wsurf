// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import Testing

/// Waits for a condition instead of for a number of ticks.
///
/// A loop of `n` sleeps spends the same time whatever the machine is doing, so
/// its budget has to cover the slowest run: a release job builds an archive in
/// the same job as the tests, and a count that passes on a quiet Mac runs out
/// there. This returns as soon as the condition holds, which makes a generous
/// timeout free on a quiet machine.
///
/// A wait that runs out never fails the test by itself (negative waits expire on
/// purpose), but it prints one `WAIT-EXPIRED <file>:<line> after <timeout> in <test>`
/// line (`-` outside a Swift Testing case), so a wait whose result is discarded and
/// always runs to its deadline shows up in the run's output instead of silently
/// costing its whole timeout.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(25),
    tick: Duration = .milliseconds(20),
    file: StaticString = #fileID,
    line: UInt = #line,
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        guard !Task.isCancelled else { return false }
        if try await condition() {
            return true
        }
        do {
            try await Task.sleep(for: tick)
        } catch {
            return false
        }
    }
    guard !Task.isCancelled else { return false }
    if try await condition() {
        return true
    }
    print("WAIT-EXPIRED \(file):\(line) after \(timeout) in \(Test.current?.name ?? "-")")
    return false
}
