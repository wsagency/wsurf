// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Contacts
import ContactsUI
import SwiftUI

/// Shows the system's contact picker beside the button; the chosen contact is handed to `onSelect` and nothing else is read.
struct ContactImportButton: NSViewRepresentable {
    let onSelect: (CNContact) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: String(localized: "Choose Contact…"), target: context.coordinator, action: #selector(Coordinator.show(_:)))
        button.bezelStyle = .rounded
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.onSelect = onSelect
    }

    static func dismantleNSView(_ nsView: NSButton, coordinator: Coordinator) {
        coordinator.picker.close()
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var onSelect: (CNContact) -> Void
        let picker = CNContactPicker()

        init(onSelect: @escaping (CNContact) -> Void) {
            self.onSelect = onSelect
            super.init()
            picker.delegate = self
        }

        @objc func show(_ sender: NSButton) {
            picker.showRelative(to: sender.bounds, of: sender, preferredEdge: .maxY)
        }

        func contactPicker(_ picker: CNContactPicker, didSelect contact: CNContact) {
            onSelect(contact)
            picker.close()
        }
    }
}
