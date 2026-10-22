// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Contacts
import ContactsUI
import SwiftUI

/// Shows the system's contact picker beside the button. Every contact clicked while it is open is collected, once; when it closes, the
/// collected contacts are handed to `onSelect` together and nothing else is read.
struct ContactImportButton: NSViewRepresentable {
    let onSelect: ([CNContact]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: String(localized: "Choose Contacts…"), target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onSelect = onSelect
    }

    /// The row is gone: what was clicked is dropped, not reviewed.
    static func dismantleNSView(_ nsView: NSButton, coordinator: Coordinator) {
        coordinator.onSelect = { _ in }
        coordinator.picker.close()
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var onSelect: ([CNContact]) -> Void
        let picker = CNContactPicker()
        /// The contacts clicked since the picker opened, in order, each once.
        private(set) var picked: [CNContact] = []

        init(onSelect: @escaping ([CNContact]) -> Void) {
            self.onSelect = onSelect
            super.init()
            picker.delegate = self
        }

        @objc func show(_ sender: NSButton) {
            picked = []
            picker.showRelative(to: sender.bounds, of: sender, preferredEdge: .maxY)
        }

        /// The picker stays open, so several contacts can be clicked in one go.
        func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
            if !picked.contains(where: { $0.identifier == contact.identifier }) {
                picked.append(contact)
            }
        }

        func contactPickerDidClose(_ picker: CNContactPicker) {
            let chosen = picked
            picked = []
            if !chosen.isEmpty {
                onSelect(chosen)
            }
        }
    }
}
