// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import CoreGraphics

enum SidebarDropBand: Equatable {
    case before
    case after
}

enum SidebarDropGeometry {
    static func band(y: CGFloat, in frame: CGRect) -> SidebarDropBand {
        y < frame.midY ? .before : .after
    }
}
