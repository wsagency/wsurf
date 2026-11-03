// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Observation

@MainActor
func waitForObservation(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    let (changes, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { continuation.finish() }
    var iterator = changes.makeAsyncIterator()
    while !Task.isCancelled {
        let satisfied = withObservationTracking {
            condition()
        } onChange: {
            continuation.yield(())
        }
        if satisfied {
            return true
        }
        guard await iterator.next() != nil else { return false }
    }
    return false
}
