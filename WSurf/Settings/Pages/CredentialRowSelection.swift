// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// How a row of the credential list or of the Trash shows and takes the selection: a wash when it is selected, a ring on the keyboard
/// cursor, a check mark, and its clicks. The row reads `selection.selected` and `selection.cursor` itself, so a change redraws only
/// the rows that are built.
struct CredentialRowSelection: ViewModifier {
    let selection: CredentialSelection
    let id: UUID
    /// A double click. `nil` where the row has no editor (the Trash).
    var open: (() -> Void)?
    /// What the "Move to Trash" or "Delete Permanently" accessibility action does.
    let remove: () -> Void
    let removeName: LocalizedStringKey

    private var isSelected: Bool {
        selection.selected.contains(id)
    }

    private var selectName: LocalizedStringKey {
        isSelected ? "Deselect" : "Select"
    }

    func body(content: Content) -> some View {
        content
            .background { wash }
            .overlay { ring }
            .overlay(alignment: .bottomLeading) { mark }
            .contentShape(.rect)
            .onTapGesture(perform: click)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction(named: selectName) { selection.toggle(id) }
            .accessibilityAction(named: removeName, remove)
    }

    /// A click on the row itself (its buttons take their own). Plain: the cursor and the keyboard. Command: toggles the row. Shift: the
    /// range from the anchor. Double: opens the editor, where there is one.
    private func click() {
        if NSApp.currentEvent?.clickCount == 2, let open {
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
        if selection.cursor == id {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(selection.ownsKeyboard ? 0.9 : 0.35), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var mark: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .background(Circle().fill(.background))
                .padding(.leading, 17)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    func credentialRowSelection(
        _ selection: CredentialSelection, id: UUID, open: (() -> Void)? = nil, remove: @escaping () -> Void, removeName: LocalizedStringKey
    ) -> some View {
        modifier(CredentialRowSelection(selection: selection, id: id, open: open, remove: remove, removeName: removeName))
    }
}
