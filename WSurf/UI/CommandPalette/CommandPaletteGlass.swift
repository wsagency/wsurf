// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import SwiftUI

struct CommandPaletteGlass: View {
    let referenceHeight: CGFloat

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .frame(width: geometry.size.width, height: max(referenceHeight, geometry.size.height))
                .chromeGlass(in: .rect(cornerRadius: Theme.Radius.panel, style: .continuous))
        }
        .clipShape(.rect(cornerRadius: Theme.Radius.panel, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
