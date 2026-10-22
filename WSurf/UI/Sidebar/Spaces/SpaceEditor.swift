// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit

/// Names a new space or edits one: a name and an icon. The color is chosen for it, as Linen does.
@MainActor
enum SpaceEditor {
    struct Choice: Equatable {
        var name: String
        var symbol: String
    }

    static let symbols = [
        "square.grid.2x2", "person", "person.2", "briefcase", "graduationcap", "book",
        "house", "building.2", "cart", "bag", "creditcard", "banknote",
        "flask", "hammer", "wrench.and.screwdriver", "paintbrush", "camera", "gamecontroller",
        "music.note", "film", "airplane", "car", "map", "leaf",
        "heart", "cross.case", "bolt", "flame", "sun.max", "moon",
        "globe", "terminal", "chart.bar", "envelope", "calendar", "folder",
        "tag", "key", "gift", "cup.and.saucer", "fork.knife", "star",
    ]

    /// Nil when the person cancels or leaves the name empty.
    static func ask(editing space: Space?) async -> Choice? {
        let alert = NSAlert()
        alert.messageText = space == nil ? String(localized: "New Space") : String(localized: "Edit Space")
        alert.informativeText = String(localized: "A space shows its own tabs and folders. Pins, Favorites, sign-ins, history and passwords stay with the profile.")
        alert.addButton(withTitle: space == nil ? String(localized: "Create Space") : String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        name.stringValue = space?.name ?? ""
        name.placeholderString = String(localized: "Space Name")
        name.setAccessibilityLabel(String(localized: "Space Name"))
        name.lineBreakMode = .byTruncatingTail

        let icon = NSPopUpButton(frame: .zero, pullsDown: false)
        let current = space?.symbol ?? Space.defaultSymbol
        for symbol in symbols.contains(current) ? symbols : [current] + symbols {
            icon.addItem(withTitle: "")
            icon.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            icon.lastItem?.representedObject = symbol
        }
        icon.selectItem(at: icon.indexOfItem(withRepresentedObject: current))
        icon.setAccessibilityLabel(String(localized: "Icon"))
        icon.sizeToFit()

        let stack = NSStackView(views: [name, icon])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        return choice(name: name.stringValue, symbol: icon.selectedItem?.representedObject as? String)
    }

    /// The trimmed name and the icon, or nil for an empty name.
    static func choice(name: String, symbol: String?) -> Choice? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Choice(name: trimmed, symbol: symbol ?? Space.defaultSymbol)
    }
}
