// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Observation

/// Counts the changes to what `read` observes: every one of them, not only the first after the setup, since
/// `withObservationTracking` reports one change and stops.
@MainActor
final class ChangeCounter {
    private(set) var count = 0
    private let read: () -> Void

    init(watching read: @escaping () -> Void) {
        self.read = read
        arm()
    }

    private func arm() {
        withObservationTracking(read, onChange: { [weak self] in
            // Runs where the change is made, before it lands: the main actor, for a main-actor model.
            MainActor.assumeIsolated {
                self?.count += 1
                self?.arm()
            }
        })
    }
}
