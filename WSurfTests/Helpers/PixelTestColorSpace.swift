// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit

extension NSColorSpace {
    /// The colour space of an unshown window whose pixels a test reads back. A window takes its screen's space by default,
    /// and on a display with a custom calibration profile (with an HDR monitor attached) Core Animation then drew sRGB 0.5
    /// grey as 0.57, in an sRGB or Display P3 window too. Device RGB keeps what was drawn: sRGB 0.5 reads back as 0.5.
    /// Set it before the window first draws.
    static let pixelTests = NSColorSpace.deviceRGB
}
