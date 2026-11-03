// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit

/// Names a new space or edits one: a name and an icon. The color is chosen for it, as Linen does. A new space also
/// chooses its sign-ins: those of an existing profile, or its own.
@MainActor
enum SpaceEditor {
    struct Choice: Equatable {
        var name: String
        var symbol: String
        /// Nil when editing: a space never changes profile.
        var sharing: SpaceSharing?
    }

    struct SharingOption: Equatable {
        let id: UUID
        let name: String

        init(profile: Profile) {
            id = profile.id
            name = profile.name
        }

        var title: String {
            String(localized: "Share sign-ins with “\(name)”")
        }
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
    static func ask(editing space: Space?, sharing options: [SharingOption] = [], currentProfile: UUID? = nil) async -> Choice? {
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
        let currentSymbol = space?.symbol ?? Space.defaultSymbol
        for symbol in symbols.contains(currentSymbol) ? symbols : [currentSymbol] + symbols {
            // Items share the empty title, so they go in through the menu: `addItem(withTitle:)` keeps one per title.
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
            item.representedObject = symbol
            icon.menu?.addItem(item)
        }
        icon.selectItem(at: icon.indexOfItem(withRepresentedObject: currentSymbol))
        icon.setAccessibilityLabel(String(localized: "Icon"))
        icon.sizeToFit()

        let row = NSStackView(views: [name, icon])
        row.orientation = .horizontal
        row.spacing = 8
        let signIns = sharingPicker(options, current: currentProfile)
        let stack = NSStackView(views: space == nil && !options.isEmpty ? [row, signIns] : [row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
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
        let chosen = space == nil && !options.isEmpty ? sharing(signIns.selectedItem?.representedObject) : nil
        return choice(name: name.stringValue, symbol: icon.selectedItem?.representedObject as? String, sharing: chosen)
    }

    /// One entry per profile ("Share sign-ins with …"), then "Separate sign-ins and data". The window's profile is
    /// chosen at first.
    private static func sharingPicker(_ options: [SharingOption], current: UUID?) -> NSPopUpButton {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        // Two profiles may share a name, so items go in through the menu, which keeps both.
        for option in options {
            let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
            item.representedObject = option.id
            picker.menu?.addItem(item)
        }
        picker.menu?.addItem(.separator())
        let separate = NSMenuItem(title: String(localized: "Separate sign-ins and data"), action: nil, keyEquivalent: "")
        separate.toolTip = String(localized: "A new profile with its own sign-ins, history and passwords.")
        picker.menu?.addItem(separate)
        if let current, let index = options.firstIndex(where: { $0.id == current }) {
            picker.selectItem(at: index)
        }
        picker.setAccessibilityLabel(String(localized: "Sign-ins and data"))
        picker.sizeToFit()
        return picker
    }

    static func sharing(_ selected: Any?) -> SpaceSharing {
        (selected as? UUID).map(SpaceSharing.profile) ?? .separate
    }

    /// The trimmed name and the icon, or nil for an empty name.
    static func choice(name: String, symbol: String?, sharing: SpaceSharing? = nil) -> Choice? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Choice(name: trimmed, symbol: symbol ?? Space.defaultSymbol, sharing: sharing)
    }
}
