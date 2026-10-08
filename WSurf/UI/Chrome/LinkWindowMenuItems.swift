// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct LinkWindowMenuItems: View {
    let isPrivate: Bool
    let onOpen: (_ isPrivate: Bool) -> Void

    var body: some View {
        if isPrivate {
            Button("Open Link in New Private Window") { onOpen(true) }
        } else {
            Button("Open Link in New Window") { onOpen(false) }
                .modifierKeyAlternate(.option) {
                    Button("Open Link in New Private Window") { onOpen(true) }
                }
        }
    }
}
