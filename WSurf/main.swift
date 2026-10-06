// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import CCefAppKit

if CommandLine.arguments.contains("--mcp") {
    let socketOption = CommandLine.arguments.firstIndex(of: "--mcp-socket")
    let socketPath = socketOption.flatMap { index in
        CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : nil
    }
    LocalMCPEndpoint.runStdioRelay(socketPath: socketPath ?? LocalMCPEndpoint.path)
}

// Install CEF's lightweight AppKit subclass without loading Chromium.
CEFApplication.install()

UserDefaults.standard.set("WhenScrolling", forKey: "AppleShowScrollBars")

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
