// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

@MainActor
final class SerialTasks {
    private var last: Task<Void, Never>?

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = last
        let task = Task {
            await previous?.value
            await operation()
        }
        last = task
        await task.value
    }
}
