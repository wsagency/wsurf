// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation

@MainActor
enum MCPAccessConsent {
    enum Access: Sendable {
        case readOnly
        case control
        /// Control plus DOM inspection, console and network metadata, viewport and device emulation.
        case development
        /// Development, typing test secrets, and no confirmation before consequential actions. Only a paired app on a developer site in the
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
            if pages.contains(where: \.developerEligible) {
                message += "\n" + String(localized: """
                    • Allow Developer: also types test passwords it gives itself, and acts without asking before purchases, \
                    sending, and deleting. Only on developer sites in your Developer profile.
                    """)
                buttons.append(.init(title: String(localized: "Allow Developer"), access: .developer, isEscape: false))
            }
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

    /// The question for a page that shows a password or payment field, reached under the Website access default.
    static func useSensitivePage(client: String, url: URL, in window: NSWindow?) async -> Bool {
        guard !AppDatabase.isRunningTests, window != nil else { return false }
        let alert = NSAlert()
        let name = displayName(for: client)
        alert.messageText = String(localized: "Allow \(name) to Use This Page?")
        alert.informativeText = String(localized: """
            This page has a password or payment field. \(name) will be able to click, type, and navigate on \(url.host() ?? url.absoluteString). \
            Password and payment fields stay blocked.
            """)
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        return await present(alert, in: window) == .alertFirstButtonReturn
    }

    /// One saved Vault login presented in the `requestUserLogin` native approval sheet (never returned to MCP clients).
    struct LoginAccount: Equatable, Sendable {
        let id: UUID
        let label: String
    }

    /// The user's answer to a `requestUserLogin` sheet, carrying the exact account ID the user approved for fill.
    enum LoginChoice: Equatable, Sendable {
        case fill(accountID: UUID?)
        case fillAndSignIn(accountID: UUID?)
        case takeOver
        case decline
    }

    /// The login approval sheet as data, testable without presenting a window.
    struct LoginSheet: Equatable {
        enum Action: Equatable {
            case fill, fillAndSignIn, takeOver, decline
        }

        struct Button: Equatable {
            let title: String
            let action: Action
            let isEscape: Bool
        }

        let title: String
        let message: String
        let accounts: [LoginAccount]
        let showsAccountPicker: Bool
        let buttons: [Button]

        func choice(forButton index: Int, selectedAccountID: UUID? = nil) -> LoginChoice {
            guard buttons.indices.contains(index) else { return .decline }
            let resolvedID: UUID?
            if let selectedAccountID {
                resolvedID = accounts.contains(where: { $0.id == selectedAccountID }) ? selectedAccountID : nil
            } else if !showsAccountPicker, accounts.count == 1 {
                resolvedID = accounts[0].id
            } else {
                resolvedID = nil
            }
            switch buttons[index].action {
            case .fill:
                guard let resolvedID else { return .decline }
                return .fill(accountID: resolvedID)
            case .fillAndSignIn:
                guard let resolvedID else { return .decline }
                return .fillAndSignIn(accountID: resolvedID)
            case .takeOver:
                return .takeOver
            case .decline:
                return .decline
            }
        }
    }

    static func loginSheet(
        client: String, url: URL, accounts: [LoginAccount], allowsManualTakeOver: Bool = true, reason: String?
    ) -> LoginSheet {
        let name = displayName(for: client)
        let host = url.host() ?? url.absoluteString
        let hasSavedLogin = !accounts.isEmpty
        let cleanedReason: String? = reason.flatMap { raw in
            let stripped = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            let trimmed = String(stripped.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            return trimmed.isEmpty ? nil : trimmed
        }

        var parts: [String] = []
        if hasSavedLogin {
            parts.append(String(localized: "\(name) asked to sign in to \(host) using your saved WSurf Vault login. Passwords are never shown to \(name)."))
            if accounts.count == 1, !accounts[0].label.isEmpty {
                parts.append(String(localized: "Saved account: \(accounts[0].label)"))
            } else if accounts.count > 1 {
                parts.append(String(localized: "Choose a saved account to fill:"))
            }
        } else {
            parts.append(String(localized: "\(name) asked you to sign in to \(host). No saved WSurf Vault login is available for this website."))
        }
        if let cleanedReason {
            parts.append(String(localized: "Reason from \(name): \(cleanedReason)"))
        }

        var buttons: [LoginSheet.Button] = []
        if hasSavedLogin {
            buttons.append(.init(title: String(localized: "Fill"), action: .fill, isEscape: false))
            buttons.append(.init(title: String(localized: "Fill & Sign In"), action: .fillAndSignIn, isEscape: false))
        }
        if allowsManualTakeOver {
            buttons.append(.init(title: String(localized: "Sign In Myself"), action: .takeOver, isEscape: false))
        }
        buttons.append(.init(title: String(localized: "Cancel"), action: .decline, isEscape: true))

        return LoginSheet(
            title: hasSavedLogin
                ? String(localized: "Sign In to \(host)?")
                : String(localized: "Sign In Yourself on \(host)?"),
            message: parts.joined(separator: "\n\n"),
            accounts: accounts,
            showsAccountPicker: accounts.count > 1,
            buttons: buttons
        )
    }

    /// Builds the account picker using explicit `NSMenuItem` entries with `representedObject = account.id` (never
    /// `NSPopUpButton.addItem(withTitle:)`, which silently removes duplicate titles and shifts item indices).
    static func makeAccountPicker(for accounts: [LoginAccount]) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.autoenablesItems = false
        popup.removeAllItems()
        for account in accounts {
            let item = NSMenuItem(title: account.label, action: nil, keyEquivalent: "")
            item.representedObject = account.id
            popup.menu?.addItem(item)
        }
        if !accounts.isEmpty {
            popup.selectItem(at: 0)
        }
        return popup
    }

    static func selectedAccountID(from picker: NSPopUpButton?) -> UUID? {
        picker?.selectedItem?.representedObject as? UUID
    }

    static func requestLogin(
        client: String, url: URL, accounts: [LoginAccount], allowsManualTakeOver: Bool = true, reason: String?, in window: NSWindow?
    ) async -> LoginChoice {
        guard !AppDatabase.isRunningTests, window != nil else { return .decline }
        let sheet = loginSheet(
            client: client, url: url, accounts: accounts, allowsManualTakeOver: allowsManualTakeOver, reason: reason)
        let alert = NSAlert()
        alert.messageText = sheet.title
        alert.informativeText = sheet.message
        var picker: NSPopUpButton?
        if sheet.showsAccountPicker {
            let popup = makeAccountPicker(for: sheet.accounts)
            alert.accessoryView = popup
            picker = popup
        }
        for button in sheet.buttons {
            alert.addButton(withTitle: button.title)
            if button.isEscape {
                alert.buttons.last?.keyEquivalent = "\u{1b}"
            }
        }
        let response = await present(alert, in: window)
        let chosenID = sheet.showsAccountPicker ? selectedAccountID(from: picker) : nil
        return sheet.choice(
            forButton: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
            selectedAccountID: chosenID)
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
