// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension AppCoordinator {
    /// Whether any external app is connected to this window. The menu command and the palette entry follow it.
    var hasExternalConnections: Bool {
        !mcpServer.sessions(in: browser).isEmpty
    }

    /// Ends every external connection bound to this window. See `BrowserMCPServer.stop(window:)`.
    func stopExternalConnections() {
        mcpServer.stop(window: browser)
    }
}
