// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension ChromiumPage {
    func didChangeProgress(_ progress: Double) {
        owner?.estimatedProgress = progress
    }

    func didHoverLink(_ url: URL?) {
        owner?.onLinkHovered?(url)
    }
    func didChangeFullscreen(_ enabled: Bool) {
        owner?.isFullscreen = enabled
    }
}
