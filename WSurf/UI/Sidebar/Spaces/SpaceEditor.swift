// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit

/// The sign-in profile of a new Space and the credential vault used by a new or existing Space.
@MainActor
enum SpaceEditor {
    struct Choice: Equatable {
        var name: String
        var symbol: String
        /// Nil when editing: a space never changes profile.
        var sharing: SpaceSharing?
        var vault: SpaceVaultReference?
    }

    struct SharingOption: Equatable {
        let id: UUID
        let name: String

        init(profile: Profile, among profiles: [Profile] = []) {
            id = profile.id
            name = profile.vaultPickerLabel(among: profiles)
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
    static func ask(
        editing space: Space?, sharing options: [SharingOption], currentProfile: UUID, vaults: SpaceVaultPicker.Choices, in window: NSWindow?
    ) async throws -> Choice? {
        let alert = NSAlert()
        alert.messageText = space == nil ? String(localized: "New Space") : String(localized: "Edit Space")
        alert.informativeText = String(localized: "A Space has its own tabs and folders. Its profile keeps its sign-ins and history. Choose a vault for passwords and passkeys.")
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
        let vault = SpaceVaultPicker(vaults, selected: space?.vault)
        let stack = NSStackView(views: [row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let signIns = sharingPicker(options, current: currentProfile)
        if space == nil {
            stack.addArrangedSubview(signIns)
        }
        stack.addArrangedSubview(NSTextField(labelWithString: String(localized: "Credential vault")))
        stack.addArrangedSubview(vault)
        if vaults.hasUnreadableProfile {
            let note = NSTextField(wrappingLabelWithString: String(localized: "Some vaults couldn’t be loaded. Reopen the editor to try again."))
            note.preferredMaxLayoutWidth = 320
            stack.addArrangedSubview(note)
        }
        stack.frame.size = stack.fittingSize
        alert.accessoryView = stack
        alert.window.initialFirstResponder = name

        let response: NSApplication.ModalResponse
        if let window = window ?? NSApp.keyWindow?.sheetHost {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let chosen: SpaceSharing?
        if space == nil {
            guard let selected = signIns.selectedItem else { throw SpaceEditorError.spaceUnavailable }
            chosen = sharing(selected.representedObject)
        } else {
            chosen = nil
        }
        return try choice(name: name.stringValue, symbol: icon.selectedItem?.representedObject as? String, sharing: chosen, vault: vault.selectedReference())
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
        separate.toolTip = String(localized: "A new profile with its own sign-ins and history.")
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
    static func choice(name: String, symbol: String?, sharing: SpaceSharing? = nil, vault: SpaceVaultReference? = nil) -> Choice? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Choice(name: trimmed, symbol: symbol ?? Space.defaultSymbol, sharing: sharing, vault: vault)
    }
}
