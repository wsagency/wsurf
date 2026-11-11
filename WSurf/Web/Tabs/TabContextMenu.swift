// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit

@MainActor
enum TabContextMenu {
    static let inspectItem = "WKMenuItemIdentifierInspectElement"

    static func linkWindowItems(opensPrivately: Bool, target: AnyObject, action: Selector) -> [NSMenuItem] {
        let privateWindow = NSMenuItem(
            title: String(localized: "Open Link in New Private Window"), action: action, keyEquivalent: ""
        )
        privateWindow.identifier = .init("WSurfOpenLinkInNewPrivateWindow")
        privateWindow.target = target
        privateWindow.tag = 1
        privateWindow.keyEquivalentModifierMask = []
        guard !opensPrivately else { return [privateWindow] }

        let window = NSMenuItem(
            title: String(localized: "Open Link in New Window"), action: action, keyEquivalent: ""
        )
        window.identifier = .init("WSurfOpenLinkInNewWindow")
        window.target = target
        window.keyEquivalentModifierMask = []
        privateWindow.isAlternate = true
        privateWindow.keyEquivalentModifierMask = .option
        return [window, privateWindow]
    }

    static let pasteItem = "WKMenuItemIdentifierPaste"

    /// WebKit offers Paste only where the right-click landed in something editable.
    static func isEditable(_ menu: NSMenu) -> Bool {
        menu.items.contains { $0.identifier?.rawValue == pasteItem }
    }

    /// "Pick Credential…" at the top of the menu, then a separator. The caller decides that the field is editable and that the
    /// policy offers it (`CredentialPicker.isOffered`), or, with a `refusal`, that it does not: the item is then disabled, has no
    /// action and names the reason in its title.
    @discardableResult
    static func addPickCredential(
        to menu: NSMenu, target: AnyObject, action: Selector, refusal: CredentialPicker.Refusal? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: refusal?.menuTitle ?? String(localized: "Pick Credential…"), action: refusal == nil ? action : nil, keyEquivalent: ""
        )
        item.identifier = CredentialPicker.menuItemIdentifier
        item.target = refusal == nil ? target : nil
        item.isEnabled = refusal == nil
        item.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
        menu.insertItem(item, at: 0)
        if menu.numberOfItems > 1 {
            menu.insertItem(.separator(), at: 1)
        }
        return item
    }

    static let linkTail = [
        "WKMenuItemIdentifierCopyLink",
        "WKMenuItemIdentifierShareMenu",
        "WKMenuItemIdentifierDownloadLinkedFile",
    ]

    static func sinkLinkTail(in menu: NSMenu) {
        let tail = linkTail.compactMap { identifier in
            menu.items.first { $0.identifier?.rawValue == identifier }
        }
        guard !tail.isEmpty else { return }
        for item in tail {
            menu.removeItem(item)
        }
        trimSeparators(in: menu)
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        for item in tail {
            menu.addItem(item)
        }
    }

    static func sinkInspect(in menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.identifier?.rawValue == inspectItem }) else { return }
        let index = menu.index(of: item)
        menu.removeItem(item)
        if index > 0, menu.items[index - 1].isSeparatorItem {
            menu.removeItem(at: index - 1)
        }
        trimSeparators(in: menu)
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(item)
    }

    private static func trimSeparators(in menu: NSMenu) {
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.numberOfItems - 1)
        }
    }
}
