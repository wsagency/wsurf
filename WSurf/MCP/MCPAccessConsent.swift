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
    }

    struct Page: Equatable, Sendable {
        let id: UUID
        let title: String
        let url: URL
    }

    /// The access sheet as data: its text and its buttons in display order. Built apart from presenting it so the order and the
    /// meaning of each button can be checked without a window.
    struct Sheet: Equatable {
        struct Button: Equatable {
            let title: String
            /// The access this button grants; nil declines.
            let access: Access?
            /// Escape presses this button.
            let isEscape: Bool
        }

        let title: String
        let message: String
        let buttons: [Button]

        /// The access chosen by the `index`th button (0 is the first button added); nil for a decline or an unknown button.
        func access(forButton index: Int) -> Access? {
            buttons.indices.contains(index) ? buttons[index].access : nil
        }
    }

    static func sheet(client: String, pages: [Page], development: Bool) -> Sheet {
        let name = displayName(for: client)
        guard !pages.isEmpty else {
            return Sheet(
                title: String(localized: "No Tab Available to Share"),
                message: String(localized: "Open a webpage in WSurf, then ask \(name) to try again."),
                buttons: [.init(title: String(localized: "OK"), access: nil, isEscape: false)])
        }
        let names = pages.map { page in
            let title = page.title.count > 80 ? String(page.title.prefix(80)) + "…" : page.title
            return "\(title)\n\(page.url.host() ?? "")"
        }.joined(separator: "\n\n")
        let tabLabel = pages.count == 1
            ? String(localized: "Tab to share:")
            : String(localized: "Tabs to share:")
        var message = String(localized: """
            \(tabLabel)
            \(names)

            Choose access:
            • Read Only: read page content.
            • Allow Control: also click, type, and navigate.
            """)
        var buttons: [Sheet.Button] = [
            .init(title: String(localized: "Read Only"), access: .readOnly, isEscape: false),
            .init(title: String(localized: "Allow Control"), access: .control, isEscape: false),
        ]
        if development {
            message += "\n" + String(localized: """
                • Allow Development: also inspect page structure and styles, read console and network metadata, and change the viewport. \
                These can disclose additional private site data, including text a page writes to its console.
                """)
            buttons.append(.init(title: String(localized: "Allow Development"), access: .development, isEscape: false))
        }
        buttons.append(.init(title: String(localized: "Don’t Allow"), access: nil, isEscape: true))
        return Sheet(
            title: pages.count == 1
                ? String(localized: "Allow \(name) to Access This Tab?")
                : String(localized: "Allow \(name) to Access These Tabs?"),
            message: message, buttons: buttons)
    }

    static func share(client: String, pages: [Page], development: Bool = false, in window: NSWindow?) async -> Access? {
        guard !AppDatabase.isRunningTests, window != nil else { return nil }
        let sheet = sheet(client: client, pages: pages, development: development)
        let alert = NSAlert()
        alert.messageText = sheet.title
        alert.informativeText = sheet.message
        for button in sheet.buttons {
            alert.addButton(withTitle: button.title)
            if button.isEscape {
                alert.buttons.last?.keyEquivalent = "\u{1b}"
            }
        }
        let response = await present(alert, in: window)
        return sheet.access(forButton: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
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
