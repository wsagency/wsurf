// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import CCefAppKit

if CommandLine.arguments.contains("--mcp") {
    let socketOption = CommandLine.arguments.firstIndex(of: "--mcp-socket")
    let socketPath = socketOption.flatMap { index in
        CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
    }
    switch MCPToolCatalog.Profile.parse(CommandLine.arguments) {
    case .success(let profile):
        LocalMCPEndpoint.runStdioRelay(socketPath: socketPath ?? LocalMCPEndpoint.path, profile: profile ?? .all)
    case .failure:
        FileHandle.standardError.write(Data("WSurf: --tools must be core, playwright, or all.\n".utf8))
        exit(EXIT_FAILURE)
    }
}

// Install CEF's lightweight AppKit subclass without loading Chromium.
CEFApplication.install()

if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
    UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
