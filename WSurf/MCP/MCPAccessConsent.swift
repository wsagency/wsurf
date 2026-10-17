// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

@MainActor
enum MCPAccessConsent {
    enum Access: Sendable {
        case readOnly
        case control
        /// Control plus DOM inspection, console and network metadata, viewport and device emulation.
        case development
        /// Development, and no confirmation before consequential actions. Only a paired app on a developer site in the
        /// Developer profile can hold it.
        case developer
    }

    struct Page: Equatable, Sendable {
        let id: UUID
        let title: String
        let url: URL
        /// Whether this page qualifies for Allow Developer: a paired app asked for it on a developer site in the
        /// Developer profile. The sheet offers the choice only when at least one page qualifies.
        var developerEligible = false
    }

    static func share(client: String, pages: [Page], development: Bool = false, in window: NSWindow?) async -> Access? {
        guard !AppDatabase.isRunningTests, window != nil else { return nil }
        let alert = NSAlert()
        let name = displayName(for: client)
        alert.messageText = pages.count == 1
            ? String(localized: "Allow \(name) to Access This Tab?")
            : String(localized: "Allow \(name) to Access These Tabs?")
        guard !pages.isEmpty else {
            alert.messageText = String(localized: "No Tab Available to Share")
            alert.informativeText = String(localized: "Open a webpage in WSurf, then ask \(name) to try again.")
            alert.addButton(withTitle: String(localized: "OK"))
            _ = await present(alert, in: window)
            return nil
        }
        let names = pages.map { page in
            let title = page.title.count > 80 ? String(page.title.prefix(80)) + "…" : page.title
            return "\(title)\n\(page.url.host() ?? "")"
        }.joined(separator: "\n\n")
        let tabLabel = pages.count == 1
            ? String(localized: "Tab to share:")
            : String(localized: "Tabs to share:")
        alert.informativeText = String(localized: """
            \(tabLabel)
            \(names)

            Choose access:
            • Read Only: read page content.
            • Allow Control: also click, type, and navigate.
            """)
        alert.addButton(withTitle: String(localized: "Read Only"))
        alert.addButton(withTitle: String(localized: "Allow Control"))
        var choices: [Access?] = [.readOnly, .control]
        if development {
            alert.informativeText += "\n" + String(localized: """
                • Allow Development: also inspect page structure and styles, read console and network metadata, and change the viewport. \
                These can disclose additional private site data, including text a page writes to its console.
                """)
            alert.addButton(withTitle: String(localized: "Allow Development"))
            choices.append(.development)
            if pages.contains(where: \.developerEligible) {
                alert.informativeText += "\n" + String(localized: """
                    • Allow Developer: also acts without asking before purchases, sending, and deleting. \
                    Only on developer sites in your Developer profile.
                    """)
                alert.addButton(withTitle: String(localized: "Allow Developer"))
                choices.append(.developer)
            }
        }
        alert.addButton(withTitle: String(localized: "Don’t Allow"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        let response = await present(alert, in: window)
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : nil
    }

    static func open(client: String, url: URL, in window: NSWindow?) async -> Bool {
        guard !AppDatabase.isRunningTests, window != nil else { return false }
        let alert = NSAlert()
        let name = displayName(for: client)
        alert.messageText = String(localized: "Open and Share This Website?")
        alert.informativeText = String(localized: """
            \(name) wants to open \(url.absoluteString).

            It will be able to read the page, click, type, and navigate.
            """)
        alert.addButton(withTitle: String(localized: "Open and Share"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return await present(alert, in: window) == .alertFirstButtonReturn
    }

    private static func displayName(for client: String) -> String {
        client == "codex-mcp-client" ? "Codex" : client
    }

    private static func present(_ alert: NSAlert, in window: NSWindow?) async -> NSApplication.ModalResponse {
        guard !Task.isCancelled, let window else { return .abort }
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return .abort }
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } onCancel: {
            Task { @MainActor in
                window.endSheet(alert.window, returnCode: .abort)
            }
        }
    }
}

@MainActor
final class MCPActionGrantStorage: AgentGrantStorage {
    var grantData: Data?
}
