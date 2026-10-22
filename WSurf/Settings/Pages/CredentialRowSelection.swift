// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// How a row of the credential list or of the Trash shows and takes the selection: a wash when it is selected, a ring on the keyboard
/// cursor, a leading checkbox while selecting, and its clicks. The row reads only its own `CredentialRowState` and the checkbox flag,
/// so a cursor move or a toggle redraws only the rows it changes, not every row that is built.
struct CredentialRowSelection: ViewModifier {
    let selection: CredentialSelection
    let id: UUID
    /// What the checkbox says it selects.
    let title: String
    /// A double click. `nil` where the row has no editor (the Trash).
    var open: (() -> Void)?
    /// What the "Move to Trash" or "Delete Permanently" accessibility action does.
    let remove: () -> Void
    let removeName: LocalizedStringKey

    private var state: CredentialRowState {
        selection.state(of: id)
    }

    private var isSelected: Bool {
        state.isSelected
    }

    private var selectName: LocalizedStringKey {
        isSelected ? "Deselect" : "Select"
    }

    func body(content: Content) -> some View {
        HStack(alignment: .center, spacing: 8) {
            if selection.showsCheckboxes {
                checkbox
            }
            content
        }
        .background { wash }
        .overlay { ring }
        .contentShape(.rect)
        .onTapGesture(perform: click)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: selectName) { selection.toggle(id) }
        .accessibilityAction(named: removeName, remove)
    }

    /// A click on the row itself (its buttons take their own). Plain: the cursor and the keyboard, or in selection mode a toggle.
    /// Command: toggles the row. Shift: the range from the anchor. Double: opens the editor, where there is one (not while selecting).
    private func click() {
        if NSApp.currentEvent?.clickCount == 2, let open, !selection.isSelecting {
            open()
            return
        }
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.command) {
            selection.toggle(id)
            selection.takeKeyboard()
        } else if modifiers.contains(.shift) {
            selection.extend(to: id)
            selection.takeKeyboard()
        } else {
            selection.click(id)
        }
    }

    @ViewBuilder
    private var wash: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor.opacity(0.14))
        }
    }

    @ViewBuilder
    private var ring: some View {
        if state.isCursor {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(selection.ownsKeyboard ? 0.9 : 0.35), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    /// Drawn, not an AppKit control: select all shows one in every built row at once, and creating a native checkbox per row was the
    /// largest part of that change. A click on it toggles the row; VoiceOver gets a button with the same action.
    private var checkbox: some View {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.system(size: 14))
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 16, height: 16)
            .contentShape(.rect)
            .onTapGesture { selection.toggle(id) }
            .accessibilityElement()
            .accessibilityLabel(isSelected ? Text("Deselect \(title)") : Text("Select \(title)"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { selection.toggle(id) }
    }
}

extension View {
    func credentialRowSelection(
        _ selection: CredentialSelection, id: UUID, title: String, open: (() -> Void)? = nil, remove: @escaping () -> Void,
        removeName: LocalizedStringKey
    ) -> some View {
        modifier(CredentialRowSelection(selection: selection, id: id, title: title, open: open, remove: remove, removeName: removeName))
    }
}
